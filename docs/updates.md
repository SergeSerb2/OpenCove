# Sparkle updates

OpenCove uses the actual Sparkle 2.10.0 SDK and its standard native update UI.
The menu bar menu and About settings have **Check for Updates…**. Settings also
exposes automatic checks and automatic download/installation. Those controls read
and change Sparkle's own persisted properties. OpenCove does not store a second
copy of consent. It leaves `SUEnableAutomaticChecks`, `SUAutomaticallyUpdate`, and
`SUAllowsAutomaticUpdates` unset: Sparkle asks permission on a later launch, and
automatic downloads initially remain off. See the official
[setup](https://sparkle-project.org/documentation/),
[programmatic API](https://sparkle-project.org/documentation/programmatic-setup/),
[settings](https://sparkle-project.org/documentation/preferences-ui/), and
[policy](https://sparkle-project.org/documentation/customization/) guides.

## Pinned dependency and source archives

`Package.swift` has a direct SwiftPM binary target for the official
[2.10.0 release](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0).
Its fixed URL and SHA-256 match the upstream package manifest at commit
`eef1a539a373c1f1a320624b1130fc5de7b2e100`:

```text
https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip
17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959
```

There is no floating Git dependency and no `Package.resolved` for this binary-only
package. SwiftPM verifies the SDK archive checksum. A new dependency or lockfile
requires a source-allowlist/provenance review. Source ZIPs include `Package.swift`,
the validator's dependency identity, and the original Sparkle/third-party license.
They fetch this same pinned SDK when rebuilt; the SDK is not vendored in source
ZIPs. Network access or a trusted existing SwiftPM cache is needed for that step.

`SOURCE_MANIFEST.json` records the SDK identity, upstream revision, URL, checksum,
and license digest. The app also includes `SPARKLE_DEPENDENCY.json` and
`Sparkle-LICENSE.txt`. No Alcove source or assets are used.

## Release configuration: closed until supplied

Every release-variant build, including a local ad-hoc release, needs:

- `OPENCOVE_UPDATE_FEED_URL`: a real public HTTPS appcast URL without credentials,
  query, or fragment, ending in `.xml`.
- `OPENCOVE_UPDATE_PUBLIC_ED_KEY`: the maintainer's real base64 Ed25519 public key
  (exactly 32 decoded bytes). This public value is safe to include in a bundle.

The intended owned-domain endpoint is
`https://opencove.sergeserbinenko.com/appcast.xml`, subject to the parent's hosting
and DNS confirmation. It is a deployment target, not a claim that a feed exists.
Downloads should use immutable versioned paths on the same Cloudflare-backed
owned domain. The feed URL remains configurable. No hosting, DNS, release
publication, credential generation, or private key import is done by these tools.

Set these public environment values from maintained release configuration, then:

```sh
python3 script/package_release.py build --configuration release --variant release \
  --arch arm64 --output /absolute/fresh/bundle/OpenCove.app --signing adhoc
# Or, from clean committed source:
python3 script/package_release.py package --arch universal2 --signing developer-id
```

Missing or invalid configuration fails before SwiftPM runs. The script embeds
`SUFeedURL`, `SUPublicEDKey`, and `SUVerifyUpdateBeforeExtraction = true`. It does
not embed private signing material. `CFBundleVersion` is the canonical build
integer in `version.json`; increase it for every update, including beta updates.
Never reset it when the marketing version changes. Use a universal archive for a
single shared feed; separate architecture archives need separate feeds so an
Intel Mac cannot be offered an arm64-only app.

The public key must correspond to a real externally held Sparkle signing key.
An HTTPS URL and a well-formed public key do not prove feed availability, private
key ownership, or a working update. These remain explicit release gates.

## Framework packaging and signing

The builder copies the macOS SDK framework into
`Contents/Frameworks/Sparkle.framework`, with symlinks and executable modes intact.
The app links `@rpath/Sparkle.framework/Versions/B/Sparkle` and searches
`@executable_path/../Frameworks`. Build-machine runpaths are removed before
signing. SDK tools and the test app are not copied into OpenCove.

Both signing modes sign nested code inside out: Installer.xpc, Downloader.xpc,
Autoupdate, Updater.app, Sparkle.framework, then OpenCove.app. Developer ID mode
uses the same identity, secure timestamps, and hardened runtime throughout. Only
Downloader preserves its upstream entitlements; the validator limits these to
its optional sandbox/network entitlements. The host keeps its existing Apple
Events entitlement. Library validation is not disabled. `--deep` is used only to
verify signatures, never to sign. See Sparkle's
[manual signing instructions](https://sparkle-project.org/documentation/sandboxing/#code-signing).

The ZIP writer preserves framework links as Unix symlinks. The validator permits
only relative links contained within Sparkle.framework and rejects source ZIP
symlinks, archive traversal, links with children, escaping targets, and missing
link targets. It checks the actual framework version, app linkage/runpaths,
helper architectures/executable modes, licenses, dependency identity, and every
nested signature/team/runtime policy. Developer ID signing, notarization,
Gatekeeper, and real updates need validation on the final artifact.

## Local appcast/signing commands; no publication

Use Sparkle's actual CLI tools from the checksum-verified SDK. Keep the SwiftPM
scratch directory for the build. After that build, this read-only command finds
the tools without resolving or launching anything:

```sh
SPARKLE_BIN="$(python3 script/package_release.py sparkle-tools \
  --scratch-path /absolute/retained/swift/arm64)"
```

The tools are beside the downloaded `Sparkle.xcframework`, typically
`<scratch>/<arch>/artifacts/<package-identity>/Sparkle/bin/generate_appcast` and
`.../bin/sign_update`. Use the command's actual result; the snapshot package's
identity can differ from the checkout's. Temporary default scratch directories
are removed after builds. A missing SDK makes this command fail; it does not
fetch a second unchecked tool distribution.

After signing, notarizing (if requested), and stapling, use the final app ZIP.
Verify its SHA-256 against the retained `SHA256SUMS` and release JSON. Do not
recompress or modify the ZIP after it is signed for Sparkle. Create a fresh local
feed staging folder outside the release artifact directory. Copy only the final
app ZIP there; keep source ZIPs and release metadata out of the feed input.
`BUILD` must equal the app's `CFBundleVersion` and release JSON build. `LABEL`
must equal the release label. `KEY_FILE` must name an existing private Sparkle
EdDSA key file supplied by the maintainer, outside this repository and bundle,
with private permissions. Do not put the key value on the command line, in logs,
or in a public configuration file. These invocations do not read/write Keychain:

```sh
# Set RELEASE_DIR, APP_ZIP, FEED_DIR, BUILD, LABEL, and KEY_FILE to reviewed values.
(cd "$RELEASE_DIR" && shasum -a 256 -c SHA256SUMS)
mkdir "$FEED_DIR"
cp "$APP_ZIP" "$FEED_DIR/"
"$SPARKLE_BIN/generate_appcast" --ed-key-file "$KEY_FILE" \
  --download-url-prefix "https://opencove.sergeserbinenko.com/releases/$LABEL/" \
  --versions "$BUILD" --maximum-versions 2 --maximum-deltas 0 \
  -o "$FEED_DIR/appcast.xml" "$FEED_DIR"
```

The input set is one reviewed archive, the new item is bounded to the exact
build, and delta generation is disabled. `generate_appcast` extracts the real
bundle version, public key, minimum OS, and signature metadata. It must accept
the supplied key for that archive's embedded public key. Inspect its result and
require a matching `sparkle:version`, marketing version, minimum macOS 15,
archive length, HTTPS immutable download URL, and EdDSA enclosure signature.
Preserve the final archive hash with the feed for review. The official
[appcast format](https://sparkle-project.org/documentation/publishing/) describes
these fields. Do not upload until the parent validates the owned-domain endpoint
and final artifact. This command does not publish or change DNS.

For a manual enclosure/signature diagnostic, `sign_update --ed-key-file
"$KEY_FILE" "$APP_ZIP"` emits only public signature and length attributes.
`sign_update --verify --ed-key-file "$KEY_FILE" "$APP_ZIP" "$SIGNATURE"`
checks the archive signature. Never use the deprecated `-s` private-key argument
or run `generate_keys` as part of packaging. Appcast signing is optional and is
not required by this configuration; HTTPS and signed, pre-extraction-verified
update archives are required. Key rotation for this stricter extraction policy
needs the Developer ID signed DMG procedure described in Sparkle's setup guide.

## Isolated real updater verification

For unattended checks through Sparkle's own command interface, upstream has a
separate `sparkle-cli` Xcode scheme. It is **not** in the binary SDK archive.
The parent can separately check out the pinned upstream commit above, fetch its
pinned submodules, and build that scheme in an isolated derived-data directory.
Its product is `Build/Products/Release/sparkle.app/Contents/MacOS/sparkle` under
that directory. This integration does not build or bundle that tool.
The verified upstream entry point is
[`sparkle-cli/main.m`](https://github.com/sparkle-project/Sparkle/blob/eef1a539a373c1f1a320624b1130fc5de7b2e100/sparkle-cli/main.m).
For a copied verification bundle, `sparkle "$OLD_APP" --probe
--check-immediately --feed-url "$LOCAL_FEED" --user-agent-name OpenCoveVerification`
performs a real availability probe without installing. Its exit status is zero
when an update is available. Omitting `--probe` can replace the target and relaunch
it; reserve that for the parent's explicitly isolated two-version proof. A CLI
probe does not prove the app's menu, Settings, or consent UI.

Ordinary development builds have no feed or key. The updater is not constructed.
Release builds launched with `OPENCOVE_DATA_DIR` or `--control-port` also do not
construct it. This stays true even if stored Sparkle preferences enable checks.

For an explicit real loopback update check, use `build --variant development
--updater-test` with a loopback `OPENCOVE_UPDATE_FEED_URL` such as an actual local
server's `http://127.0.0.1:<port>/appcast.xml` and the matching externally supplied
public key. This option cannot be used with release variants or `package`.
Each such bundle gets a fresh `SUDefaultsDomain`, so it does not read or change
production or normal development Sparkle preferences. At launch it additionally
requires `--enable-isolated-updater` and a fresh private `OPENCOVE_DATA_DIR`.
Without both, it stays stopped. A local transport exception exists only in this
test bundle. Sparkle itself performs checks and verifies real signed archives;
there is no mock driver or custom update implementation.

A full update proof needs two isolated copies with the same development bundle
identifier and trust key, increasing build numbers, a real loopback server/feed,
and a final newer archive signed with that key. Start the older copy in a private
writable location. Use its real menu/Settings action, accept Sparkle's update,
verify replacement and relaunch into the newer build, and retain the new bundle
version/hash plus old/new data continuity. Repeat for no update, missing feed,
invalid key/signature, corrupted archive, and an older offered version. Prove
ordinary development/control launches make zero feed requests, and prove opt-in
persistence independently. Do not update any installed or personal copy.

A local ad-hoc two-version result does not prove Developer ID identity continuity,
notarized downloaded-update behavior, app translocation, permissions after a
signed replacement, delta updates, or the public Cloudflare feed. Those require
separate owned release/account and runtime evidence. No such proof is claimed
by adding this integration.
