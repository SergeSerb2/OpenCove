# Compatibility and beta limits

The app targets macOS 15+. That is a build deployment target, not evidence that every target OS has passed runtime checks.

## Build and verification scope

Building needs the macOS 26 SDK or later because the source names glass APIs, guarded with `#available(macOS 26.0, *)`. The package retains a macOS 15 deployment target and an older-system material fallback. Local development has used arm64 macOS 27.2 with Xcode 27.1, Swift 6.4, and the macOS 27 SDK. Hosted [CI run 39747247029](https://github.com/SergeSerb2/OpenCove/actions/runs/39747247029) passed on the macOS 15 arm64 runner with Xcode 26.2, Swift 6.2.3, and the macOS 26.2 SDK. It rebuilt the curated source ZIP without Git and exercised the isolated real app/API/CLI smoke flow. Full macOS 15 feature coverage remains open.

The checked-in [quality workflow](quality.md) uses real packaged app/API/CLI paths and optional native offscreen renders. Its default run disables protected integrations and network features. It does not establish granted-permission, hardware, media-player, secure-screen, or cross-version runtime compatibility. Record final results for the exact integrated source and bundle; older local checks do not certify a later build.

## Capabilities and open checks

- **Media:** Direct MediaRemote access is OS-dependent and can be denied. The default adapter uses macOS’s built-in JavaScript host. The retained legacy Swift diagnostic adapter needs Xcode/Command Line Tools. Music/Spotify-specific shuffle, repeat, favorite, and links require supported source capabilities and Automation permission; broad live-player compatibility is unverified. No playback-speed setter is provided.
- **Displays:** Brightness uses private DisplayServices where available. External DDC/BetterDisplay control is absent. Mixed scale, negative origins, screen removal, Spaces, fullscreen, sleep/wake, and exact geometry/timing need manual coverage.
- **Audio and accessories:** CoreAudio outputs can have fixed volume or lack mute support. AirPlay/HomePod discovery/control is incomplete. Bluetooth batteries depend on the driver and accessory; all models/components are not promised. Audible waveform behavior needs real manual verification.
- **Calendar and travel:** Granted calendar access, month/filter/meeting flows, naturally reached alerts, real Maps routes/deadlines, and location consent need further manual coverage. EventKit accounts and MapKit availability affect results.
- **Privacy and secure screen:** Granted Accessibility/Automation/Bluetooth/Focus paths, readable notification banners, hardware-key hold/release and stock HUD suppression, inactive sessions, and secure lock-screen visibility/credential clearance need real manual checks. An offscreen render cannot establish these results. Event details are hidden by default on lock widgets.
- **Platforms and signing:** Intel and universal binaries can be built, but Intel runtime, macOS 26 runtime, and full macOS 15 feature coverage remain unverified. A Developer ID hardened/notarized distribution needs its own artifact and installed/downloaded verification. No App Store compatibility is claimed.

The app is not measured pixel-for-pixel or motion-for-motion parity with another product. The file tray and timer are independent additions. Weather currently supplies conditions and temperature, not a complete forecast interface. No sample tracks or calendar events substitute for unavailable real data.

Private MediaRemote/DisplayServices interfaces and other undocumented OS details can change without notice. Turning off private integrations is supported, with reduced capability. A signing or notarization result would not prove those APIs are compatible on other OS versions.
