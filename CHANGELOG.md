# Changelog

## 0.1.0-beta.3 — November 2, 2026

Build 3. A universal, Developer ID signed and notarized beta, delivered through the existing Sparkle feed. It updates 0.1.0-beta.2.

- **Sounds:** a timer-finished sound (on by default) and optional lock, unlock, charger, low-battery, calendar-start and hourly-chime (daytime only by default) sounds, using built-in macOS sounds, with previews and a volume level.
- **Battery:** configurable low-battery warning level, an optional percentage beside the battery mark, and time until full charge.
- **Overlays:** Accent, White, Segmented and Gradient level bars that animate between values; the volume symbol fills with the level.
- **Bluetooth:** device symbols for AirPods, Beats, HomePod, keyboards, mice and controllers, with battery level when the accessory reports one.
- **Media:** the playing app's icon on the artwork, artwork glow, hide title extras (Remastered, Bonus Track, feat.), Back 15 / Forward 30 seconds, an optional compact progress line and a lock-screen volume slider.
- **Timer:** a stopwatch, an optional automatic break (1–30 minutes) after each timer, +1 minute while running, custom durations up to 12 hours and a live progress ring in the compact view.
- **Calendar and weather:** Celsius or Fahrenheit (wind in km/h or mph), an optional Weather section (now, feels-like, humidity, wind, a 12-hour rain outlook, next six hours and four days), an empty calendar day shows its forecast, and the idle compact clock shows the current temperature.
- **Shortcuts:** pin up to eight macOS Shortcuts as one-tap tiles in a new panel section. Each shows progress, and the result appears as an overlay.
- **Clipboard history:** an optional section with the last 20 copied texts, kept in memory only. Concealed and transient items (such as passwords) are skipped. Click to copy again.
- **Notes:** an optional scratchpad section, saved as a private text file on this Mac.
- **Stay Awake:** keep the Mac and display awake for 30 minutes to 4 hours or until turned off, from the System section or the menu bar. A cup shows in the idle clock while it is on.
- **System stats:** an optional section with CPU, memory, network and disk, sampled only while it is open.
- **General:** a global open/close shortcut, hide menu bar icon (open the app again to reach Settings), hide from screenshots and recordings, dropping files on the notch opens the file tray (now with image, PDF and video thumbnails plus kind and size), and the right-click menu gains playback controls and Quit.
- **Lock screen:** a simpler Keep Awake card with duration presets, and a widget position setting.
- **Settings:** search, reorderable panel sections, a new Overlays page, a live Appearance preview with color swatches, and shorter, plainer descriptions.
- **Keyboard:** ← → switch sections and Space plays or pauses while the panel has focus.
- **Polish:** an option to hide the compact playback indicator, no more "-0°", player launchers when nothing is playing, Clear All in notification history, and gestures explained in onboarding.

Also new since beta.2:

- **Panel:** middle click cycles Media and Calendar, downward swipes cycle the enabled sections, Duo is chosen automatically for two activities at once, an optional idle-hover expansion, and optional hiding in Mission Control, in games and while the media app is in front.
- **Media:** optional swipe to skip tracks, a total-duration time choice, dimmed artwork while paused, and playback controls in the menu bar menu.
- **Calendar:** better grid and Today contrast, optional event dots, source colors, a hidden event list, and filters for declined events and subscriptions.
- **Overlays:** separate label and percentage choices, accent outlines and a brightness glow, optional Low Power Mode overlays, and brightness feedback from BetterDisplay.
- **Lock screen:** finite Keep Awake sessions, battery time remaining, and explicit consent for lock-screen widgets.
- **Setup and reliability:** an optional Bluetooth step, Focus and Bluetooth monitoring that stays off when disabled, optional integrations that stay off after damaged preferences, and less audio and Calendar work in the background.

## Unreleased — 0.1.0-beta.1

Initial independent MIT implementation of a native macOS notch app:

- Media, calendar, system-status HUDs, file tray, and timer.
- Optional weather, Maps travel alerts, audio levels, notification mirroring, and lock widgets.
- Separate development/release identities and data directories, with an opt-in authenticated development API.
- Local packaging validation, explicit signing modes, source notices, source archive, and SHA-256 checksums.
- Preference recovery and visible save errors, onboarding completion rollback on failed saves, and privacy lifecycle hardening.
- Complete locked-weather attribution and a portable real app/API/CLI quality workflow; raw local audits stay outside public exports.
- Item-bound media seeking, bounded weather downloads, strict control requests, authentication-loss cleanup, and retained cold-launch URLs.
- Physical-directory safety checks for macOS path aliases, bounded tray persistence, and timer consent recovery.
- Smaller media layout, per-display pill/notch shapes, compact event countdowns, shared motion timing, and a bounded artwork thumbnail cache.
- A low-memory system JavaScript media host, item-bound artwork, stopped idle playback clocks, and deadline-based activity timers.
- Structured signing validation and builds from verified source snapshots, with real restart/recovery tooling.
- Source-supplied explicit badges and shared artwork colors that respond to preference changes without new cover data.
- Media-reader lifecycle wakeups instead of fixed idle polling, and no travel heartbeat while alerts are disabled.
- Pixel-aligned native panel anchors during interrupted expand/collapse animations.
- Optional panel contrast outlines, plus an opaque outline when macOS Increase Contrast is active.

This entry describes source under development. It does not mean a binary has been published, notarized, or verified on every supported target. See [compatibility](docs/compatibility.md) and [release gates](docs/releasing.md).
