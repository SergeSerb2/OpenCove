# Hardware key HUD replacement

`HardwareKeyController(system:)` adds optional hardware volume, mute, and brightness key interception. The store owns `replaceSystemHUDs`, which defaults to `false`, and the system service. The controller does not own preferences or start/stop the system service.

## Integration

- Create one controller with the store's existing system service.
- Set `volumeEnabled = preferences.enableVolumeHUD` and `brightnessEnabled = preferences.enableBrightnessHUD` before starting and after category preference changes. Both properties default to `true`. A disabled category passes through before any refresh/write/HUD action. Changing a category clears its existing press ownership, so toggling a category off and back on during a held key cannot consume the remaining repeats/release. Volume includes mute.
- Start system monitoring first, then call `start(enabled: preferences.replaceSystemHUDs && preferences.enablePrivateAPIs)` on the main actor. Use this same method after preference changes and app activation to recheck permission. It never prompts.
- Bind the access button to `requestAccessAndStart()` only after the user chooses replacement. That explicit action can request Accessibility and, after Accessibility is granted, Input Monitoring access. Permission requests can require another click or an app relaunch before preflight succeeds.
- Call `stop()` before stopping/restarting system monitoring and at app shutdown. Restart it after the system service has established its new baseline, including changes to private integrations. Turning the preference off calls `start(enabled: false)` or `stop()`.
- Observe `status` and `available` directly. `available` means an active tap has at least one supported control and the system service has no reported error. Permission-required, unsupported, disabled, and failure states have explicit text. A tap can remain installed while no control is supported, so a later output/display change can restore support without another permission request.
- Keep the existing `SystemController.onHUD` connection to the store. Setters emit HUDs for real changes. The key controller uses that callback when a submitted operation reports no error and the measured level stays unchanged, including range boundaries.

## Event handling

An active Core Graphics session event tap sits at the head of the filter chain. Its mask contains only `NSEvent.EventType.systemDefined` (14), never ordinary typing or mouse events. The callback converts the event to `NSEvent` and requires system-defined subtype 8 (`NX_SUBTYPE_AUX_CONTROL_BUTTONS`). Only these SDK media codes are eligible: sound up 0, sound down 1, brightness up 2, brightness down 3, and mute 7.

The high word of `data1` contains the code; the following byte contains key down 10 or key up 11; the low bit marks repeat. Unknown phases/repeat encodings, unrelated subtypes, media transport keys, keyboard backlight keys, and unrecognized keys pass through unchanged. Option, Control, Command, and Help combinations pass through, including macOS settings shortcuts. Shift alone selects a smaller step: normal volume/brightness step is 1/16, Shift step is 1/64. Option+Shift remains with macOS.

The controller refreshes the system service's real readings before a relative write, but only for an enabled category. Volume requires both readable volume and `canSetVolume`; mute requires readable mute and `canSetMute`; brightness requires readable brightness and `canSetBrightness`. The system service only publishes the latter when private integrations and a DisplayServices control are available. Fixed-volume outputs, missing controls, unsupported external displays, stopped monitoring, failed reads, and a target identity change before submission pass through without a write.

A submitted initial down event grants ownership of that press. Volume and brightness repeats each make a guarded write. Mute repeats do not toggle mute again. Only an owned, still-supported press with no current service error has its release consumed. Unowned repeats/releases pass through, including when replacement starts during a held key. A pre-write rejection gives the remaining press back to macOS. No input is injected, queued for replay, or modified.

Hardware writers return `rejected` or `submitted`. Once a real write is attempted, its event is consumed even if the OS reports an error or a driver only partly applies it. Passing that same event to macOS could apply it twice. The error remains visible and pauses further handling until the service clears it; no rollback or successful physical change is implied. An existing service error, including one from another feature, prevents a new write and passes the event through.

The HTTP API uses a separate per-operation result: rejected, submitted, or failed. A synchronous write failure returns HTTP 500 on every request. An unrelated old diagnostic cannot turn a successful request into a failure. Native controls keep their `Void` action wrappers. Driver updates can be asynchronous, so subsequent service readings establish the actual level.

## Permissions, lifetime, and recovery

`start(enabled:)` checks `AXIsProcessTrusted()` and `CGPreflightListenEventAccess()` without prompting. A denied permission creates no tap. Only `requestAccessAndStart()` calls `AXIsProcessTrustedWithOptions` with the prompt option and may call `CGRequestListenEventAccess`. It then uses the same preflight/start path, rather than treating a permission request as a grant. The controller does not request event-posting permission.

The source is added only to `CFRunLoopGetMain()` in common modes. Callback decisions run synchronously with `MainActor.assumeIsolated`, guarded by a main-thread check. They cannot be deferred to a task because macOS needs the consume/pass decision before the callback returns.

On a tap timeout, press ownership is cleared. The tap is enabled again only if replacement is still enabled, the port is valid, and both permission checks pass. macOS/user disable notifications retire the tap and require an explicit later start. `stop()` disables the tap, removes and invalidates its source, invalidates the port, and then releases the callback context. Deinitialization retains the port, source, and weak-owner context until main-queue cleanup finishes. The callback never has an unmanaged pointer to an already released controller.

There is no global key log, input persistence, notification content access, launch-agent change, system preference write, OSDUIHelper change, or Apple binary/signature modification. Stock HUD suppression depends on consuming a submitted hardware event. Other sources of macOS HUDs remain under macOS control.

## Compact HUD presentation

Activities settings expose two saved choices shared by all compact HUD categories: `showHUDLabels` (Show overlay labels) and `showHUDPercentage` (Show overlay percentage). Both default to `true`, including when an older preferences document has neither field, to preserve the existing display. These are independently chosen OpenCove defaults. The official Alcove changelog declares an option to hide HUD labels in 1.0.1 and a percentage option in 1.0.3, but does not establish defaults or exact label, subtitle, layout, or accessibility semantics.

Labels control the visible title and subtitle only. Percentage visibility is independent of labels and requires an existing finite numeric `hud.value`; a missing or nonfinite value never produces percentage text. Neither choice removes the icon or the existing progress display. Both choices apply to the physical-center-gap and continuous compact layouts. Hiding both leaves the icon and any existing progress within the same bounded panel dimensions and center clearance. The compact button keeps its existing accessible title and subtitle even when visual labels are hidden.

These choices only change compact HUD presentation. They do not enable a HUD category, alter its capability or failure handling, or change hardware interception, readings, timing, animation, preview, or scheduling. No timer, observer, or system read is added. They use the existing preference save and recovery paths and the existing settings error display.

### Parent acceptance gates

This implementation has source inspection and static parse/diff checks only. Builds, app/helper launches, tests, runtime calls, renders, desktop input, hardware actions, permission changes, credentials, cloud, signing, and publication were outside this implementation task. Source checks do not prove the mounted UI, persistence, failure handling, or complete visual parity. The parent must run the following real-interface gates when authorized:

1. Use an isolated real bundle and private data directory. Keep protected integrations, key interception, haptics, weather, and notification mirroring off. Do not issue volume, brightness, output-selection, media, or permission commands, or load personal calendar data.
2. Save each choice through the real authenticated preferences interface. Verify both controls in the actual Activities settings at `/render?surface=settings-activities`; API readback alone does not prove the settings UI. Check all four visibility combinations through the existing read-only `hud.preview` path and actual fully mounted HUD at `/render?surface=live-notch`. Preserve the icon, progress, accessible status, panel bounds, and center clearance. Record which geometry ran and cover both supported physical-center-gap and continuous layouts. A forced-gap offscreen render alone does not prove physical display behavior.
3. Require a naturally available finite reading on the real preview HUD for the positive percentage case. If none is available, leave that case blocked; do not fabricate a value. Use the existing notification preview for a no-numeric-value case and confirm that it never gains a percentage. Verify that disabled categories still reject preview and that unavailable or failed readings keep their existing failure behavior.
4. Save both `false` and mixed choices, restart the isolated app, and verify persistence. Load a real legacy document without the new fields and confirm the prior display and unrelated preferences remain intact. Exercise a real failed save and confirm that the existing error remains visible and no successful persistence is claimed. Verify the useful accessible status with labels hidden.

Keep these gates pending until their evidence exists. They do not establish physical key interception, stock HUD suppression, timing parity, or external-display support.

### Optional display brightness glow

Activities → System overlays adds **Brightness symbol glow** beside Display brightness. The local Boolean `brightnessHUDGlow` defaults to `false`. The control uses the existing preference binding and save-error display; it is disabled while the brightness category is off without clearing the saved choice. Missing legacy fields stay `false`. Invalid values, including numbers, strings and null, use the existing Boolean recovery path: repair to `false`, report the field, and preserve unrelated valid settings. The field is outside `CoveSyncedSettings` and does not sync with iCloud.

The user-supplied developer changelog 1.2.2 (9 February 2025) declares a display-HUD glow option. It does not specify its target, color, radius or intensity. OpenCove chooses one static shadow on the existing sun symbol: the current HUD accent at **0.65 opacity**, a **2-point blur radius**, and **zero horizontal and vertical offset**. The existing panel clip bounds the halo. This is an OpenCove design, not an exact Alcove reconstruction. It adds no HDR or overshoot behavior; the supplied 1.7.3 entry separately removes overshoot HDR glow.

The shadow exists only when the HUD kind is brightness and the choice is on. Both continuous and center-gap compact layouts use the same symbol treatment. Off and nonbrightness paths draw the original symbol without a shadow or duplicate glow layer. The symbol core, font, foreground color, text, percentage, progress geometry, spacing, panel dimensions and center clearance retain their existing definitions. Label and percentage preferences remain independent. An unavailable brightness preview can show the glow while retaining its unavailable status and missing numeric value. The option does not change the HUD model, title, value, preview/action handling, accessible label, animation, original dismissal deadline or scheduling. It adds no timer, sampler, system read, hardware write or private API.

#### Parent glow acceptance gates — pending

This change has source checks only. The existing recorded visibility-option acceptance below does not cover glow. No build, app/helper launch, runtime call, render or browser session ran for this change. The parent must collect separate real-interface evidence when that scope is authorized:

1. Use an isolated real bundle and private data directory. Keep protected integrations, hardware-key replacement, haptics, calendar, media, notification mirroring, weather and iCloud off before startup. Enable the brightness HUD category. Do not issue hardware, player, permission or global brightness commands. Keep evidence directories `0700` and files `0600`; keep control credentials private.
2. Set a sufficient supported brightness overlay duration **before** preview. Submit exactly one real `hud.preview` event with `kind=brightness` for each geometry run. While that same HUD remains active, save `brightnessHUDGlow` **off → on → off** through the authenticated preferences command. Bracket each capture with fresh state and compare the complete HUD model and original dismissal deadline across all three choices. Use caller monotonic request brackets with `hudRemaining` to bound the same absolute deadline; remaining time must decrease rather than reset after a preference edit. Require the same event, title, subtitle, symbol, value and accessible label, with unchanged native bounds, gap, text and progress regions. Do not submit replacement previews to manufacture the comparison. If the HUD expires before completion, repeat the whole run with a new single event and mark the incomplete run.
3. Capture the actual mounted native HUD at `/render?surface=live-notch` in both continuous and supported simulated-notch center-gap geometries. Require a bounded sun halo only in the on capture and restoration in the final off capture. Check the symbol core and existing clip separately from halo pixels. Record the live geometry exercised. An offscreen forced-gap view, CSS imitation or drawn screenshot does not substitute for either live native branch. AppKit mounted-view capture does not prove compositor output or physical-notch behavior.
4. Capture the actual native Activities view at `/render?surface=settings-activities` and confirm the new control beside Display brightness, its saved state and disabled-category state. Use the existing authenticated `ControlClient` request route; the CLI render surface list does not include `settings-activities`. Exercise the allowed browser flow on the real development page: select Display brightness, click its existing **Preview overlay** button once, then use `window.opencove.command('preferences', {values: {brightnessHUDGlow: true}})` and the corresponding false command for the same active-event comparison. Check fresh readback and native captures. The browser command verifies the real preference path; it does not establish native Settings toggle input. Keep native toggle interaction pending if that input is outside the parent's allowed scope.
5. With glow saved on and `enableBrightnessHUD=false`, require the existing brightness-preview rejection. Restore the category before a positive run. Check every available nonbrightness category with glow on, including the nonnumeric notification preview: none may glow. With a real unavailable brightness reading, require unchanged unavailable text and no numeric value or percentage while the sun can glow. A naturally available finite brightness reading can extend coverage; leave that case pending if unavailable and never fabricate it. Cover all four label/percentage choices independently without changing their semantics.
6. Verify persistence separately from live rendering. Save both Boolean choices and relaunch the isolated app after each. Load a real legacy document without the key, then a separately owned malformed-key document; require false defaults/repair, the existing recovery notice and exact backup, and unchanged unrelated valid preferences. Exercise an actually unwritable owned preference destination and require the real save failure plus the native settings error. A session choice may apply, but must not claim persistence. Restore access and relaunch without another successful save to verify the last successfully saved choice.

Keep these gates pending until their evidence exists. They do not establish HDR, exact reference-product styling, external-display support, physical key handling or runtime cost.

## BetterDisplay reported brightness feedback

Activities → System overlays offers **Show BetterDisplay brightness feedback**.
The local `enableBetterDisplayFeedback` Boolean defaults to `false` and stays
outside `CoveSyncedSettings`. Only this disclosed native Settings control can
grant consent. Generic preference edits, imports, resets and cloud settings
cannot add it. The existing central store transaction saves a new grant before
starting reception. A failed save discards the grant. Opt-out stops reception
and clears its cache/HUD before a fallible save; an error explains if an older
saved choice may return after restart. Disabling the brightness category also
revokes this consent. Missing or malformed Boolean fields repair to `false`;
a repaired preferences document cannot activate this reader. Widget consent
keeps its separate dedicated action and existing revocation rules.

This receiver uses only public Foundation `DistributedNotificationCenter`.
It observes `pro.betterdisplay.BetterDisplay.osd` once and the current
`.launched` / `.terminated` lifecycle names. It never posts a notification,
sends a request, launches or discovers an installed app, invokes a vendor CLI,
opens a URL, uses HTTP, queries hardware, requests access or edits vendor
settings. BetterDisplay must already run with **Dispatch OSD notifications**
enabled in its Integration settings. Dispatch does not suppress BetterDisplay's
own overlays; the user must choose the vendor's presentation to avoid duplicates.

Only one explicitly selected external logical display is eligible. The store
uses the existing public display-selection snapshot, with no new display read.
It requires `mode == "selected"`, no fallback, one selected positive current ID,
one matching non-built-in selectable entry, and a valid UUID unique across the
available entries. The UUID must match the current preference and the current
ID must be unique. All, Main, Built-in, ambiguous, unmatched and stale selections
are unavailable. Each changed snapshot or invalidation retires the registration
and cache generation. A screen/session transition requires another snapshot
from the existing layout lifecycle, even when the numeric ID stays the same.

Notification data is untrusted and unauthenticated. JSON must be in the object
string and fit a fixed **16,384 UTF-8 byte** limit before decoding. The receiver
requires a positive `UInt32` display ID matching that selected presentation
display and the exact `controlTarget` string `hardwareBrightness`. It requires
numeric finite `value` and `maxValue`, with `0 <= value <= maxValue` and
`maxValue > 0`, before calculating `value / maxValue`. Booleans, strings and
null cannot stand in for required numbers. Missing, malformed, locked and
unsupported reports are ignored. No invalid value is clamped into validity.
External text, symbols, commands, paths, fade and sizing hints are not retained,
displayed, logged or acted on. Fixed OpenCove labels, sun symbol, layout and
existing category timing apply.

`BetterDisplayFeedback` has a separate provider, origin, UUID/current-ID/
generation identity, fraction and monotonic receipt time. There is one in-memory
cache entry. The **5-second receipt TTL** is local OpenCove policy, checked lazily
without timers or polling. It is not physical freshness: notifications can be
delayed or dropped and carry no source timestamp. `displayID` identifies where
to present feedback, not an attested physical adjustment target. A local
generation rejects callbacks from retired registrations; it cannot date a
vendor message delivered later to a new registration.

Feedback uses the brightness category and active/unlocked, awake session policy.
The receiver pauses when overlay labels are hidden so the source stays visible.
Expansion clears an external HUD and prevents external presentation while the
panel is expanded. Opt-out, category disable, selection/display/session changes,
sleep, shutdown and stop clear the cache and external HUD. Orderly vendor
termination retires OSD reception until a launch notification in that enabled
session. Launch also clears old data. Silent termination cannot be detected;
receipt expiry limits later preview eligibility without claiming provider liveness.
These events never produce haptics or alter native brightness availability,
writability, key ownership, `SystemController` or `HardwareKeyController`.

**Preview BetterDisplay feedback** explicitly chooses this provider and reads
only an eligible cached report. It never starts the receiver or refreshes any
source. Missing/expired data produces a source-labelled unavailable preview
without a percentage. Ineligible display/session/consent choices reject preview
with a reason. The ordinary **Preview overlay** action retains its native source;
a vendor report never replaces a good native reading. Neither path proves a
physical reading, DDC units, nits, a completed change or writable control.

The source contract comes from the vendor's [third-party integration guide](https://betterdisplay.pro/guide/integration/third-party-apps/)
and [current CLI reference](https://betterdisplay.pro/guide/integration/cli-reference/),
captured in the 24 October 2026 research. That reference identifies **5.2.0
Pre-Release Build 53990**, imported 21 October 2026. It does not certify stable
5.1.1 or older v4 behavior. Apple's [Foundation documentation](https://developer.apple.com/documentation/foundation/distributednotificationcenter)
describes untrusted data, unbounded latency and possible loss.

### BetterDisplay acceptance — UNVERIFIED

This slice has Swift parse, diff and source checks only. No build, app/helper/
vendor launch, native input, tests, mocks, synthetic notifications, hardware or
permission action ran. The parent must separately verify persistence and real
save failure through native Settings, missing/expired cache, genuine compatible
vendor events, identity/reconnect/ID-reuse and session invalidation, late callbacks,
and unchanged native control/haptic behavior when authorized. A real positive
case requires already-running, user-configured BetterDisplay events; no fabricated
event substitutes. Installed-vendor positive acceptance and hardware proof remain
**UNVERIFIED**. External DDC control remains absent. **Strict media C-PID FAILED**
and **M1/cloud DEFERRED** remain unchanged.

## Validation boundary

Build the real app with the checked-in [bundle workflow](building.md). The [integration workflow](quality.md) checks the real control API without enabling hardware interception by default. Preference-off and denied-access cases do not prove an active tap. Do not enable an authorized tap, generate key events, or drive desktop input for automated verification. Actual stock-HUD suppression and held-key behavior require an explicitly authorized manual session; compilation and permission preflight alone do not prove them.

## Apple references

- [CGEvent.tapCreate](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:)): event masks, filter creation, callback run-loop contract.
- [CGEventTapCallBack](https://developer.apple.com/documentation/coregraphics/cgeventtapcallback): synchronous event return and filtering.
- [AXIsProcessTrustedWithOptions](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions): explicit, asynchronous Accessibility prompt.
- [CGPreflightListenEventAccess](https://developer.apple.com/documentation/coregraphics/cgpreflightlisteneventaccess()): nonprompting event access check.
- Installed macOS SDK: `IOKit.framework/Headers/hidsystem/ev_keymap.h` (media codes), `IOLLEvent.h` (system-defined type, subtype, down/up codes), `AppKit.framework/Headers/NSEvent.h`, and `CoreGraphics.framework/Headers/CGEvent.h` (tap lifetime and permission declarations).


### Recorded visibility-option acceptance

An optimized arm64 development bundle of `7da217d` produced 22 check records,
including a pending accessibility record. The covered presentation and
persistence branches passed.
Mounted captures covered all four visual choices for real finite volume and
battery readings, unavailable brightness and nonnumeric notification previews.
Continuous and supported simulated-notch center-gap layouts both ran. Across
live preference edits, the model and original dismissal deadline stayed fixed;
no second preview was submitted within each matrix. Icon/progress regions and
center clearance were checked separately from label and percentage pixels.

The actual Activities settings views showed the controls and save/repair/error
states. Both-false and mixed choices survived process restart. Legacy omissions
kept both choices on; malformed fields followed the existing repair path. A real
unwritable destination returned a save error, kept the session choice and did not
claim persistence. The browser used the actual Preview overlay button and the
same authenticated preference path. All nine owned launches stopped and their
credentials were cleared.

This establishes the recorded presentation and persistence subset. Physical
notch behavior, a finite brightness reading, native Settings input, native
accessibility/VoiceOver and compositor output remain unverified. Source preserves the accessible compact
label; that is separate from runtime accessibility proof. No hardware write,
key interception, personal player control or new permission was exercised.
