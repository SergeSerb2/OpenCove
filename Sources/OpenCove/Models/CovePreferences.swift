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
                                          "showLiveWaveform", "replaceSystemHUDs", "enableBetterDisplayFeedback", "showOnLockScreen",
                                          "showLockScreenPrivateContent", "enableWeather", "launchAtLogin", "syncSettingsWithiCloud",
                                          "hideForGamesCategory", "enableLowPowerModeAlerts"]
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
        // A missing mode follows activities. Partial/orphan consent fields can
        // never infer a grant. Keep an explicit independent mode when repairing.
        let widgetFields = ["lockWidgetsFollowActivities"] + CoveLockWidget.allCases.map(\.preferenceName)
        if widgetFields.contains(where: { saved[$0] != nil }) {
            let complete = widgetFields.allSatisfy { key in
                (saved[key] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
            }
            if !complete {
                // The strict Boolean pass above already fails a malformed mode
                // to false; a missing mode retains its documented true default.
                for widget in CoveLockWidget.allCases { defaults[widget.preferenceName] = false }
                repairs += widgetFields
            }
        }
        var result = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: defaults))
        // File recovery and the central store transaction own revocation. Keep
        // normalize() compatible with the generic API's existing range check.
        if !result.enableBrightnessHUD { result.enableBetterDisplayFeedback = false }
        if !result.enableBattery { result.enableLowPowerModeAlerts = false }
        result.normalize()
        if let normalized = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any] {
            repairs += defaults.keys.filter { key in
                guard let before = defaults[key] as? NSObject, let after = normalized[key] as? NSObject else { return false }
                return !before.isEqual(after)
            }
        }
        // Recovered documents cannot activate extra readers from surviving grants.
        if !repairs.isEmpty {
            if result.enableLowPowerModeAlerts {
                result.enableLowPowerModeAlerts = false
                repairs.append("enableLowPowerModeAlerts")
            }
            if result.enableBetterDisplayFeedback {
                result.enableBetterDisplayFeedback = false
                repairs.append("enableBetterDisplayFeedback")
            }
            for widget in CoveLockWidget.allCases where result[keyPath: widget.selectionKey] {
                result[keyPath: widget.selectionKey] = false
                repairs.append(widget.preferenceName)
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
        result.enableLowPowerModeAlerts = false
        return result
    }

    mutating func normalize() {
        let defaults = Self()
        if lockWidgetsFollowActivities || !showOnLockScreen || !enablePrivateAPIs {
            clearIndependentLockWidgets()
        }
        func bounded(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        notchWidth = bounded(notchWidth, 120...400, defaults.notchWidth)
        notchHeight = bounded(notchHeight, 24...64, defaults.notchHeight)
        cornerRadius = bounded(cornerRadius, 8...40, defaults.cornerRadius)
        hoverDelay = bounded(hoverDelay, 0...2, defaults.hoverDelay)
        collapseDelay = bounded(collapseDelay, 0.1...5, defaults.collapseDelay)
        hudDuration = bounded(hudDuration, 0.5...10, defaults.hudDuration)
        for kind in HUDKind.allCases {
            let key = kind.durationKey
            if self[keyPath: key] != 0 { self[keyPath: key] = bounded(self[keyPath: key], 0.5...10, 0) }
            if !["global", "smooth", "fast", "instant"].contains(self[keyPath: kind.speedKey]) {
                self[keyPath: kind.speedKey] = "global"
            }
        }
        animationSpeed = bounded(animationSpeed, 0.25...2, defaults.animationSpeed)
        pausedMediaDelay = bounded(pausedMediaDelay, 1...300, defaults.pausedMediaDelay)
        mediaPeekDuration = bounded(mediaPeekDuration, 1...10, defaults.mediaPeekDuration)
        if !selectedDisplayUUID.isEmpty, UUID(uuidString: selectedDisplayUUID) == nil { selectedDisplayUUID = "" }
        if CoveWeatherStyle(rawValue: weatherStyle) == nil { weatherStyle = defaults.weatherStyle }
        if !["automatic", "media", "calendar", "timer"].contains(compactActivity) { compactActivity = defaults.compactActivity }
        if !["automatic", "media", "calendar", "duo"].contains(expandedLayout) { expandedLayout = defaults.expandedLayout }
        if !["glass", "clear", "frosted"].contains(nowPlayingStyle) { nowPlayingStyle = defaults.nowPlayingStyle }
        if !["smooth", "fast", "instant"].contains(hudSpeed) { hudSpeed = defaults.hudSpeed }
        if !["system", "music", "spotify"].contains(preferredMusicApp) { preferredMusicApp = defaults.preferredMusicApp }
        if !["calendar", "fantastical", "notionCalendar"].contains(preferredCalendarApp) { preferredCalendarApp = defaults.preferredCalendarApp }
        if !["mint", "blue", "purple", "pink", "orange"].contains(accent) { accent = defaults.accent }
    }
    var showOnAllDisplays = false
    var preferBuiltInDisplay = true
    var selectedDisplayUUID = ""
    var simulateNotch = false
    var showContrastOutline = false
    var useAccentOutline = false
    var showOnLockScreen = false
    var showLockScreenPrivateContent = false
    // Device-local selections are the consent. Never copy activity choices here
    // or include these fields in CoveSyncedSettings.
    var lockWidgetsFollowActivities = true
    var lockWidgetMedia = false
    var lockWidgetCalendar = false
    var lockWidgetWeather = false
    var lockWidgetBattery = false
    var lockWidgetFocus = false
    var lockWidgetBluetooth = false
    var hideWhenIdle = true
    var expandOnHover = true
    // Per-device gesture choices. Deliberately outside CoveSyncedSettings.
    var swipeToSkip = false
    var reverseSkipSwipe = false
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
    var peekOnSongChange = false
    var mediaPeekDuration = 3.0
    var enableVolumeHUD = true
    var enableBrightnessHUD = true
    // Explicit native Settings consent on this Mac; outside CoveSyncedSettings.
    var enableBetterDisplayFeedback = false
    var enableBattery = true
    // Separate native, save-first consent on this Mac. Never synced or granted by widgets.
    var enableLowPowerModeAlerts = false
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
    var expandedLayout = "automatic"
    var compactActivity = "automatic"
    var nowPlayingStyle = "glass"
    var hudSpeed = "smooth"
    var showHUDLabels = true
    var showHUDPercentage = true
    var brightnessHUDGlow = false
    var showPlaybackIndicator = true
    var showLiveWaveform = false
    var musicColorAccent = true
    var preferredMusicApp = "system"
    var preferredCalendarApp = "calendar"
    // Local layout only; never changes Calendar reader demand or cloud settings.
    var showCalendarList: Bool = true
    // Calendar filtering stays local, outside CoveSyncedSettings.
    var showDeclinedCalendarEvents: Bool = false
    var excludeSubscribedCalendars: Bool = false
    var hideInFullscreen = false
    // AppKit window presentation only. Device-local, outside cloud settings.
    var hideInMissionControl = false
    // Local presentation choice; never starts a media reader.
    var hideWhenMediaAppActive = false
    // Opt-in bundle-category reading. Device-local, outside cloud settings.
    var hideForGamesCategory = false
    var launchAtLogin = false
    // Per-device consent. Never included in CoveSyncedSettings.
    var syncSettingsWithiCloud = false
    var completedOnboarding = false
    var hudDuration = 2.0
    // Zero duration and "global" speed inherit the existing shared choices.
    var volumeHUDDuration = 0.0
    var brightnessHUDDuration = 0.0
    var batteryHUDDuration = 0.0
    var bluetoothHUDDuration = 0.0
    var focusHUDDuration = 0.0
    var notificationHUDDuration = 0.0
    var lockHUDDuration = 0.0
    var volumeHUDSpeed = "global"
    var brightnessHUDSpeed = "global"
    var batteryHUDSpeed = "global"
    var bluetoothHUDSpeed = "global"
    var focusHUDSpeed = "global"
    var notificationHUDSpeed = "global"
    var lockHUDSpeed = "global"

    func duration(for kind: HUDKind) -> Double {
        let value = self[keyPath: kind.durationKey]
        return value == 0 ? hudDuration : value
    }

    func speed(for kind: HUDKind?) -> String {
        guard let kind else { return hudSpeed }
        let value = self[keyPath: kind.speedKey]
        return value == "global" ? hudSpeed : value
    }
    var accent = "mint"

    mutating func clearIndependentLockWidgets() {
        for widget in CoveLockWidget.allCases { self[keyPath: widget.selectionKey] = false }
    }

    var independentLockWidgets: Set<CoveLockWidget> {
        Set(CoveLockWidget.allCases.filter { self[keyPath: $0.selectionKey] })
    }

    func permitsExtraLockWidgetReader(_ widget: CoveLockWidget) -> Bool {
        !lockWidgetsFollowActivities && showOnLockScreen && enablePrivateAPIs && self[keyPath: widget.selectionKey]
    }

    func showsLockWidget(_ widget: CoveLockWidget) -> Bool {
        lockWidgetsFollowActivities ? self[keyPath: widget.activityKey] : permitsExtraLockWidgetReader(widget)
    }

    /// A saved waveform choice alone must not start system-audio capture.
    var usesLiveWaveform: Bool { enableMedia && showPlaybackIndicator && showLiveWaveform }
}

enum CoveCompactActivity: String {
    case media, calendar, timer, clock
    var title: String {
        switch self {
        case .media: return "Now Playing"
        case .calendar: return "Calendar"
        case .timer: return "Timer"
        case .clock: return "Clock"
        }
    }
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

enum HUDKind: String, Codable, CaseIterable, Identifiable {
    case volume, brightness, battery, bluetooth, focus, notification, lock

    var id: String { rawValue }
    var title: String {
        switch self {
        case .volume: return "Volume"
        case .brightness: return "Display brightness"
        case .battery: return "Battery & charging"
        case .bluetooth: return "Bluetooth & audio devices"
        case .focus: return "Focus"
        case .notification: return "Notifications"
        case .lock: return "Session"
        }
    }
    var durationKey: WritableKeyPath<CovePreferences, Double> {
        switch self {
        case .volume: return \.volumeHUDDuration
        case .brightness: return \.brightnessHUDDuration
        case .battery: return \.batteryHUDDuration
        case .bluetooth: return \.bluetoothHUDDuration
        case .focus: return \.focusHUDDuration
        case .notification: return \.notificationHUDDuration
        case .lock: return \.lockHUDDuration
        }
    }
    var speedKey: WritableKeyPath<CovePreferences, String> {
        switch self {
        case .volume: return \.volumeHUDSpeed
        case .brightness: return \.brightnessHUDSpeed
        case .battery: return \.batteryHUDSpeed
        case .bluetooth: return \.bluetoothHUDSpeed
        case .focus: return \.focusHUDSpeed
        case .notification: return \.notificationHUDSpeed
        case .lock: return \.lockHUDSpeed
        }
    }
}

struct CoveHUD: Codable, Equatable {
    static let lowPowerModeOrigin = "systemLowPowerMode"

    var kind: HUDKind
    var title: String
    var subtitle: String = ""
    var symbol: String
    var value: Double? = nil
    var createdAt = Date()
    var origin = "app"
}

/// The six existing lock-screen categories. Each independent choice grants only
/// its existing reader, with the existing source and OS authorization gates.
enum CoveLockWidget: String, CaseIterable, Identifiable, Hashable {
    case media, calendar, weather, battery, focus, bluetooth
    var id: String { rawValue }
    var title: String {
        switch self {
        case .media: return "Now Playing"
        case .calendar: return "Calendar"
        case .weather: return "Weather"
        case .battery: return "Battery"
        case .focus: return "Focus"
        case .bluetooth: return "Connectivity"
        }
    }
    var preferenceName: String { "lockWidget" + rawValue.prefix(1).uppercased() + String(rawValue.dropFirst()) }
    var selectionKey: WritableKeyPath<CovePreferences, Bool> {
        switch self {
        case .media: return \.lockWidgetMedia
        case .calendar: return \.lockWidgetCalendar
        case .weather: return \.lockWidgetWeather
        case .battery: return \.lockWidgetBattery
        case .focus: return \.lockWidgetFocus
        case .bluetooth: return \.lockWidgetBluetooth
        }
    }
    var activityKey: WritableKeyPath<CovePreferences, Bool> {
        switch self {
        case .media: return \.enableMedia
        case .calendar: return \.enableCalendar
        case .weather: return \.enableWeather
        case .battery: return \.enableBattery
        case .focus: return \.enableFocus
        case .bluetooth: return \.enableBluetooth
        }
    }
    var disclosure: String {
        switch self {
        case .media: return "Read the selected player's existing Now Playing metadata and artwork, including while unlocked. With its activity off, this does not use AppleScript fallback or capture live audio."
        case .calendar: return "Read the existing seven-day upcoming-event feed and selected month's 42-day grid from included calendars, including while unlocked. Locked event details need a separate choice."
        case .weather: return "Refresh weather for your saved location, including while unlocked. This does not choose a location or request access."
        case .battery: return "Show battery status from existing public system monitoring. This choice does not stop that shared monitor."
        case .focus, .bluetooth: return "Use the existing status reader, including while unlocked. Existing macOS access still applies; this choice does not request access."
        }
    }
}
