# OpenCove architecture

OpenCove is an independent MIT application. SwiftUI views run in AppKit windows and panels. The deployment target is macOS 15. The package has no third-party Swift dependencies. No proprietary application code, artwork, binaries, or license service is included.

## State and service ownership

`CoveStore` is a main-actor `ObservableObject`. It owns preferences, selected tab, expanded state, HUD presentation, settings visibility, and the media, system, activity, weather, waveform, travel, notification-mirror, and hardware-key services. Views observe services directly as well as the store so service updates render without copying state into the store.

Services expose value models and bounded lifecycle methods. They do not reference `CoveStore`. The store connects their HUD callbacks, calendar routing feed, privacy gates, and preference changes. `OpenCoveApp` owns app lifetime and connects the store to the normal and lock panel controllers.

`savePreferences()` applies effective runtime choices before persistence. A save failure remains visible through `lastError`; privacy opt-outs still apply for that session. A failed save preserves the prior onboarding completion marker even when a login-item failure is followed by a successful JSON write. `completeOnboarding()` uses this same save path. Damaged preferences require a private recovery copy before replacement.

## Native surfaces

`NotchPanelController` manages display selection, per-display cutout geometry, hover/scroll handling, and panel lifetime. A display without a cutout uses a floating rounded pill. Geometry refreshes compare their inputs, so a media clock tick does not enumerate displays or query fullscreen windows. The native window and SwiftUI content share one motion policy, with reduced-motion support. `NotchView` renders compact and expanded content from real service state. Settings and onboarding use separate native windows. Normal panels require an active, unlocked session.

If Reduce Motion becomes active during a native frame transition, the controller replaces the running animator with its final frame immediately, even when the destination is unchanged. A revision check prevents an older completion from hiding restored content. This adds no timer or observer; it uses the existing preference and accessibility notifications.

Optional paused-media hiding affects compact presentation only. The store observes source/item and playing-state changes, with one cancellable continuous-clock deadline after an observed pause. Elapsed, artwork and playback-rate updates do not extend that deadline. Full media state and controls stay available; playing or a new item restores compact media. Timer/event content and temporary HUDs retain their normal priority. No extra polling loop or persisted idle deadline is added. A new launch starts a fresh grace when it first observes a paused item. When idle hiding removes the whole compact surface, its content fades as the native panel shrinks. The hosting view retires after the transition; a newer layout cancels the old completion. Hidden idle content does not mount the clock timeline. Reduced motion skips the transition.

`LockScreenController` owns the optional lock widgets. Their presentation requires explicit opt-in, private integrations, a known locked state, an active console session, and awake displays. These are ordinary app panels; macOS owns authentication and the system clock. Secure-screen visibility and credential clearance need manual verification on each supported OS. Lock weather attribution uses readable literal URLs rather than external-app actions.

## Service boundaries

- `MediaController`: real media metadata, command capabilities, transport, artwork, optional Apple Events fallback, and the isolated system MediaRemote adapter. Unsupported actions stay unavailable.
- `SystemController`: CoreAudio outputs, supported volume/mute, battery, Bluetooth, Focus, optional private brightness, and conservative session/lock knowledge.
- `ActivityController`: EventKit reads, calendar filters and alerts, bookmark-backed file references, a persistent timer, and app notifications. It never edits calendar events.
- `WeatherController`: explicit location selection, bounded Open-Meteo refreshes, stale-state handling, and cancellation on opt-out.

Weather presentation has Conditions, Sun and Precipitation styles. They share the same 24-hour/7-day response and add no service, request cadence or permission. Each mounted weather surface has one minute-based timeline for its summary, forecast and age labels. Missing sun times or chances remain unavailable. The daylight arc shows elapsed daylight, not a physical sun position. The provider's daily daylight duration distinguishes continuous daylight/night; midnight interval boundaries are not exposed as sunrise/set events. Sun events and civil-day selection use the location's IANA time zone. [Open-Meteo](https://open-meteo.com/en/docs#hourly-parameter-definition) defines precipitation probabilities for the preceding hour ending at each timestamp; the current-hour summary selects that interval, while forecast cells retain the provider's end-time labels. Style changes use the shared motion policy and respect reduced motion. The locked summary does not construct the saved location name. The opt-in state endpoint reports the actual bounded presentation and a weather request-attempt counter for verification.
- `TravelController`: consented origin, reduced physical event destination, real MapKit directions, route freshness, and deduplicated leave alerts.
- `AudioWaveformController`: optional ScreenCaptureKit audio levels in memory, with serialized stream startup/cleanup.
- `NotificationMirror`: opt-in, bounded AX reads of newly exposed Notification Center banners. The store supplies a collection gate and clears mirrored presentation when collection stops.
- `HardwareKeyController`: optional supported hardware-key interception. It consumes a key after a supported write is attempted, including an OS write failure, to avoid applying the same input twice. Capability or identity rejection before the write passes through. Submission is separate from confirmed device state.

The public models describe availability and capabilities. Empty or denied data does not become sample tracks, events, routes, or fabricated device state.

## Local files and control API

`CovePaths` separates development and release data. `OPENCOVE_DATA_DIR` selects an explicit directory. A data directory must be private and owned by the current user; unsafe existing paths fail instead of receiving a silent permission change. The instance lock and optional `control.json` descriptor use owner-only access.

The development HTTP server starts only with `--control-port`, binds to loopback, and requires an ephemeral token. Its state includes bundle path and source-tree identity, current projected playback position, and native text-layer motion diagnostics. The checked-in CLI validates the descriptor and responding owner. Read [privacy](privacy.md) before enabling this interface and [quality](quality.md) for the real integration workflow.

## Media and rendering resource limits

Direct MediaRemote reads are preferred. On systems that deny them, one app-owned `/usr/bin/osascript` process runs the bundled independent JavaScript adapter. This adapter uses Foundation and MediaRemote; it does not use Apple Events. Native notifications refresh the process-local MediaRemote cache. The adapter reads active metadata once per second and checks an empty source once per second without rebuilding its full snapshot until a source change or 15-second retry. Identical snapshots have a 15-second heartbeat. The process has a three-minute lease; the parent renews it, owns cancellation, and checks startup and heartbeat deadlines. A legacy Swift source adapter remains available for diagnostics.

JXA property proxies are resolved with fresh native KVC getters. Native arrays and image bytes are inserted directly into the property-list payload. These boundaries preserve real command capabilities and prevent stale item data. Artwork requests check source, item, and artwork version before acceptance. Replies and decoded images are bounded; late replies cannot attach artwork to another item.

Artwork decoding runs outside the main actor. An eight-entry cache of 256px, eight-bit RGBA thumbnails retains at most 2 MiB of decoded pixels. Views reuse thumbnails rather than decoding full covers during playback ticks. Unchanged cover bytes are omitted from subsequent pipe frames; the reader merges the bounded artwork delta before coalescing UI deliveries.

Playback position uses a monotonic anchor with no service-level interpolation timer. Mounted progress controls observe this small clock and schedule their own updates; paused progress schedules stop. Elapsed-only metadata updates do not invalidate artwork, transport, compact panels, or geometry. Waveform observation stays in the waveform leaf view.

Progress labels use a half-second periodic timeline, not an animation/display-link schedule. Its paused sequence has one entry, so it stops requesting updates while keeping the same progress subtree. Decorative playback bars use five bounded native layer animations with the existing height range and rates. They add no SwiftUI frame timer or model publication. Pause, reduced motion, hidden/occluded views and dismantling stop their animations. The measured live-audio waveform remains a separate opt-in view.

Expanded media text scrolls only when it exceeds its available width. A native layer transform supplies linear movement and reading pauses without publishing model state per frame. Hidden/occluded views, reduced motion, and dismantled views stop that animation. Short text stays stationary. Display text and tooltips use at most 1,024 UTF-16 units plus an ellipsis; larger source values remain available through accessibility and the API. Text wider than the 4,096-pixel animation budget uses static truncation. Measurement does not assign an oversized backing frame. This is independently chosen reading behavior; exact reference-product timing is unmeasured.

Calendar activity ticks run only around actual event phases; an empty or unauthorized calendar has no second ticker. The independent timer uses whole-second updates plus its exact final deadline.

These are implementation limits, not a cross-machine performance guarantee. See [quality](quality.md) for real-interface checks and manual gates.
