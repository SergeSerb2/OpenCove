import Carbon.HIToolbox
import Foundation

/// Preset global shortcuts that open or close the panel. Presets avoid the
/// need for a key recorder and keep away from common system shortcuts.
enum CoveHotKeyChoice: String, CaseIterable, Identifiable {
    case off, controlOptionSpace, optionCommandN, controlCommandO, controlOptionN

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .controlOptionSpace: return "⌃⌥ Space"
        case .optionCommandN: return "⌥⌘ N"
        case .controlCommandO: return "⌃⌘ O"
        case .controlOptionN: return "⌃⌥ N"
        }
    }

    fileprivate var key: (code: UInt32, modifiers: UInt32)? {
        switch self {
        case .off: return nil
        case .controlOptionSpace: return (UInt32(kVK_Space), UInt32(controlKey | optionKey))
        case .optionCommandN: return (UInt32(kVK_ANSI_N), UInt32(optionKey | cmdKey))
        case .controlCommandO: return (UInt32(kVK_ANSI_O), UInt32(controlKey | cmdKey))
        case .controlOptionN: return (UInt32(kVK_ANSI_N), UInt32(controlKey | optionKey))
        }
    }
}

@MainActor
final class CoveHotKey {
    enum Status: Equatable {
        case off
        case registered(CoveHotKeyChoice)
        case unavailable(CoveHotKeyChoice, OSStatus)

        var description: String {
            switch self {
            case .off: return "off"
            case .registered(let choice): return "registered \(choice.rawValue)"
            case .unavailable(let choice, let code): return "unavailable \(choice.rawValue) (\(code))"
            }
        }
    }

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var status: Status = .off
    var onPress: (() -> Void)?
    private static let signature: OSType = 0x4F434F56 // "OCOV"

    func apply(_ choice: CoveHotKeyChoice) {
        if case .registered(let current) = status, current == choice { return }
        unregister()
        guard let key = choice.key else { status = .off; return }
        installHandlerIfNeeded()
        var reference: EventHotKeyRef?
        let result = RegisterEventHotKey(key.code, key.modifiers, EventHotKeyID(signature: Self.signature, id: 1),
                                         GetApplicationEventTarget(), 0, &reference)
        if result == noErr, let reference {
            hotKey = reference
            status = .registered(choice)
        } else {
            // Another app may own this combination. Report it so Settings can say so.
            status = .unavailable(choice, result)
        }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        status = .off
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                         nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard read == noErr, identifier.signature == CoveHotKey.signature else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<CoveHotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { owner.onPress?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}
