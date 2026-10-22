# Changelog

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
