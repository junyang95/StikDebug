#!/bin/zsh
set -euo pipefail

usage() {
  echo "Usage: $0 <input.ipa> <signing.p12> <profile.mobileprovision> <output.ipa>"
  echo "Set P12_PASSWORD in the environment."
}

if [[ $# -ne 4 ]]; then
  usage
  exit 64
fi

: "${P12_PASSWORD:?P12_PASSWORD is required}"

input_ipa=$1
p12=$2
profile=$3
output_ipa=$4

for path in "$input_ipa" "$p12" "$profile"; do
  if [[ ! -f "$path" ]]; then
    echo "Missing input: $path" >&2
    exit 66
  fi
done

for command_name in security plutil openssl unzip zsign; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command not found: $command_name" >&2
    exit 69
  fi
done

if unzip -Z1 "$input_ipa" | grep -Eq '/PlugIns/[^/]+\.appex/'; then
  echo "This IPA contains an app extension and requires separate extension and host profiles." >&2
  echo "The single-profile signing command intentionally refuses to produce an invalid IPA." >&2
  exit 65
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

profile_plist="$work_dir/profile.plist"
entitlements_plist="$work_dir/entitlements.plist"
p12_certificate="$work_dir/p12-certificate.pem"

security cms -D -i "$profile" > "$profile_plist"

prefix=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationIdentifierPrefix:0' "$profile_plist")
team_id=$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$profile_plist")
application_identifier=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$profile_plist")
bundle_id=${application_identifier#${prefix}.}

if [[ "$application_identifier" != "${prefix}.${bundle_id}" ]]; then
  echo "Unable to derive Bundle ID from profile App ID: $application_identifier" >&2
  exit 65
fi

healthkit=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.healthkit' "$profile_plist" 2>/dev/null || true)
if [[ "$healthkit" != "true" ]]; then
  echo "The provisioning profile does not authorize HealthKit." >&2
  exit 65
fi

openssl pkcs12 \
  -in "$p12" \
  -clcerts \
  -nokeys \
  -passin "pass:${P12_PASSWORD}" \
  -out "$p12_certificate" \
  >/dev/null 2>&1
p12_fingerprint=$(openssl x509 -in "$p12_certificate" -noout -fingerprint -sha1 | cut -d= -f2)

certificate_matches=false
index=0
while encoded_certificate=$(plutil -extract "DeveloperCertificates.${index}" raw -o - "$profile_plist" 2>/dev/null); do
  certificate_path="$work_dir/profile-${index}.der"
  print -r -- "$encoded_certificate" | base64 -D > "$certificate_path"
  profile_fingerprint=$(openssl x509 -inform DER -in "$certificate_path" -noout -fingerprint -sha1 | cut -d= -f2)
  if [[ "$profile_fingerprint" == "$p12_fingerprint" ]]; then
    certificate_matches=true
    break
  fi
  (( index += 1 ))
done

if [[ "$certificate_matches" != "true" ]]; then
  echo "The P12 certificate is not authorized by the provisioning profile." >&2
  exit 65
fi

/usr/libexec/PlistBuddy -c 'Clear dict' "$entitlements_plist"
/usr/libexec/PlistBuddy -c "Add :application-identifier string ${application_identifier}" "$entitlements_plist"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string ${team_id}" "$entitlements_plist"
/usr/libexec/PlistBuddy -c 'Add :com.apple.developer.healthkit bool true' "$entitlements_plist"
/usr/libexec/PlistBuddy -c 'Add :keychain-access-groups array' "$entitlements_plist"
/usr/libexec/PlistBuddy -c "Add :keychain-access-groups:0 string ${application_identifier}" "$entitlements_plist"

get_task_allow=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:get-task-allow' "$profile_plist" 2>/dev/null || true)
if [[ -n "$get_task_allow" ]]; then
  /usr/libexec/PlistBuddy -c "Add :get-task-allow bool ${get_task_allow}" "$entitlements_plist"
fi

echo "Signing for Team ${team_id}, Bundle ID ${bundle_id}"
zsign \
  -f \
  -k "$p12" \
  -p "$P12_PASSWORD" \
  -m "$profile" \
  -b "$bundle_id" \
  -e "$entitlements_plist" \
  -o "$output_ipa" \
  "$input_ipa"

zsign -C "$output_ipa"
echo "Signed IPA: $output_ipa"
