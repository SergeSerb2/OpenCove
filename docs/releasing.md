# Manual releases

Releases are cut by a maintainer. No workflow publishes, creates tags/releases, signs with a secret, or uploads a binary. CI uses read-only repository permissions and standard runners only, guarded to run in public repositories. [GitHub documents standard hosted runners as free for public repositories](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job). No cache or hosted artifact upload is configured.

## Version and source gates

`version.json` is the single packaging version input. `version` is a three-part numeric marketing version (up to 9999.99.99). `build` is an increasing decimal integer from 1 to 9999, without leading zeroes. It is a valid canonical `CFBundleVersion`, not a Unix epoch. `prerelease` is empty or `alpha.N`, `beta.N`, or `rc.N` (1–9999). Increase the build before a new distributed binary. Do not reuse a version/build for a changed release. These scripts do not infer a build number from the date or Git history.

The filename label includes the prerelease, for example `0.1.0-beta.1`; the bundle's `CFBundleShortVersionString` is `0.1.0` and `CFBundleVersion` is `1`. The architecture is verified against Mach-O slices. Names distinguish `adhoc` from `developer-id`. Signing timestamps/toolchain output mean binary archives are not claimed byte-reproducible.

Package only a stable clean committed checkout. Stage only intended public source after review. The source allowlist excludes `.local`, `.codex`, raw research, private reviews, runtime data, tokens, keys, generated bundles, and Git internals. Unexpected tracked files fail the gate. The concise public [quality guide](quality.md) and `script/control_e2e.py` are permitted. All raw `docs/audits/` reports remain ignored and are rejected by the allowlist, including with `--allow-dirty`. New source paths require an allowlist review. Basic credential-pattern checks supplement that review; they cannot prove an arbitrary file has no secret.

```sh
python3 script/validate_release.py version
python3 script/validate_release.py source
```

Run the [real integration workflow](quality.md), inspect its native renders, and close or disclose the relevant manual compatibility gates before describing a binary as ready. Retain the results outside the public source if they contain private state. Update the changelog and version before committing the intended release source. The scripts never stage or commit.

## Local ad-hoc archive

Release builds include the native Sparkle updater. First supply the real public
`OPENCOVE_UPDATE_FEED_URL` and `OPENCOVE_UPDATE_PUBLIC_ED_KEY` configuration in
[the update guide](updates.md). Missing configuration stops before compilation.
The intended feed is on OpenCove's owned Cloudflare domain, pending deployment
confirmation. No feed or release is published by the packaging command.

```sh
python3 script/package_release.py package --arch arm64 --signing adhoc
```

The default output is `dist/releases/OpenCove-0.1.0-beta.1-arm64-adhoc/`:

- `OpenCove-0.1.0-beta.1-arm64-adhoc.zip` — optimized app with MIT license, source/provenance notice, adapter source, and source manifest.
- `OpenCove-0.1.0-beta.1-source.zip` — allowlisted source, public docs, icon, scripts, and `SOURCE_MANIFEST.json`; no `.git` or private local state.
- `OpenCove-0.1.0-beta.1-arm64-adhoc-release.json` — exact version, architecture, source hashes, toolchain, and signing/notarization status.
- `SHA256SUMS` — SHA-256 hashes for the other three files.

Use `--output-dir` for a different fresh directory. Existing output directories fail rather than silently replacing a prior release. Packaging verifies the completed ZIPs after extraction, framework symlinks, executable modes, source hashes, nested signatures, architecture, and checksums. It never installs or launches the app. Metadata includes the public Sparkle feed/key policy. The source manifest records the exact SDK identity and checksum.

An ad-hoc signature is a local code-integrity signature. It is not an Apple distribution identity or notarization, and macOS can block a downloaded archive. Label it clearly if publishing it for beta use. Source builds remain the current primary installation path.

## Opt-in Developer ID and notarization

The Developer ID path requires the certificate below. An Apple Development certificate cannot satisfy it. A configured pipeline does not establish a signed artifact, Apple acceptance, Gatekeeper behavior, or permission/media compatibility. Record those results for the exact distributed artifact.

A maintainer must have a **Developer ID Application** certificate and its private key in a local keychain. Do not commit/export the key into the repository. Supply its full nonsecret identity name:

```sh
OPENCOVE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID1234)' \
python3 script/package_release.py package --arch arm64 --signing developer-id
```

For an identity in an existing isolated keychain, also set
`OPENCOVE_SIGN_KEYCHAIN` to its absolute path. It must be a regular file owned by
the current user. The parent prepares/unlocks that keychain separately; these
scripts never create, import, unlock, or change a keychain search list. Identity
discovery uses `security find-identity -v -p codesigning <keychain-path>`; every
host/framework/helper signing command uses `codesign --keychain <keychain-path>`.
The system tool help confirms that `security` takes a positional keychain operand
and `codesign` uses the named flag. Apple's `codesign` manual says intermediate
certificate-chain lookup can still consult the existing search list. It is never
mutated here. Supply a complete, valid identity/chain through the parent's setup.

The bundle validator accepts the same optional path and checks its ownership and
type. Verification inspects embedded signatures, certificate class, and team
through Security.framework; it does not find or read private keys. The
`codesign --keychain` option selects an identity only during signing, so it is
not applied to `codesign --verify`. A signature remains portable to machines
without the signing keychain. The notary-profile path is unchanged and independent
of this signing-keychain option.

This enables hardened runtime and a secure signing timestamp. The only added entitlement is `com.apple.security.automation.apple-events`, for the optional Music/Spotify Apple Events path. There is no App Sandbox, `get-task-allow`, disabled library validation, or blanket entitlement inheritance. Do not add exceptions without a demonstrated feature need and revalidation.

Sparkle's nested helpers and framework are signed individually from the inside
out before the host. Its optional Downloader entitlements are preserved and
checked separately. The host entitlement above is not copied to helpers. See
[the framework and appcast workflow](updates.md) before shipping updates.

Validation checks each Mach-O architecture through the Security framework. An Apple certificate requirement verifies the Developer ID Application certificate class and binds its team to the signed team identifier. Structured fields must show hardened runtime, a timestamp authority's signing timestamp, the same team across slices, and exactly the entitlement above. Human-readable `codesign` diagnostics are not signing evidence. The helper requires the selected Xcode Swift toolchain even for a standalone bundle check.

Signing alone does not notarize. Following [Apple's notary workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), store credentials privately with `xcrun notarytool store-credentials`. Never put the credential value in a command in shared logs, CI, or a public issue. Then opt in to the Apple upload:

```sh
OPENCOVE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID1234)' \
OPENCOVE_NOTARY_PROFILE='OpenCove-notary' \
python3 script/package_release.py package --arch arm64 --signing developer-id --notarize
```

The script waits for `Accepted`, staples the ticket, validates it, and runs `spctl --assess` on both the staged app and extracted ZIP. A failure leaves no final artifact directory. It does not publish. Incorrect/partial identity/profile combinations and an Apple Development identity fail closed. Local ad-hoc builds reject ambient signing/notary configuration instead of silently ignoring it.

See [Apple's Developer ID guidance](https://developer.apple.com/developer-id/) for certificate requirements and [notarization guidance](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) for hardened runtime requirements.

## Source-archive and final checks

For a source-only preview while files are intentionally uncommitted:

```sh
python3 script/package_release.py source-archive --allow-dirty \
  --output .local/archive-check/OpenCove-0.1.0-beta.1-source.zip
```

That preview records `dirty: true` and is not a release. Production `package` never accepts dirty source. Both exports use the same archive writer. Extract the ZIP outside the checkout with `ditto -x -k`, confirm `.git` is absent, and build it with a fresh output/scratch directory using [the normal local command](building.md). The embedded manifest is validated without Git. Modifying an exported source file or losing its executable mode fails that check.

Exports verify the actual file bytes and executable modes as they are read. Bundle builds use a separate manifest-only source snapshot, including the icon and bundled notices. Extra version-specific SwiftPM manifests and linked source directories are rejected. Ignored local evidence and build directories remain outside that snapshot. Keep the checkout stable until the final source-change check completes.

```sh
python3 script/validate_release.py artifacts dist/releases/OpenCove-0.1.0-beta.1-arm64-adhoc
(cd dist/releases/OpenCove-0.1.0-beta.1-arm64-adhoc && shasum -a 256 -c SHA256SUMS)
```

Before public launch, enable GitHub private vulnerability reporting and check the repository's public file list. Create a release manually only after reviewing the final artifacts. Attach the matching source archive, release metadata, and checksums. State beta limits and actual signing status in the release notes. GitHub's automatically generated source snapshots do not include the exported manifest; they are distinct from the attached source ZIP. Do not claim notarization from a configured option or an ad-hoc build.
