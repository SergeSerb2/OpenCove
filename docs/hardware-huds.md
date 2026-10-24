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

## Validation boundary

Build the real app with the checked-in [bundle workflow](building.md). The [integration workflow](quality.md) checks the real control API without enabling hardware interception by default. Preference-off and denied-access cases do not prove an active tap. Do not enable an authorized tap, generate key events, or drive desktop input for automated verification. Actual stock-HUD suppression and held-key behavior require an explicitly authorized manual session; compilation and permission preflight alone do not prove them.

## Apple references

- [CGEvent.tapCreate](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:)): event masks, filter creation, callback run-loop contract.
- [CGEventTapCallBack](https://developer.apple.com/documentation/coregraphics/cgeventtapcallback): synchronous event return and filtering.
- [AXIsProcessTrustedWithOptions](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions): explicit, asynchronous Accessibility prompt.
- [CGPreflightListenEventAccess](https://developer.apple.com/documentation/coregraphics/cgpreflightlisteneventaccess()): nonprompting event access check.
- Installed macOS SDK: `IOKit.framework/Headers/hidsystem/ev_keymap.h` (media codes), `IOLLEvent.h` (system-defined type, subtype, down/up codes), `AppKit.framework/Headers/NSEvent.h`, and `CoreGraphics.framework/Headers/CGEvent.h` (tap lifetime and permission declarations).
