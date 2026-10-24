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

Expanded layout accepts `automatic`, `media`, `calendar` and `duo`. For Automatic,
first verify fresh defaults, persistence, explicit-layout preservation, no
activities, media-only playback/pause, disabled features and all-disabled state.
The `expandedDuo` decision and mounted native height must agree. These negative
and empty paths do not prove simultaneous Calendar/media behavior.

Positive Automatic Duo acceptance needs real authorized EventKit activity and
the owned silent media fixture. Require the exact owned calendar/event and media
source identities before checking playing → paused → playing, activity removal,
source disablement, content transitions and mounted split geometry. Never inject
an event snapshot into the view or controller. Calendar creation, event changes,
permission changes and access to existing event data need their own explicit
authorization; the default verification does none of them.

The opt-in development server also accepts one app-local middle-button event:

```sh
./script/opencovectl --data-dir "$OPENCOVE_DATA_DIR" command \
  '{"action":"input.middleClick","region":"gestureStrip"}'
```

`region` is either `gestureStrip` or the expanded `body`. Arbitrary coordinates,
buttons, windows and PIDs are rejected. The controller requires one visible,
settled owned panel in the active session. It constructs a real middle-button
`NSEvent` through the public Core Graphics bridge, checks that the owned window
and local point survive, then uses `NSApplication.sendEvent` synchronously.
The request observes the original native handler and returns `nativeInput`
with its button number, window/target numbers, PID, receipt and handled result.
No queued event remains when the request ends. No desktop input, pointer move,
global event post, monitor, event tap or permission request is used.

Require receipt and target identity before checking Media → Calendar → Media,
disabled-section skipping, Files/Timer exclusion and the empty case. Check the
mounted native surface after selection. `handled: false` is expected for the
expanded body and when both cycle targets are disabled. Hidden, ambiguous or
moving panels return `409`. This proves app-local dispatch and native routing;
physical mouse delivery, secure-screen behavior and reference hit-area parity
remain separate coverage.

```sh
python3 -B script/smoke.py --app "$OPENCOVE_CHECK_ROOT/bundle/OpenCove.app" \
  --slow --render
```

`--app` starts only the supplied built bundle in new private temporary data directories. It disables permission/network integrations, login registration, haptics, and native notifications before launch. It checks actual occupied/invalid control ports and a descriptor blocked by a real directory: the native app stays alive, startup reports a useful diagnostic, and readiness refuses the failed endpoint. It then exercises real HTTP authentication/framing, the actual CLI, file add/deduplication/removal, a real timer, preference persistence, and an actual save failure. It restores its own state and stops only children it started. `--slow` adds idle/partial connection teardown. `--render` checks four offscreen native surfaces; it does not operate the desktop.

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

The default runtime run also checks native panel motion. To run that group alone:

```sh
python3 -B script/runtime_e2e.py --app "$OPENCOVE_CHECK_ROOT/bundle/OpenCove.app" --only motion
```

This uses the authenticated controls and actual `NSWindow` frame reads. It establishes an in-flight expansion/collapse, enables the app's Reduce Motion option, checks prompt settling and unchanged geometry afterward, reverses an active transition, and checks top/center anchoring. It also interrupts an idle shrink, restores its content before the old completion, and verifies the saved option after restart. It never changes system accessibility settings or generates desktop input. When system Reduce Motion is already enabled, the group checks immediate geometry and records that animated interruption was not observed. Frame samples show native geometry and lifecycle behavior; they are not display-frame, frame-rate, energy or reference-product measurements. `--only storage` excludes this group.

The motion group also checks monotonic native expansion/collapse at 0.5×, 1× and 2× speed, requires observed intermediate geometry, and records caller-observed settling time. It saves actual mounted in-flight and settled PNGs for visual inspection of control layout and fades. The captures can add work to a transition; their timing is not a display performance benchmark. Inspect those images and exercise the real browser controls before reporting visual changes. Mouse hover, trackpad feel and mixed-refresh displays still need separate manual coverage.

For an interrupted fade, it captures the mounted controls immediately after Reduce Motion settles the native window. AppKit decodes those PNGs and compares interior text-pixel coverage with the corresponding static references. This catches a correctly sized window whose controls remain invisible. It does not establish frame pacing or replace visual inspection.

With `--media-fixture`, `--only compact-motion` checks actual media/timer content changes at constant native geometry. It captures distinct intermediate mounted PNGs, rapid reversals, exact current content after Reduce Motion is enabled and quickly disabled, immediate media opt-out, an instant local HUD and its expiry. Native AppKit decodes the captures after the app stops. The fixture keeps playing and its concurrent timer stays paused. The run records an unavailable constant-size observation when actual display cutouts force different dimensions, and skips animated assertions when system Reduce Motion is on. It does not claim display frame pacing, physical input or reference-product timing. The full fixture run includes this group.

`--only timer-presentation` runs a real hidden timer behind Files, checks advancing API time with no countdown publications, then checks the mounted native ring between second ticks. Actual native PNGs must include the running ring and a changed countdown label. The flow also checks rejected input, pause/resume, Reduce Motion, section cleanup, exactly one hidden completion and the saved deadline after restart. The full default run includes it; storage mode excludes it. The opt-in `timerClock` and `timerProgressMotion` fields are on-demand diagnostics. These checks do not measure display frame pacing, GPU energy, physical input or a natural system clock/sleep transition. Do not change the host clock to test them.

The default runtime run also includes display selection. `--only displays` checks the actual connected logical screens and native window screen/frame, Built-in/Main/All and available UUID choices, legacy and saved-choice restarts, valid unavailable-choice fallback, malformed-input rejection, and failed-save errors. It preserves exact original bytes during repair and verifies the private backup. It does not create a virtual display or generate screen events. A one-display run cannot establish mixed-scale, negative-origin, mirrored-display, hot-plug or secure-lock behavior. `--only storage` excludes display and motion checks.

`--only activities` checks real section selection, repeated native preview mounting, collapse/reopen, default-layout changes, disabled/empty-section fallbacks, failed-save behavior and process restart. It preserves an actual tray source and paused timer while switching sections. Its private damaged calendar policy pauses event queries; media features use their disabled-integration empty state. It does not use calendar events, start a player, grant permission or drive native input. The default runtime run includes this group; `--only storage` excludes it. Actual mouse/trackpad/menu/VoiceOver behavior still needs separate manual coverage.

`--only dismissal` exercises a real running timer through `compact.dismiss` and `compact.restore`. It checks empty and stale actions, target stability across countdown/pause/resume, replacement timers with identical durations, HUD/expanded guards, exact saved-file preservation, native idle hide/restore, actual completion, preference changes and process restart. The default run includes it; storage mode excludes it. With `--media-fixture`, the media group also checks concurrent media/timer dismissal, restore order, bringing an activity forward, hidden secondary summaries, a real next-item change, stale-target rejection and restart. The fixture's source identity is verified before player commands. No synthetic calendar event, native input, permission or physical hardware action substitutes for missing coverage. Actual calendar occurrence and gesture/VoiceOver behavior remain manual gates.

`--only compact` checks the actual compact preference and resolved activity with no player integration: legacy defaults, unavailable choices, a real persisted timer, disabled-feature fallback, shared opening behavior, temporary local HUD restoration, idle retirement and restart. A damaged private calendar policy pauses EventKit queries. The opt-in media flow separately checks a real concurrent silent player and paused timer, priority changes, unchanged playback, native captures, opening and restart. These callers use the real packaged app and authenticated API; they do not prove native mouse/hover or populated calendar behavior. No additional polling or demonstration event is introduced into the app.

The runtime harness retries startup at most twice only after the app reports an occupied control port and no descriptor exists. It stops its own failed process before selecting another ephemeral port, records the diagnostic and exit status, and never stops a competing listener. An unknown readiness timeout, unsafe data directory or unrelated failure is not retried. `--only startup` holds a real owned loopback listener, exercises that app failure/retry and verifies the fresh authenticated owner; the default and storage runs include it.

`--only shape` switches the real app between automatic and simulated-notch presentation, captures the actual mounted view and Appearance settings, checks native edge placement and camera clearance, interrupts a geometry transition with Reduce Motion, and checks failed-save and restart behavior. It never substitutes a virtual screen or changes display hardware. It records the real camera dimensions and whether motion was observed. The default runtime run includes it; `--only storage` excludes it. A notched-machine run cannot establish actual notchless or mixed-display behavior.

`--media-fixture` is a separate opt-in. It starts and controls only the project's own silent MediaPlayer fixture, checks its real source identity, and stops that child. It also reads the actual native presentation-layer motion for long titles/artists, checks reduced-motion reset, and checks section/collapse cleanup. Combined-layout reflow uses a damaged private calendar policy that pauses calendar reads. System Reduce Motion stays unchanged; when it is enabled, the flow records that native movement was not observed. This flow does not establish Music/Spotify or general player compatibility. Add `--pathological-duration` with that option to check native rendering of extreme finite metadata from the owned fixture. These flags are excluded from the normal CI smoke flow.

For artwork-transition verification, the owned fixture accepts `--artwork-style shared|alternate|none|missing-second|triple`. Shared preserves its original cover on both tracks; alternate publishes two distinct original covers through MediaPlayer; none omits artwork. Missing-second keeps the original cover on track 1 and omits it on track 2. Triple uses three real silent tracks and three distinct original covers; next and previous cycle in opposite directions. Its optional `--stdin-control` accepts bounded `next` and `previous` lines for its own player only. EOF or invalid input retires that reader while playback keeps its existing 90-second limit. Status fields describe local completed actions; verify actual OS publication and the app's selected source separately. These modes provide real inputs for hold and retarget checks; they do not by themselves establish transition timing or continuity. The separate `--native-artwork` opt-in sends metadata and cached original PNGs through the existing own-process MediaRemote publisher instead of the public metadata dictionary. Silent AVAudioPlayer playback and registered remote commands remain real. One metadata writer avoids competing public/native artwork publications. It retains at most three images of at most 12 MiB each, rejects live/rate combinations before playback, and adds no timer. The OS may convert these bytes to another image format. Verify actual OS source/item/artwork and mounted pixels; this path does not establish ordinary MediaPlayer delivery latency or another player's behavior.

Capture the actual mounted artwork while its source and geometry remain fixed. Use identical visible metadata and distinct steady cover references so text or progress changes cannot pass as a blend. Require intermediate cover pixels, then the current cover. Reverse during an observed unfinished fade, enable Reduce Motion during that fade, and check quick toggle-off, unchanged artwork, missing artwork and media disablement. A settled final image alone does not prove continuity. Keep capture timing separate from resource measurements, and report any unsampled interruption as inconclusive. Native view captures do not establish display frame pacing or exact Alcove timing.

`--weather-service` is a separate network opt-in. Combine it with `--only weather` to request real Open-Meteo forecasts for public Vancouver and Berlin coordinates. The flow checks hourly/daily values, civil dates in the provider's time zone (including DST when the live range crosses it), city changes, saved-choice restart, opt-out, and location removal failures. It captures the real native forecast view. It never requests device location. Provider downtime or incomplete live data is reported as a failed flow; the caller does not replace the service with a mock. Default CI remains offline for weather.

That flow also switches the actual Conditions, Sun and Precipitation views for both cities and public polar coordinates (±89.99°, 0°). It independently checks the current civil day, the next sunrise/sunset, daylight progress and the provider's preceding-hour probability interval against the real response. It records the polar conditions actually returned; it does not replace seasonal data with a fixture. All-day daylight/night boundaries must not become false midnight sunrise/set events. It captures native weather and lock-widget renders (including Frosted), checks that style changes do not queue a weather request, and checks the saved style after restart. Every style is also exercised without a location; missing weather must not become a zero chance or a sun event.

With `--media-fixture`, `--only media-refresh` checks real next/previous/pause/play updates against the owned player, holds the resulting state to catch stale reversals, kills only the owned metadata reader during a queued refresh, and checks app survival and reader recovery after an explicit media restart. Actual mounted PNGs must keep colored fixture artwork at the first changed item and clear it immediately on media opt-out. A native decoder inspects those captures after the app stops; this is not display-frame sampling. It also drives the packaged CLI stream with a burst of metadata-only stdin input, checks unchanged actual playback before a separate source-bound next command, then requires a new actual item after input EOF. The full fixture run includes this group. These checks do not establish physical control latency, display frame pacing, other-player behavior or a natural source-change race.

The owned media flow also starts a separate `--rate-controls` fixture. It checks real advertised playback speeds, a real AVAudioPlayer rate change while playing and paused, changed capabilities on the next item, unsupported-value rejection, and refusal of stale API and adapter targets. A separate fixture without that command verifies that the rate control stays unavailable. This does not establish rate support in Music, Spotify, or other players.

That flow also uses `--live-metadata` on the owned local fixture. Its first item publishes MediaPlayer's public live flag and unavailable duration; its second item publishes a false flag and real duration. The caller checks the actual native metadata, app live status, unavailable seek rejection, native LIVE presentation, restoration of advancing timed progress and return to the live item. A separate zero-duration item without a live flag must not become live content. These are real local MediaPlayer publications, not internet-stream or broad radio/player compatibility checks. The fixture accepts finite nonnegative metadata durations; actual silent audio playback retains its own finite duration.

The song-peek flow uses the owned fixture's `identical` metadata style and the same published duration on both real items. It requires a changed native item ID before accepting the peek. It checks opt-in/defaults, shared opening, expiry without deadline extension, replacement deadlines, native layer retirement, HUD/expanded/pause/opt-out interruption, reconnection and restart. It reads actual monotonic deadline remaining time, records observed overlap and accounts for command latency rather than shortening a replacement's expected duration. It observes intermediate native window geometry and reduced-motion layer cleanup when system Reduce Motion is off; it does not synthesize a mouse, trackpad, lock or session event. Captures use the real native notch/Media settings. This does not prove other players' identity stability, metadata-only fallback, natural lock transitions or original-product timing.

The bound-seek flow uses the same real identical-metadata items. It checks stable targets across repeated source samples and pause, actual current-target seeks, rejection without a source-position change after item replacement/return, malformed/out-of-range requests, legacy immediate seeks and fresh targets after media/process restart. Native notch/lock captures and the existing mounted progress flow use the real source. The callback binding change is source-reviewed; this caller does not drive a native scrub/keyboard gesture or prove AppleScript/direct-MediaRemote behavior.

For `media.speed`, API clients must echo the current media state's `sourceBundleIdentifier` as `source` and `contentItemIdentifier` as `item`, plus a `speed` from `supportedPlaybackSpeeds`. A stale target returns HTTP 409; missing identifiers or an unadvertised value return HTTP 400. The app reports a new speed only when the source supplies it; HTTP 200 means submission. Native speed menus capture the same item identity when built.

`playbackClock` in the development state reports received source samples and clock change notifications. The real media flow checks that stable playback can receive several samples without notifying progress observers for each one, while actual playing seeks and paused position changes still reach the real app. These counters are diagnostic counts, not frame-rate or energy measurements.

`playbackIndicatorMotion` reports actual native layer heights and active-animation counts when controls are enabled. The media flow checks moving layers, static reduced-motion/paused states, and section cleanup. It also captures `--surface live-notch`, which draws the app's existing native view rather than mounting a new preview. With decorative motion and hardware indicators disabled, successive captures check that mounted progress changes while playing, stays fixed while paused, changes after a paused seek, and resumes after play. These captures still need visual inspection; an image difference alone does not establish its cause. They do not capture desktop pixels, order a window or generate input. A hidden or unavailable native panel returns HTTP 409.

The media flow also enables paused-media compact hiding with a short real deadline. It checks the grace, retained expanded controls, native edge-target geometry, resume cancellation, new-item grace, unchanged deadlines on rate/appearance changes, real timer completion HUDs, and saved preferences after a process restart. Where system reduced motion is off, it also reverses an actual native shrink and checks that its old completion cannot hide restored content, then checks content retirement after a completed shrink. These are native lifecycle checks, not frame-rate measurements. The default setting stays off. Existing metadata is retained and no source is paused, resumed, or sought merely because its compact view hides.

## Evidence and manual gates

For expanded-section motion, use real paused Timer and empty Files views in an owned packaged session. Switch sections through the authenticated API while sampling `live-notch`; use equal destination dimensions to distinguish content fading from native window resizing. Inspect intermediate and settled captures. Enable Reduce Motion during a fade, switch it off before the old duration ends, and require the current content to stay settled. A later distinct section change should animate again. Also check rapid reversals, feature disablement, single/Duo changes, and collapse/reopen. Native menu, popover, sheet and accessibility interaction still need separate live coverage; PNGs alone do not establish those actions or display frame pacing.

The authenticated development command `system.refreshAudio` runs the same audio-only refresh as the output picker. It returns `audioRefreshAcceptance` samples and actual system readings. Use `caller: "nativePicker"` to mount actual Activities settings in the unordered native renderer and require the picker's `onAppear`; the default caller is `developmentAPI`. The `hardwareControl` caller invokes the same read-only current-level path used before handling a hardware control; it posts no key event and calls no setter. Require the expected caller, one `audio` entry, zero unrelated domain entries, and zero `hardwareWriteDelta`. Full refresh/picker callers also require one `audioOutputs` entry. A healthy unchanged current route skips that inventory entry for `hardwareControl`; route/UID changes, errors, pending metadata invalidation and listener/polling failures retain the full refresh. Inspect actual `audioReadErrors` and unavailable output state. Counts cover synchronous domain entries and attempted controller setters, not individual OS queries or later listener/fallback/HUD work. No retained counters or clocks run outside an explicit acceptance window. Native menu interaction and real route changes remain separate manual coverage.

`--only hud-timing` launches the real packaged app with private legacy settings, saves per-category overrides, rejects invalid types/ranges, and checks labelled read-only previews. It checks captured deadlines across preference edits, repeated/replaced alerts, unchanged notification receipts and underlying paused timer/files/selection, opt-out, native captures, restart, and individual damaged-field recovery with an exact private backup. The default run includes it; storage mode excludes it. Inspect the native preview and Activities settings captures. Recorded window geometry is sampled on demand; it is not a display frame-rate measurement. Physical hardware-key repetition, haptics, session events and exact reference-product timing remain manual gates.

Record the exact source-tree hash, bundle path/variant, architecture, version/build, macOS/toolchain, commands, exit status, and failing flows for each final integration run. Keep tokens, private event/banner/media data, and raw state out of public reports. This guide is a procedure, not a record that its commands passed. The final integrated revision still needs its own recorded run.

Native offscreen output needs visual inspection for wrapping, clipping, errors, empty states, and accessibility labels. The cache uses AppKit’s compatible bitmap format and waits for native containers to mount. Some system glass/vibrancy content, especially lock-widget text, can be absent from an unordered window capture. A PNG pass checks encoding and process survival; it does not prove every native element is visible. It does not establish menu actions, window resizing, VoiceOver, display geometry, Spaces, sleep/wake, or secure lock-screen visibility and credential clearance.

Further manual coverage requires explicit feature consent and real existing data: granted EventKit/source filtering and alerts, meeting/calendar routes, real weather and MapKit responses, live-player command identity, readable notification banners, waveform audio capture, hardware-key holds/releases, stock HUD suppression, and natural privacy/session transitions. Never substitute generated desktop input, fabricated events/tracks, or a mock for those results. Empty or denied access proves only that path.

Intel and each supported macOS version need runtime checks. Developer ID signing, notarization, downloaded-install/Gatekeeper behavior, and complete player/device compatibility remain separate gates. No measured parity with another application is claimed. Read [compatibility](compatibility.md) and [releasing](releasing.md) before describing a binary as ready.

`--only indicators` restores real saved live-waveform choices behind disabled media or an off indicator, repeats unrelated saves and restarts, and requires zero capture start attempts/sessions/meter tasks. It also checks the legacy decorative default and malformed-flag recovery with an exact private backup. No capture permission is requested or live capture enabled. The opt-in real media flow checks actual native layer removal/restoration in expanded, compact and song-peek surfaces, and captures the shared lock layout and Media settings. Lock rendering and API seeking do not prove physical native scrubbing or secure lock-screen visibility/input; those remain manual gates. Development `waveform` fields are on-demand lifecycle diagnostics, not an added observer or performance schedule.

The opt-in media flow uses `--explicit-metadata` on a separate silent fixture. Its own native publisher sends the real explicit field through MediaRemote, because the public MediaPlayer key did not reach the native snapshot on the current host. It never injects a response into OpenCove or overrides another application's identity. Independent native reads must confirm the owned source and true/false flag before app assertions or commands. The flow checks identical-title marked/false item changes, notch/Duo/lock captures, opt-out, restart and an independent unmarked source with no stale flag. Combining this fixture mode with live/rate modes is rejected before playback. A missing publisher or field fails the flow; no mock or renderer-only state replaces it. Broad marked Music/Spotify/browser behavior and physical native/secure-screen input remain unverified.

The owned media flow also toggles artwork color without changing its actual item/cover, compares the real native layer colors across compact and expanded media, captures Duo/lock composition, and verifies media opt-out/remount. The authenticated development snapshot reads layer RGBA only on request; it adds no animation timer or normal runtime telemetry. These checks do not establish every image format, rapid alternating artwork, or secure-screen presentation.

`--only outline` exercises the actual outline preference through the packaged app: legacy default off, compact/expanded/attached native captures, unchanged window geometry, strict Boolean input, saved-field recovery with an exact private backup, and process restart. The outline is drawn inside the existing shape with no new window, timer or input area. Toggling macOS Increase Contrast and checking every display scale remain manual gates.

`--surface live-notch-compositor` is a separate, explicit authenticated development capture. It uses ScreenCaptureKit's current-process content API, then matches the mounted notch window ID and owning PID. It excludes child windows, shadows, cursor, mouse clicks, audio and microphone. It never selects a display or rectangle, opens a sharing picker, requests permission, or falls back to broader capture. A hidden, resized, retired, source-changed or cancelled window request is rejected. Output is limited to 4096 pixels per edge, 4,194,304 pixels and 16 MiB. This captures that app-owned window's compositor output; it does not establish a desktop backdrop or progressive blur. The existing `live-notch` surface retains its AppKit caching-renderer semantics. Screenshot requests cannot be cancelled at the system API; late results are discarded and the render-busy guard stays held until completion.

For an actual interrupted artwork fade, the development `/state` snapshot exposes
`mediaDelivery.adapterSampleAgeSeconds` from the last accepted adapter frame and
`artworkTransitionMotion.phaseOrigin` for one native phase. Phase origins exist
only in a development bundle launched with explicit control arguments. They
retain scalar revision, slot-equality, presentation-opacity and installed-start
values, with no source strings, images, observer or recurring publication.
The timestamps share Core Animation's clock; compare their differences, not an
external runner's clock origin. Require a prior animation still within its
native deadline, unchanged slots/source, and the installed start equal to the
interrupted presentation opacity. Bracket captured pixels with native samples
and check displacement in both directions. Insufficient interruption or sampling
coverage stays pending. AppKit caching captures do not establish WindowServer
frame cadence; final correct artwork alone does not prove continuity.

`artworkTransitionMotion.distinctInput` observes a decoded input that differs
from both installed native slots while an existing fade is active. This bounded
development-only record holds scalar timing, revision and equality checks; the
input identity is non-retaining and is never returned. The record also notes
when that same input reaches a slot. Require a ready observation before the old
native deadline, unchanged incoming slots/revision at that observation, and
consumption after the old animation ends. Use calibrated real A/B/C cover
references and bracket both fade phases with native opacity samples. An item ID
change or a third cover that decodes only after completion does not establish
three-cover interruption coverage. The record is cleared on source/input
replacement, hiding and retirement and adds no timer or model publication.
