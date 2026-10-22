# Quality and integration checks

Verify through the real built app, authenticated HTTP API, checked-in CLI, and native offscreen renderer. The project does not use unit tests, isolated-function checks, or mocked services for this workflow. Run from the repository root with the toolchain in [building](building.md).

## Build an isolated bundle

```sh
OPENCOVE_CHECK_ROOT="$(mktemp -d /tmp/opencove-check.XXXXXX)"
OPENCOVE_OUTPUT_DIR="$OPENCOVE_CHECK_ROOT/bundle" \
OPENCOVE_SCRATCH_PATH="$OPENCOVE_CHECK_ROOT/swift" \
./script/build_and_run.sh --build
python3 -B script/validate_release.py version
python3 -B script/validate_release.py source --allow-dirty
```

This builds without launching or replacing a shared app. `--allow-dirty` records uncommitted source for local inspection; a release requires the clean committed gate. Public exports use an explicit source/docs allowlist. Raw audits, research, review records, runtime data, and Git internals are local evidence and stay outside the source archive.

## Exercise the real interface

```sh
python3 -B script/smoke.py --app "$OPENCOVE_CHECK_ROOT/bundle/OpenCove.app" \
  --slow --render
```

`--app` starts only the supplied built bundle in a new private temporary data directory. It disables permission/network integrations, login registration, haptics, and native notifications before launch. It exercises real HTTP authentication/framing, the actual CLI, file add/deduplication/removal, a real timer, preference persistence, and an actual save failure. It restores its own state and stops only the child it started. `--slow` adds idle/partial connection teardown. `--render` checks four offscreen native surfaces; it does not operate the desktop.

For an existing explicitly enabled API, use the non-mutation mode:

```sh
python3 -B script/smoke.py --data-dir "$OPENCOVE_DATA_DIR"
```

That mode does not launch an app or submit accepted app-state changes. `--render` and `--hardware-volume` require the owned `--app` session. Physical volume verification is a separate explicit `--hardware-volume` opt-in; no hardware/player writes or permission prompts belong to the default run. Inspect the harness before authorizing that optional hardware path.

`verify_control.py DATA_DIR BUILD EXPECTED_APP_BUNDLE` compares the actual responding bundle path and source-tree hash as well as version/build and identifier. For the stale-owner regression, `smoke.py --stale-bundle OTHER.app` needs a different real bundle with the same build. It must be rejected as the expected owner. A successful process launch or matching build number alone is insufficient.

Data directories use `0700`; control descriptors and instance locks use `0600`. Existing unsafe paths are rejected without silently changing permissions. Use a fresh `mktemp -d` directory rather than repairing a user-data directory for verification. Malformed commands return HTTP 400; unavailable/unsupported actions return 409; persistence and internal failures return 500. Other HTTP framing/authentication failures have their own explicit status codes.

## Restart and recovery checks

```sh
python3 -B script/runtime_e2e.py --app "$OPENCOVE_CHECK_ROOT/bundle/OpenCove.app"
```

This starts the supplied bundle with fresh private data for each flow. It checks real process restarts, malformed saved preferences, exact recovery backups, onboarding save failure, timers, calendar-settings recovery, and file-tray persistence and limits. It does not request privacy permissions or operate hardware or an existing player. Evidence stays under an ignored local directory; inspect its summary and failed groups before making a pass claim. Use `--help` for a targeted group and a fresh explicit evidence directory.

`--media-fixture` is a separate opt-in. It starts and controls only the project's own silent MediaPlayer fixture, checks its real source identity, and stops that child. It also reads the actual native presentation-layer motion for long titles/artists, checks reduced-motion reset, and checks section/collapse cleanup. Combined-layout reflow uses a damaged private calendar policy that pauses calendar reads. System Reduce Motion stays unchanged; when it is enabled, the flow records that native movement was not observed. This flow does not establish Music/Spotify or general player compatibility. Add `--pathological-duration` with that option to check native rendering of extreme finite metadata from the owned fixture. These flags are excluded from the normal CI smoke flow.

`--weather-service` is a separate network opt-in. Combine it with `--only weather` to request real Open-Meteo forecasts for public Vancouver and Berlin coordinates. The flow checks hourly/daily values, civil dates in the provider's time zone (including DST when the live range crosses it), city changes, saved-choice restart, opt-out, and location removal failures. It captures the real native forecast view. It never requests device location. Provider downtime or incomplete live data is reported as a failed flow; the caller does not replace the service with a mock. Default CI remains offline for weather.

The owned media flow also starts a separate `--rate-controls` fixture. It checks real advertised playback speeds, a real AVAudioPlayer rate change while playing and paused, changed capabilities on the next item, unsupported-value rejection, and refusal of stale API and adapter targets. A separate fixture without that command verifies that the rate control stays unavailable. This does not establish rate support in Music, Spotify, or other players.

For `media.speed`, API clients must echo the current media state's `sourceBundleIdentifier` as `source` and `contentItemIdentifier` as `item`, plus a `speed` from `supportedPlaybackSpeeds`. A stale target returns HTTP 409; missing identifiers or an unadvertised value return HTTP 400. The app reports a new speed only when the source supplies it; HTTP 200 means submission. Native speed menus capture the same item identity when built.

`playbackClock` in the development state reports received source samples and clock change notifications. The real media flow checks that stable playback can receive several samples without notifying progress observers for each one, while actual playing seeks and paused position changes still reach the real app. These counters are diagnostic counts, not frame-rate or energy measurements.

The media flow also enables paused-media compact hiding with a short real deadline. It checks the grace, retained expanded controls, native edge-target geometry, resume cancellation, new-item grace, unchanged deadlines on rate/appearance changes, real timer completion HUDs, and saved preferences after a process restart. Where system reduced motion is off, it also reverses an actual native shrink and checks that its old completion cannot hide restored content, then checks content retirement after a completed shrink. These are native lifecycle checks, not frame-rate measurements. The default setting stays off. Existing metadata is retained and no source is paused, resumed, or sought merely because its compact view hides.

## Evidence and manual gates

Record the exact source-tree hash, bundle path/variant, architecture, version/build, macOS/toolchain, commands, exit status, and failing flows for each final integration run. Keep tokens, private event/banner/media data, and raw state out of public reports. This guide is a procedure, not a record that its commands passed. The final integrated revision still needs its own recorded run.

Native offscreen output needs visual inspection for wrapping, clipping, errors, empty states, and accessibility labels. The cache uses AppKit’s compatible bitmap format and waits for native containers to mount. Some system glass/vibrancy content, especially lock-widget text, can be absent from an unordered window capture. A PNG pass checks encoding and process survival; it does not prove every native element is visible. It does not establish menu actions, window resizing, VoiceOver, display geometry, Spaces, sleep/wake, or secure lock-screen visibility and credential clearance.

Further manual coverage requires explicit feature consent and real existing data: granted EventKit/source filtering and alerts, meeting/calendar routes, real weather and MapKit responses, live-player command identity, readable notification banners, waveform audio capture, hardware-key holds/releases, stock HUD suppression, and natural privacy/session transitions. Never substitute generated desktop input, fabricated events/tracks, or a mock for those results. Empty or denied access proves only that path.

Intel and each supported macOS version need runtime checks. Developer ID signing, notarization, downloaded-install/Gatekeeper behavior, and complete player/device compatibility remain separate gates. No measured parity with another application is claimed. Read [compatibility](compatibility.md) and [releasing](releasing.md) before describing a binary as ready.
