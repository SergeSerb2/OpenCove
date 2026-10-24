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

Apple's primary documentation defines
[callback batches](https://developer.apple.com/documentation/coreaudio/audioobjectpropertylistenerblock),
the [three address fields](https://developer.apple.com/documentation/coreaudio/audioobjectpropertyaddress)
and the returned byte count for
[property reads](https://developer.apple.com/documentation/coreaudio/audioobjectgetpropertydata(_:_:_:_:_:_:)).
