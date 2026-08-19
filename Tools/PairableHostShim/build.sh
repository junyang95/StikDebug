#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
    echo "usage: $0 /path/to/locus/libidevice_ffi.a /path/to/locus/idevice.h /path/to/output.a" >&2
    exit 64
fi

input_archive=$1
input_header=$2
output_archive=$3
script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/pikmin-pairable.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT

sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
header_directory=$(dirname -- "$input_header")

clang \
    -target arm64-apple-ios18.0 \
    -isysroot "$sdk_path" \
    -I "$header_directory" \
    -c "$script_directory/pikmin_pairable_wrapper.c" \
    -o "$temporary_directory/wrapper.o"

ld \
    -r \
    -arch arm64 \
    -syslibroot "$sdk_path" \
    -force_load "$input_archive" \
    "$temporary_directory/wrapper.o" \
    -exported_symbols_list "$script_directory/exported_symbols.txt" \
    -o "$temporary_directory/isolated.o"

libtool -static -o "$output_archive" "$temporary_directory/isolated.o"
