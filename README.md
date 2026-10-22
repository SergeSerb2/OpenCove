<img src="assets/icon.svg" width="64" height="64" alt="OpenCove">

# OpenCove

[![Build and source archive](https://github.com/SergeSerb2/OpenCove/actions/workflows/ci.yml/badge.svg)](https://github.com/SergeSerb2/OpenCove/actions/workflows/ci.yml)

An independent, MIT-licensed macOS notch app, written in SwiftUI and AppKit.

**Early beta (`0.1.0-beta.1`).** Real app/API/CLI integration checks are provided in [the quality guide](docs/quality.md). This is not a stable release or a claim of complete hardware, macOS, or player compatibility. No notarized public binary has been verified. See [compatibility and open gaps](docs/compatibility.md).

## What it does

- Shows Now Playing metadata, readable long titles and artists, and supported media controls.
- Shows calendar events, meeting links, and event countdowns.
- Shows volume, brightness, battery, Bluetooth, and shared Focus status when available.
- Offers optional current weather with a 24-hour and 7-day forecast, time-to-leave alerts, system audio levels, notification-banner mirroring, lock widgets, a file tray, and a persistent timer.
- Uses a floating pill on notchless displays, native windows, multiple-display policies, reduced motion, and configurable hover behavior. No web wrapper, account, or paid subscription is required.

## Requirements

The deployment target is **macOS 15+**. Local app/API runtime evidence is **Apple silicon, macOS 27.2**. Automated packaged-app/API/CLI smoke checks have also passed on the macOS 15 arm64 CI runner; full macOS 15/26 and Intel feature coverage is still open. Glass effects use macOS 26 APIs with an older-system fallback.

Building needs **Xcode 26+ with the macOS 26 SDK**, Swift 6+, and Python 3.9+. Local builds use **Xcode 27.1 / Swift 6.4 / macOS 27 SDK**. Hosted CI has also passed with **Xcode 26.2 / Swift 6.2.3 / macOS 26.2 SDK**. There are no third-party Swift packages.

When macOS denies direct media reads, an isolated adapter uses the built-in `/usr/bin/osascript` JavaScript host. This path does not need developer tools at runtime and does not send Apple Events. A legacy Swift adapter is retained for diagnostics and needs Xcode or Command Line Tools. Music/Spotify Automation is a separate opt-in fallback.

## Build and install

```sh
git clone https://github.com/SergeSerb2/OpenCove.git
cd OpenCove
./script/build_and_run.sh --build    # Local development bundle: dist/OpenCove.app
./script/build_and_run.sh            # Build and launch the development app
```

Quit a running copy before rebuilding its bundle, or select an isolated output directory. The menu bar icon opens the notch, Settings, or Quit. Hover expands the notch; Escape closes it. The expanded panel’s ellipsis menu selects sections and opens Settings. Right-click and swipe navigation are also available.

For an optimized local app, run `./script/build_and_run.sh --release`, then copy `dist/release/OpenCove.app` to your Applications folder with Finder. These builds are **ad-hoc signed**, not Developer ID signed or notarized; macOS may block a downloaded copy. Do not treat ad-hoc archives as trusted distribution builds. Future approved downloads belong on [GitHub Releases](https://github.com/SergeSerb2/OpenCove/releases), with checksums and a stated signing status.

[Build instructions](docs/building.md) cover source ZIPs without Git, architecture selection, isolated paths, and real app controls. [Quality checks](docs/quality.md) define the real integration workflow and manual gates. [Release instructions](docs/releasing.md) cover manual packaging and the opt-in Developer ID/notarization path.

## Privacy and network use

Permissions are optional and requested from explicit controls. Calendar, Automation, Bluetooth, Focus, Accessibility, location, system notifications, and system audio capture can expose sensitive data. Notification mirroring reads new readable banners. Audio levels use ScreenCaptureKit in memory; the app does not use the microphone or save a recording.

Private system integrations are enabled by default and can be disabled in Settings. Undocumented MediaRemote and DisplayServices interfaces can stop working after OS updates. This is not an App Store build.

Settings, file references, timers, and selected locations are stored locally. Normal launches have no HTTP control listener. An explicit development launch can enable a token-protected loopback API that can read app state and change real settings. Keep its token private.

Weather sends selected coordinates to Open-Meteo. Optional Maps routing sends the selected origin, event destination, and arrival time to Apple. Spotify fallback artwork can contact Spotify's image CDN. Links and file sharing use the chosen app or service. There is no app-operated account, analytics, update, or telemetry backend. See [the full permission, data, and network disclosure](docs/privacy.md).

## Limits and project links

Secure lock-screen visibility, hardware-key interception, granted-permission flows, audible waveform behavior, and display/Space transitions need further manual verification. Playback-speed control, external DDC brightness, full AirPlay/HomePod control, and universal accessory battery coverage are not provided. Feature availability must come from real source/device data.

[Contribute](CONTRIBUTING.md) · [Report a bug](https://github.com/SergeSerb2/OpenCove/issues/new/choose) · [Security reporting](SECURITY.md) · [Code of conduct](CODE_OF_CONDUCT.md) · [Changes](CHANGELOG.md)

OpenCove's app code, media adapter, and icon are independently authored under [MIT](LICENSE). It contains no Alcove code, artwork, binaries, license checks, or account services. It is not affiliated with Alcove or Apple. Optional weather data has [separate provider and attribution terms](docs/privacy.md). Created with [T3 Code](https://t3.codes).
