// SPDX-License-Identifier: MIT
import AppKit
import ApplicationServices
import Combine
import CoreGraphics

/// Optional media-key filtering. The parent owns the preference (default false),
/// SystemController lifecycle, and HUD presentation. No input is ever posted.
@MainActor
final class HardwareKeyController: ObservableObject {
    @Published private(set) var status = "System HUD replacement is off."
    /// True only while the tap is active and at least one control is supported.
    @Published private(set) var available = false
    /// The parent mirrors enableVolumeHUD/enableBrightnessHUD before start().
    /// A disabled category never refreshes, writes, consumes input, or emits HUDs.
    var volumeEnabled = true {
        didSet { if volumeEnabled != oldValue { categoryChanged(volume: true) } }
    }
    var brightnessEnabled = true {
        didSet { if brightnessEnabled != oldValue { categoryChanged(volume: false) } }
    }

    private let system: SystemController
    private var enabled = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var context: HardwareKeyTapContext?
    private var stateObservation: AnyCancellable?
    private var presses: [MediaKey: PressDisposition] = [:]
    private var failure: String?

    init(system: SystemController) {
        self.system = system
        // Published sends before state changes, so use its incoming value.
        stateObservation = system.$state.combineLatest(system.$lastError).sink { [weak self] state, error in
            guard let self, self.enabled, self.tap != nil else { return }
            self.updateStatus(state, error: error)
        }
    }

    deinit {
        // A MainActor object's final release need not occur on the main thread.
        // Keep userInfo alive until main-run-loop callbacks have been retired.
        let cleanup = HardwareKeyTapCleanup(tap: tap, source: source, context: context)
        DispatchQueue.main.async {
            cleanup.invalidate()
        }
    }

    /// Startup/preference restoration never requests new permission.
    func start(enabled: Bool) {
        guard enabled else { return stop() }
        self.enabled = true
        failure = nil
        if let issue = permissionIssue() {
            removeTap()
            available = false
            status = issue
            return
        }
        if let tap, CFMachPortIsValid(tap), CGEvent.tapIsEnabled(tap: tap) {
            updateStatus()
            return
        }
        removeTap()
        let newContext = HardwareKeyTapContext(owner: self)
        // IOLLEvent.h: NX_SYSDEFINED = 14. Do not subscribe to typing or mouse input.
        let mask = CGEventMask(1) << NSEvent.EventType.systemDefined.rawValue
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, rawContext in
                // This source is scheduled ONLY on CFRunLoopGetMain(). Return the
                // original event if that invariant ever fails; never hop a callback.
                guard Thread.isMainThread, let rawContext else {
                    return Unmanaged.passUnretained(event)
                }
                return MainActor.assumeIsolated {
                    let context = Unmanaged<HardwareKeyTapContext>.fromOpaque(rawContext).takeUnretainedValue()
                    guard let owner = context.owner else { return Unmanaged.passUnretained(event) }
                    return owner.handle(type: type, event: event)
                }
            }, userInfo: Unmanaged.passUnretained(newContext).toOpaque()
        ) else {
            available = false
            status = "System HUD replacement is unavailable: macOS did not allow the media-key event tap. Check Accessibility and Input Monitoring access, then try again."
            return
        }
        guard let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            CFMachPortInvalidate(newTap)
            available = false
            status = "System HUD replacement is unavailable: its main-run-loop source could not be created."
            return
        }
        context = newContext
        tap = newTap
        source = newSource
        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        guard CGEvent.tapIsEnabled(tap: newTap) else {
            removeTap()
            available = false
            status = "System HUD replacement is unavailable: macOS left the media-key event tap disabled."
            return
        }
        updateStatus()
    }

    func stop() {
        enabled = false
        removeTap()
        failure = nil
        available = false
        status = "System HUD replacement is off."
    }

    /// Wire ONLY to an explicit access button. AX prompting is asynchronous;
    /// startup, permission recovery, and event callbacks never request access.
    func requestAccessAndStart() {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        // Avoid presenting a second permission request while AX is still denied.
        if AXIsProcessTrusted(), !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }
        start(enabled: true)
    }

    private func permissionIssue() -> String? {
        guard AXIsProcessTrusted() else {
            return "System HUD replacement requires Accessibility access. Use Grant Access, allow OpenCove in System Settings > Privacy & Security > Accessibility, then try again."
        }
        guard CGPreflightListenEventAccess() else {
            return "System HUD replacement requires Input Monitoring access. Use Grant Access, allow OpenCove in System Settings > Privacy & Security > Input Monitoring, then try again. A relaunch may be required."
        }
        return nil
    }

    private func removeTap() {
        HardwareKeyTapContext.invalidate(tap: tap, source: source)
        source = nil
        tap = nil
        // Invalidate first: no callback can retain a dangling userInfo pointer.
        context = nil
        presses.removeAll()
    }

    private func updateStatus() { updateStatus(system.state, error: system.lastError) }

    private func updateStatus(_ state: SystemState, error: String?) {
        guard enabled, let tap, CFMachPortIsValid(tap), CGEvent.tapIsEnabled(tap: tap) else {
            available = false
            return
        }
        let controls = [
            supports(.soundUp, state) ? "volume" : nil,
            supports(.mute, state) ? "mute" : nil,
            supports(.brightnessUp, state) ? "brightness" : nil
        ].compactMap { $0 }
        available = !controls.isEmpty && error == nil
        if let failure {
            status = failure
        } else if error != nil {
            status = "System HUD replacement is paused while the system service reports an error. Hardware keys keep their normal macOS behavior."
        } else if !volumeEnabled && !brightnessEnabled {
            status = "System HUD replacement is inactive: both volume and brightness HUD categories are disabled. Hardware keys keep their normal macOS behavior."
        } else if controls.isEmpty {
            status = "System HUD replacement is unavailable: no readable, writable volume, mute, or brightness control is available. Brightness also requires private integrations. Hardware keys keep their normal macOS behavior."
        } else {
            status = "System HUD replacement is active for \(controls.joined(separator: ", ")). Other hardware keys and unsupported controls keep their normal macOS behavior."
        }
    }

    private func categoryChanged(volume: Bool) {
        for key in presses.keys.filter({ $0.isVolume == volume }) { presses.removeValue(forKey: key) }
        failure = nil
        updateStatus()
    }

    private func categoryEnabled(_ key: MediaKey) -> Bool {
        key.isVolume ? volumeEnabled : brightnessEnabled
    }

    private func supports(_ key: MediaKey, _ state: SystemState) -> Bool {
        guard categoryEnabled(key) else { return false }
        switch key {
        case .soundUp, .soundDown:
            return state.outputDeviceID != nil && !state.outputDeviceUID.isEmpty && state.volumeAvailable && state.canSetVolume && state.volume.isFinite
        case .mute:
            return state.outputDeviceID != nil && !state.outputDeviceUID.isEmpty && state.muteAvailable && state.canSetMute
        case .brightnessUp, .brightnessDown:
            // SystemController clears this capability when private APIs are off.
            return state.brightnessAvailable && state.canSetBrightness && state.brightness.isFinite
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let original = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout {
            presses.removeAll() // Never claim the remainder of an interrupted press.
            guard enabled else { return original }
            if let issue = permissionIssue() {
                removeTap()
                available = false
                status = issue
            } else if let tap, CFMachPortIsValid(tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
                updateStatus()
                if !CGEvent.tapIsEnabled(tap: tap) {
                    status = "System HUD replacement is unavailable: macOS could not re-enable the media-key tap after a timeout. Turn replacement off and on to retry."
                }
            }
            return original
        }
        if type == .tapDisabledByUserInput {
            // Respect an explicit system/user disable; only a later start retries.
            removeTap()
            available = false
            status = "macOS disabled system HUD replacement. Turn replacement off and on to retry."
            return original
        }
        guard enabled, tap != nil,
              type.rawValue == UInt32(NSEvent.EventType.systemDefined.rawValue),
              let native = NSEvent(cgEvent: event), native.type == .systemDefined,
              native.subtype.rawValue == 8,
              let key = MediaKey(rawValue: (native.data1 >> 16) & 0xffff) else { return original }
        guard categoryEnabled(key) else {
            presses.removeValue(forKey: key)
            return original
        }

        // AUX_CONTROL_BUTTONS data1: key in bits 16...31, NX_KEYDOWN/NX_KEYUP
        // (10/11) in bits 8...15, repeat in bit 0. Unknown encodings pass through.
        let phase = (native.data1 >> 8) & 0xff
        let repeatBits = native.data1 & 0xff
        guard (phase == 0x0a || phase == 0x0b), repeatBits <= 1 else {
            presses[key] = .passthrough
            return original
        }
        let modifiers = native.modifierFlags
        // Option/Control open system settings or have other system meanings.
        // Preserve Command/Help combinations too, rather than guess their action.
        guard modifiers.intersection([.option, .control, .command, .help]).isEmpty,
              event.flags.intersection([.maskAlternate, .maskControl, .maskCommand, .maskHelp]).isEmpty else {
            if phase == 0x0b { presses.removeValue(forKey: key) } else { presses[key] = .passthrough }
            return original
        }
        if let issue = permissionIssue() {
            removeTap()
            available = false
            status = issue
            return original
        }
        if phase == 0x0b {
            let handled = presses.removeValue(forKey: key) == .handled
            return handled && supports(key, system.state) && system.lastError == nil ? nil : original
        }
        let isRepeat = repeatBits == 1
        if isRepeat, presses[key] != .handled { return original }

        // Refresh real readings before calculating a relative step. A changed
        // output/display must not inherit a target calculated for the old device.
        system.refreshHardwareControls(volume: key.isVolume)
        guard enabled, tap != nil, supports(key, system.state), system.lastError == nil else {
            presses[key] = .passthrough
            updateStatus()
            return original
        }
        // Holding mute must not toggle it on every repeat. Only an initial
        // successful write grants ownership of its repeat/release sequence.
        if key == .mute, isRepeat { return nil }
        let before = system.state
        let step = modifiers.contains(.shift) ? 1.0 / 64.0 : 1.0 / 16.0
        let result: SystemController.HardwareWriteResult
        switch key {
        case .soundUp, .soundDown, .mute:
            guard let device = before.outputDeviceID else { presses[key] = .passthrough; return original }
            if key == .mute { result = system.toggleMuteByHardware(expectedDeviceID: device, expectedUID: before.outputDeviceUID) }
            else { result = system.adjustVolumeByHardware(key == .soundUp ? step : -step, expectedDeviceID: device, expectedUID: before.outputDeviceUID) }
        case .brightnessUp, .brightnessDown:
            guard let display = before.brightnessDisplayID else { presses[key] = .passthrough; return original }
            result = system.adjustBrightnessByHardware(key == .brightnessUp ? step : -step, expectedDisplayID: display)
        }
        guard result == .submitted else {
            presses[key] = .passthrough
            updateStatus()
            return original
        }
        // A submitted write owns this key sequence, even if a driver reports a
        // failure or the default target subsequently changes. Never apply it twice.
        presses[key] = .handled
        failure = system.lastError
        updateStatus()
        if system.lastError == nil { showHUDIfUnchanged(key: key, before: before) }
        return nil
    }

    private func showHUDIfUnchanged(key: MediaKey, before: SystemState) {
        // SystemController emits real changes. A successful key at the range
        // boundary should still show a HUD, without duplicating its change HUD.
        let after = system.state
        switch key {
        case .soundUp, .soundDown, .mute:
            guard after.outputDeviceID == before.outputDeviceID, after.outputDeviceUID == before.outputDeviceUID,
                  abs(after.volume - before.volume) <= 0.001, after.isMuted == before.isMuted else { return }
            system.onHUD?(CoveHUD(kind: .volume, title: after.isMuted ? "Muted" : "Volume",
                                 subtitle: after.outputDevice,
                                 symbol: after.isMuted || after.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                 value: after.isMuted ? 0 : (after.volumeAvailable ? after.volume : nil)))
        case .brightnessUp, .brightnessDown:
            guard after.brightnessDisplayID == before.brightnessDisplayID,
                  abs(after.brightness - before.brightness) <= 0.002 else { return }
            system.onHUD?(CoveHUD(kind: .brightness, title: "Brightness", subtitle: after.brightnessDisplayName,
                                 symbol: "sun.max.fill", value: after.brightness))
        }
    }

    // SDK IOKit/hidsystem/ev_keymap.h; IOLLEvent.h supplies subtype and phases.
    private enum MediaKey: Int {
        case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
        var isVolume: Bool { self == .soundUp || self == .soundDown || self == .mute }
    }
    private enum PressDisposition { case handled, passthrough }
}

/// The controller owns this context; the context never retains the controller.
/// All callback dereferences and port/source teardown run on the main run loop.
private final class HardwareKeyTapContext {
    weak var owner: HardwareKeyController?

    init(owner: HardwareKeyController) { self.owner = owner }

    static func invalidate(tap: CFMachPort?, source: CFRunLoopSource?) {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        if let tap { CFMachPortInvalidate(tap) }
    }
}

/// Immutable lifetime transfer from a possibly nonisolated deinit to the main
/// queue. The CF handles and weak owner are only USED on the main actor. Their
/// strong references can safely be retained while that cleanup is enqueued.
private final class HardwareKeyTapCleanup: @unchecked Sendable {
    let tap: CFMachPort?
    let source: CFRunLoopSource?
    let context: HardwareKeyTapContext?

    init(tap: CFMachPort?, source: CFRunLoopSource?, context: HardwareKeyTapContext?) {
        self.tap = tap
        self.source = source
        self.context = context
    }

    @MainActor func invalidate() {
        HardwareKeyTapContext.invalidate(tap: tap, source: source)
        withExtendedLifetime(context) {}
    }
}
