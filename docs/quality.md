# Quality and integration checks

Verify through the real built app, authenticated HTTP API, checked-in CLI, and native offscreen renderer. The project does not use unit tests, isolated-function checks, or mocked services for this workflow. Run from the repository root with the toolchain in [building](building.md).

## Optional Bluetooth onboarding

Retained declaration `1.2.3 features[3]`, “Added Bluetooth step to onboarding”
(audit O02), maps to the explicit Bluetooth page between Permissions and Ready.
It participates in the actual onboarding enum, title, step count and Back/Continue
navigation. The page observes the existing `store.system`, shows its published
Bluetooth authorization, capability message and errors, and explains why the
request button is disabled or busy.

Only **Allow Bluetooth Access** calls the existing `requestBluetoothAccess()`.
The action requires `enableBluetooth`; the control also stays disabled while a
request is in flight, as in Settings. The controller retains its running,
reader-enabled, in-flight and bundle usage-description guards. Entry, Back,
Continue, skipping and completion add no Bluetooth request, refresh, scan or
reader start. They do not change `enableBluetooth`, other feature defaults,
private-integration choices or independent widget consent. The existing Ready
controls and `completeOnboarding()` save result still govern completion and
dismissal; a failed save keeps setup open with the store error visible.

This page is not a first-read opt-in. `enableBluetooth` defaults to true, and an
independent Bluetooth lock-screen widget can keep reader demand active while
the activity is off. A disabled request button describes the activity guard,
not proof that every Bluetooth reader is stopped. An existing OS grant can
already permit reads. Completion neither grants access nor changes that policy.

Parent-owned real acceptance remains required:

1. In an owned packaged app with protected readers and all independent grants
   already off, open the existing Review Setup flow. Inspect the optional page,
   actual status, disabled request and explanation. Use Back and Continue without
   making a request or enabling an activity/widget. Confirm four-step progress
   and retained Ready controls. Normal-window scrolling, keyboard and accessibility
   reachability require authorized native evidence.
2. Complete through the real UI, reopen setup and restart through the supported
   workflow. Confirm saved completion and unchanged activity, private-integration
   and independent-widget choices. Do not infer a permission grant from a saved
   completion marker or an API response.
3. Exercise a real save failure in the owned app data path. Setup must remain open,
   the error must be visible, and the saved completion marker must not advance.
   Reopening/restarting must reflect the actual saved state. Do not mock the store
   or inject device data.
4. The affirmative OS request, denial, device data and late callbacks stay
   **UNVERIFIED**. No grant or independent widget enablement is needed for the
   no-grant path. Keep each positive gate separate.

This slice has source parsing and diff/call-site review only. Build, runtime,
native input and real persistence acceptance remain **UNVERIFIED** and owned by
the parent. **C-PID remains FAILED. M1 remains USER-DEFERRED.**

## Mission Control presentation

The local `hideInMissionControl` choice defaults to false. Ordinary notch panels use AppKit's [`stationary`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/stationary) behavior when off and [`transient`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/transient) when on. AppKit documents that transient windows hide in Mission Control. The choice updates existing panels and applies to newly created panels. Other panel behaviors and the lock-screen controller stay unchanged. It adds no Mission Control observer, polling, permission, private API or cloud setting.

Verify off/on/off through the real preferences command and inspect `nativeWindows[].missionControlPolicy` for the mounted notch panels. Verify persistence across restart and rejection of a non-Boolean value. These observations establish the app's actual window policy, not physical Mission Control visibility. Native toggle input, Mission Control entry/exit, Spaces, full-screen transitions and multiple displays remain separate acceptance gates.

## Declared Games category hiding

The local `hideForGamesCategory` choice defaults to false. Missing or invalid saved values recover to false. It is outside the cloud allowlist. Settings labels it **Hide for apps in the Games category** and explains its declared-category coverage. This advances only a subset of retained `1.7.3:5` / audit D03. Full gaming parity remains **INCOMPLETE**. It does not detect system Game Mode or actual play.

The primary contract is Apple's [Launch Services Keys reference, LSApplicationCategoryType, tables 2 and 3](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/LaunchServicesKeys.html#//apple_ref/doc/uid/20001431-108256). The key is a String. The classifier accepts exactly `public.app-category.games` and the 19 documented game-specific UTIs. It does not use a prefix match, title, process name, fullscreen state, custom UTI conformance, or launcher identity. AppKit's public `NSWorkspace.frontmostApplication`, `NSRunningApplication.isActive`, and `bundleURL` identify the supplied frontmost app. OpenCove's own process is excluded before bundle access.

Only controller start, the existing workspace activation observer, and changes to this opt-in refresh the cached Boolean. Off returns before frontmost lookup or category file access and clears the cache. Unrelated preference edits, animation, layout, clock ticks, HUD updates, and developer snapshots do not read the category file. The reader opens only that bundle's `Contents/Info.plist`. It rejects an Info.plist symlink, nonregular file, empty file, and file larger than 256 KiB before reading. The read is capped at the checked size. Missing, unreadable, malformed, non-String, and unsupported declarations are unknown and never hide. There is no filesystem scan, helper, new monitor, permission, private API, or activity reader.

A match retires the normal panels through the existing teardown: hover/collapse work, event handlers, gesture state, sheets, responders, and mounted surfaces. Logical expansion and section selection remain intact. Leaving the app or disabling the setting lets the existing layout restore them. Invalidating the layout cache also covers rapid opt-in changes that end at the original value. Session, lock, display, active-media hiding, and fullscreen guards retain their existing order.

**Alerts retain the existing active-media HUD priority.** A nonnil HUD bypasses this category hiding policy. Alerts are neither paused nor queued by this setting. Their existing dismissal deadlines continue unchanged. The existing expanded/HUD presentation rules still apply. On HUD expiry, layout uses the cached classification and hides the panel again. Other guards can still prevent display. The authenticated state field `declaredGameCategoryHiding` reports this policy Boolean only. It adds no app name, bundle identifier, path, raw category, setter, or fresh metadata lookup.

This slice received source parsing, diff review, and static call tracing only. **Build and all real acceptance are UNVERIFIED and owned by the parent.** Parent acceptance must cover default/legacy false, strict Boolean persistence and rejection, off/on/off including rapid changes, own-process and unknown cases, real game-category and game-subcategory activation/leave, restored expansion/section, input retirement, HUD expiry, lock/session/sleep, multiple displays, and interaction with existing media/fullscreen hiding. Positive coverage requires an actual game app with a supported declaration. No real game fixture was supplied or inspected here. No test, mock, synthetic activation, app, helper, or runtime check ran. **C-PID remains FAILED. M1 remains USER-DEFERRED.**

## Public Low Power Mode overlays

Retained W02 is “Added low power mode notification”, version 1.3.2,
14 Sep 2025, `/entries/4/minors/7/features/1`. It does not specify defaults,
direction, consent, visuals or native-notification behavior. This bounded OpenCove
slice selects local default-off, save-first native consent and both observed
Boolean directions. It does not establish exact reference-product parity.

The public contract is `ProcessInfo.isLowPowerModeEnabled` plus
`NSProcessInfoPowerStateDidChange` (macOS 12+, below this app's minimum).
The retained Foundation header explicitly collapses unknown/unsupported hardware
to false. Status is typed; only `reported` has an optional real Boolean. Disabled,
paused and awaiting-baseline states have nil. `apiUnavailable` is reserved for API
availability, unreachable at the current target; it is not a fabricated getter
error or a hardware inference. No permission or private API is a prerequisite.

Source invariants for this slice:

- `enableLowPowerModeAlerts = false` is outside the fixed sync allowlist.
  Only the disclosed native action can add it, after the central save and existing
  registration handling succeed. Generic/reset/cloud/widget paths cannot grant it.
  Recovery fails closed; Battery & charging opt-out clears it. Revocation reaches
  the controller before fallible saves. A failed write retains the explicit warning
  that an older saved grant may return after restart.
- The dedicated MainActor domain is outside `SystemRefreshParts`, `.all`, battery
  invalidations and existing timers. One default-center token has a weak owner,
  exact ProcessInfo object and main delivery queue. Registration precedes a silent
  baseline. Before each getter and after publication, running/demand, global and
  domain revisions, and token ownership must still match. Equal readings do nothing.
  State publication that reenters teardown cannot emit an old-domain event. A
  cache-only state-commit check repairs stale mode fields in an unrelated reader's
  pre-revocation copy; it neither configures the domain nor calls its getter.
- Store admission uses current saved effective consent, started/session state,
  the session latch, existing awake/shutdown caches and cached lock state. The latch
  is seeded from the existing startup result, cleared on resignation and reopened
  only by the matching session-active handler after its existing refresh and a
  session-revision check. Ordinary
  session refresh and lock callbacks cannot reopen it. System startup/restart
  suspends mode demand; reconciliation then recomputes current Store demand.
- Stop/opt-out and processed session/sleep/screen-sleep/lock/shutdown boundaries
  remove only this token and clear its comparison, cached report and mode-origin
  HUD/dismissal task/deadline/dedup. Return establishes a quiet baseline. Other
  readers, observations and unrelated overlays keep their ownership. The existing
  deinit cleanup transfer still owns final observer removal.
- Only real observed differences emit nil-valued `.battery` events with fixed
  `systemLowPowerMode` origin. Final Store admission repeats the category, consent
  and lifecycle gates before `showHUD` can replace an overlay or perform haptics.
  Existing timing, motion, labels, panel rules and haptics policy apply. No new
  preview, history, native notification, sound, helper, setter or polling exists.

This slice permits **Swift parse, diff review and static hashes only**. No build,
typecheck, runtime/app/helper/fixture/probe/test, power/permission/device read,
notification post, mode change, network or native input ran for its implementation.
Compilation, native UI, natural transitions, session races, performance and full
parity acceptance are **UNVERIFIED**, and remain parent-owned.

Parent real acceptance plan, after separate authorization, with no mode change:

1. Use the actual app with an owned private profile and unrelated protected readers
   and extra grants already off. Check default/legacy/malformed/damaged/repaired
   recovery, exact backups, generic true/reset/cloud rejection, unrelated saves,
   activation, refresh and restart. Require nil/disabled mode state while off.
   Claim zero reads only with independent evidence at the actual service boundary;
   absence of a HUD alone is insufficient. Do not add mocks or fake events.
2. Use the native disclosed action with the category already enabled. Require saved
   readback, one observer and one silent real baseline where independently visible.
   Accept whichever Boolean the OS reports. Check restart and quiet re-admission.
   Human native reachability, text, accessibility and optional haptics need their
   own evidence; browser/API readback cannot prove them.
3. Revoke the choice and then its category through the real interface. Require
   immediate selective teardown and successful saved clearing. Category re-enable
   must leave consent off. Use a genuine failure in the owned preference-save path
   to check that failed grants never read/install and failed revocations remain off
   in-session with the older-grant restart warning. Existing widget authorization
   may check separation; do not grant extra readers merely to obtain coverage.
4. Only with later explicit authorization, wait for real independent natural mode
   notifications. Do not change power mode, charging or power settings, post a
   notification, inject cached values or manufacture a transition. Retain the actual
   Boolean before/after, callback/read, revisions, Store admission and live HUD/
   expiry. Each direction is a separate unproved variant until naturally observed.
   If no transition occurs, keep this gate UNVERIFIED. Charge previews, baseline
   reads and notification receipt alone cannot substitute.
5. Observe later authorized natural session/lock/sleep/wake boundaries, quiet return,
   selective HUD retirement and existing panel suppression. Late/duplicate callback
   races require actual evidence; source guards alone prove only static intent.
   Unknown initial lock state, intermediate burst states, display frame timing and
   hardware/OS breadth remain unproved. Do not invent an unsupported/error positive
   from false or lower the deployment target to manufacture one.

**C-PID remains FAILED. M1 remains USER-DEFERRED. Stage4 remains HOLD.
Focus default backend remains UNVERIFIED.** This source slice upgrades none of them.

## Local Calendar event-dot policy

From parent `65dc8651a83595740a0e40792b5f74f4ea7ae017`, the parent explicitly
selects the research's conditional visual-only OpenCove variant. Retained
`1.7.3 features[2]` event indicators map to month-grid dots; `1.7.5 fixes[5]`
live toggle maps to the saved choice reaching the observed full/Duo callers.
Exact reference OFF-state count and surface behavior remain **SPEC_UNKNOWN**.
This is no broader indicator/privacy switch or exact reference-parity claim.

The native **Show event dots** control uses the existing preference binding and
store error path, and stays editable while Calendar activity is off. The local
ordinary Boolean `showCalendarEventIndicators = true` stays outside consent fields
and the cloud allowlist. Missing means true. Malformed means false under existing
strict Boolean recovery, with repair notices, backup protection and recovery
policy unchanged. Save failure keeps the session value and visible error; the
older saved value can return after restart.

Only existing day-cell dot contents are conditional. Fixed row/cell bounds,
unique-color grouping/sort/cap/colors, date/Today/selection styling, count help,
accessibility labels/values and selected trait stay unchanged. List content/opener,
`showCalendarList`, list/status popovers, status/recovery/privacy/loading, compact
countdowns, alerts, routing and widget consent keep their existing paths. The
observed store supplies both callers without a new event result, restart, cache
flush, identity reset, callback, refresh/date query, timer, animation or reader
demand. Static source preservation does not establish live behavior.

This slice permits **Swift parse, diff review and static hashes only**. No build,
typecheck, runtime/app/helper/fixture/probe/test/unit/mock, browser/native input,
EventKit, power/permission query, network or nested agent ran. No synthetic event
or permission workaround is permitted. Build and real acceptance are parent-owned
and **UNVERIFIED**.

Bounded parent plan, only in a separately authorized real-app context:

1. Keep Calendar activity, independent Calendar widget reading and other protected
   readers OFF throughout no-data validation. Use the real supported preference
   caller for true/false save/readback, unrelated saves and process restart. Check
   that only the intended Boolean changes. Confirm missing-key true; reject
   numbers, strings, null, arrays and objects through the strict command validator.
   Keep native Settings reachability/input evidence separate from API/CLI proof.
2. In the owned private profile, exercise malformed-value false repair and
   whole-document recovery. Retain the exact damaged bytes and private backup;
   confirm repair notices and existing grant revocations. Exercise a genuine save
   failure, visible error and session-only value, then restart to inspect actual
   disk state. Confirm backup failure preserves the damaged file. Restore a writable
   path, save through the same real caller, read back and restart for recovery.
   Do not mock storage or enable a reader to obtain this evidence.
3. Preference/API proof cannot accept live populated dots. Calendar's disabled
   section gate remains in place; do not bypass it to manufacture grid evidence.
   Full/Duo layout, selection/month preservation, ON/OFF/ON dot removal/restoration,
   grouping/cap/colors, complete count/help/accessibility, all four list/dot states,
   retained popovers and native positives remain **UNVERIFIED**. Disabled/unloaded
   output is not an authorized-empty result. Positive checks need separately
   authorized real owned data and permitted reading. Add no synthetic events or
   grant workaround. Actual media-plus-Calendar Duo also needs the failed C-PID
   prerequisite resolved under separate authorization.

**C-PID FAILED; M1 USER-DEFERRED; Stage4 HOLD; Focus execution HOLD;
full parity INCOMPLETE** remain unchanged. This preparation clears none of them.

## Local Calendar source-color policy

This one bounded C04 slice starts at exact published base
`3a5dffa670c12062ebe18411c14aa4a29a81bc44`, tree
`c700870f74ac6bbc5f5e4deeb63e91355309c4f2`. It independently addresses retained
`1.5.0 features[12]`, “Added calendar color option”. Exact reference defaults,
surfaces and behavior remain **SPEC_UNKNOWN**. It does not accept full C04 or parity.

The native **Use source colors in Calendar view** Toggle and scope note use the
existing ordinary Store binding. `useCalendarViewSourceColors = true` is local,
outside reader consent and the cloud allowlist. Missing legacy keys keep true;
malformed Boolean values recover to false through existing strict recovery,
repair notices and backup protection. Whole-document damage retains reader-off
recovery. Save failure keeps the session value and existing error; the older
saved value can return after restart. Ordinary saves still reconcile services;
no zero-system-status-call path is claimed.

On keeps the old source fills, hex RGB parser and invalid-hex gray fallback.
Off changes only month-dot and schedule-row leading-rail fills to existing
`CoveNotchStyle.secondary`, including the shared condensed schedule popover.
Distinct original source-hex grouping, sorting and the three-dot cap remain
before color selection. Neutral groups do not collapse into one dot. Counts,
help/AX, text/time zones, selection/date identity, Today circles, navigation,
actions, list/dot choices, source filters, access/loading/recovery/privacy,
popover binding, geometry, cadence and automatic Duo keep their existing paths.
Dots off means no dots; list off means no list content/opener; no real events
means no marks. Compact activity and lock/widget colors stay outside this policy.

Only source/text/Git/hash/static comparisons, syntax-only Swift parsing and diff
checks are permitted in this slice. No build/typecheck, app/caller/helper/CLI,
runtime, unit/mock/synthetic event, fixture, permission/status query, personal-data
read, browser/native input, computer use or nested agent runs are permitted.
Parent-owned independent review, optimized real build, exact caller binding,
bounded execution and any PR remain separate work at a fresh candidate pin.

Future acceptance requires a separately authorized legitimate real context:

1. Keep all protected readers, Calendar activity, independent widget readers,
   media/private integrations, cloud, providers, hardware replacement and sound
   OFF. Preserve existing local choices. Use the existing real Settings or
   already-authorized preference interface in an app-owned disposable data path.
   Inspect and save true/false/true, close/reopen, perform unrelated saves and
   restart. Verify saved/effective values and unchanged grants, filters and other
   choices. No new permission/status query or personal-data access is authorized
   to find that context. Settings already checks AX trust and refreshes Calendar;
   ordinary saves can inspect login-item status and reconcile readers. Calendar
   activity plus widget demand OFF gates its refresh before EventKit status/read;
   an enabled grid's `events(on:)` still checks authorization. No supported
   zero-status native Settings context is established here.
2. Through the existing real preferences command, reject numeric, string, null,
   array and object Boolean representations, unknown fields and mixed-invalid
   requests. Require no partial save. In owned disposable settings files, check
   missing-key true, valid true/false, malformed-field false repair, whole-document
   recovery, notices, exact damaged-byte recovery backup and backup failure.
   Require backup failure to preserve the damaged file. Exercise an actual save
   failure, visible error and session value; restart to inspect the saved value,
   restore the path, save normally and restart again. No mock storage or new route.
3. Native Toggle reachability, keyboard/AX labels, normal-window scrolling/error
   visibility and actual native input remain **UNVERIFIED**. API/browser readback
   proves only its caller and cannot establish native approval. This slice adds
   no native input, desktop-driving computer use, fixture or permission bypass.
4. Populated full Calendar, Duo and condensed popover colors need separately
   authorized real existing events. Compare on/off/on, original color grouping,
   sorting/cap, list/dot combinations, counts/help/AX/actions, retained selection
   and month navigation, and real empty/loading/access/privacy states. Do not
   grant access or add synthetic events to obtain proof. Disabled/unloaded output
   does not prove an authorized-empty or populated view. Actual automatic
   media-plus-Calendar Duo still depends on the separate failed media/real-data
   prerequisites. All these positive/native checks remain **UNVERIFIED**.
5. Actual source/neutral contrast, native scales/appearances, clipping, reference
   meaning/defaults/surfaces, real motion/cadence and measured resource impact are
   separate **UNVERIFIED** gates. Source reuse, a future build, or a saved Boolean
   accepts none of these. Do not invent RGB, opacity, timing or geometry policy.

**C-PID FAILED; M1 USER-DEFERRED; original Stage4 HOLD; Focus execution HOLD;
blur-control background-alpha FAILED; C03 phase HOLD; sound blocked;
full parity INCOMPLETE** remain unchanged. Existing adverse measurements and
unproved variants receive no replacement metric or acceptance here.

## Whole-document preferences recovery safety

This separate hardening layer starts directly at C04 commit
`eb65f8700717454b7f1ac37ee1f6f95e841af71a`. The selected product policy strengthens
whole-document fallback to all 29 optional selections OFF. It does not relax the
all-OFF acceptance rule or identify an introduced C04 defect. The historical
`becc168e39108252339b7f7f2e9d1d797cf68a0de81a856d48943b6d940b051e`
caller preparation remains **BLOCKED / NOT RUN**. This source change cannot clear
or authorize that caller.

Only `CovePreferences.recoveryDefaults` changes product behavior. The Store uses
it when the saved document cannot be read or recovered, including oversized,
malformed and non-object JSON. It installs the fallback before services start and
before the control server exists. A later preferences request cannot establish
an all-OFF startup. Missing files still use factory defaults; readable valid
documents, individual-field recovery, strict Boolean checks, missing-field consent,
grant repair, normalization and the cloud allowlist retain their existing rules.
This is a corruption fallback policy, not a new consent policy for valid documents.

The exact fallback inventory is:

```text
enableCalendar, enableMedia, enablePrivateAPIs, enableBluetooth, enableFocus,
enableWeather, enableNotifications, syncSettingsWithiCloud, showOnLockScreen,
showLiveWaveform, launchAtLogin, allowAppleScript, enableVolumeHUD,
enableBrightnessHUD, enableBattery, enableHaptics, enableFileTray, enableTimer,
replaceSystemHUDs, mirrorSystemNotifications, lockWidgetMedia, lockWidgetCalendar,
lockWidgetWeather, lockWidgetFocus, lockWidgetBluetooth, lockWidgetBattery,
enableBetterDisplayFeedback, hideForGamesCategory, enableLowPowerModeAlerts
```

Local presentation defaults stay unchanged: Calendar source colors, list and dots
remain true, as does `lockWidgetsFollowActivities`. Disabled activities and cleared
widget selections produce no extra reader demand. `completedOnboarding` retains
its normal recovery default. Existing affirmative controls can enable ordinary
choices again; protected readers still require their existing explicit consent
and macOS permission rules. No automatic permission request is added.

Recovery does not rewrite preferences on load. Before explicit replacement, the
existing Store must preserve an exact private copy of the original damaged bytes.
Backup failure prevents replacement. Ordinary save errors can still leave a
session-only value; successful save and restart need actual evidence. Store,
reader policy, file ownership, source error notices and atomic writes are unchanged.

Source checks and syntax-only Swift parsing are the permitted evidence here.
Build/typecheck and real-interface acceptance remain **PENDING**. The parent owns
a newly hashed caller, its baseline and ownership rules, exact source/package
binding, independent review and authorization before execution. Required future
acceptance uses the real packaged app and existing interface:

1. Launch with owned malformed JSON in a fresh private data directory. Require
   actual preflight state with all 29 selections false. Review source guards and
   actual startup scope for provider, EventKit, Bluetooth, Focus, notification and
   physical actions before launch. Do not infer their absence from an empty view
   or from a later all-OFF POST. Shared AX, session, status and system monitoring
   work remains; no zero-OS-call claim or observed startup result exists here.
2. Keep the original bytes separately. After readiness, use only the fixed
   filesystem mechanism: change the retained owned data-directory descriptor from
   `0700` to `0500` so creation of a recovery backup fails. Require the actual
   backup error, no backup, unchanged original bytes and the real save failure;
   an ordinary HTTP 500 alone is insufficient. Restore that same descriptor to
   `0700` in independent cleanup even if an assertion or receipt fails. Do not
   substitute injected state, mock storage, permission probes or another directory.
3. With write access restored, explicitly save through the existing real caller.
   Require the actual backup to byte-match the retained original, the actual
   notice, saved choices and restart readback. Separately retain the missing-file,
   valid-document and partial-field recovery regression gates. Do not run the
   historical blocked caller or flip its commissioning constant.

No runtime result is recorded for this layer. C03 phase and diagnostic execution
remain **HOLD / BLOCKED**; its final tiny Store fix has separate static CLEAR only
and is unintegrated. **C-PID FAILED; M1 USER-DEFERRED; Stage4 HOLD; Focus execution
HOLD; blur FAILED; sound blocked; full parity INCOMPLETE** remain unchanged.
Populated C04 colors, native input, contrast, AX, performance and exact reference
**SPEC_UNKNOWN** gates stay pending. Existing adverse metrics and unproved variants
receive no replacement result.

## M17 non-playing artwork opacity: conditional source slice

The retained declaration is `1.2.1 features[3]`, "Added album art opacity on
pause" (10 January 2025, `entries[5].minors[7].features[3]`). Later
`1.6.9 fixes[8]` removes the disable-opacity control; this slice adds no preference.
Version 1.7.9 is the latest retained declaration, not a latest-release claim.
No original Alcove app, source or assets were used.

The explicit OpenCove policy uses the existing `MediaState.isPlaying` Boolean:
actual displayed artwork is 1.0 when true and 0.60 when false. False includes
stopped, missing and unknown state, not confirmed paused. The fixed 0.60 value is
not a reference measurement or legibility/performance proof. Exact reference
classification, value, surfaces, placeholder behavior and motion are
**SPEC_UNKNOWN**. Apple's public opacity contract supports the mechanism only.

All four existing calls bind that Boolean. Both retained slots share one
presentation effect on their existing wrapper; the direct displayed bitmap uses
the same rule. The generic gradient/music-note placeholder and decorative border
stay unchanged. Scope is only already-admitted compact, QuickPeek,
full/condensed/Duo and locked shared media. This creates no surface and changes no
admission, grace, privacy, lock/session or hidden-state rule. Artwork input/hash
identity, native blend targets, slots, decode-gap retention, source-switch/loss/nil
cleanup, transactions, completions, tasks and timers stay unchanged. Playback
does not restart an image fade or extend its lifecycle. No motion/duration, cache,
source field, API, reader, model, settings, Store or controller change is included.
Tint, text, indicators, progress, seek identity, actions, focus and AX stay exact.

This commission permits only source review, syntax-only parsing of the changed
Swift files, diff checks and immutable hash/mode/text preservation checks. It
records no built or runtime acceptance. Independent source review and a separate
parent-owned build remain **PENDING**. A future build needs its own exact source
and artifact binding and authority; compilation would not accept the effect.
The general runtime commands below are not authorized by this source slice.

Positive actual-media/native playing → non-playing → playing acceptance is
**BLOCKED by C-PID FAILED**. No new execution clearance, fixture, identity
workaround, media query or C-PID repair follows. If that prerequisite is resolved
and the parent separately authorizes real-interface acceptance, correlate the
actual displayed source/item and existing Boolean. Check compact, QuickPeek and
full media separately. Populated Duo, secure lock, source loss, missing artwork,
same-source decode gaps, interrupted replacement and Reduce Motion remain
separate variants. An unavailable-media image cannot accept the positive effect.

Native input, populated media, AX, contrast, rendering/compositing, ancestor
transaction/opacity multiplication, motion and performance remain **UNVERIFIED**.
Exact reference behavior remains **SPEC_UNKNOWN**. C04 R7 remains bounded
API/recovery acceptance only; it supplies no M17 or full C04 acceptance.
**C-PID FAILED; M1 USER-DEFERRED; Stage4 HOLD; Focus HOLD/default backend
UNVERIFIED; C03 HOLD; blur FAILED; sound blocked; full parity INCOMPLETE** remain
unchanged. No adverse gate or prior measurement is upgraded by this source work.

## M12 local total-duration display

This commissioned source slice starts directly at
`a0787515ed946419b5eb74967e5ef2c1f1344925`. Retained M12 is
`entries[4].minors[1].features[1]`, 1.3.8 (14 October 2025), "Added ability to
toggle slider total duration". No later retained declaration removes it. The
1.4.1 hour-format fix is context only; the existing `m:ss`/`h:mm:ss` formatter
stays unchanged. Replacement of the right label and the OFF default are explicit
OpenCove policy. Exact reference behavior remains **SPEC_UNKNOWN**. No original
Alcove app, source or assets were used, and the removed M17 control stays absent.

The ordinary local Boolean uses existing recovery and saving. All three shared
media calls explicitly bind it. ON changes only the existing valid-duration right
label to total duration; OFF keeps negative remaining time. Elapsed, invalid or
unknown duration, unavailable media, trusted LIVE, unsupported seek, Slider/AX,
seek identity, admission, M17 and C04/C03 code retain their existing contracts.
The Settings row and scope note remain visible and editable with Media OFF.

This source commission permits syntax-only parsing of the five changed Swift
files, diff checks and immutable Git/hash/mode/text preservation checks only.
Independent source review is **PENDING** for the actual new immutable delta,
three callers, both flag states, unchanged fallback branches, complete Slider
and recovery contracts, protected hunks and all 91 unowned leaves. Static checks
do not typecheck or establish persistence, native input, pixels or performance.

Build/package/signing is **NOT RUN for M12** and needs separate parent authority
and exact new source/artifact binding. The a078 build supplies no M12 pass.
A fresh disabled-reader preference caller/API review and package binding are
**PENDING / NOT RUN**. C04/c435/e350 caller bindings and green R7 do not transfer.
Future separately authorized real flows must cover OFF→ON→OFF, saved read-back,
restart, same-value submission, missing legacy key, strict invalid-Boolean repair,
whole-document failure, original-byte backup and real backup/write failure.
Account for existing save reconciliation and login-item status paths. Distinguish
400 rejection from recovery, and distinguish returned status, session value,
actual saved bytes, backups and restart outcome: an overall 500 alone does not
prove that disk bytes stayed old. Preserve actual failures.

Native Settings visibility/editability with Media OFF, actual input, error
visibility, focus/keyboard and AX require separate authorization and remain
**UNVERIFIED**. Existing Settings permission/Calendar refresh needs its own review;
API evidence cannot accept native behavior. Positive total-label pixels and
actual seek remain **BLOCKED by C-PID FAILED**. Full media, populated Duo, secure
lock, known-duration/no-seek, unknown-duration, trusted live and item replacement
remain separate authentic cases. No fixture, player query, injected state/clock/
bounds/event, C-PID workaround or unavailable screenshot accepts those cases.

Native spoken text and Slider semantics, truncation/large hours, contrast,
rendering identity, motion and resource/performance comparisons remain
**UNVERIFIED**. Build time and source equality are not performance evidence.
**M1 USER-DEFERRED; Stage4 HOLD; Focus HOLD/default backend UNVERIFIED;
C03 phase/endpoint-binding HOLD; blur FAILED; sound blocked; full parity
INCOMPLETE** remain unchanged. No adverse result or open variant is upgraded.
The general runtime commands below are not authorized by this source commission.

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

### Local media and Calendar preference controls

The development page has three explicit save groups. Each uses the existing
authenticated `preferences` command and sends only its listed Boolean fields:

- Save media visibility: `hideWhenMediaAppActive`.
- Save media swipe controls: `swipeToSkip` and `reverseSkipSwipe`.
- Save Calendar filters: `showDeclinedCalendarEvents` and
  `excludeSubscribedCalendars`.

These local choices can be saved while media, private integrations, and Calendar
are off. The saves do not include or enable any protected source flag. The page
labels explain this before the save. Reverse direction is disabled while swipe
is off, but its checkbox value remains intact and is included in the swipe save.

The controls share the page's explicit-edit drafts, serialized authenticated
commands, error alert, fresh-state readback, and connection-generation guards.
Polling and unrelated group saves keep unsaved edits. Each input edit advances
that input's revision. The shared command path copies submitted preference
values and captures edit revisions before enqueueing, including calls through
`window.opencove.command`. A successful response retires a draft only when its
revision and value still match that submission. A newer edit survives even if
it returns to the submitted value. Numeric Appearance fields keep their existing
number conversion; `playbackIndicator` keeps its mapping to
`showPlaybackIndicator` and `showLiveWaveform`. A failed save keeps
drafts and reads current app state without hiding the error. A disconnected or
expired-token page disables inputs and saves, clears app-derived values, and
keeps explicit drafts for reconnection. Group status text reports unsaved edits
or choices read from the app. Labels, help text, focus outlines, and status
regions support browser keyboard and accessibility use; live acceptance remains
required.

This control addition starts from frozen parent
`e2aca48246e22f8fbd2b81943c9c3f4f0da7c65c`. The edit-revision correction starts
from frozen implementation parent `1941279a0aabadb615495edd3f869e03f15d6894`.
Implementation checks are limited to source review, embedded-JavaScript parsing,
and diff checks. Build and runtime proof belong to the parent integration run.
Common on/off and restart checks do not establish the queued-save race. The
corrected integrated revision still needs that coverage. Before accepting the controls:

- In the real authenticated browser and an owned packaged session, keep all
  protected readers off. Save each group through off → on → off, inspect each
  request's exact field set, and require matching response and later poll values.
  Reload and restart the owned session to check persistence. Require every
  protected source flag to remain unchanged and off throughout these saves.
- Make unsaved edits in all groups. Let polling occur, save a different group,
  and edit a submitted field again while its save is in flight. Require the
  newer draft and unrelated drafts to survive. Check real save failure and
  rejected-command paths: the error remains visible, fresh app state is read,
  drafts remain, and a later successful save clears only the matching revision
  and value.
- Check the queued same-value edit case with real requests: start with a false
  choice, edit true and submit save A. While A is pending, edit false and submit
  save B, then edit true without saving again, all before A completes. After A
  succeeds, the newest true draft must stay unsaved. After B succeeds, app
  readback must be false while the checkbox stays true and unsaved. A later save
  of that draft may clear it only if no further edit occurs. Cover each local
  group, ordinary Appearance fields, the synthetic `playbackIndicator` choice,
  and generic preference submissions through `window.opencove.command`.
  Use equivalent A/B/A values for inputs that are not Boolean.
  Keep unrelated drafts intact. If the required overlap is not observed, leave
  race acceptance unverified; do not add delays, hooks, or substitute responses.
- Disconnect and reconnect the owned server, including during a pending save.
  Check disabled inputs and save buttons, retained drafts, retirement of stale
  responses, and fresh readback after reconnect. Check the real expired-token
  path and reconnect with the newly issued authenticated URL. No old response
  may clear or replace a newer connection's drafts or state.
- With swipe on, choose reverse direction. Turn swipe off before saving and
  require reverse to become disabled without losing its checked value. Save,
  poll, reload, reconnect, and restart; the chosen reverse value must remain.
  Turn swipe on again and require reverse to become editable with that value.
  Check labels, help text, focus visibility, status/error announcements, and
  keyboard reachability in the real browser at narrow and wide widths.
- The parent separately owns real-source off → on → off acceptance. Enabling a
  source needs its existing explicit authorization; these saves never enable it.
  Require the strict owned-media C-PID prerequisite before any positive media
  behavior claim. Its failed gate remains failed; injected media is no
  substitute. Real Calendar filtering needs separately authorized owned data.
  Native swipe feel, active-app hiding, Calendar results, and performance remain
  separate runtime gates. M1 iCloud setup stays deferred.

Keep private run evidence in `0700` directories with `0600` files. Record the
exact integrated commit, source pointers, bundle identity, real browser steps,
command results, and failed or unverified gates. Source parsing does not prove
build success, browser behavior, native input, or design/performance parity.

### iCloud developer controls

Authenticated `GET /state` and successful command responses include `settingsSync`:
`state` (`off`, `unavailable`, `choosing`, `active`, `conflict`, or `paused`),
the controller's fixed UI `status` and `detail`, and `canChooseLocal`,
`canChooseCloud`, `canCheck`, and `canReconnect`. This projection only reads the
existing controller's UI properties. It never starts sync or obtains a cloud
store or account identity, including while sync is off. It exposes no account
token, identity, envelope, cloud payload, revision, secret, or path.

The development page's iCloud card uses these flags to enable four explicit
developer control commands. Each calls the existing `CoveSettingsSyncController`
method used by native Settings:

```sh
./script/opencovectl --data-dir "$OPENCOVE_DATA_DIR" command '{"action":"settings.sync.check"}'
./script/opencovectl --data-dir "$OPENCOVE_DATA_DIR" command '{"action":"settings.sync.useLocal"}'
./script/opencovectl --data-dir "$OPENCOVE_DATA_DIR" command '{"action":"settings.sync.useCloud"}'
./script/opencovectl --data-dir "$OPENCOVE_DATA_DIR" command '{"action":"settings.sync.reconnect"}'
```

These use the existing authenticated `POST /command` path and accept exactly
one `action` key, with no arguments. Extra keys, including `values: {}`, return
400. Each action requires its corresponding controller capability and the
effective opt-in preference; the controller capabilities require its saved
consent session. Off, failed-save, or otherwise unavailable actions return 409.
The commands do not enable or save the opt-in preference. `useLocal` is the
explicit action that can replace the shared snapshot, including one still in
transit. `useCloud` replaces only the shared appearance and behavior settings
on this Mac. Checks and reconnects keep the controller's existing incoming-update
policy and do not invoke the explicit shared-snapshot replacement action.

The existing loopback bind, `X-OpenCove-Token`, Host/Origin and cross-site checks,
HTTP framing, 16,384-byte header limit, 65,536-byte body limit, connection
deadline and no-store response rules apply unchanged. A 200 response means
submission and includes fresh controller status; it does not confirm delivery.

Real-service proof remains pending until the parent runs the checked-in packaged
build and exercises both real Macs through the authenticated browser/API.
Check off-state rejection, invalid shapes, unavailable reconnect/choices, saved
opt-in, initial choice, shared replacement, incoming changes, opt-out and
restart. Keep real account data and private control descriptors out of reports.
Native toggle input is a separate gate: browser preference commands and these
controller actions do not prove native toggle interaction.

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

`opencovectl render --surface settings-calendar` captures the same native Activities
form at a fixed 760×2400 size. Earlier 760×1600 captures remain evidence only for
their visible content; they do not show controls below their lower edge.
`settings-general` retains its 760×1600 size for
the native General form, including its lower interaction controls. These expose
controls below the ordinary previews. They create no separate settings component,
change no preference, and send no desktop input. The larger captures do not
prove normal-window scroll reachability, native Toggle input, or compositor
appearance. Inspect alpha and the embedded color profile before drawing contrast
conclusions from offscreen pixels; a raw RGB value alone does not describe the
composited color.

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
