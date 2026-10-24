# Optional Developer ID KVS packaging

This is a draft source contract. No real provisioning profile, signing identity,
signed artifact, system-policy result, or two-Mac iCloud result has been validated
for this path. It does not enable or prove cloud delivery. Default builds and
packages still omit KVS and provisioning profiles. Default Developer ID signing
still claims only `com.apple.security.automation.apple-events = true`.

## Apple assets and identifiers

The release owner must supply an unmodified **Apple-issued Developer ID
distribution provisioning profile**, the matching usable **Developer ID
Application** signing identity, and the authorized full KVS identifier. The
registered explicit App ID must match `org.opencove.OpenCove` and authorize
iCloud **Key-value storage**. These scripts do not create profiles, register
App IDs, enable account capabilities, obtain credentials, or change keychains.
Keep profiles outside the repository. No sample profile is supplied.

Apple's [macOS capability table](https://developer.apple.com/help/account/reference/supported-capabilities-macos/)
lists KVS for Developer ID. The [Foundation class page](https://developer.apple.com/documentation/foundation/nsubiquitouskeyvaluestore)
still describes App Store distribution as required. This documentation difference
does not establish service acceptance for OpenCove. KVS alone needs no CloudKit
database or invented `iCloud.` document container.

Keep these three identifiers separate:

- The signing Team ID comes from the real certificate and profile.
- The macOS App ID comes from the profile's explicit
  `com.apple.application-identifier`, with the registered bundle ID as its suffix.
  Its App ID prefix can differ from the signing Team ID.
- The KVS value must be the full authorized store identifier, already resolved.
  This product accepts a ten-character uppercase letter/digit prefix, one period,
  and exactly `org.opencove.OpenCove`. It does not support shared-store suffixes
  or the `.dev` bundle. Its prefix need not equal the current Team ID or App ID
  prefix, for example after an app transfer. Never derive it from either value.

Apple's [KVS entitlement guide](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingiCloud.html)
describes `$(TeamIdentifierPrefix)$(CFBundleIdentifier)` for the usual same-app
configuration. Raw `codesign` input needs its resolved value. Apple's
[transfer guidance](https://developer.apple.com/help/app-store-connect/transfer-an-app/overview-of-app-transfer/)
requires the full value from the newly issued profile for a transferred KVS app.
[TN2415](https://developer.apple.com/library/archive/technotes/tn2415/)
explains the separate App ID prefix. Neither a wildcard nor a build variable is
a valid signed KVS value. A legitimate profile with a different product identity
needs a separate reviewed contract; do not change its fields to pass this one.

## Explicit ingestion

Only `package` accepts `--provisioning-profile` and `--kvs-identifier`. Supply both
or neither. There is no automatic environment-variable fallback for these flags.
The profile path must be absolute, with no symlink components or parent traversal.
The file must already exist, be regular and owned by the caller, and contain
between 1 byte and 1 MiB. The packager reads it once through file descriptors and
uses those exact bytes. It does not rewrite the CMS object.

The optional path requires `--signing developer-id --notarize`. This is stricter
than the default path because it must pass system provisioning checks before
retaining an output. It uses the existing explicitly authorized Apple upload.
`OPENCOVE_NOTARY_PROFILE` / `--notary-profile` names a **notary credential
profile**, which is different from the supplied **app provisioning profile**.

Before identity discovery, the decoded profile's Team ID must match the suffix
of the requested identity name. The name alone does not authorize a certificate.
The packager resolves that name to one usable identity fingerprint, reads the
actual public certificate DER from the same keychain scope, and checks its
SHA-256 against `DeveloperCertificates`. An ambiguous name or unauthorized
certificate stops before toolchain discovery, build, host/helper private-key
signing, or Apple upload. The build entry repeats this preflight and requires the
same selected certificate. Signing uses the checked certificate's SHA-1
fingerprint as the exact `codesign` selector;
SHA-256 of its DER remains the profile-authorization predicate. The optional
release JSON records this selected fingerprint in `identity`.

After the release owner has prepared the real assets and the existing public
updater configuration from [updates.md](updates.md), run from clean committed
source. The variables below must contain the actual caller configuration:

```sh
python3 script/package_release.py package --arch universal2 \
  --signing developer-id --notarize \
  --notary-profile "${OPENCOVE_NOTARY_PROFILE:?Use the existing notary credential profile}" \
  --provisioning-profile "${OPENCOVE_KVS_PROFILE:?Set the actual external profile path}" \
  --kvs-identifier "${OPENCOVE_KVS_IDENTIFIER:?Set the authorized full KVS value}" \
  --output-dir /absolute/fresh/release-output
```

The host claims exactly four entitlements: the existing Boolean automation
entitlement and the profile-bound team, explicit macOS App ID, and resolved KVS
identifier. It does not copy the profile's full entitlement allowlist. Debugging,
sandbox exceptions, Documents, CloudKit, and push capabilities are not added.
Automation is an unrestricted hardened-runtime claim on macOS; it does not need
the profile's permission. The three restricted identity/KVS claims must match
the profile contract and pass the system check.

The packager embeds `Contents/embedded.provisionprofile` before final host
`codesign`. Sparkle signing, its upstream trust key, dependency pin, source
provenance, and nested entitlement rules are unchanged. Helpers receive no host
entitlements or profile. The ZIP includes the exact embedded bytes. Its release
JSON `provisioning` record contains the profile digest, UUID, validity dates,
team, App ID, and resolved KVS identifier. Extraction rechecks these values and
the profile digest. The source ZIP contains no provisioning profile. Review the
distribution profile's contents before sharing the binary; do not publish raw
account diagnostics or private signing material as evidence.

## Authentication and validation boundary

[TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
describes CMS wrapping, profile placement, certificate authorization, validity,
entitlement allowlists, and the authoritative DER profile on modern systems.
Its plist layout can change. The narrow profile reader rejects unsupported or
inconsistent fields; it does not claim to implement Apple's profile policy.
It checks `ProvisionsAllDevices = true`, absence of a device list or debug grant,
current validity, one team, explicit App ID, and KVS authorization. It permits
an exact KVS grant or a matching terminal prefix wildcard in the profile only.
`ProvisionsAllDevices` alone is not channel proof: the actual Developer ID
Application certificate binding and the system provisioning decision are also
required.

**`security cms -D` only decodes the profile; it does not authenticate it.**
The public [CMSDecoder signer-status API](https://developer.apple.com/documentation/security/cmsdecodercopysignerstatus(_:_:_:_:_:_:_:))
requires a caller-selected trust policy. The reviewed public Security SDK
`CMSDecoder.h` and `SecPolicy.h` do not establish a provisioning-profile signer
policy for this implementation. Generic X.509 trust, certificate display names,
or guessed private OIDs cannot replace that policy.

Instead, `/usr/bin/syspolicy_check distribution APP` is mandatory for both the
staged signed/notarized host and the extracted final ZIP. Apple's installed
`syspolicy_check(1)` manual explicitly includes provisioning-profile checks in
`distribution`, alongside execution-policy checks. Read it with
`man syspolicy_check`. [TN3161](https://developer.apple.com/documentation/technotes/tn3161-inside-code-signing-certificates)
directs Developer ID verification to this system tool. A missing tool or failed
system decision stops packaging; there is no decode-only fallback or skip flag.
This requires the documented system distribution checks. It does not establish
the exact authentication guarantees for the supplied CMS bytes or authoritative
DER representation. Those guarantees remain open and need real-profile evidence
and a supported policy basis. No private CMS trust policy is implemented here.

Every requested Mach-O architecture also passes the existing Security.framework
signature, Apple Developer ID Application class, team, hardened-runtime, and
secure-timestamp checks. The validator requires exactly the selected main-app
entitlement set and binds that slice's actual leaf certificate to a certificate
in the profile. Sparkle checks remain separate. Plist matches and static
signature checks cannot override a failed system provisioning decision.

For the actual extracted app and output directory:

```sh
python3 script/validate_release.py bundle /absolute/extracted/OpenCove.app \
  --arch universal2 --signing developer-id --notarized \
  --kvs-identifier "${OPENCOVE_KVS_IDENTIFIER:?Set the authorized full KVS value}"
python3 script/validate_release.py artifacts /absolute/release-output
```

These commands run real system validation and need the trusted local validation
scripts and selected Swift toolchain. No script from the inspected source ZIP
is executed as a validation tool.

## Negative command gates and remaining proof

These are required caller checks, not results from this source-only change.
Each incomplete pair must fail before profile reads, identity lookup, build,
signing, or upload:

```sh
python3 script/package_release.py package --signing developer-id \
  --provisioning-profile "${OPENCOVE_KVS_PROFILE:?Set the actual external profile path}"
python3 script/package_release.py package --signing developer-id \
  --kvs-identifier "${OPENCOVE_KVS_IDENTIFIER:?Set the authorized full KVS value}"
```

A complete pair with ad-hoc signing or without `--notarize` must also fail before
those operations. With the correct channel selected, nonexistent, empty,
oversized, unowned, nonregular, or symlinked profile inputs must fail. Wildcard,
unresolved-variable, wrong-suffix, or malformed signed identifiers must fail.
Expired/not-yet-valid, development/device-limited, wrong-team/App-ID/KVS, or
wrong-certificate profiles must fail. In particular, a wrong-team profile must
stop before identity discovery. A profile for another certificate on the same
team must stop before build, host/helper private-key signing, or Apple upload.
An edited, unsigned, or untrusted CMS object must never pass the system gate even
if its plist fields match. Extra
host entitlements, a profile in a helper, dropped/changed ZIP profile bytes, and
missing provisioning metadata must fail. Real asset-dependent negative cases
remain for the release owner; do not fabricate a grant to claim coverage.

No real command above, Swift typecheck, build, signing, notary submission,
system-profile check, install, launch, account operation, or service flow was run
for this draft or its signing-order repair. Static source parsing cannot prove
those results or exact CMS/DER authentication. The release owner must verify the
exact final digests, notarization/stapling, system policy,
and normal installation/launch on a clean Mac without the signing keychain or
Xcode profile library. Track the actual profile expiration and replacement
release; [Apple's Developer ID guidance](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
explains that required profiles are checked at installation and launch.

Then prove the integrated opt-in controller on two explicitly authorized real
Macs with the same validation Apple account and app/KVS identity. Keep the second
Mac opted out first. Verify real Settings values and saved local state after
delivery and relaunch in both directions. Include conflict/offline recovery,
opt-out/reset, pending writes across restart, and account changes. Confirm that
the controller's Drive identity-token gate works for the KVS-only package.
A local cache, identity token, `synchronize()` return, successful signature, or
successful system-policy check does not prove cross-device delivery. Leave
unobserved service cases open. Packaging does not replace that acceptance work.
