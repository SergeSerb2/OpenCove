import AppKit
import Combine
import CoreAudio
import CoreBluetooth
import CoreGraphics
import Darwin
import IOBluetooth
import IOKit
import IOKit.ps
import Intents

/// Passive system monitoring and explicit user controls. This service never suppresses
/// Apple's HUD, injects input, or changes Focus/lock state. Permission requests and
/// audio output writes have explicit user-action entry points only.
@MainActor
final class SystemController: NSObject, ObservableObject {
    @Published private(set) var state = SystemState()
    @Published private(set) var lastError: String?
    @Published private(set) var outputDevices: [CoveAudioOutput] = []
    @Published private(set) var accessoryBatteries: [CoveAccessoryBattery] = []
    @Published private(set) var isRequestingBluetoothAccess = false
    @Published private(set) var isRequestingFocusAccess = false
    var onHUD: ((CoveHUD) -> Void)?
    var onLockChange: ((Bool) -> Void)?

    private var running = false
    private var privateAPIs = false
    private var generation = 0
    private var observations = SystemObservations()
    private var displayServices: SystemDisplayServices?
    private var audioDevice = AudioObjectID(kAudioObjectUnknown)
    private var brightnessDisplay: CGDirectDisplayID?
    private var connectedBluetooth: [String: String] = [:]
    private var bluetoothObserver: SystemBluetoothObserver?
    private var bluetoothAccessRequest: SystemBluetoothAccessRequest?
    private var pendingParts: SystemRefreshParts = []
    private var refreshWork: DispatchWorkItem?
    private var errors: [String: String] = [:]
    private var audioSystemNeedsPolling = false
    private var audioDeviceNeedsPolling = false
    private var audioListenersNeedRefresh = false
    private var outputDevicesNeedPolling = false
    private var outputListenersNeedPolling = false
    private var outputObservedDevices = Set<AudioObjectID>()
    private var bluetoothNeedsPolling = false
    private var screensAwake = true
    private var systemAwake = true
    private var lastHUD: CoveHUD?
    private var audioRefreshAcceptance: AudioRefreshAcceptance?
    private var audioRefreshCapture: AudioRefreshEvidence?

    enum AudioRefreshCaller: String, Encodable { case nativePicker, developmentAPI, hardwareControl }

    struct ReadEvidence: Encodable {
        var count = 0
        var milliseconds = 0.0
    }

    struct AudioRefreshEvidence: Encodable {
        let caller: AudioRefreshCaller
        let generation: Int
        var milliseconds = 0.0
        // Counts are domain-entry calls, not individual OS property reads.
        var reads = Dictionary(uniqueKeysWithValues: ["audio", "audioOutputs", "brightness", "battery",
            "bluetooth", "bluetoothRegistry", "focus", "lock"].map { ($0, ReadEvidence()) })
        // Request-scoped attempted OS setter calls, including failed attempts.
        let hardwareWritesBefore: Int
        var hardwareWritesAfter = 0
        var hardwareWriteDelta = 0
        var audioReadErrors: [String] = []
    }

    private final class AudioRefreshAcceptance {
        var hardwareWrites = 0
        var samples: [AudioRefreshEvidence] = []
    }

    /// Only the opt-in development server opens this short capture window. No
    /// clocks, counters or retained samples run outside an explicit acceptance.
    func withAudioRefreshAcceptance(_ operation: @MainActor () async throws -> Void) async rethrows -> [AudioRefreshEvidence]? {
        guard running, audioRefreshAcceptance == nil else { return nil }
        let acceptance = AudioRefreshAcceptance()
        let initialGeneration = generation
        audioRefreshAcceptance = acceptance
        defer { audioRefreshAcceptance = nil }
        try await operation()
        guard running, generation == initialGeneration else { return nil }
        return acceptance.samples
    }

    private func beginReadEvidence(_ domain: String) -> TimeInterval? {
        guard audioRefreshCapture != nil else { return nil }
        audioRefreshCapture?.reads[domain, default: ReadEvidence()].count += 1
        return ProcessInfo.processInfo.systemUptime
    }

    private func finishReadEvidence(_ domain: String, since start: TimeInterval?) {
        guard let start else { return }
        audioRefreshCapture?.reads[domain, default: ReadEvidence()].milliseconds +=
            (ProcessInfo.processInfo.systemUptime - start) * 1_000
    }

    deinit {
        refreshWork?.cancel()
        // A final release can occur off the main actor. Keep callback userInfo
        // and Bluetooth selector targets alive until the main-run-loop sources
        // and subscriptions have been removed on that same run loop.
        let cleanup = SystemControllerCleanup(observations: observations, bluetooth: bluetoothObserver,
                                              accessRequest: bluetoothAccessRequest)
        DispatchQueue.main.async {
            cleanup.cancel()
        }
    }

    func start(privateAPIs: Bool) {
        if running, self.privateAPIs == privateAPIs {
            refresh()
            return
        }
        stop()
        self.privateAPIs = privateAPIs
        running = true
        generation += 1
        state = SystemState()
        outputDevices = []
        accessoryBatteries = []
        errors.removeAll()
        lastError = nil
        connectedBluetooth.removeAll()
        lastHUD = nil
        screensAwake = true
        systemAwake = true
        displayServices = privateAPIs ? SystemDisplayServices() : nil
        installWorkspaceObservers()
        installPowerObserver()
        installAudioSystemObservers()
        if privateAPIs {
            installLockObservers()
            installBrightnessKeyObserverIfAuthorized()
        }
        // Establish each real baseline before any change can produce a HUD.
        read(parts: .all, emitHUD: false)
    }

    func stop() {
        running = false
        generation += 1
        refreshWork?.cancel()
        refreshWork = nil
        pendingParts = []
        observations.cancel()
        observations = SystemObservations()
        bluetoothObserver = nil
        bluetoothAccessRequest = nil
        isRequestingBluetoothAccess = false
        isRequestingFocusAccess = false
        displayServices = nil
        audioDevice = AudioObjectID(kAudioObjectUnknown)
        brightnessDisplay = nil
        audioSystemNeedsPolling = false
        audioDeviceNeedsPolling = false
        audioListenersNeedRefresh = false
        outputDevicesNeedPolling = false
        outputListenersNeedPolling = false
        outputObservedDevices.removeAll()
        bluetoothNeedsPolling = false
    }

    func refresh() {
        guard running else { return }
        read(parts: .all, emitHUD: true)
    }

    /// Refresh audio readings and output choices without reading unrelated domains.
    func refreshAudio(caller: AudioRefreshCaller = .nativePicker) {
        guard running else { return }
        withAudioReadEvidence(caller: caller) { read(parts: .audio, emitHUD: true) }
    }

    private func withAudioReadEvidence(caller: AudioRefreshCaller, operation: () -> Void) {
        // The picker keeps its original entry path. Only an armed acceptance
        // captures this synchronous call; later listener/fallback/HUD work is
        // outside its interval. A reentrant read contributes to the outer call.
        let capture = audioRefreshAcceptance != nil && audioRefreshCapture == nil
        let start = capture ? ProcessInfo.processInfo.systemUptime : nil
        if capture, let acceptance = audioRefreshAcceptance {
            audioRefreshCapture = AudioRefreshEvidence(caller: caller, generation: generation,
                                                       hardwareWritesBefore: acceptance.hardwareWrites)
        }
        defer {
            if let start, var evidence = audioRefreshCapture, let acceptance = audioRefreshAcceptance {
                evidence.milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000
                evidence.hardwareWritesAfter = acceptance.hardwareWrites
                evidence.hardwareWriteDelta = evidence.hardwareWritesAfter - evidence.hardwareWritesBefore
                evidence.audioReadErrors = ["audioDevicesRead", "audioRead"].compactMap { errors[$0] }
                acceptance.samples.append(evidence)
                audioRefreshCapture = nil
            }
        }
        operation()
    }

    /// The synchronous event-tap path must not enumerate Bluetooth, query Focus,
    /// or read private content while deciding whether to consume a control key.
    func refreshHardwareControls(volume: Bool) {
        guard running else { return }
        if volume {
            withAudioReadEvidence(caller: .hardwareControl) { read(parts: .audio, emitHUD: false) }
        } else { read(parts: .brightness, emitHUD: false) }
    }

    /// Call only from an explicit output choice. Monitoring never changes routes.
    func selectOutputDevice(_ id: UInt32) { _ = selectOutputDeviceWithResult(id) }

    func selectOutputDeviceWithResult(_ id: UInt32) -> OperationResult {
        guard running else { return rejectOperation("audioRoute", "System monitoring is stopped.") }
        guard let requested = outputDevices.first(where: { $0.id == id }) else {
            return rejectOperation("audioRoute", "That audio output is no longer available.")
        }
        read(parts: .audio, emitHUD: false)
        // CoreAudio IDs may be reused after device removal or a service restart.
        guard outputDevices.contains(where: { $0.id == id && $0.uid == requested.uid }) else {
            return rejectOperation("audioRoute", "That audio output disconnected. Choose an available output.")
        }
        guard state.outputDeviceID != id else { setError("audioRoute", nil); return .submitted }
        guard state.canSelectOutputDevice else {
            return rejectOperation("audioRoute", "CoreAudio does not allow changing the default output.")
        }
        var property = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(id)
        audioRefreshAcceptance?.hardwareWrites += 1
        let result = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil,
                                               UInt32(MemoryLayout<AudioObjectID>.size), &device)
        let outcome = finishOperation("audioRoute", result == noErr ? nil : "Could not select audio output: \(statusDescription(result)).")
        // Report the real route. Do not optimistically publish the requested ID.
        read(parts: [.audio, .bluetooth], emitHUD: true)
        if result == noErr { scheduleRead([.audio, .bluetooth], after: 0.15) }
        return outcome
    }

    /// The sole Bluetooth permission request path; never scans, connects, or pairs.
    func requestBluetoothAccess() {
        guard running else { return setError("bluetoothAccess", "System monitoring is stopped.") }
        guard !isRequestingBluetoothAccess else { return }
        guard CBManager.authorization == .notDetermined else {
            read(parts: .bluetooth, emitHUD: false)
            setError("bluetoothAccess", CBManager.authorization == .allowedAlways ? nil : "Enable Bluetooth access for OpenCove in System Settings > Privacy & Security > Bluetooth.")
            return
        }
        guard hasUsageDescription("NSBluetoothAlwaysUsageDescription") else {
            return setError("bluetoothAccess", "The app bundle needs NSBluetoothAlwaysUsageDescription before it can request Bluetooth access.")
        }
        setError("bluetoothAccess", nil)
        isRequestingBluetoothAccess = true
        bluetoothAccessRequest = SystemBluetoothAccessRequest(owner: self, generation: generation)
    }

    /// Requests read-only shared Focus status, never a Focus mode change.
    func requestFocusAccess() {
        guard running else { return setError("focusAccess", "System monitoring is stopped.") }
        guard !isRequestingFocusAccess else { return }
        let center = INFocusStatusCenter.default
        guard center.authorizationStatus == .notDetermined else {
            read(parts: .focus, emitHUD: false)
            setError("focusAccess", center.authorizationStatus == .authorized ? nil : "Focus status access is disabled or restricted. Review OpenCove's Focus status access in System Settings.")
            return
        }
        guard hasUsageDescription("NSFocusStatusUsageDescription") else {
            return setError("focusAccess", "The app bundle needs NSFocusStatusUsageDescription before it can request Focus status access.")
        }
        setError("focusAccess", nil)
        isRequestingFocusAccess = true
        let currentGeneration = generation
        center.requestAuthorization { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.running, self.generation == currentGeneration else { return }
                self.isRequestingFocusAccess = false
                self.read(parts: .focus, emitHUD: false)
                self.setError("focusAccess", self.state.focusAuthorization == "authorized" ? nil : "Focus status access was not granted.")
            }
        }
    }

    private func hasUsageDescription(_ key: String) -> Bool {
        guard let description = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return false }
        return !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    enum HardwareWriteResult { case rejected, submitted }

    /// A synchronous result for this operation, independent of persistent read diagnostics.
    /// Submitted means no synchronous failure, including an already-selected route.
    /// It is not a later device acknowledgement.
    enum OperationResult {
        case rejected(String), submitted, failed(String)

        fileprivate var hardwareWriteResult: HardwareWriteResult {
            switch self {
            case .rejected: return .rejected
            // Consume a key after any attempted write, even when the OS rejected it.
            // Passing it through could apply the same input a second time.
            case .submitted, .failed: return .submitted
            }
        }
    }

    // Preserve the native controls' Void action signatures, including method references.
    func setVolume(_ value: Double) { _ = setVolumeWithResult(value) }
    func toggleMute() { _ = toggleMuteWithResult() }
    func setBrightness(_ value: Double) { _ = setBrightnessWithResult(value) }

    func setVolumeWithResult(_ value: Double) -> OperationResult { writeVolume(absolute: value) }
    func toggleMuteWithResult() -> OperationResult { writeMuteControl() }
    func setBrightnessWithResult(_ value: Double) -> OperationResult { writeBrightness(absolute: value) }

    func adjustVolume(_ delta: Double, expectedDeviceID: UInt32, expectedUID: String) -> OperationResult {
        writeVolume(delta: delta, expectedDeviceID: expectedDeviceID, expectedUID: expectedUID)
    }

    func adjustVolumeByHardware(_ delta: Double, expectedDeviceID: UInt32, expectedUID: String) -> HardwareWriteResult {
        adjustVolume(delta, expectedDeviceID: expectedDeviceID, expectedUID: expectedUID).hardwareWriteResult
    }

    func toggleMuteByHardware(expectedDeviceID: UInt32, expectedUID: String) -> HardwareWriteResult {
        writeMuteControl(expectedDeviceID: expectedDeviceID, expectedUID: expectedUID).hardwareWriteResult
    }

    func adjustBrightnessByHardware(_ delta: Double, expectedDisplayID: UInt32) -> HardwareWriteResult {
        writeBrightness(delta: delta, expectedDisplayID: expectedDisplayID).hardwareWriteResult
    }

    private func writeVolume(absolute: Double? = nil, delta: Double = 0,
                             expectedDeviceID: UInt32? = nil, expectedUID: String? = nil) -> OperationResult {
        guard running else { return rejectOperation("audioControl", "System monitoring is stopped.") }
        read(parts: .audio, emitHUD: false)
        guard expectedDeviceID == nil || (state.outputDeviceID == expectedDeviceID && state.outputDeviceUID == expectedUID) else {
            return .rejected("Audio target changed. No write was submitted.")
        }
        let value = absolute ?? (state.volume + delta)
        guard value.isFinite, state.canSetVolume else {
            return rejectOperation("audioControl", "The output does not expose a writable volume control.")
        }
        let target = audioDevice
        let addresses = volumeAddresses(for: target, writableOnly: true)
        guard !addresses.isEmpty else { return rejectOperation("audioControl", "The output volume control disappeared.") }
        let level = Float32(min(1, max(0, value)))
        let current = addresses.compactMap { readFloat(target, $0) }
        guard current.count == addresses.count else {
            return rejectOperation("audioControl", "The output volume could not be read before the write.")
        }
        let maximum = current.max() ?? 0
        var failures: [String] = []
        for (index, varAddress) in addresses.enumerated() {
            var address = varAddress
            var scalar = addresses.count > 1 && maximum > 0 ? level * current[index] / maximum : level
            audioRefreshAcceptance?.hardwareWrites += 1
            let result = AudioObjectSetPropertyData(target, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &scalar)
            if result != noErr { failures.append(statusDescription(result)) }
        }
        if level > 0, state.isMuted, state.canSetMute { failures.append(contentsOf: writeMute(false)) }
        let outcome = finishOperation("audioControl", failures.isEmpty ? nil : "Could not set output volume: \(failures.joined(separator: ", ")).")
        read(parts: .audio, emitHUD: true)
        return outcome
    }

    private func writeMuteControl(expectedDeviceID: UInt32? = nil, expectedUID: String? = nil) -> OperationResult {
        guard running else { return rejectOperation("audioControl", "System monitoring is stopped.") }
        read(parts: .audio, emitHUD: false)
        guard expectedDeviceID == nil || (state.outputDeviceID == expectedDeviceID && state.outputDeviceUID == expectedUID) else {
            return .rejected("Audio target changed. No write was submitted.")
        }
        guard state.canSetMute else { return rejectOperation("audioControl", "The output does not expose a writable mute control.") }
        let failures = writeMute(!state.isMuted)
        let outcome = finishOperation("audioControl", failures.isEmpty ? nil : "Could not change output mute: \(failures.joined(separator: ", ")).")
        read(parts: .audio, emitHUD: true)
        return outcome
    }

    private func writeBrightness(absolute: Double? = nil, delta: Double = 0, expectedDisplayID: UInt32? = nil) -> OperationResult {
        guard running, privateAPIs else { return rejectOperation("brightnessControl", "Brightness control requires private integrations.") }
        read(parts: .brightness, emitHUD: false)
        guard expectedDisplayID == nil || state.brightnessDisplayID == expectedDisplayID else {
            return .rejected("Brightness target changed. No write was submitted.")
        }
        let value = absolute ?? (state.brightness + delta)
        guard value.isFinite, let display = brightnessDisplay, let services = displayServices, state.canSetBrightness else {
            return rejectOperation("brightnessControl", "No active display exposes brightness control. External DDC displays are not supported.")
        }
        audioRefreshAcceptance?.hardwareWrites += 1
        let result = services.set(display, Float(min(1, max(0, value))))
        let outcome = finishOperation("brightnessControl", result == 0 ? nil : "DisplayServices could not set brightness (\(result)).")
        read(parts: .brightness, emitHUD: true)
        scheduleRead(.brightness, after: 0.15)
        return outcome
    }

    private func rejectOperation(_ source: String, _ message: String) -> OperationResult {
        setError(source, message)
        return .rejected(message)
    }

    private func finishOperation(_ source: String, _ failure: String?) -> OperationResult {
        setError(source, failure)
        return failure.map { .failed($0) } ?? .submitted
    }

    private func setError(_ source: String, _ message: String?) {
        errors[source] = message
        let messages = errors.keys.sorted().compactMap { errors[$0] }
        let next = messages.isEmpty ? nil : messages.joined(separator: "\n")
        if lastError != next { lastError = next }
    }

    private func scheduleRead(_ parts: SystemRefreshParts, after delay: TimeInterval = 0.04) {
        guard running else { return }
        pendingParts.formUnion(parts)
        guard refreshWork == nil else { return }
        let currentGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.running, self.generation == currentGeneration else { return }
                self.refreshWork = nil
                let parts = self.pendingParts
                self.pendingParts = []
                self.read(parts: parts, emitHUD: true)
            }
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func read(parts: SystemRefreshParts, emitHUD: Bool) {
        guard running else { return }
        let previous = state
        let previousBluetooth = connectedBluetooth
        var next = state
        if parts.contains(.audio) { readAudio(into: &next) }
        if parts.contains(.battery) { readBattery(into: &next) }
        if parts.contains(.brightness), systemAwake, screensAwake { readBrightness(into: &next) }
        if parts.contains(.bluetooth) { readBluetooth(into: &next) }
        if parts.contains(.focus) { readFocus(into: &next) }
        if parts.contains(.lock) { readLock(into: &next) }
        if !next.bluetoothAvailable {
            next.bluetoothDevices = next.audioOutputIsBluetooth && !next.outputDevice.isEmpty ? [next.outputDevice] : []
        } else if next.audioOutputIsBluetooth, !next.outputDevice.isEmpty, !next.bluetoothDevices.contains(next.outputDevice) {
            next.bluetoothDevices.append(next.outputDevice)
            next.bluetoothDevices.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        if next != state { state = next }
        if outputDevices != next.outputDevices { outputDevices = next.outputDevices }
        if accessoryBatteries != next.accessoryBatteries { accessoryBatteries = next.accessoryBatteries }
        if previous.isLocked != next.isLocked || previous.lockStateKnown != next.lockStateKnown { onLockChange?(next.isLocked) }
        if emitHUD { emitChanges(from: previous, to: next, previousBluetooth: previousBluetooth) }
        configurePolling()
    }

    private func emitChanges(from old: SystemState, to new: SystemState, previousBluetooth: [String: String]) {
        let routeChanged = old.outputDeviceUID != new.outputDeviceUID || old.outputDevice != new.outputDevice
        if routeChanged {
            if new.outputDevice.isEmpty {
                emit(CoveHUD(kind: .volume, title: "Audio output disconnected", subtitle: old.outputDevice, symbol: "speaker.slash"))
            } else {
                emit(CoveHUD(kind: new.audioOutputIsBluetooth ? .bluetooth : .volume,
                             title: new.outputDevice, subtitle: "Audio output", symbol: new.audioOutputIsBluetooth ? "headphones" : "speaker.wave.2.fill"))
            }
        } else if (old.volumeAvailable && new.volumeAvailable && abs(new.volume - old.volume) > 0.001) ||
                    (old.muteAvailable && new.muteAvailable && new.isMuted != old.isMuted) {
            emit(CoveHUD(kind: .volume, title: new.isMuted ? "Muted" : "Volume",
                         subtitle: new.outputDevice, symbol: new.isMuted || new.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                         value: new.isMuted ? 0 : (new.volumeAvailable ? new.volume : nil)))
        }
        if old.brightnessAvailable, new.brightnessAvailable,
           old.brightnessDisplayID == new.brightnessDisplayID, abs(new.brightness - old.brightness) > 0.002 {
            emit(CoveHUD(kind: .brightness, title: "Brightness", subtitle: new.brightnessDisplayName, symbol: "sun.max.fill", value: new.brightness))
        }
        if old.batteryAvailable, new.batteryAvailable, old.hasBattery, new.hasBattery {
            if old.isOnACPower != new.isOnACPower || old.isCharging != new.isCharging {
                let title = new.isCharging ? "Charging" : (new.isOnACPower ? "Power connected" : "On battery")
                emit(CoveHUD(kind: .battery, title: title, subtitle: "\(new.batteryPercent)%",
                             symbol: new.isOnACPower ? "battery.100percent.bolt" : "battery.100percent", value: Double(new.batteryPercent) / 100))
            } else if !new.isOnACPower, [20, 10, 5].contains(where: { old.batteryPercent > $0 && new.batteryPercent <= $0 }) {
                emit(CoveHUD(kind: .battery, title: "Low battery", subtitle: "\(new.batteryPercent)% remaining", symbol: "battery.25percent", value: Double(new.batteryPercent) / 100))
            } else if old.batteryPercent < 100, new.batteryPercent == 100, new.isOnACPower {
                emit(CoveHUD(kind: .battery, title: "Battery full", subtitle: "100%", symbol: "battery.100percent", value: 1))
            }
        }
        if old.bluetoothAvailable, new.bluetoothAvailable {
            for identifier in connectedBluetooth.keys.sorted() where previousBluetooth[identifier] == nil {
                if !(routeChanged && new.audioOutputIsBluetooth && connectedBluetooth[identifier] == new.outputDevice) {
                    emit(CoveHUD(kind: .bluetooth, title: connectedBluetooth[identifier] ?? "Bluetooth device", subtitle: "Connected", symbol: "antenna.radiowaves.left.and.right"))
                }
            }
            for identifier in previousBluetooth.keys.sorted() where connectedBluetooth[identifier] == nil {
                emit(CoveHUD(kind: .bluetooth, title: previousBluetooth[identifier] ?? "Bluetooth device", subtitle: "Disconnected", symbol: "antenna.radiowaves.left.and.right.slash"))
            }
        }
        if old.focusAvailable, new.focusAvailable, old.focusEnabled != new.focusEnabled {
            emit(CoveHUD(kind: .focus, title: new.focusEnabled ? "Focus on" : "Focus off", symbol: new.focusEnabled ? "moon.fill" : "moon"))
        }
        if privateAPIs {
            for battery in new.accessoryBatteries {
                guard let previous = old.accessoryBatteries.first(where: { $0.id == battery.id }) else { continue }
                let components: [(String, Int?, Int?)] = [
                    ("Battery", previous.percentage, battery.percentage),
                    ("Left", previous.leftPercentage, battery.leftPercentage),
                    ("Right", previous.rightPercentage, battery.rightPercentage),
                    ("Case", previous.casePercentage, battery.casePercentage)
                ]
                let low = components.compactMap { label, before, after -> (String, Int)? in
                    guard let before, let after,
                          [20, 10, 5].contains(where: { before > $0 && after <= $0 }) else { return nil }
                    return (label, after)
                }.min { $0.1 < $1.1 }
                if let (component, percentage) = low {
                    emit(CoveHUD(kind: .bluetooth, title: "Low accessory battery", subtitle: "\(battery.label) · \(component) \(percentage)%",
                                 symbol: "battery.25percent", value: Double(percentage) / 100))
                }
            }
        }
        if old.lockStateKnown, new.lockStateKnown, old.isLocked != new.isLocked {
            emit(CoveHUD(kind: .lock, title: new.isLocked ? "Locked" : "Unlocked", symbol: new.isLocked ? "lock.fill" : "lock.open.fill"))
        }
    }

    private func emit(_ hud: CoveHUD) {
        if let previous = lastHUD, previous.kind == hud.kind, previous.title == hud.title,
           previous.subtitle == hud.subtitle, previous.value == hud.value,
           hud.createdAt.timeIntervalSince(previous.createdAt) < 0.5 { return }
        lastHUD = hud
        onHUD?(hud)
    }

    // MARK: CoreAudio

    private func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private func readUInt32(_ object: AudioObjectID, _ valueAddress: AudioObjectPropertyAddress) -> UInt32? {
        var property = valueAddress
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<UInt32>.size else { return nil }
        return value
    }

    private func readFloat(_ object: AudioObjectID, _ valueAddress: AudioObjectPropertyAddress) -> Float32? {
        var property = valueAddress
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<Float32>.size, value.isFinite else { return nil }
        return value
    }

    private func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector)
        // Keep actual pointer storage alive across HAL's raw output write. Passing
        // &Optional<Unmanaged<CFString>> directly can form an unsafe raw pointer.
        let value = UnsafeMutablePointer<Unmanaged<CFString>?>.allocate(capacity: 1)
        value.initialize(to: nil)
        defer {
            value.deinitialize(count: 1)
            value.deallocate()
        }
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, value) == noErr,
              size == MemoryLayout<Unmanaged<CFString>?>.size else { return nil }
        // HAL's CFString properties return an owned value (AudioHardwareBase.h).
        return value.pointee?.takeRetainedValue() as String?
    }

    private func readOutputDevices(into next: inout SystemState) {
        let start = beginReadEvidence("audioOutputs")
        defer { finishReadEvidence("audioOutputs", since: start) }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        next.outputDevices = []
        next.canSelectOutputDevice = false
        let sizeResult = AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size)
        let stride = MemoryLayout<AudioObjectID>.stride
        guard sizeResult == noErr, size <= 1_048_576, Int(size) % stride == 0 else {
            outputDevicesNeedPolling = true
            next.capabilityMessages["audioOutputs"] = "CoreAudio could not list available audio outputs."
            return setError("audioDevicesRead", "CoreAudio could not read the audio device list size.")
        }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / stride)
        let result: OSStatus = devices.isEmpty ? noErr : devices.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(system, &property, 0, nil, &size, bytes.baseAddress!)
        }
        guard result == noErr, Int(size) <= devices.count * stride, Int(size) % stride == 0 else {
            outputDevicesNeedPolling = true
            next.capabilityMessages["audioOutputs"] = "CoreAudio could not list available audio outputs."
            return setError("audioDevicesRead", "CoreAudio could not read the audio device list: \(statusDescription(result)).")
        }
        outputDevicesNeedPolling = false
        let availableDevices = Array(devices.prefix(Int(size) / stride))
        refreshAudioOutputObservers(availableDevices)
        next.outputDevices = availableDevices.compactMap { device in
            guard device != kAudioObjectUnknown,
                  readUInt32(device, address(kAudioDevicePropertyDeviceIsAlive)) == 1,
                  readUInt32(device, address(kAudioDevicePropertyIsHidden)) != 1,
                  readUInt32(device, address(kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioDevicePropertyScopeOutput)) == 1,
                  !outputElements(for: device).isEmpty,
                  let uid = readString(device, kAudioDevicePropertyDeviceUID), !uid.isEmpty else { return nil }
            let transport = readUInt32(device, address(kAudioDevicePropertyTransportType))
            return CoveAudioOutput(id: device, name: readString(device, kAudioObjectPropertyName) ?? "Audio output",
                                   uid: uid, isBluetooth: transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE)
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        next.canSelectOutputDevice = !next.outputDevices.isEmpty && isWritable(system, address(kAudioHardwarePropertyDefaultOutputDevice))
        next.capabilityMessages["audioOutputs"] = next.outputDevices.isEmpty ? "No selectable audio output is connected." :
            (next.canSelectOutputDevice ? nil : "The default audio output is read-only.")
        setError("audioDevicesRead", nil)
    }

    private func isWritable(_ object: AudioObjectID, _ valueAddress: AudioObjectPropertyAddress) -> Bool {
        var property = valueAddress
        var writable = DarwinBoolean(false)
        return AudioObjectHasProperty(object, &property) &&
            AudioObjectIsPropertySettable(object, &property, &writable) == noErr && writable.boolValue
    }

    private func outputElements(for device: AudioObjectID) -> [AudioObjectPropertyElement] {
        var property = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size, size <= 1_048_576 else { return [] }
        let allocatedSize = size
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, storage) == noErr,
              size >= MemoryLayout<AudioBufferList>.size, size <= allocatedSize else { return [] }
        let bufferCount = Int(storage.assumingMemoryBound(to: AudioBufferList.self).pointee.mNumberBuffers)
        let bufferOffset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
        guard bufferCount <= (Int(size) - bufferOffset) / MemoryLayout<AudioBuffer>.stride else { return [] }
        let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        let count = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard count > 0, count <= 4_096 else { return [] }
        return (1...count).map { AudioObjectPropertyElement($0) }
    }

    private func volumeAddresses(for device: AudioObjectID, writableOnly: Bool) -> [AudioObjectPropertyAddress] {
        let master = address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput)
        if readFloat(device, master) != nil { return !writableOnly || isWritable(device, master) ? [master] : [] }
        return outputElements(for: device).compactMap { element in
            let property = address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
            return readFloat(device, property) != nil && (!writableOnly || isWritable(device, property)) ? property : nil
        }
    }

    private func muteAddresses(for device: AudioObjectID, writableOnly: Bool) -> [AudioObjectPropertyAddress] {
        let master = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        if readUInt32(device, master) != nil { return !writableOnly || isWritable(device, master) ? [master] : [] }
        return outputElements(for: device).compactMap { element in
            let property = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, element: element)
            return readUInt32(device, property) != nil && (!writableOnly || isWritable(device, property)) ? property : nil
        }
    }

    private func writeMute(_ muted: Bool) -> [String] {
        let addresses = muteAddresses(for: audioDevice, writableOnly: true)
        guard !addresses.isEmpty else { return ["the mute control disappeared"] }
        return addresses.compactMap { valueAddress in
            var property = valueAddress
            var value: UInt32 = muted ? 1 : 0
            audioRefreshAcceptance?.hardwareWrites += 1
            let result = AudioObjectSetPropertyData(audioDevice, &property, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
            return result == noErr ? nil : statusDescription(result)
        }
    }

    private func readAudio(into next: inout SystemState) {
        let start = beginReadEvidence("audio")
        defer { finishReadEvidence("audio", since: start) }
        readOutputDevices(into: &next)
        var property = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let result = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device)
        if result != noErr || size != MemoryLayout<AudioObjectID>.size { device = AudioObjectID(kAudioObjectUnknown) }
        if device != audioDevice || audioListenersNeedRefresh {
            observations.removeDeviceAudioListeners()
            audioDevice = device
            audioListenersNeedRefresh = false
            if device != kAudioObjectUnknown { installAudioDeviceObservers(device) }
        }
        next.outputDevice = ""
        next.outputDeviceUID = ""
        next.outputDeviceID = nil
        next.audioOutputIsBluetooth = false
        next.volumeAvailable = false
        next.canSetVolume = false
        next.muteAvailable = false
        next.canSetMute = false
        guard result == noErr else {
            audioDeviceNeedsPolling = true
            next.capabilityMessages["audio"] = "CoreAudio could not read the default output device."
            setError("audioRead", "CoreAudio could not read the default output device: \(statusDescription(result)).")
            return
        }
        if device == kAudioObjectUnknown { audioDeviceNeedsPolling = false }
        guard device != kAudioObjectUnknown,
              readUInt32(device, address(kAudioDevicePropertyDeviceIsAlive)) == 1 else {
            audioDeviceNeedsPolling = device != kAudioObjectUnknown
            next.capabilityMessages["audio"] = "No default audio output is connected."
            setError("audioRead", nil)
            return
        }
        next.outputDevice = readString(device, kAudioObjectPropertyName) ?? "Audio output"
        next.outputDeviceID = device
        next.outputDeviceUID = readString(device, kAudioDevicePropertyDeviceUID) ?? ""
        let transport = readUInt32(device, address(kAudioDevicePropertyTransportType))
        next.audioOutputIsBluetooth = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        let levels = volumeAddresses(for: device, writableOnly: false).compactMap { readFloat(device, $0) }
        if !levels.isEmpty {
            next.volume = min(1, max(0, Double(levels.max() ?? 0)))
            next.volumeAvailable = true
        }
        let writableVolumes = volumeAddresses(for: device, writableOnly: true)
        next.canSetVolume = !writableVolumes.isEmpty && writableVolumes.count == levels.count
        let mutes = muteAddresses(for: device, writableOnly: false).compactMap { readUInt32(device, $0) }
        next.muteAvailable = !mutes.isEmpty
        next.isMuted = !mutes.isEmpty && mutes.allSatisfy { $0 != 0 }
        let writableMutes = muteAddresses(for: device, writableOnly: true)
        next.canSetMute = !writableMutes.isEmpty && writableMutes.count == mutes.count
        next.capabilityMessages["audio"] = next.canSetVolume ? nil : "This audio output has fixed volume or requires its own volume controls."
        setError("audioRead", nil)
    }

    private func installAudioSystemObservers() {
        audioSystemNeedsPolling = false
        let object = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices, kAudioHardwarePropertyServiceRestarted] {
            if !addAudioListener(object, address(selector), deviceListener: false) { audioSystemNeedsPolling = true }
        }
    }

    private func installAudioDeviceObservers(_ device: AudioObjectID) {
        audioDeviceNeedsPolling = false
        var properties = [address(kAudioObjectPropertyName), address(kAudioDevicePropertyDeviceIsAlive),
                          address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)]
        properties += volumeAddresses(for: device, writableOnly: false)
        properties += muteAddresses(for: device, writableOnly: false)
        for property in properties {
            if !addAudioListener(device, property, deviceListener: true) { audioDeviceNeedsPolling = true }
        }
    }

    private func refreshAudioOutputObservers(_ devices: [AudioObjectID]) {
        let identifiers = Set(devices.filter { $0 != kAudioObjectUnknown })
        guard identifiers != outputObservedDevices else { return }
        observations.removeOutputAudioListeners()
        outputObservedDevices = identifiers
        outputListenersNeedPolling = false
        for device in identifiers {
            let properties = [address(kAudioObjectPropertyName), address(kAudioDevicePropertyDeviceUID),
                              address(kAudioDevicePropertyDeviceIsAlive), address(kAudioDevicePropertyIsHidden),
                              address(kAudioDevicePropertyTransportType),
                              address(kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioDevicePropertyScopeOutput),
                              address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)]
            for var property in properties where AudioObjectHasProperty(device, &property) {
                if !addAudioListener(device, property, deviceListener: false, outputListListener: true) {
                    outputListenersNeedPolling = true
                }
            }
        }
    }

    private func addAudioListener(_ object: AudioObjectID, _ valueAddress: AudioObjectPropertyAddress,
                                  deviceListener: Bool, outputListListener: Bool = false) -> Bool {
        var property = valueAddress
        let currentGeneration = generation
        let block: AudioObjectPropertyListenerBlock = { [weak self] count, changed in
            let selectors = (0..<Int(count)).map { changed[$0].mSelector }
            Task { @MainActor [weak self] in
                guard let self, self.running, self.generation == currentGeneration else { return }
                if selectors.contains(kAudioHardwarePropertyServiceRestarted) {
                    self.observations.audio.forEach { $0.remove() }
                    self.observations.audio.removeAll()
                    self.outputObservedDevices.removeAll()
                    self.outputListenersNeedPolling = false
                    self.audioListenersNeedRefresh = true
                    self.installAudioSystemObservers()
                } else if selectors.contains(kAudioHardwarePropertyDevices) {
                    // A replacement device can reuse the same numeric HAL ID.
                    self.observations.removeOutputAudioListeners()
                    self.outputObservedDevices.removeAll()
                    self.audioListenersNeedRefresh = true
                } else if selectors.contains(kAudioDevicePropertyStreamConfiguration) ||
                            selectors.contains(kAudioHardwarePropertyDefaultOutputDevice) ||
                            selectors.contains(kAudioDevicePropertyDeviceUID) {
                    self.audioListenersNeedRefresh = true
                }
                self.scheduleRead(deviceListener || outputListListener ? .audio : [.audio, .bluetooth])
            }
        }
        let result = AudioObjectAddPropertyListenerBlock(object, &property, .main, block)
        if result == noErr {
            observations.audio.append(SystemAudioListener(object: object, address: valueAddress, block: block,
                                                         isDevice: deviceListener, isOutputList: outputListListener))
        }
        return result == noErr
    }

    private func statusDescription(_ status: OSStatus) -> String {
        let bits = UInt32(bitPattern: status)
        let bytes = [UInt8((bits >> 24) & 255), UInt8((bits >> 16) & 255), UInt8((bits >> 8) & 255), UInt8(bits & 255)]
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }), let fourCC = String(bytes: bytes, encoding: .ascii) {
            return "\(status) ('\(fourCC)')"
        }
        return String(status)
    }

    // MARK: IOKit power sources

    private func installPowerObserver() {
        let context = SystemCallbackContext(owner: self)
        observations.contexts.append(context)
        if let source = IOPSNotificationCreateRunLoopSource({ rawContext in
            guard let rawContext else { return }
            let context = Unmanaged<SystemCallbackContext>.fromOpaque(rawContext).takeUnretainedValue()
            Task { @MainActor [weak owner = context.owner] in owner?.scheduleRead(.battery) }
        }, Unmanaged.passUnretained(context).toOpaque())?.takeRetainedValue() {
            observations.powerSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    private func readBattery(into next: inout SystemState) {
        let start = beginReadEvidence("battery")
        defer { finishReadEvidence("battery", since: start) }
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            next.batteryAvailable = false
            next.capabilityMessages["battery"] = "Power source information is unavailable."
            setError("batteryRead", "IOKit could not read power source information.")
            return
        }
        next.batteryAvailable = true
        next.hasBattery = false
        next.isCharging = false
        next.isOnACPower = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String? == kIOPSACPowerValue
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  (description[kIOPSIsPresentKey] as? Bool) != false else { continue }
            next.hasBattery = true
            next.isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            next.isOnACPower = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            if let capacity = description[kIOPSCurrentCapacityKey] as? NSNumber,
               let maximum = description[kIOPSMaxCapacityKey] as? NSNumber, maximum.doubleValue > 0 {
                next.batteryPercent = Int(min(100, max(0, (100 * capacity.doubleValue / maximum.doubleValue).rounded())))
            } else {
                next.batteryAvailable = false
            }
            break
        }
        if !next.hasBattery { next.batteryPercent = 0 }
        next.capabilityMessages["battery"] = next.hasBattery ? (next.batteryAvailable ? nil : "Battery capacity is not available yet.") : "This Mac has no internal battery."
        setError("batteryRead", nil)
    }

    // MARK: DisplayServices (optional, dynamically loaded)

    private func readBrightness(into next: inout SystemState) {
        let start = beginReadEvidence("brightness")
        defer { finishReadEvidence("brightness", since: start) }
        next.brightnessAvailable = false
        next.canSetBrightness = false
        next.brightnessDisplayID = nil
        brightnessDisplay = nil
        guard privateAPIs else {
            next.capabilityMessages["brightness"] = "Brightness control requires the private integrations setting."
            return
        }
        guard let services = displayServices else {
            next.capabilityMessages["brightness"] = "DisplayServices brightness symbols are unavailable on this macOS version."
            return
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(displays.count), &displays, &count) == .success else {
            setError("brightnessRead", "CoreGraphics could not list active displays.")
            return
        }
        let candidates = displays.prefix(Int(count)).sorted {
            let left = CGDisplayIsBuiltin($0) != 0 ? 0 : ($0 == CGMainDisplayID() ? 1 : 2)
            let right = CGDisplayIsBuiltin($1) != 0 ? 0 : ($1 == CGMainDisplayID() ? 1 : 2)
            return left == right ? $0 < $1 : left < right
        }
        for display in candidates {
            var value: Float = 0
            guard services.get(display, &value) == 0, value.isFinite else { continue }
            brightnessDisplay = display
            next.brightnessDisplayID = display
            next.brightness = min(1, max(0, Double(value)))
            next.brightnessAvailable = true
            next.canSetBrightness = services.canSet(display)
            next.brightnessDisplayName = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
            }?.localizedName ?? (CGDisplayIsBuiltin(display) != 0 ? "Built-in display" : "Display")
            next.capabilityMessages["brightness"] = next.canSetBrightness ? nil : "This display exposes brightness reading only."
            setError("brightnessRead", nil)
            return
        }
        next.brightnessDisplayName = ""
        next.capabilityMessages["brightness"] = "No active display supports DisplayServices brightness. External DDC displays are not supported."
        setError("brightnessRead", nil)
    }

    private func installBrightnessKeyObserverIfAuthorized() {
        // Preflight never asks for Input Monitoring access. There is deliberately no
        // call to CGRequestListenEventAccess or AXIsProcessTrustedWithOptions.
        guard CGPreflightListenEventAccess() else { return }
        let context = SystemCallbackContext(owner: self)
        let mask: CGEventMask = 1 << NSEvent.EventType.systemDefined.rawValue
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                         eventsOfInterest: mask, callback: { _, type, event, rawContext in
            guard let rawContext else { return Unmanaged.passUnretained(event) }
            let context = Unmanaged<SystemCallbackContext>.fromOpaque(rawContext).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                Task { @MainActor [weak owner = context.owner] in
                    if let tap = owner?.observations.keyTap { CGEvent.tapEnable(tap: tap, enable: true) }
                }
            } else if let native = NSEvent(cgEvent: event), native.type == .systemDefined, native.subtype.rawValue == 8 {
                let key = (native.data1 >> 16) & 0xffff
                let keyState = (native.data1 >> 8) & 0xff
                if (key == 2 || key == 3), keyState == 0x0a {
                    Task { @MainActor [weak owner = context.owner] in owner?.scheduleRead(.brightness, after: 0.08) }
                }
            }
            // A listen-only tap cannot consume input; return the original event.
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(context).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return }
        observations.contexts.append(context)
        observations.keyTap = tap
        observations.keySource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        state.brightnessKeysAvailable = true
    }

    // MARK: Bluetooth (authorized passive connections and driver battery reports)

    private func readBluetooth(into next: inout SystemState) {
        let start = beginReadEvidence("bluetooth")
        defer { finishReadEvidence("bluetooth", since: start) }
        let authorization = CBManager.authorization
        switch authorization {
        case .allowedAlways: next.bluetoothAuthorization = "authorized"
        case .denied: next.bluetoothAuthorization = "denied"
        case .restricted: next.bluetoothAuthorization = "restricted"
        case .notDetermined: next.bluetoothAuthorization = "notDetermined"
        @unknown default: next.bluetoothAuthorization = "unknown"
        }
        // Do not initialize a Bluetooth manager or query IOBluetooth until access is
        // already granted. CoreAudio still reports the active Bluetooth audio route.
        guard authorization == .allowedAlways else {
            observations.removeBluetooth()
            bluetoothObserver = nil
            connectedBluetooth.removeAll()
            bluetoothNeedsPolling = false
            next.bluetoothAvailable = false
            next.accessoryBatteries = []
            next.capabilityMessages["bluetooth"] = "Full device monitoring needs existing Bluetooth permission. Active Bluetooth audio output is available without a permission prompt."
            next.capabilityMessages["accessoryBattery"] = "Accessory battery reporting needs existing Bluetooth permission."
            return
        }
        if bluetoothObserver == nil {
            let observer = SystemBluetoothObserver(owner: self, generation: generation)
            bluetoothObserver = observer
            observations.bluetoothConnect = IOBluetoothDevice.register(forConnectNotifications: observer, selector: #selector(SystemBluetoothObserver.connected(_:device:)))
            bluetoothNeedsPolling = observations.bluetoothConnect == nil
        }
        bluetoothNeedsPolling = observations.bluetoothConnect == nil
        var devices: [String: IOBluetoothDevice] = [:]
        for device in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []) where device.isConnected() {
            let identifier = device.addressString ?? device.nameOrAddress ?? ""
            if !identifier.isEmpty { devices[identifier] = device }
        }
        // Preserve non-paired devices discovered by an actual connect callback.
        for (identifier, device) in observations.bluetoothConnectedDevices where device.isConnected() { devices[identifier] = device }
        observations.bluetoothConnectedDevices = devices
        let removed = observations.bluetoothDisconnect.keys.filter { devices[$0] == nil }
        for identifier in removed { observations.bluetoothDisconnect.removeValue(forKey: identifier)?.unregister() }
        connectedBluetooth = devices.mapValues { $0.nameOrAddress ?? "Bluetooth device" }
        for (identifier, device) in devices where observations.bluetoothDisconnect[identifier] == nil {
            if let observer = bluetoothObserver,
               let notification = device.register(forDisconnectNotification: observer, selector: #selector(SystemBluetoothObserver.disconnected(_:device:))) {
                observations.bluetoothDisconnect[identifier] = notification
            } else { bluetoothNeedsPolling = true }
        }
        next.bluetoothDevices = connectedBluetooth.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        next.bluetoothAvailable = true
        next.capabilityMessages["bluetooth"] = "Passive Classic Bluetooth connections; this service does not scan for arbitrary BLE peripherals."
        readAccessoryBatteries(devices: devices, into: &next)
    }

    private func readAccessoryBatteries(devices: [String: IOBluetoothDevice], into next: inout SystemState) {
        next.accessoryBatteries = []
        // IORegistry access is public, but these optional driver property names
        // are not a stable SDK contract. Honor the private integrations switch.
        guard privateAPIs else {
            next.capabilityMessages["accessoryBattery"] = "Driver accessory battery reporting requires the private integrations setting."
            return
        }
        var labels: [String: String] = [:]
        for (identifier, device) in devices {
            guard let address = normalizedBluetoothAddress(identifier) else { continue }
            labels[address] = device.nameOrAddress ?? "Bluetooth accessory"
        }
        guard !labels.isEmpty else {
            next.capabilityMessages["accessoryBattery"] = "No connected Bluetooth accessory is available for battery reporting."
            return
        }
        var readings: [String: CoveAccessoryBattery] = [:]
        var visited = Set<UInt64>()
        var registryReadFailed = false
        // Read a small set of device services, never the entire registry tree or
        // a user's preferences. An exact connected address is required; names
        // and model names alone cannot identify an accessory safely.
        for serviceClass in ["AppleDeviceManagementHIDEventService", "IOBluetoothDevice", "IOHIDDevice"] {
            // One pass per service class, only after the existing authorization,
            // private-integration and connected-address guards have passed.
            let start = beginReadEvidence("bluetoothRegistry")
            defer { finishReadEvidence("bluetoothRegistry", since: start) }
            guard let matching = IOServiceMatching(serviceClass) else { continue }
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
                registryReadFailed = true
                continue
            }
            defer { IOObjectRelease(iterator) }
            while true {
                let entry = IOIteratorNext(iterator)
                guard entry != 0 else { break }
                defer { IOObjectRelease(entry) }
                var entryID: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(entry, &entryID) == KERN_SUCCESS,
                      visited.insert(entryID).inserted else { continue }
                let identifier = ["BluetoothDeviceAddress", "DeviceAddress", "BD_ADDR", "SerialNumber"].lazy.compactMap { key -> String? in
                    let value = self.registryValue(entry, key: key)
                    if let text = value as? String { return self.normalizedBluetoothAddress(text) }
                    if let bytes = value as? Data, bytes.count == 6 {
                        return bytes.map { String(format: "%02x", $0) }.joined()
                    }
                    return nil
                }.first { labels[$0] != nil }
                guard let identifier, let label = labels[identifier] else { continue }
                var battery = readings[identifier] ?? CoveAccessoryBattery(id: identifier, label: label)
                battery.percentage = battery.percentage ?? registryPercentage(entry, key: "BatteryPercent")
                battery.leftPercentage = battery.leftPercentage ?? registryPercentage(entry, key: "BatteryPercentLeft")
                battery.rightPercentage = battery.rightPercentage ?? registryPercentage(entry, key: "BatteryPercentRight")
                battery.casePercentage = battery.casePercentage ?? registryPercentage(entry, key: "BatteryPercentCase")
                if battery.percentage != nil || battery.leftPercentage != nil || battery.rightPercentage != nil || battery.casePercentage != nil {
                    readings[identifier] = battery
                }
            }
        }
        next.accessoryBatteries = readings.values.sorted {
            let order = $0.label.localizedStandardCompare($1.label)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        next.capabilityMessages["accessoryBattery"] = !next.accessoryBatteries.isEmpty ?
            "Driver-reported accessory batteries; missing components are unavailable. Readings may be cached by the driver." :
            (registryReadFailed ? "Accessory battery registry services are unavailable or did not report a connected battery." :
                "No connected accessory reports battery percentages through the available registry services. AirPods component readings depend on the macOS driver.")
    }

    private func normalizedBluetoothAddress(_ value: String) -> String? {
        let compact = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").lowercased()
        guard compact.utf8.count == 12, compact.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return compact
    }

    private func registryValue(_ entry: io_registry_entry_t, key: String) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private func registryPercentage(_ entry: io_registry_entry_t, key: String) -> Int? {
        guard let number = registryValue(entry, key: key) as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        // Reject driver sentinels (for example 255), fractions, and bad values.
        guard value.isFinite, (0...100).contains(value), value.rounded() == value else { return nil }
        return Int(value)
    }

    fileprivate func bluetoothPermissionChanged(_ manager: CBCentralManager, generation: Int) {
        guard running, self.generation == generation, bluetoothAccessRequest?.manager === manager else { return }
        guard CBManager.authorization != .notDetermined else {
            if manager.state == .unsupported {
                bluetoothAccessRequest = nil
                isRequestingBluetoothAccess = false
                setError("bluetoothAccess", "This Mac does not support CoreBluetooth authorization.")
            }
            return
        }
        bluetoothAccessRequest = nil
        isRequestingBluetoothAccess = false
        read(parts: .bluetooth, emitHUD: false)
        setError("bluetoothAccess", CBManager.authorization == .allowedAlways ? nil : "Bluetooth access was not granted.")
    }

    fileprivate func bluetoothChanged(_ device: IOBluetoothDevice, connected: Bool, generation: Int) {
        guard running, self.generation == generation else { return }
        let identifier = device.addressString ?? device.nameOrAddress ?? ""
        if connected, !identifier.isEmpty { observations.bluetoothConnectedDevices[identifier] = device }
        else { observations.bluetoothConnectedDevices.removeValue(forKey: identifier) }
        scheduleRead([.bluetooth, .audio])
    }

    // MARK: Public read-only Focus status

    private func readFocus(into next: inout SystemState) {
        let start = beginReadEvidence("focus")
        defer { finishReadEvidence("focus", since: start) }
        let center = INFocusStatusCenter.default
        next.focusAvailable = false
        switch center.authorizationStatus {
        case .authorized:
            next.focusAuthorization = "authorized"
            if let focused = center.focusStatus.isFocused {
                next.focusEnabled = focused
                next.focusAvailable = true
            }
            next.capabilityMessages["focus"] = next.focusAvailable ? "Read-only shared Focus status; mode names and Focus control are unavailable." : "Focus status is not currently shared with this app."
        case .denied:
            next.focusAuthorization = "denied"
            next.capabilityMessages["focus"] = "Focus status access was denied."
        case .restricted:
            next.focusAuthorization = "restricted"
            next.capabilityMessages["focus"] = "Focus status access is restricted."
        case .notDetermined:
            next.focusAuthorization = "notDetermined"
            next.capabilityMessages["focus"] = "Focus status needs prior authorization. OpenCove does not request it at startup."
        @unknown default:
            next.focusAuthorization = "unknown"
            next.capabilityMessages["focus"] = "Focus status is unavailable on this macOS version."
        }
        if !next.focusAvailable { next.focusEnabled = false }
    }

    // MARK: Session lock (undocumented notifications, no lock mutation)

    private func installLockObservers() {
        let center = DistributedNotificationCenter.default()
        let currentGeneration = generation
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            let token = center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.running, self.privateAPIs, self.generation == currentGeneration else { return }
                    let previous = self.state
                    var next = self.state
                    guard self.hasActiveLoginSession else {
                        self.invalidateLockKnowledge()
                        return
                    }
                    next.isLocked = locked
                    next.lockStateKnown = true
                    next.capabilityMessages["lock"] = nil
                    self.state = next
                    if previous.isLocked != locked || !previous.lockStateKnown { self.onLockChange?(locked) }
                    self.emitChanges(from: previous, to: next, previousBluetooth: self.connectedBluetooth)
                    if !previous.lockStateKnown {
                        self.emit(CoveHUD(kind: .lock, title: locked ? "Locked" : "Unlocked", symbol: locked ? "lock.fill" : "lock.open.fill"))
                    }
                    if !locked { self.scheduleRead(.all, after: 0.3) }
                }
            }
            observations.distributed.append(token)
        }
    }

    private func readLock(into next: inout SystemState) {
        let start = beginReadEvidence("lock")
        defer { finishReadEvidence("lock", since: start) }
        guard privateAPIs else {
            next.lockStateKnown = false
            next.capabilityMessages["lock"] = "Lock state monitoring requires the private integrations setting."
            return
        }
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session[kCGSessionLoginDoneKey as String] as? Bool == true else {
            next.lockStateKnown = false
            next.capabilityMessages["lock"] = "Lock state is unknown outside the active, logged-in session."
            return
        }
        // The key is undocumented. Absence must not be interpreted as unlocked.
        if let locked = session["CGSSessionScreenIsLocked"] as? Bool {
            next.isLocked = locked
            next.lockStateKnown = true
            next.capabilityMessages["lock"] = nil
        } else if !next.lockStateKnown {
            next.capabilityMessages["lock"] = "Initial lock state is unknown; waiting for a screen lock/unlock notification."
        }
    }

    private var hasActiveLoginSession: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session[kCGSessionOnConsoleKey as String] as? Bool == true &&
            session[kCGSessionLoginDoneKey as String] as? Bool == true
    }

    private func invalidateLockKnowledge() {
        guard state.lockStateKnown else { return }
        var next = state
        next.lockStateKnown = false
        next.capabilityMessages["lock"] = "Lock state must be confirmed again after a session transition."
        state = next
        onLockChange?(next.isLocked)
    }

    // MARK: Lifecycle and fallback cadence

    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let currentGeneration = generation
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            observations.workspace.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.running, self.generation == currentGeneration else { return }
                    self.invalidateLockKnowledge()
                    if name == NSWorkspace.willSleepNotification {
                        self.systemAwake = false
                        self.configurePolling()
                    }
                }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observations.workspace.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.running, self.generation == currentGeneration else { return }
                    if name == NSWorkspace.didWakeNotification { self.systemAwake = true }
                    self.configurePolling()
                    self.scheduleRead(.all, after: 0.4)
                }
            })
        }
        for (name, awake) in [(NSWorkspace.screensDidSleepNotification, false), (NSWorkspace.screensDidWakeNotification, true)] {
            observations.workspace.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.running, self.generation == currentGeneration else { return }
                    self.screensAwake = awake
                    self.configurePolling()
                    if awake { self.scheduleRead(.all, after: 0.3) }
                }
            })
        }
        observations.local.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleRead(.brightness, after: 0.4) }
        })
        observations.local.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.running else { return }
                if self.privateAPIs, self.observations.keyTap == nil { self.installBrightnessKeyObserverIfAuthorized() }
                self.scheduleRead(.all)
            }
        })
    }

    private func configurePolling() {
        setTimer("brightness", interval: state.brightnessAvailable ? 2 : 15,
                 needed: running && privateAPIs && displayServices != nil && systemAwake && screensAwake) { owner in
            // DisplayServices has no supported change subscription. Polling also
            // covers automatic brightness and Control Center slider changes. A
            // failed read keeps a slower, bounded recovery cadence while awake.
            if owner.privateAPIs, owner.displayServices != nil, owner.systemAwake, owner.screensAwake {
                owner.scheduleRead(.brightness)
            }
        }
        setTimer("focusBluetooth", interval: 15, needed: state.focusAuthorization == "authorized" || bluetoothNeedsPolling) { owner in
            var parts: SystemRefreshParts = []
            // Public Focus status has no documented change notification.
            if owner.state.focusAuthorization == "authorized" { parts.insert(.focus) }
            if owner.bluetoothNeedsPolling { parts.insert(.bluetooth) }
            if !parts.isEmpty { owner.scheduleRead(parts) }
        }
        setTimer("accessoryBattery", interval: 30, needed: privateAPIs && state.bluetoothAvailable && !connectedBluetooth.isEmpty) { owner in
            if owner.screensAwake { owner.scheduleRead(.bluetooth) }
        }
        setTimer("audio", interval: 3, needed: audioSystemNeedsPolling || audioDeviceNeedsPolling || outputDevicesNeedPolling || outputListenersNeedPolling) { owner in
            owner.scheduleRead(.audio)
        }
        setTimer("battery", interval: 30, needed: observations.powerSource == nil) { $0.scheduleRead(.battery) }
    }

    private func setTimer(_ name: String, interval: TimeInterval, needed: Bool, action: @escaping @MainActor (SystemController) -> Void) {
        guard needed else {
            observations.timers.removeValue(forKey: name)?.invalidate()
            return
        }
        if let timer = observations.timers[name] {
            guard timer.timeInterval != interval else { return }
            timer.invalidate()
            observations.timers.removeValue(forKey: name)
        }
        let currentGeneration = generation
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.running, self.generation == currentGeneration else { return }
                action(self)
            }
        }
        timer.tolerance = min(1, interval / 5)
        observations.timers[name] = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

private struct SystemRefreshParts: OptionSet {
    let rawValue: Int
    static let audio = Self(rawValue: 1 << 0)
    static let battery = Self(rawValue: 1 << 1)
    static let brightness = Self(rawValue: 1 << 2)
    static let bluetooth = Self(rawValue: 1 << 3)
    static let focus = Self(rawValue: 1 << 4)
    static let lock = Self(rawValue: 1 << 5)
    static let all: Self = [.audio, .battery, .brightness, .bluetooth, .focus, .lock]
}

private final class SystemCallbackContext {
    weak var owner: SystemController?
    init(owner: SystemController) { self.owner = owner }
}

private final class SystemBluetoothObserver: NSObject {
    weak var owner: SystemController?
    private let generation: Int
    init(owner: SystemController, generation: Int) {
        self.owner = owner
        self.generation = generation
    }

    @objc func connected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let generation = generation
        Task { @MainActor [weak owner] in owner?.bluetoothChanged(device, connected: true, generation: generation) }
    }

    @objc func disconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let generation = generation
        Task { @MainActor [weak owner] in owner?.bluetoothChanged(device, connected: false, generation: generation) }
    }
}

/// Allocated only by requestBluetoothAccess(), retained until a decision, and
/// released on stop. It requests authorization without scanning or connecting.
private final class SystemBluetoothAccessRequest: NSObject, CBCentralManagerDelegate {
    weak var owner: SystemController?
    private let generation: Int
    private(set) var manager: CBCentralManager!

    init(owner: SystemController, generation: Int) {
        self.owner = owner
        self.generation = generation
        super.init()
        manager = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let generation = generation
        Task { @MainActor [weak owner] in owner?.bluetoothPermissionChanged(central, generation: generation) }
    }

    deinit { manager?.delegate = nil }
}

private struct SystemAudioListener {
    let object: AudioObjectID
    var address: AudioObjectPropertyAddress
    let block: AudioObjectPropertyListenerBlock
    let isDevice: Bool
    let isOutputList: Bool

    func remove() {
        var property = address
        AudioObjectRemovePropertyListenerBlock(object, &property, .main, block)
    }
}

/// Owns all registrations so a released controller does not leave callbacks behind.
private final class SystemObservations {
    var audio: [SystemAudioListener] = []
    var powerSource: CFRunLoopSource?
    var keyTap: CFMachPort?
    var keySource: CFRunLoopSource?
    var contexts: [SystemCallbackContext] = []
    var local: [NSObjectProtocol] = []
    var workspace: [NSObjectProtocol] = []
    var distributed: [NSObjectProtocol] = []
    var timers: [String: Timer] = [:]
    var bluetoothConnect: IOBluetoothUserNotification?
    var bluetoothDisconnect: [String: IOBluetoothUserNotification] = [:]
    var bluetoothConnectedDevices: [String: IOBluetoothDevice] = [:]

    func removeDeviceAudioListeners() {
        audio.filter(\.isDevice).forEach { $0.remove() }
        audio.removeAll(where: \.isDevice)
    }

    func removeOutputAudioListeners() {
        audio.filter(\.isOutputList).forEach { $0.remove() }
        audio.removeAll(where: \.isOutputList)
    }

    func removeBluetooth() {
        bluetoothConnect?.unregister()
        bluetoothConnect = nil
        bluetoothDisconnect.values.forEach { $0.unregister() }
        bluetoothDisconnect.removeAll()
        bluetoothConnectedDevices.removeAll()
    }

    func cancel() {
        timers.values.forEach { $0.invalidate() }
        timers.removeAll()
        audio.forEach { $0.remove() }
        audio.removeAll()
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes)
            CFRunLoopSourceInvalidate(powerSource)
        }
        powerSource = nil
        if let keyTap {
            CGEvent.tapEnable(tap: keyTap, enable: false)
            CFMachPortInvalidate(keyTap)
        }
        if let keySource { CFRunLoopRemoveSource(CFRunLoopGetMain(), keySource, .commonModes) }
        keySource = nil
        keyTap = nil
        contexts.removeAll()
        local.forEach { NotificationCenter.default.removeObserver($0) }
        local.removeAll()
        workspace.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspace.removeAll()
        distributed.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        distributed.removeAll()
        removeBluetooth()
    }

    deinit { cancel() }
}

/// Immutable ownership transfer only. The resource graph and selector targets
/// remain on the main actor; this box only retains them across the queued handoff.
private final class SystemControllerCleanup: @unchecked Sendable {
    private let observations: SystemObservations
    private let bluetooth: SystemBluetoothObserver?
    private let accessRequest: SystemBluetoothAccessRequest?

    init(observations: SystemObservations, bluetooth: SystemBluetoothObserver?, accessRequest: SystemBluetoothAccessRequest?) {
        self.observations = observations
        self.bluetooth = bluetooth
        self.accessRequest = accessRequest
    }

    @MainActor func cancel() {
        observations.cancel()
        withExtendedLifetime((bluetooth, accessRequest)) {}
    }
}

/// Only resolves Apple's system framework, never a bundled or user-supplied library.
private final class SystemDisplayServices {
    typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    typealias CanChangeBrightness = @convention(c) (CGDirectDisplayID) -> Bool
    private let library: UnsafeMutableRawPointer
    private let getBrightness: GetBrightness
    private let setBrightness: SetBrightness?
    private let canChangeBrightness: CanChangeBrightness?

    func canSet(_ display: CGDirectDisplayID) -> Bool {
        setBrightness != nil && canChangeBrightness?(display) == true
    }

    init?() {
        guard let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL) else { return nil }
        guard let getter = dlsym(library, "DisplayServicesGetBrightness") else {
            dlclose(library)
            return nil
        }
        self.library = library
        getBrightness = unsafeBitCast(getter, to: GetBrightness.self)
        setBrightness = dlsym(library, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetBrightness.self) }
        canChangeBrightness = dlsym(library, "DisplayServicesCanChangeBrightness").map { unsafeBitCast($0, to: CanChangeBrightness.self) }
    }

    func get(_ display: CGDirectDisplayID, _ value: UnsafeMutablePointer<Float>) -> Int32 { getBrightness(display, value) }
    func set(_ display: CGDirectDisplayID, _ value: Float) -> Int32 {
        guard canSet(display) else { return -1 }
        return setBrightness?(display, value) ?? -1
    }
    deinit { dlclose(library) }
}
