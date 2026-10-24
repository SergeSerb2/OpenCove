# Audio level and output inventory reads

Volume/mute notifications and the synchronous hardware-control read refresh the
actual current route, UID, levels and capabilities. A level read skips the
output-device inventory only when all of these conditions hold:

- The default-device read succeeds and returns exactly one `AudioObjectID`.
- The ID is known, equals the prior route ID, and its fresh alive value is `1`.
- Its fresh UID is nonempty, equals the prior route UID, and the exact ID/UID
  pair is in the cached output choices.
- All four polling flags are clear: `audioSystemNeedsPolling`,
  `audioDeviceNeedsPolling`, `outputDevicesNeedPolling` and
  `outputListenersNeedPolling`.
- No listener rebuild or full audio refresh is pending, and the caller did not
  request a full refresh.

Every failed condition attempts one inventory read in that same audio read,
including failures on early return paths. Recovery does not recursively read
audio. A changed UID behind the same numeric HAL ID removes both current-route
and inventory listeners and clears the observed-ID set before the scan. The
scan rebuilds inventory listeners; the route read rebuilds current-route
listeners. Failed scans and registrations retain fallback polling. Later full
reads retry failed device and inventory listener registrations.

CoreAudio can include unrelated property addresses in a listener callback.
Only a nonempty batch in which every address matches the registered level
selector, scope and element takes the level path. Any other batch takes the
full path. A coalesced full audio request wins over a level request and performs
one audio read. Callbacks copy the address data before scheduling actor work;
that work checks both the controller generation and the live registration ID.
Queued callbacks from removed registrations are ignored.

Startup, explicit Refresh, the native output picker and existing fallback
polling still read all output choices. The picker keeps fresh names, eligibility
and route selection. Setter validation still checks actual IDs/UIDs before
writing. Full reads recheck route validity, ID, alive state and UID after the
inventory attempt. If that snapshot changed during the scan, the read leaves
controls unavailable, records an audio read error and coalesces a later full
read through the existing scheduler. It does not scan twice in one audio read.
This changes no hardware value and adds no timer or recurring telemetry.

The opt-in development `system.refreshAudio` command accepts `hardwareControl`
to exercise the real read-only current-level entry. Its existing request-scoped
evidence reports actual synchronous domain entries and attempted setters.
`nativePicker` mounts the real Activities settings picker; `developmentAPI`
retains the full audio refresh. No caller posts a hardware event. Physical
volume-key delivery, natural listener events, hotplug, service restart and
listener-failure recovery require separate live coverage. Read counts alone do
not establish CPU, energy or reference-product superiority.

## Request-scoped inventory evidence

`AudioRefreshEvidence.inventoryDecisions` is an ordered array with one entry
per synchronous `readAudio` call inside the existing explicit acceptance
capture. It adds no normal-operation samples, counters, clocks or timers. Each
entry has these fields:

- `action`: `scan` means one inventory attempt, including a failed attempt;
  `skip` means no inventory attempt.
- `skipEligible`: `true` only when every skip condition above passes. It is
  equivalent to `action == "skip"` and an empty `reasons` array. A full refresh
  always makes it `false`.
- `reasons`: all failed skip conditions, in the order below, captured before
  scan or listener repair. Reasons can overlap. They contain no IDs or UIDs.
  Changes detected by the post-scan route check appear in `audioReadErrors`.

The reason values and their meanings are:

- `fullRefresh`: this read explicitly requests inventory.
- `systemPolling`: the system audio listener fallback flag is set.
- `devicePolling`: the current-route read/listener fallback flag is set.
- `inventoryPolling`: the inventory read fallback flag is set.
- `inventoryListenerPolling`: the inventory listener fallback flag is set.
- `listenerInvalidation`: the current-route listener rebuild flag is set.
- `pendingFullRefresh`: a full audio request is already queued.
- `invalidDefaultDevice`: the default-ID read status or byte size is invalid.
- `unknownDefaultDevice`: the validated default ID is unknown. Invalid reads
  also normalize the ID to unknown.
- `routeChanged`: the validated default ID differs from the prior route ID.
- `deviceNotAlive`: a known default device did not return an alive value of `1`,
  or no known default device was available to query.
- `missingUID`: no fresh nonempty UID was obtained. Dead/unknown devices also
  have no fresh UID.
- `uidChanged`: the fresh UID differs from the prior route UID, including a
  change to or from an empty UID.
- `uncachedRoute`: the fresh nonempty ID/UID pair is absent from cached choices.

An eligible steady level sample has `action: "skip"`, `skipEligible: true`,
`reasons: []` and zero `reads.audioOutputs.count`. A recovery sample has
`action: "scan"`, `skipEligible: false`, at least one reason and one inventory
entry count per audio read. Counts show attempts, not successful recovery;
inspect the existing `audioReadErrors` as well. Later asynchronous callbacks
and fallback work remain outside the synchronous request sample.

These fields support source review and later acceptance work. Static parsing
does not typecheck the implementation or prove live listener delivery, ID
reuse recovery, physical key delivery, hardware behavior or energy use.

## Recorded packaged comparison

On October 23, 2026, optimized arm64 development bundles exercised the actual
read-only `hardwareControl` entry with the same real output route. The baseline
performed 26 inventory reads for 26 requests. The candidate recorded 26 eligible
skips and zero inventory reads. Adjacent full reads agreed on the current route,
volume, mute, capabilities and output inventory. Native picker, full refresh,
CLI, invalid caller, authentication and unavailable output-selection checks also
passed, with zero instrumented setter attempts. Release and Debug builds passed.

A separate baseline/candidate/candidate/baseline comparison used 256 requests
per block at a 40 ms cadence, after 16 warm-up requests and one idle second.
Launch and rendering were outside the measured intervals. Each block checked
the packaged source, PID, process-start counter and unchanged route/state.

| Block | Inventory entries | App CPU seconds | Interrupt wakeups | Final footprint MiB |
| --- | ---: | ---: | ---: | ---: |
| Baseline 1 | 256 | 0.813 | 18 | 53.91 |
| Candidate 1 | 0 | 0.661 | 21 | 54.80 |
| Candidate 2 | 0 | 0.675 | 21 | 54.67 |
| Baseline 2 | 256 | 0.769 | 21 | 53.69 |

Each interval lasted about 10.21 seconds. `proc_pid_rusage` CPU counters were
converted from Mach ticks using the actual timebase. Footprint values are end
samples, not peaks. These four app-PID samples support lower CPU cost for this
explicit steady read workload. Wakeup and footprint savings are not established.
They exclude `coreaudiod`, drivers and WindowServer work, and do not establish
physical-key latency, natural callback delivery, recovery, energy savings or an
Alcove comparison. All measured app owners stopped after their blocks.

Apple's primary documentation defines
[callback batches](https://developer.apple.com/documentation/coreaudio/audioobjectpropertylistenerblock),
the [three address fields](https://developer.apple.com/documentation/coreaudio/audioobjectpropertyaddress)
and the returned byte count for
[property reads](https://developer.apple.com/documentation/coreaudio/audioobjectgetpropertydata(_:_:_:_:_:_:)).

## Live waveform consumer demand

The live waveform requires both the running store's saved `usesLiveWaveform`
opt-in and at least one presented `LiveWaveformView`. A Settings status label
alone is not a waveform consumer. Saving opt-in with no consumer retains the
choice and reports idle, or the existing access-required/package error. It
does not create a capture stream or start the 50 ms meter task.

Each waveform has a native background view with its own consumer ID. The view
must have a visible, nonminiaturized, nonoccluded window, nonzero window and
native ancestor alpha, no hidden ancestor, positive finite bounds, and a
nonempty visible rectangle. Local view/window events reconcile demand. Ancestor
frame/bounds notifications cover clipping and scrolling; no desktop inventory,
input monitor, new permission poll, or visibility timer is added. As in the
existing native media-region marker, the bridge enables geometry notifications
on its native ancestors. It removes its observers when detached or dismantled.

The bridge defers controller publication until after the native/SwiftUI update
and checks presentation again before acquiring a lease. Dismantle cancels a
pending acquisition and queues an ID-specific release that survives view
destruction. A replacement view has a different ID. Native detach, hidden
ancestry, zero alpha, clipping, window occlusion, and minimization also retire
demand. A later presentation can acquire the same view's lease again.

Source lifecycle trace (not a runtime observation):

1. Store startup enables the controller from `usesLiveWaveform`. The existing
   no-prompt permission preflight still provides the missing-access status.
   With zero consumers, stream creation and the meter remain off.
2. The first presented native waveform acquires its ID and uses the existing
   no-prompt start path. Further panel, peek, full Media, or lock-widget
   consumers add IDs without another start. Title, color, countdown, level,
   and unchanged layout updates keep the same lease.
3. A permitted outgoing transition remains a consumer while its native view
   remains presented. Selection alone does not retire it. After outgoing
   Media content is dismantled on settled Files, its ID is released. Another
   presented panel or lock widget can still retain capture.
4. The final release invalidates the capture generation, cancels and clears
   the meter/start tasks, invalidates the receiver, clears displayed levels,
   and uses the existing serialized stream teardown. Missing-access and
   backend-error status survive retirement; a successful session becomes idle.
5. A returning first consumer starts a new generation through `start()`, which
   waits for prior teardown before creating a stream. Rapid retirement and
   reappearance cannot let an old view release the replacement view's ID or
   let a cancelled acquisition register after dismantle.
6. Store stop or opt-out disables capture even if native views remain mounted.
   It does not change the saved opt-in during ordinary consumer retirement.
   `Allow System Audio Levels` remains the only permission-request path. With
   no presented waveform, that explicit action can request access but cannot
   start capture or the meter. Ordinary view updates do not retry a failure.

Consumer coverage follows the existing view branches, not just `selectedTab`.
Compact Media and peek require available media and the indicator/live options.
Full Media mounts the waveform only with available media and an enabled
indicator. Condensed Duo omits it. Files, Calendar, Timer, empty/unavailable
Media, disabled indicators, Settings status, and unmounted lock widgets do not
create a waveform lease. Offscreen rendering without a presented native window
does not qualify. The bridge does not treat disabled hit testing as hidden:
outgoing content can remain visible while it no longer accepts input.

Parent-owned real acceptance remains **UNVERIFIED**:

- First integrate and build the exact candidate. Parsing alone does not
  typecheck AppKit/SwiftUI APIs or prove native event/KVO delivery, clipping,
  or actual representable retirement during SwiftUI transitions.
- With an already authorized, isolated, owned audio workload and permitted
  observation path, compare Media → settled Files → Media with equal dwell
  periods. Confirm final-consumer retirement stops capture and meter work,
  and return resumes actual measured levels once without overlap or a prompt.
- Repeat with two presented panels, one panel retiring, the final panel
  retiring, a permitted presented lock widget, hidden/ordered-out/minimized
  windows, clipped lock content, outgoing transitions, Reduce Motion, and rapid
  retirement/reappearance including a return during an in-flight start/stop.
- Check opt-out with mounted views, opt-in without a waveform, missing access
  without granting it, empty/unavailable Media, condensed Duo, disabled
  indicators, and ordinary title/countdown/layout updates. Confirm these
  updates do not restart a stream or turn a Settings status label into demand.
  Exercise explicit access only when separately authorized; without a
  presented consumer it must not start capture after access succeeds.
- Use the real permitted visual/caller path and parent-owned process traces.
  Do not use injected levels/media, a new fixture, a prohibited native/private
  diagnostic getter, a permission workaround, or desktop input to establish
  acceptance. The strict media C-PID prerequisite remains **FAILED**; native
  owned-media acceptance remains blocked. M1 iCloud remains **DEFERRED**.

This change has source parsing and diff checks only. No build, app, helper,
fixture, capture, runtime or performance sample was run. It establishes no
CPU, wakeup, GPU, FPS, energy, hardware, permission, or cloud acceptance claim.
