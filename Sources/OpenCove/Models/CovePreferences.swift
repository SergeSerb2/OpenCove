import Foundation
import CoreFoundation

struct CovePreferences: Codable, Equatable {
    static func load(_ data: Data) throws -> CovePreferences {
        try recover(data).preferences
    }

    static func recover(_ data: Data) throws -> (preferences: CovePreferences, repairedFields: [String]) {
        guard data.count <= 65_536,
              var defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self())) as? [String: Any],
              let saved = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        // New integrations require an explicit saved choice in a legacy document.
        let consentFields: Set<String> = ["enablePrivateAPIs", "enableCalendar", "allowAppleScript", "mirrorSystemNotifications",
                                          "showLiveWaveform", "replaceSystemHUDs", "showOnLockScreen",
                                          "showLockScreenPrivateContent", "enableWeather", "launchAtLogin"]
        var repairs: [String] = []
        for key in Array(defaults.keys) {
            guard let value = saved[key] else {
                if consentFields.contains(key) { defaults[key] = false }
                continue
            }
            let valid: Bool
            if let expected = defaults[key] as? NSNumber {
                if CFGetTypeID(expected) == CFBooleanGetTypeID() {
                    valid = (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
                    if !valid { defaults[key] = false }
                } else {
                    valid = (value as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite } ?? false
                }
            } else { valid = value is String }
            if valid { defaults[key] = value }
            else { repairs.append(key) }
        }
        var result = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: defaults))
        result.normalize()
        if let normalized = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any] {
            repairs += defaults.keys.filter { key in
                guard let before = defaults[key] as? NSObject, let after = normalized[key] as? NSObject else { return false }
                return !before.isEqual(after)
            }
        }
        return (result, Array(Set(repairs)).sorted())
    }

    /// A damaged file must not turn previously disabled private integrations back on.
    static var recoveryDefaults: CovePreferences {
        var result = Self()
        result.enablePrivateAPIs = false
        result.enableCalendar = false
        result.enableMedia = false
        return result
    }

    mutating func normalize() {
        let defaults = Self()
        func bounded(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        notchWidth = bounded(notchWidth, 120...400, defaults.notchWidth)
        notchHeight = bounded(notchHeight, 24...64, defaults.notchHeight)
        cornerRadius = bounded(cornerRadius, 8...40, defaults.cornerRadius)
        hoverDelay = bounded(hoverDelay, 0...2, defaults.hoverDelay)
        collapseDelay = bounded(collapseDelay, 0.1...5, defaults.collapseDelay)
        hudDuration = bounded(hudDuration, 0.5...10, defaults.hudDuration)
        animationSpeed = bounded(animationSpeed, 0.25...2, defaults.animationSpeed)
        pausedMediaDelay = bounded(pausedMediaDelay, 1...300, defaults.pausedMediaDelay)
        if !selectedDisplayUUID.isEmpty, UUID(uuidString: selectedDisplayUUID) == nil { selectedDisplayUUID = "" }
        if CoveWeatherStyle(rawValue: weatherStyle) == nil { weatherStyle = defaults.weatherStyle }
        if !["media", "calendar", "duo"].contains(expandedLayout) { expandedLayout = defaults.expandedLayout }
        if !["glass", "clear", "frosted"].contains(nowPlayingStyle) { nowPlayingStyle = defaults.nowPlayingStyle }
        if !["smooth", "fast", "instant"].contains(hudSpeed) { hudSpeed = defaults.hudSpeed }
        if !["system", "music", "spotify"].contains(preferredMusicApp) { preferredMusicApp = defaults.preferredMusicApp }
        if !["calendar", "fantastical", "notionCalendar"].contains(preferredCalendarApp) { preferredCalendarApp = defaults.preferredCalendarApp }
        if !["mint", "blue", "purple", "pink", "orange"].contains(accent) { accent = defaults.accent }
    }
    var showOnAllDisplays = false
    var preferBuiltInDisplay = true
    var selectedDisplayUUID = ""
    var showOnLockScreen = false
    var showLockScreenPrivateContent = false
    var hideWhenIdle = true
    var expandOnHover = true
    var hoverDelay = 0.25
    var collapseDelay = 0.6
    var notchWidth = 190.0
    var notchHeight = 32.0
    var cornerRadius = 20.0
    var animationSpeed = 1.0
    var enableHaptics = true
    var reduceMotion = false
    var enableMedia = true
    var hidePausedMedia = false
    var pausedMediaDelay = 30.0
    var enableVolumeHUD = true
    var enableBrightnessHUD = true
    var enableBattery = true
    var enableBluetooth = true
    var enableCalendar = true
    var enableNotifications = true
    var mirrorSystemNotifications = false
    var enableFileTray = false
    var enableTimer = false
    var enableFocus = true
    var enableWeather = false
    var weatherStyle = "conditions"
    var enablePrivateAPIs = true
    var replaceSystemHUDs = false
    var allowAppleScript = false
    var expandedLayout = "media"
    var nowPlayingStyle = "glass"
    var hudSpeed = "smooth"
    var showLiveWaveform = false
    var musicColorAccent = true
    var preferredMusicApp = "system"
    var preferredCalendarApp = "calendar"
    var hideInFullscreen = false
    var launchAtLogin = false
    var completedOnboarding = false
    var hudDuration = 2.0
    var accent = "mint"
}

enum CoveTab: String, Codable, CaseIterable, Identifiable {
    case media, calendar, files, timer
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .media: return "music.note"
        case .calendar: return "calendar"
        case .files: return "tray"
        case .timer: return "timer"
        }
    }
}

enum HUDKind: String, Codable { case volume, brightness, battery, bluetooth, focus, notification, lock }

struct CoveHUD: Codable, Equatable {
    var kind: HUDKind
    var title: String
    var subtitle: String = ""
    var symbol: String
    var value: Double? = nil
    var createdAt = Date()
    var origin = "app"
}
