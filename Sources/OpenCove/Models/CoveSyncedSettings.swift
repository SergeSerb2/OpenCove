import Foundation

/// An explicit allowlist, independent of the local preference document. New
/// preferences stay local until deliberately added to a new supported schema.
struct CoveSyncedSettings: Codable, Equatable {
    private enum Value: Codable, Equatable {
        case flag(Bool), number(Double), choice(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Bool.self) { self = .flag(value) }
            else if let value = try? container.decode(Double.self), value.isFinite { self = .number(value) }
            else if let value = try? container.decode(String.self), value.utf8.count <= 32 { self = .choice(value) }
            else { throw CocoaError(.coderReadCorrupt) }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .flag(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .choice(let value): try container.encode(value)
            }
        }
    }

    private static let flags: [(String, WritableKeyPath<CovePreferences, Bool>)] = [
        ("showContrastOutline", \.showContrastOutline), ("hideWhenIdle", \.hideWhenIdle),
        ("expandOnHover", \.expandOnHover), ("reduceMotion", \.reduceMotion),
        ("hidePausedMedia", \.hidePausedMedia), ("peekOnSongChange", \.peekOnSongChange),
        ("showPlaybackIndicator", \.showPlaybackIndicator), ("musicColorAccent", \.musicColorAccent),
        ("hideInFullscreen", \.hideInFullscreen),
    ]
    private static let numbers: [(String, WritableKeyPath<CovePreferences, Double>, ClosedRange<Double>)] = [
        ("hoverDelay", \.hoverDelay, 0...2), ("collapseDelay", \.collapseDelay, 0.1...5),
        ("notchWidth", \.notchWidth, 120...400), ("notchHeight", \.notchHeight, 24...64),
        ("cornerRadius", \.cornerRadius, 8...40), ("animationSpeed", \.animationSpeed, 0.25...2),
        ("pausedMediaDelay", \.pausedMediaDelay, 1...300), ("mediaPeekDuration", \.mediaPeekDuration, 1...10),
        ("hudDuration", \.hudDuration, 0.5...10),
    ]
    private static let choices: [(String, WritableKeyPath<CovePreferences, String>, Set<String>)] = [
        ("expandedLayout", \.expandedLayout, ["automatic", "media", "calendar", "duo"]),
        ("compactActivity", \.compactActivity, ["automatic", "media", "calendar", "timer"]),
        ("nowPlayingStyle", \.nowPlayingStyle, ["glass", "clear", "frosted"]),
        ("hudSpeed", \.hudSpeed, ["smooth", "fast", "instant"]),
        ("accent", \.accent, ["mint", "blue", "purple", "pink", "orange"]),
        ("weatherStyle", \.weatherStyle, Set(CoveWeatherStyle.allCases.map(\.rawValue))),
    ]

    private let values: [String: Value]

    init(_ preferences: CovePreferences) {
        var result: [String: Value] = [:]
        for (name, key) in Self.flags { result[name] = .flag(preferences[keyPath: key]) }
        for (name, key, _) in Self.numbers { result[name] = .number(preferences[keyPath: key]) }
        for (name, key, _) in Self.choices { result[name] = .choice(preferences[keyPath: key]) }
        for kind in HUDKind.allCases {
            result[kind.rawValue + "HUDDuration"] = .number(preferences[keyPath: kind.durationKey])
            result[kind.rawValue + "HUDSpeed"] = .choice(preferences[keyPath: kind.speedKey])
        }
        values = result
    }

    func validate() throws {
        guard values.count == Self.flags.count + Self.numbers.count + Self.choices.count + HUDKind.allCases.count * 2 else {
            throw CocoaError(.coderReadCorrupt)
        }
        for (name, _) in Self.flags {
            guard case .flag? = values[name] else { throw CocoaError(.coderReadCorrupt) }
        }
        for (name, _, range) in Self.numbers {
            guard case .number(let value)? = values[name], range.contains(value) else { throw CocoaError(.coderReadCorrupt) }
        }
        for (name, _, allowed) in Self.choices {
            guard case .choice(let value)? = values[name], allowed.contains(value) else { throw CocoaError(.coderReadCorrupt) }
        }
        for kind in HUDKind.allCases {
            guard case .number(let duration)? = values[kind.rawValue + "HUDDuration"],
                  duration == 0 || (0.5...10).contains(duration),
                  case .choice(let speed)? = values[kind.rawValue + "HUDSpeed"],
                  ["global", "smooth", "fast", "instant"].contains(speed) else { throw CocoaError(.coderReadCorrupt) }
        }
    }

    /// Overlay only the allowlist. Device choices, integration consent, and all
    /// other saved fields keep their current values in CoveStore's document.
    func apply(to preferences: inout CovePreferences) {
        for (name, key) in Self.flags {
            if case .flag(let value)? = values[name] { preferences[keyPath: key] = value }
        }
        for (name, key, _) in Self.numbers {
            if case .number(let value)? = values[name] { preferences[keyPath: key] = value }
        }
        for (name, key, _) in Self.choices {
            if case .choice(let value)? = values[name] { preferences[keyPath: key] = value }
        }
        for kind in HUDKind.allCases {
            if case .number(let value)? = values[kind.rawValue + "HUDDuration"] { preferences[keyPath: kind.durationKey] = value }
            if case .choice(let value)? = values[kind.rawValue + "HUDSpeed"] { preferences[keyPath: kind.speedKey] = value }
        }
    }
}

struct CoveSettingsSyncEnvelope: Codable, Equatable {
    static let maximumBytes = 16_384
    let version: Int
    let revision: UUID
    let parentRevision: UUID?
    let settings: CoveSyncedSettings

    init(settings: CoveSyncedSettings, parentRevision: UUID?) {
        version = 1
        revision = UUID()
        self.parentRevision = parentRevision
        self.settings = settings
    }

    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else { throw CocoaError(.coderReadCorrupt) }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.version == 1, result.revision != result.parentRevision else { throw CocoaError(.coderReadCorrupt) }
        try result.settings.validate()
        return result
    }

    func encoded() throws -> Data {
        try settings.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw CocoaError(.coderInvalidValue) }
        return data
    }
}
