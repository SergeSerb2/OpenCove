# Building OpenCove

## Toolchain and targets

Use Xcode 26 or later with a macOS 26+ SDK, Swift 6+, and Python 3.9+. The source uses guarded macOS 26 glass APIs; Command Line Tools with an older SDK cannot compile them. Check `xcodebuild -version`, `xcrun swift --version`, and `xcrun --sdk macosx --show-sdk-version`. Set `DEVELOPER_DIR` to select an installed Xcode without changing the system selection.

The deployment target is macOS 15. Local evidence is Xcode 27.1 / Swift 6.4 / macOS 27 SDK on arm64 macOS 27.2. Xcode 26.2 on the standard `macos-15` GitHub runner is a CI target, not a locally proven minimum. macOS 15/26 runtime and Intel compatibility still need verification.

## Local bundles

```sh
./script/build_and_run.sh --build     # Debug, development identity, no launch
./script/build_and_run.sh             # Debug, development identity, launch
./script/build_and_run.sh --release   # Optimized, release identity, no launch
```

All three use ad-hoc signatures. None installs an app, requests Developer ID credentials, or uploads to Apple. `--release` is a local optimized build, not a published or notarized release. Quit a running app before replacing its bundle. The script refuses to overwrite a running destination and does not kill an app.

Choose a new private directory for a separate bundle and scratch build:

```sh
OPENCOVE_BUILD_ROOT="$(mktemp -d /tmp/opencove-build.XXXXXX)"
OPENCOVE_OUTPUT_DIR="$OPENCOVE_BUILD_ROOT/bundle" \
OPENCOVE_SCRATCH_PATH="$OPENCOVE_BUILD_ROOT/swift" \
OPENCOVE_ARCH=arm64 ./script/build_and_run.sh --build
```

`OPENCOVE_ARCH` accepts only `arm64`, `x86_64`, or `universal2`. A universal build compiles each architecture separately and combines them with `lipo`. Runtime support for both architectures is a separate gate. Scratch paths default to a temporary directory, which is removed after the build. An explicitly chosen scratch path can retain compiler output for local reuse.

The builder generates a fresh icon and bundle, copies the adapter source and MIT license, checks the signature and architecture, then replaces the destination. It never writes into an Applications folder. All versions come from `version.json`; malformed values stop before compilation.

Each bundle build first copies only manifest-listed files into a fresh private source snapshot. It checks the actual copied bytes and executable modes, then runs SwiftPM and icon generation there. Alternate `Package@*.swift` manifests and symlinked source directories fail before compilation. Ignored evidence, `.swiftpm` settings, and old build output stay in the original folder and do not enter the snapshot. A source change during copying or building discards the build.

## Source ZIPs without Git

Extract the project-generated `OpenCove-<version>-source.zip`, enter its top-level folder, and use the same build commands. No `.git` directory is required. The builder verifies `SOURCE_MANIFEST.json`, public paths, file digests, and executable modes. Extract with a tool that preserves Unix executable modes, such as macOS Archive Utility or `ditto -x -k`. If your extractor loses modes, extract again with `ditto`.

A source archive with changed files fails the manifest check. To edit that copy, use `swift build --scratch-path /a/fresh/path` directly, or clone the repository for the full bundle workflow. Manual release packaging requires a clean committed Git checkout. GitHub's automatic source snapshots do not carry the generated manifest; use the attached project source archive or a clone.

## Identities and local data

- Development: `org.opencove.OpenCove.dev`, scheme `opencove-dev`, default Finder data `~/Library/Application Support/OpenCove Development`.
- Release: `org.opencove.OpenCove`, scheme `opencove`, default data `~/Library/Application Support/OpenCove`.
- Development launches from the wrapper use `.local/runtime`; set `OPENCOVE_DATA_DIR` for a different isolated directory.

Use a new `mktemp -d` directory for verification. Data directories must be owned by you with mode `0700`; the app rejects unsafe existing directories without changing their permissions. Instance locks and control descriptors use mode `0600`. Startup resolves the accepted data path once. The lock and services use that same target even if an intermediate alias later changes. The app claims one process per resolved data directory. Do not point a development run at release data. Signing changes can change macOS permission recognition. Request permissions from explicit app controls when you choose to verify those features.

## Real development controls

After building a separate bundle as above, the safe default integration command starts that exact built bundle in a new private temporary data directory:

```sh
python3 -B script/smoke.py --app "$OPENCOVE_BUILD_ROOT/bundle/OpenCove.app"
```

This checks real occupied/invalid control ports and a blocked descriptor write, then runs real file, timer, and preference flows. It restores its temporary state and stops only its own processes. It does not build, replace, or install an app. Protected integrations, network features, login registration, and haptics start disabled. Add `--slow` for connection deadline checks or `--render` for offscreen native renders. Hardware changes require the separate explicit `--hardware-volume` opt-in and a supported real output; they never run by default.

To inspect an existing app with controls already enabled:

```sh
python3 -B script/smoke.py --data-dir "$OPENCOVE_DATA_DIR"
./script/opencovectl --data-dir "$OPENCOVE_DATA_DIR" state
```

`--data-dir` checks the existing API without accepted app mutations. It never launches an app. Keep raw state private. For a separate interactive development session, set `OPENCOVE_DATA_DIR` to a new `mktemp -d` directory and use `./script/build_and_run.sh --control` with a separate output directory. That command builds and launches, enables the token-protected listener on port 48765, and verifies the expected bundle. Normal launches do not start a listener.

Readiness checks need all three positional arguments:

```sh
python3 -B script/verify_control.py "$OPENCOVE_DATA_DIR" 1 \
  "$OPENCOVE_BUILD_ROOT/bundle/OpenCove.app"
```

Replace `1` with the expected `CFBundleVersion` from `version.json`. The check compares the responding bundle path, identifier, version/build, and source-tree hash. A same-build app from another path or source tree fails readiness.

If the explicitly enabled control listener or its descriptor cannot start, the app keeps running and reports the reason in Settings and on standard error. No descriptor is published for a failed listener. Check the requested port and the private data directory, then restart. The diagnostic excludes the control token and authenticated URL. A normal launch still has no control listener.

`opencovectl command` sends real app actions. `opencovectl render --surface notch --output NEW.png` creates an offscreen native capture at a new path. `opencovectl url` prints a token-bearing browser URL; keep it private. An offscreen capture does not prove desktop placement, native menu interaction, or secure-screen visibility. See [quality](quality.md) for the complete workflow and manual gates.

`opencovectl render --surface live-notch --output NEW.png` draws the existing visible native notch view. It checks mounted UI state without creating another preview. It reads only the app's own view drawing, not the desktop; hidden or unavailable content returns HTTP 409.

## Non-launch validation

```sh
bash -n script/build_and_run.sh
python3 -B script/validate_release.py version
python3 -B script/validate_release.py source --allow-dirty
python3 -B script/validate_release.py bundle "$OPENCOVE_BUILD_ROOT/bundle/OpenCove.app" \
  --variant development --arch arm64 --signing adhoc
```

Omit `--allow-dirty` for the clean-source release gate. Compilation and manifest validation do not establish runtime behavior. No unit tests, isolated-function tests, or mock services are part of the verification workflow.

Bundle signature validation also uses the selected Xcode Swift toolchain to run the checked-in `script/signing_info.swift` helper. It reads verified signing fields through Apple's Security framework for every architecture; diagnostic path text cannot establish a signing identity.
