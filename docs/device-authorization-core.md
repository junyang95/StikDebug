# Shared device authorization core

> 历史版本记录：0.1.9 (10) 已移除商业授权并改用内置 DDI。本文中的授权和联网下载机制不再适用；当前行为见 [精简版说明](simplified-setup-and-bundled-ddi.md)。

`DeviceAuthorizationCore.swift` is versioned verbatim in both app branches: PikminHelper uses `StikDebug/Core/DeviceAuthorizationCore.swift`; JITLauncher uses `App/Models/DeviceAuthorizationCore.swift`. Neither build depends on an absolute machine path or the other checkout. Change the shared source in both branches together and check byte-for-byte parity with `python3 Tools/check-device-authorization-parity.py <jit-checkout>` or JIT's `scripts/check-device-authorization-parity.py <pikmin-checkout>`.

The shared Foundation/CryptoKit source owns signed payload decoding, pinned P-256 verification, nonce checks, policy evaluation, the seven-day clock, persistent clock state, and automatic signing-identity parsing. Platform adapters own Keychain, transport, UI state and paired-device I/O. Pikmin uses thin aliases/wrappers and keeps its existing VIP policy and setup flow.

## Policies

- `.vip`: VALID, VIP, unbanned; expires at the earlier of signed timestamp + 7 days or VIP membership expiry. Old signed payloads without `isRegistered` remain compatible with this policy.
- `.registeredUnbanned`: `isRegistered` must be signed and exactly true; either ban flag or BANNED status refuses use. Registered ordinary and expired-VIP devices are allowed. VIP membership expiry does not shorten this policy's signed timestamp + 7-day period.

JIT requests app-shop.cn first, wow-app.store second, with one unpredictable nonce shared within a round and independent 10-second endpoint deadlines. Signed bans/non-registration stop fallback. A missing signed registration field may try the other endpoint but never creates or restores an offline grant. There is no unsigned legacy-registration fallback: deploy the compatible backend first. Invalid signatures and network/HTTP failures cannot issue new grants, but a previously verified unexpired binding may remain usable.

## Setup, binding and storage

First-step candidates come from a bounded wowvip.plist UDID or exactly one valid provisioning-profile UDID. These inputs never select servers, keys or permissions. Candidate precheck stores its signed envelope in RAM only and never opens a tool gate. A real UDID read from the paired device must match before cache persistence. Missing candidates permit setup connectivity; every protected operation still requires the real-device authorization. Pairing digest plus connection mode binds the JIT cache, and the policy is included in the record and Keychain namespace.

Each later protected operation reads the actual UDID and verifies online, falling back to an existing bound cache only for availability errors. UI strings never grant access: icon reads consult the in-memory lease; a new action still uses the authorization session. Cancellation and operation generations reject late results. The first local bind after a fresh online precheck reports online, while restored cache reports its offline deadline.

Both adapters confirm a DeviceOnly Keychain request barrier before networking. Authenticated refusals leave that barrier intact even if old-cache deletion fails. New bound grants require confirmed cache write and security-state commit. First-step signed prechecks may persist security state, but no device grant. Storage unavailability fails closed. Intentional cancellation/transport failures may restore the previous trusted state; a process crash during the request requires fresh online verification.

Trusted server time, a persisted highwater and same-boot uptime prevent common clock rollback and repeated app restart from refilling seven days. Fresh nonce-bound signatures can recover a wrong wall clock. Normal device reboot still supports offline use. Without a hardware trusted clock, deliberate reboot plus wall-time manipulation that never crosses the persisted highwater cannot be fully detected offline; this is not a claim of complete tamper resistance.

Once JIT has been enabled in another process, denying future launcher actions cannot revoke that process's existing JIT entitlement.

## Local regression checks

- Pikmin: `Tools/test-pikmin-runtime.sh`.
- JIT signed policy and bounded mock transport: `bash scripts/test-wow-device-access.sh`.
- JIT candidate/binding/cache/cancellation/clock and injected Keychain failures: `bash scripts/test-launcher-authorization.sh`.

All authorization tests use fixture signing keys, mocked transport and memory persistence. They do not use real device IDs, production license endpoints or the user's Keychain.
