import AppKit

/// Short feedback sounds for system events. OpenCove ships no audio assets:
/// each event uses one of the alert sounds that macOS installs in
/// /System/Library/Sounds. Sounds play through the current output device and
/// follow its volume and mute state.
enum CoveSoundEvent: String, CaseIterable {
    case lock, unlock, lowBattery, hourlyChime, eventStart

    var systemSoundName: NSSound.Name {
        switch self {
        case .lock: return "Pop"
        case .unlock: return "Tink"
        case .lowBattery: return "Submarine"
        case .hourlyChime: return "Glass"
        case .eventStart: return "Ping"
        }
    }

    var preferenceKey: KeyPath<CovePreferences, Bool> { writableKey }

    var writableKey: WritableKeyPath<CovePreferences, Bool> {
        switch self {
        case .lock: return \.playSoundOnLock
        case .unlock: return \.playSoundOnUnlock
        case .lowBattery: return \.playSoundOnLowBattery
        case .hourlyChime: return \.playHourlyChime
        case .eventStart: return \.playSoundOnEventStart
        }
    }
}

@MainActor
final class CoveSoundPlayer {
    private var sounds: [CoveSoundEvent: NSSound] = [:]
    private(set) var lastPlayed: (event: CoveSoundEvent, date: Date)?
    private(set) var playCount = 0

    /// Plays the event's sound if its preference is on. Returns whether a
    /// sound started. A repeat of the same event within one second is ignored.
    @discardableResult
    func play(_ event: CoveSoundEvent, preferences: CovePreferences) -> Bool {
        guard preferences[keyPath: event.preferenceKey] else { return false }
        return play(event, volume: preferences.soundVolume)
    }

    /// Plays without a preference check. Use only for an explicit Settings preview.
    @discardableResult
    func play(_ event: CoveSoundEvent, volume: Double) -> Bool {
        if let lastPlayed, lastPlayed.event == event, Date().timeIntervalSince(lastPlayed.date) < 1 { return false }
        guard let sound = sound(for: event) else { return false }
        sound.stop()
        sound.volume = Float(min(1, max(0, volume)))
        guard sound.play() else { return false }
        lastPlayed = (event, Date())
        playCount += 1
        return true
    }

    private func sound(for event: CoveSoundEvent) -> NSSound? {
        if let cached = sounds[event] { return cached }
        guard let loaded = NSSound(named: event.systemSoundName)?.copy() as? NSSound else { return nil }
        sounds[event] = loaded
        return loaded
    }
}
