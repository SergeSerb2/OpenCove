# OpenCove architecture

OpenCove is an independent MIT application. SwiftUI views run in AppKit windows and panels. The deployment target is macOS 15. Sparkle is a pinned binary dependency for updates; see [its trust and packaging policy](updates.md). No proprietary application code, artwork, binaries, or license service is included.

Middle-button navigation uses the existing native panel event handler. Button 2
in the compact panel or expanded gesture strip cycles enabled Media and Calendar
sections and expands the result. Files and Timer are outside that cycle. With
neither target enabled, the event does not change selection. Expanded content
keeps its normal event path. Swipe and scroll navigation retain their existing
enabled-section order. The handler adds no timer, event tap or global monitor.

General settings also has local `swipeToSkip` and `reverseSkipSwipe` choices.
Both default to false and stay outside the iCloud allowlist. They use the normal
preference recovery, normalization, save and error path. With skipping off, the
existing navigation handler retains its behavior. With it on, the top six points
of the panel remain an activity-navigation route. A precise, phased horizontal
scroll gesture can skip over compact media, Quick Peek, expanded media, or the
media view in Duo. Background AppKit markers measure the mounted media views;
Duo bounds do not come from a half-width calculation. Current presentation and
section identities revoke markers in retained outgoing views. Calendar, Files,
Timer, HUDs, hidden idle content and lock widgets supply no skip region.

The OpenCove thresholds are 28 points horizontally and 20 vertically, with a
1.25 dominant-axis ratio. These are independent choices, not measured reference
values. A skip uses leftward device movement for Next and rightward for Previous;
`isDirectionInvertedFromDevice` removes Natural Scrolling inversion, and the
optional reverse choice flips skipping only. Activity navigation retains its
original deltas. Vertical media gestures use the existing expand/collapse or
compact-dismiss actions. There is no new visual tracking animation. Scrubbers,
transport buttons, player-opening artwork, menus, output controls and compact
Calendar/Timer badges have input-exclusion markers. Native controls, editable
text, scroll views, sheets and open menus/popovers keep their own event paths.

Only a non-momentum `.began` can start a skip interaction. It captures the
source/item `seekTarget`, direction capabilities, view kind, marker identity and
revision, window frame and panel layout revision. Incoming item/capability,
store/activity, lock, session, sleep, presentation, disappearance and geometry
changes cancel it. Marker ancestry frame/bounds notifications cover geometry
changes between events. A canceled or completed media interaction remains
claimed until the next real beginning; pauses, `.mayBegin`, metadata refreshes,
end events and momentum cannot rearm it or turn it into activity navigation.
The enabled phased navigation route also latches after one action. Coarse or
unphased input, momentum and modified input cannot skip. Public `NSEvent` phase
and precision properties do not establish physical device identity: this filters
ordinary mouse wheels, but does not prove that every mouse is excluded.

`MediaController.skip(forward:target:)` requires available media, the captured
target and the actual direction capability. It submits synchronously through
the existing native bridge after fresh source, item and command checks. Adapter
metadata can use this entry only when that native bridge independently verifies
the current item. Otherwise it rejects the skip. No source-only adapter command
is queued: the existing adapter skip protocol accepts no item identifier. The
AppleScript queue has item epochs and track checks for item-bound work, but no
presentation/lifecycle cancellation lease; AppleScript-only swipe skips remain
unsupported. Existing button transports and seek behavior are unchanged. No new
private symbol or command option is introduced. These adjacent app-local checks
do not make the global OS command atomic, and submission does not confirm player
acceptance. This implementation has static parse and source-review evidence
only; the parent must verify real native gestures and owned-player behavior.

## State and service ownership

The local `hideWhenMediaAppActive` preference defaults to false. When enabled,
ordinary panels retire while the already accepted Now Playing source exactly
matches the frontmost application's bundle identifier. Unknown identities do
not hide them. This applies to browser sources when their accepted source is
the browser's actual bundle identifier; no process-family or website guess is
made. The existing AppKit application-activation notification and coalesced
media/layout updates refresh the decision. No media reader, timer, global input
monitor, player command, or new application observer is added.

Retirement cancels hover work, input and mounted gesture regions while keeping
the selected section and expanded state. Leaving the source app restores the
normal layout. Temporary HUDs retain priority and can display before the panel
hides again. Session, lock, display and full-screen rules still apply. Lock
widgets have their separate owner. The choice uses normal Boolean recovery and
atomic saving, stays outside the iCloud allowlist, and never enables media.
The authenticated development state exposes only the resulting Boolean as
`mediaSourceAppHiding`; it adds no frontmost application identity to the response.
Real source/browser activation, restoration and HUD-interruption acceptance
remain pending until the owned-media identity prerequisite is available.

Overlay timing uses the existing single cancellable dismissal task. Each category can inherit the default duration/appearance animation or override them. A zero category duration and `global` category speed select the defaults. A nonzero duration is 0.5–10 seconds; appearance choices are `smooth`, `fast`, and `instant`. The animation-speed multiplier and Reduce Motion still apply. Opening expanded controls and restoring the underlying activity use normal panel motion. Timing edits apply to the next presentation; repeated events replace the monotonic deadline. No countdown publication, polling schedule, helper, or per-frame task is added.

Activities settings include a labelled overlay preview. The preview reads cached available system values, reports unavailable readings, and uses the same presentation path. It does not write hardware, request access, perform haptics, or post a system notification. Disabled categories and expanded controls reject preview. Development clients can call `hud.preview` with a known `kind`; unknown kinds return 400 and unavailable previews return 409. `hudRemaining` reads the current monotonic deadline on request. Neither category timing nor preview enables an integration.

`CoveStore` is a main-actor `ObservableObject`. It owns preferences, selected tab, expanded state, HUD presentation, settings visibility, and the media, system, activity, weather, waveform, travel, notification-mirror, and hardware-key services. Views observe services directly as well as the store so service updates render without copying state into the store.

Services expose value models and bounded lifecycle methods. They do not reference `CoveStore`. The store connects their HUD callbacks, calendar routing feed, privacy gates, and preference changes. `OpenCoveApp` owns app lifetime and connects the store to the normal and lock panel controllers.

`savePreferences()` applies effective runtime choices before persistence. A save failure remains visible through `lastError`; privacy opt-outs still apply for that session. A failed save preserves the prior onboarding completion marker even when a login-item failure is followed by a successful JSON write. `completeOnboarding()` uses this same save path. Damaged preferences require a private recovery copy before replacement.

The store owns section selection. It applies the configured expanded-layout default at initialization, when that setting changes, and when opening the idle compact clock without a HUD. Calendar maps to Calendar; Automatic, Media and Duo map to Media. Unrelated saves and view mounting preserve manual choices. Disabling the selected section chooses an enabled default, then the first enabled section; all-disabled state has no visible section. Native menus, file-open routing and authenticated commands use one selection operation. A disabled `selectTab` request returns HTTP 409 before changing selection or expansion. The control state separates the remembered `tab` from the actual nullable `visibleTab` and lists `enabledTabs`. Rendering a native preview has no section-selection side effect. This policy adds no timer or observer.

New settings use the Automatic expanded layout. While Media is selected, playing
media and a visible current/starting-soon calendar activity enable Duo. The
calendar must remain enabled, valid, authorized and unredacted. A locked session
cannot activate Automatic Duo. Pausing media or losing the calendar activity
returns to the single Media surface. Explicit Media, Calendar and Duo choices
remain available and are preserved from existing settings.

`CoveStore.showsExpandedDuo` supplies one decision to the SwiftUI section and
native desired size. The native layout-input comparison includes that decision,
so playing/paused changes can update geometry even when compact visibility stays
the same. This consumes existing service publications and phase boundaries;
it adds no timer, reader, permission request or recurring model publication.
The opt-in control snapshot reports `expandedDuo` on request. It reports the
policy decision, not proof that a populated split view was rendered.

## Native surfaces

`NotchPanelController` manages display selection, per-display cutout geometry, hover/scroll handling, and panel lifetime. A display without a cutout uses a floating rounded pill. Geometry refreshes compare their inputs, so a media clock tick does not enumerate displays or query fullscreen windows. The native window and SwiftUI content share one motion policy, with reduced-motion support. `NotchView` renders compact and expanded content from real service state. Settings and onboarding use separate native windows. Normal panels require an active, unlocked session.

The shared compact/expanded surface has a local `useAccentOutline` Boolean, defaulting to false. Appearance / Panel shape exposes “Use accent color for outline” only while `showContrastOutline` is enabled. Under normal contrast, an enabled outline uses `CoveNotchStyle.accent(preferences.accent)` when the choice is on and white when it is off, at the existing 45% opacity. Increase Contrast always forces the existing opaque white outline, regardless of either preference. The doubled two-point stroke stays clipped inside the shape for a one-point visible outline. Geometry, center clearance, input bounds, accessibility exclusion, idle hiding, the faint fallback stroke and panel lifetime keep their existing behavior. The color choice alone cannot enable an outline.

The new field uses the existing local preference document, `recover()` defaults/type repair, `savePreferences()` and visible save-error path. An omitted key retains false; an invalid Boolean repairs to false and appears in the existing recovery notice. It stays outside the explicit `CoveSyncedSettings` allowlist and does not change `syncSettingsWithiCloud` or HUD settings. The saved-accent choice is an OpenCove design decision. The supplied Alcove 1.7.6 changelog declares colored outline support but does not specify adaptive sampling; this feature does not establish a reconstruction of that behavior. It adds no sampler, watcher, timer, animation, global setting or desktop read.

Colored-outline acceptance remains pending after source-only implementation. A later task with explicit runtime/render scope must use an isolated app and private owned files and captures (0700 directories, 0600 files):

1. Before startup, disable personal/protected integrations, media, Calendar, weather, mirroring, hardware-key replacement, haptics, waveform and iCloud. Set `hideWhenIdle=false` and use the actual clock-only compact panel and an actual empty expanded panel. No player, EventKit, cloud or hardware input is needed.
2. Under actual normal host contrast, submit `showContrastOutline=true` and a saved blue accent through the authenticated `preferences` command. Capture the mounted owned `live-notch` surface for `useAccentOutline=false / true / false`. Require white / accent / white border-region pixels at the existing opacity, with unchanged interior, native frame, center clearance and input bounds. Repeat with orange, in compact and empty expanded states, for both the floating pill and attached simulated-notch geometries. Record the geometry exercised; simulation does not prove physical-notch behavior.
3. Capture the actual native Appearance settings at `settings-appearance` and verify the new control and its outline-enabled visibility. Separately exercise actual browser input through the authenticated control interface, including outline enablement, valid changes and invalid Boolean rejection without changing live or saved state. This slice adds no dedicated browser checkbox for `useAccentOutline`; browser input for that choice requires a separately authorized real input surface. Neither API readback nor a native render alone proves input. Keep the native-control and browser-input gates separate and pending until exercised.
4. Under normal contrast, set `showContrastOutline=false` and toggle the color choice: the existing faint fallback must remain unchanged. With `hideWhenIdle=true` and no active activity, no outline may remain visible. Check both geometries and restore the owned configuration.
5. Save and restart to verify both false and true choices. Separately load owned legacy files missing the key and owned files containing invalid Boolean values. Require false defaults/repair, the existing invalid-field notice and recovery backup, and preservation of unrelated preferences. Invalid API input must reject rather than repair.
6. Use a real unwritable owned preference destination, not an injected failure. Require the actual failed-save response and native settings error. A session choice may apply, but must not claim persistence. Restore access and restart from the last successful file to verify it survived.
7. Increase Contrast proof requires actual host accessibility state and the mounted owned panel: require opaque white with the color choice both off and on, including blue and orange, compact/empty expanded and both geometries. Do not change the system toggle or substitute an injected environment value. If that host state is unavailable, leave this gate pending. If the host is already in Increase Contrast, leave normal-contrast color proof pending.

AppKit owns the panel's moving viewport. Compact and expanded controls keep their destination layout sizes during the transition; they do not reflow through intermediate window dimensions. A flexible viewport draws and clips the surface at the current native bounds. Incoming controls fade after the viewport starts opening, and outgoing controls fade sooner at their existing size. A retained transition reads the current presentation policy: Reduce Motion immediately reveals active controls and clears departing controls, including during a scheduled fade. The native drawer curve retains the existing duration and speed settings, without overshoot. Will-change notifications coalesce into one main-actor layout job, which checks committed geometry inputs before querying displays. This adds no frame timer, display link, model publication or helper process.

Expanded activity and single/Duo replacements use the shorter content fade, without the panel-opening delay. A separate activation revision keeps only the selected section interactive and accessible; an outgoing section can fade only while its feature and privacy gates remain valid. Reduce Motion settles that section immediately and stays settled if the option is switched off before the old fade ends. A later distinct section change gets a new revision and can animate again. This changes content replacement, not the native window's geometry curve.

The compact activity preference chooses Automatic, Now Playing, Calendar or Timer. A preferred activity must be enabled and actually available; otherwise the shared store policy falls back to media, timer, calendar, then the idle clock. Calendar availability requires a real event activity, and media respects paused-media hiding. The choice never enables a service. Temporary HUDs still take priority without changing the remembered expanded section. Clicking the compact panel or completing hover expansion opens the displayed activity. Opening a HUD preserves the prior section. Opening the idle clock without a HUD resolves the saved expanded layout through the same enabled-section fallback used at initialization, then expands; all-disabled state opens with no visible section. Plain expansion and explicit section selection retain their existing behavior. The authenticated `compact.open` command uses the same operation. `compactActivity` in control state identifies the underlying resolved activity, independently of the temporary `hud` and expanded state. Native content, accessibility text and desired panel geometry share this policy. It adds no observer, timer or process. Missing legacy preferences retain Automatic.

Compact activities can be dismissed independently of their services. The existing panel collapse gesture closes expanded controls or dismisses the current compact activity. The native context menu and accessibility actions provide Dismiss and Restore alternatives. Restore also appears in the expanded section menu and brings the restored activity forward in compact form. The dismissal history is session-only and bounded to one instance per category. Media uses source/item identity, with metadata fallback when no identified source/item pair exists; timers use a presentation ID that survives pause/resume; calendar uses event ID and occurrence start. A new instance is eligible without inheriting an old dismissal. Completed or unavailable instances cannot be restored. An explicit compact-priority change clears the history; feature-toggle changes clear the affected category. Restart clears all dismissals. These actions do not stop playback, cancel timers, alter events or save preferences. Dismissed secondary summaries are omitted too; all-dismissed state follows the existing idle-hiding choice. HUDs prevent dismissal of an obscured activity.

The authenticated `compact.dismiss` and `compact.restore` commands require the exact `target` from the corresponding nullable `compactDismissTarget` or `compactRestoreTarget` state field. The UI captures that target when offering its action, so an old menu or queued request cannot affect a replacement instance. Missing/malformed targets return 400; stale or unavailable actions return 409. State also reports eligible `compactActivities`, current `dismissedCompactActivities`, and the corresponding action activity kinds. These are in-memory presentation fields. They add no polling, persistence, helper or recurring model publication. Physical gesture feel and exact Alcove dismissal rules require separate reference/manual evidence.

Opt-in song-change peek is separate from expanded, HUD and compact-selection state. The existing media subscription compares the source and opaque item identity, with title/artist/album fallback when no item identity is supplied. It ignores obsolete deferred samples and does not show a peek for initial discovery or reconnection, resume, or same-item metadata changes. A playing-item change in an active unlocked session shows bounded metadata and cached artwork below the camera clearance. One cancellable monotonic deadline retires it; a newer item replaces that deadline with a revision guard. Elapsed/rate/artwork and unrelated preference updates do not restart it. The bounded 1–10-second duration applies to the next peek. Opening controls, explicit collapse, pause, a HUD, media/peek opt-out, source-policy changes, session boundaries and stop cancel it. A peek opens Media through `compact.open`; expiry restores the underlying compact activity without changing the remembered expanded section. Native geometry and content use the shared motion policy, including reduced motion. `mediaPeekVisible` reports actual eligible presentation. The authenticated state's nullable `mediaPeekRemaining` reads the actual monotonic deadline on demand and adds no publication ticks. This adds no subscription, polling loop or helper process. Older preferences leave the feature off.

Optional simulated-notch presentation attaches the panel to the display edge. `CoveNotchCutout` resolves center clearance as the maximum of the real camera housing and bounded Width/Height preferences. Live per-display views and native previews share it; physical notch diagnostics retain only real hardware measurements. Ordinary notchless presentation keeps its six-point top gap. Simulation uses existing layout and motion updates and adds no timer, observer or helper. Idle hiding still retires the simulated panel's content. `settings-appearance` is an offscreen native capture surface available through the existing authenticated API and CLI.

If Reduce Motion becomes active during a native frame transition, the controller replaces the running animator with its final frame immediately, even when the destination is unchanged. A revision check prevents an older completion from hiding restored content. This adds no timer or observer; it uses the existing preference and accessibility notifications.

Optional paused-media hiding affects compact presentation only. The store observes source/item and playing-state changes, with one cancellable continuous-clock deadline after an observed pause. Elapsed, artwork and playback-rate updates do not extend that deadline. Full media state and controls stay available; playing or a new item restores compact media. Timer/event content and temporary HUDs retain their normal priority. No extra polling loop or persisted idle deadline is added. A new launch starts a fresh grace when it first observes a paused item. When idle hiding removes the whole compact surface, its content fades as the native panel shrinks. The hosting view retires after the transition; a newer layout cancels the old completion. Hidden idle content does not mount the clock timeline. Reduced motion skips the transition.

`LockScreenController` owns the optional lock widgets. Their presentation requires explicit opt-in, private integrations, a known locked state, an active console session, and awake displays. These are ordinary app panels; macOS owns authentication and the system clock. Secure-screen visibility and credential clearance need manual verification on each supported OS. Lock weather attribution uses readable literal URLs rather than external-app actions.

### Independent lock-screen widgets: local consent

The retained reference declares “Fixed widgets to work properly even if activity is disabled”
(1.3.6, fixes[8]). This source implements a separate local widget policy. It does
not establish reference visual parity or secure-screen acceptance.

`lockWidgetsFollowActivities` defaults to true, including when the mode is missing
from a saved document. Follow mode uses the six existing activity choices.
Independent mode uses explicit `lockWidgetMedia`, `lockWidgetCalendar`,
`lockWidgetWeather`, `lockWidgetBattery`, `lockWidgetFocus`, and
`lockWidgetBluetooth` selections. All six default to false. A mode change clears
all independent selections; it never copies activity choices. The fields stay
outside `CoveSyncedSettings` and apply only to this Mac.

**Collection is not lock-only.** An explicit local widget choice permits the
selected existing reader while the app is started and its console session is
active, including unlocked periods. The widget master and private integrations
must already be on. The native control discloses this scope before an affirmative
choice; it never enables a prerequisite, selects a weather location, requests OS
access, or grants locked event details. Missing or denied access stays unavailable.
The existing source choices, Calendar exclusions/declined/subscribed filters,
weather location consent, cancellation and authorization gates remain in force.
Battery uses the existing public base monitor; turning its widget off does not
stop that shared monitor.

`CoveStore` owns the single preference transaction. Preferences are read-only to
other types. Native settings, onboarding, display selection, generic API patches,
reset, and remote style overlays enter store methods. Ordinary settings retain
their existing session-on-save-failure behavior. Independent additions use only
`setIndependentLockWidget`, called by the disclosed native control. The store
keeps a prospective addition out of published/effective state until the complete
local save succeeds. Login-item failure strips the prospective addition before
any JSON write, even though other settings can still be saved. Backup, encoding,
or write failure discards the addition. No draft, pending grant, retry closure or
unrelated later save can activate that failed addition in the current session.
Validated saved selections can be restored on a later launch.

A mode change, widget master off, private integrations off, or a true-to-false
locked-event-details choice clears all independent selections. Each activity's
true-to-false transition clears its matching selection. A separate later native
affirmative choice can enable the widget while that activity remains off. The
API rejects additions and explicit disable-activity-plus-enable-widget batches
with HTTP 400 before applying them. Other valid patches can revoke selections.
Re-enabling a prerequisite cannot restore a selection. Reset keeps the existing
ordinary defaults and grants no independent widgets. A partial, non-Boolean or
orphan widget consent record clears the independent selections; missing mode
keeps Follow, a valid explicit independent mode stays independent, and malformed
mode fails to independent with no selections. Any repaired preference document
also clears surviving independent grants. Recovery keeps the existing actual
error and exact original-file backup path before a later save.

Revocations publish and stop no-longer-needed extra readers synchronously before
fallible persistence. Existing generations/cancellation reject stale results;
a synchronous OS query already in progress need not be physically interruptible.
**If revocation cannot be saved, the previous saved choices may return after
restart.** The actual save error and this warning stay visible in Settings.
This deliberate limit matches existing preferences. There is no restart
interlock, crash-proof revocation guarantee, or new confirmation flow. An
unrelated successful save can persist the effective revocations; an unrelated
failed save cannot re-grant them in the current session.

Reader demand is the old activity demand OR the eligible independent selection.
Session resignation removes extra demand, and session return can restore a valid
saved/effective selection. Calendar receives reader demand and activity intent
in one configuration call before work is queued. Widget-only Calendar reads its
existing seven-day feed and selected month's 42-day grid. It does not create an
event activity, alerts, alert receipts, travel routes, Duo demand, activity ticks,
permission requests, or disabled-activity date/open/join actions. Widget-only
media uses the existing selected native reader/adapter without AppleScript
Automation fallback and never enables live waveform capture. Waveform demand
continues to require the Media activity, playback indicator, and live choice.
Activity HUDs keep their old activity gates.

Presentation remains separate from reading. The lock controller retains started,
active-console, fresh-session-check, awake-display, private-integration, master,
known-lock and locked-state guards. It selects content with the effective widget
policy and removes panels through the existing guard path. These are app-observed
guards, not atomic physical-lock guarantees. Locked media restrictions, Calendar
redaction, hidden weather location name, and literal attribution URLs remain.

The control API reports selections, last validated/saved selections and extra
reader requests as policy status, without widget-only content. Disabled Media
and Calendar activities reject their API commands with HTTP 409. State masks
widget-only Media, Calendar, weather, Focus and Bluetooth content and artwork
availability. Development captures of widget-only lock content and disabled
weather content are rejected. No widget-grant API or capture preset is added.
The native permission buttons still require the matching activity; extra reader
demand alone cannot enable them.

Source parsing and diff review are the only validation for this implementation.
Compilation and all real-interface checks remain parent-owned and pending:
legacy and independent selection, each revocation path, conflicting batches,
backup/write/login-item failures, unrelated local/remote saves, restart after a
failed revocation (where old choices may return), denied permissions, Calendar
consumer isolation, waveform isolation, session/lock/display removal, native
Settings layout/accessibility, and secure-screen visibility/credential clearance.
Strict owned-media C-PID remains **FAILED**, with no injected substitute.
M1 identity and two-Mac iCloud delivery remain **USER-DEFERRED**.


## Service boundaries

- `MediaController`: real media metadata, command capabilities, transport, artwork, optional Apple Events fallback, and the isolated system MediaRemote adapter. Unsupported actions stay unavailable.
- `SystemController`: CoreAudio outputs, supported volume/mute, battery, Bluetooth, Focus, optional private brightness, and conservative session/lock knowledge.
  The store passes the effective Bluetooth and Focus reader demand (activity OR eligible independent widget) before the first system read and on runtime preference/session changes, including when private integrations do not change or saving preferences fails. Each reader with no demand skips authorization queries, device/registry enumeration, Focus status reads, and its observer/poll work. With no remaining demand, opt-out removes Bluetooth subscriptions and retained devices/battery reports, clears Focus knowledge, and retires pending reader callbacks with separate revisions. Queued Bluetooth events check that revision and the feature flag before accessing a device. Disabled authorization text describes the app setting, not an OS permission result. Explicit permission buttons require the matching feature to be enabled; a late permission completion cannot restart an opted-out reader. CoreAudio route data and the audio, battery, brightness, lock, and workspace paths keep their existing behavior.
  The output picker's appearance refresh reads audio only. It still enumerates current outputs and reads the real route, UID, levels and capabilities. Explicit route/volume/mute writes retain their fresh identity and capability checks. An opt-in development acceptance window can record synchronous domain entries and attempted controller hardware writes; outside that window it retains no samples or timing work.
- `ActivityController`: EventKit reads, calendar filters and alerts, bookmark-backed file references, a persistent timer, and app notifications. It never edits calendar events.
- `WeatherController`: explicit location selection, bounded Open-Meteo refreshes, stale-state handling, and cancellation on opt-out.

Weather presentation has Conditions, Sun and Precipitation styles. They share the same 24-hour/7-day response and add no service, request cadence or permission. Each mounted weather surface has one minute-based timeline for its summary, forecast and age labels. Missing sun times or chances remain unavailable. The daylight arc shows elapsed daylight, not a physical sun position. The provider's daily daylight duration distinguishes continuous daylight/night; midnight interval boundaries are not exposed as sunrise/set events. Sun events and civil-day selection use the location's IANA time zone. [Open-Meteo](https://open-meteo.com/en/docs#hourly-parameter-definition) defines precipitation probabilities for the preceding hour ending at each timestamp; the current-hour summary selects that interval, while forecast cells retain the provider's end-time labels. Style changes use the shared motion policy and respect reduced motion. The locked summary does not construct the saved location name. The opt-in state endpoint reports the actual bounded presentation and a weather request-attempt counter for verification.
- `TravelController`: consented origin, reduced physical event destination, real MapKit directions, route freshness, and deduplicated leave alerts.
- `AudioWaveformController`: optional ScreenCaptureKit audio levels in memory, with serialized stream startup/cleanup.
- `NotificationMirror`: opt-in, bounded AX reads of newly exposed Notification Center banners. The store supplies a collection gate and clears mirrored presentation when collection stops.
- `HardwareKeyController`: optional supported hardware-key interception. It consumes a key after a supported write is attempted, including an OS write failure, to avoid applying the same input twice. Capability or identity rejection before the write passes through. Submission is separate from confirmed device state.

The public models describe availability and capabilities. Empty or denied data does not become sample tracks, events, routes, or fabricated device state.

## Local files and control API

`CoveDisplays` supplies one display-selection policy for native notch panels and optional lock widgets. It considers active, online, awake logical screens and deduplicates their display IDs. All takes precedence over a saved individual UUID, followed by the built-in/main preference. An unavailable or ambiguous saved identity falls back to the primary available screen without erasing the saved choice. Main uses `CGMainDisplayID`, so opening a key window on another screen does not change this policy. Missing or duplicate UUIDs cannot be chosen individually. Display discovery runs during existing coalesced layout and lifecycle events; it adds no timer. Settings read a cached plain-value catalog, and unchanged catalogs do not publish updates.

The authenticated `display.select` command accepts `builtIn`, `main`, `all`, or a currently available unique display UUID as `choice`. The native picker calls the same store operation. A stale unavailable choice returns HTTP 409, malformed input returns 400, and a failed save returns 500 with the runtime choice and visible save error retained. Generic `preferences` can restore a valid saved UUID that is currently absent; the resulting state explains the temporary fallback. `displaySelection` describes that policy, while `nativeWindows[].displayID` reports the actual window screen for real placement checks.

`CovePaths` separates development and release data. `OPENCOVE_DATA_DIR` selects an explicit directory. A data directory must be private and owned by the current user; unsafe existing paths fail instead of receiving a silent permission change. The instance lock and optional `control.json` descriptor use owner-only access.

The development HTTP server starts only with `--control-port`, binds to loopback, and requires an ephemeral token. Its state includes bundle path and source-tree identity, current projected playback position, and native text-layer motion diagnostics. The checked-in CLI validates the descriptor and responding owner. Read [privacy](privacy.md) before enabling this interface and [quality](quality.md) for the real integration workflow.

## Media and rendering resource limits

Direct MediaRemote reads are preferred. On systems that deny them, one app-owned `/usr/bin/osascript` process runs the bundled independent JavaScript adapter. This adapter uses Foundation and MediaRemote; it does not use Apple Events. Native notifications refresh the process-local MediaRemote cache. The adapter reads active metadata once per second and checks an empty source once per second without rebuilding its full snapshot until a source change or 15-second retry. Identical snapshots have a 15-second heartbeat. The process has a three-minute lease; the parent renews it, owns cancellation, and checks startup and heartbeat deadlines. A successful source-bound adapter command can wake that existing reader through its private stdin pipe after a coalesced 50 ms delay. The input requests metadata only. A command burst reads at least 250 ms apart for up to 750 ms, stopping when the actual item or playback state changes. Early reads do not postpone the normal periodic read. Input EOF leaves that normal cadence and lease intact. The parent uses a nonblocking, SIGPIPE-safe writer and unpublishes it before descriptor cleanup. This adds no process or faster background polling. A legacy Swift source adapter remains available for diagnostics.

Explicit media refresh from the empty-state button, Refresh Activities menu or authenticated control command wakes the existing adapter through its bounded metadata-only input before consuming the cache. Internal refreshes keep their existing cadence. The child coalesces request bursts; a stopped or unavailable adapter receives no write. The command remains asynchronous: its response confirms submission, and later native delivery updates the item.

JXA property proxies are resolved with fresh native KVC getters. Native arrays and image bytes are inserted directly into the property-list payload. These boundaries preserve real command capabilities and prevent stale item data. Artwork requests check source, item, and artwork version before acceptance. Replies and decoded images are bounded; late replies cannot attach artwork to another item.

Artwork decoding runs outside the main actor. An eight-entry cache of 256px, eight-bit RGBA thumbnails retains at most 2 MiB of decoded pixels. Views reuse thumbnails rather than decoding full covers during playback ticks. Unchanged cover bytes are omitted from subsequent pipe frames; the reader merges the bounded artwork delta before coalescing UI deliveries. A different source/item/version resets the send context even when it has no artwork, so returning to an earlier item sends that cover again.

Ready, different covers from the same source use a 120 ms opacity crossfade with the shared content curve. SwiftUI owns two fixed image slots, retaining at most one outgoing cover. A small native layer view interpolates the top cover's opacity and reports one revision-checked completion. A reversal between those covers starts from the current presentation opacity; a third ready cover waits for the active fade and then uses the latest input. A brief missing decode result preserves the current blend, with a 200 ms hold that repeated missing input or motion changes cannot extend. Source changes, source loss, Reduce Motion, disabled outgoing sections and disappearance clear or settle the presentation immediately. Turning Reduce Motion off cannot resume an old fade. This adds no recurring timer, display link or model publication schedule. The opt-in development snapshot reports native opacity and a conservative remaining-time budget on demand. Native capture copies presentation opacity for its synchronous draw and restores the target without restarting the animation.

The activity timer keeps its saved absolute deadline and schedules one completion boundary. Its API snapshot derives remaining time on demand; it does not publish every second. Only mounted countdown labels use a one-second timeline, which stops while paused. The expanded ring uses a native layer animation toward the actual deadline, with no SwiftUI frame schedule. Color/layout updates preserve its phase. Pause, Reduce Motion, hidden/occluded views and dismantling remove its continuous animation. Reduced Motion keeps functional whole-second progress in that mounted leaf. Clock/wake events recheck completion, reschedule the boundary and retarget native progress, including a full-progress hold after a backwards clock change. Compact accessibility labels use SwiftUI's deadline-based timer text. This does not change persisted deadlines, pause values or notification identity. Calendar activity scheduling is unchanged.

The opt-in development server counts timer publications and reads actual timer-layer state only when requested. Native capture temporarily copies presentation stroke values into model layers for AppKit's caching renderer, then restores those models in the same transaction without stopping motion. It never reads desktop pixels or adds a diagnostic ticker.

Playback position uses a monotonic anchor with no service-level interpolation timer. Mounted progress controls observe this small clock and schedule their own updates; paused progress schedules stop. Elapsed-only metadata updates do not invalidate artwork, transport, compact panels, or geometry. Waveform observation stays in the waveform leaf view.

Progress labels use a half-second periodic timeline, not an animation/display-link schedule. Its paused sequence has one entry, so it stops requesting updates while keeping the same progress subtree. Decorative playback bars use five bounded native layer animations with the existing height range and rates. They add no SwiftUI frame timer or model publication. Pause, reduced motion, hidden/occluded views and dismantling stop their animations. Playback indicators can be None, decorative bars or optional measured system-audio levels. None unmounts the decorative/live leaf from compact, song-peek, expanded and lock layouts. A legacy document keeps the prior decorative/live choice; malformed indicator flags recover to off. System-audio capture requires enabled media, an enabled indicator and the saved live-waveform choice. Off or disabled media stops capture, even if the saved live choice remains true. An already stopped meter does not allocate another teardown task on unrelated saves. The store rechecks these gates before the explicit permission button. No permission request is part of rendering or preference restoration.

Unknown-duration progress is static and does not mount an observing playback clock or timeline; the API clock still advances independently. A later timed item mounts normal progress again. Live status comes from the source's numeric boolean metadata: current `IsAlwaysLive`, with `IsLiveStream` retained as an older-field fallback. Missing/malformed flags remain unknown; zero duration never implies live content. The native mapping was observed from the public MediaPlayer [live-stream property](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfopropertyislivestream). Live status does not itself remove advertised seek support; the existing duration, item-identity and capability checks still apply.

Media state also supplies an ephemeral `seekTarget`. The controller renews it on accepted item/source/backend identity changes and media restarts, including two items with identical displayed metadata. Position, rate, pause and artwork updates for the same identity retain it. Native progress closures capture the rendered target, compare it before value/edit callbacks and include it in scrub identity; the controller rechecks it before submitting. The notch and lock widget use this shared media surface. The locked layout omits app-opening artwork, action menus, clipboard actions and output popovers; its transport and seek controls cannot take keyboard focus. The existing lock/session/privacy and non-key-panel gates remain in the controller. API clients can pass `target` to `media.seek`; a retired target returns 409 and a malformed target returns 400. An omitted target retains immediate-current-item behavior for existing protocol-1 callers. Delayed requests should always echo the current target. Backend-native source/item guards still protect submission races, and HTTP 200 means submission rather than player confirmation. The target is bounded, in-memory and does not add a timer or observer.

Source format, live and advertised-speed badges share one caption row. Format rendering uses at most 32 UTF-16 units plus an ellipsis, with a single line and a tooltip bounded to 160 units plus an ellipsis. The API retains the original source format. This keeps metadata labels from adding unlimited rows or measuring an unbounded format string. Explicit-content status remains optional source data; this live-stream change does not invent an explicit badge from a title or an absent flag.

Expanded media text scrolls only when it exceeds its available width. A native layer transform supplies linear movement and reading pauses without publishing model state per frame. Hidden/occluded views, reduced motion, and dismantled views stop that animation. Short text stays stationary. Display text and tooltips use at most 1,024 UTF-16 units plus an ellipsis; larger source values remain available through accessibility and the API. Text wider than the 4,096-pixel animation budget uses static truncation. Measurement does not assign an oversized backing frame. This is independently chosen reading behavior; exact reference-product timing is unmeasured.

Calendar activity ticks run only around actual event phases; an empty or unauthorized calendar has no second ticker. The independent timer uses whole-second updates plus its exact final deadline.

These are implementation limits, not a cross-machine performance guarantee. See [quality](quality.md) for real-interface checks and manual gates.

The shared media surface renders a static explicit-content badge only for `isExplicit == true`. It uses the existing source-coherent state; it adds no timer, process, metadata inference or extra read. False and unknown states omit the badge. The label says Explicit content for accessibility and identifies the player as the source of the marking.

Shared media artwork uses one bounded cache result per mounted surface for both cover and tint. A mounted cover can keep its outgoing thumbnail for at most 200 ms while the same source prepares a replacement, then apply the bounded transition above. A source change suppresses it immediately, and opt-out unmounts it. This is presentation continuity only: it never supplies old bytes or tint as current-item metadata. Its cancellable decode task runs only on cover/source changes. The displayed bytes must match the resolved bytes, and canceled tasks cannot replace newer artwork. The artwork-color preference selects this ready tint immediately, including compact media and song peeks; missing/invalid artwork uses the surface’s existing fallback. The adapter reader waits for actual data, a lifecycle wake pipe, or its existing watchdog deadline. Stop and child exit wake it directly; the reader owns descriptor cleanup. Travel owns a heartbeat only while its service and saved travel enablement are active.
