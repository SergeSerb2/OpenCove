// SPDX-License-Identifier: MIT
import Foundation

struct WeatherState: Codable, Equatable {
    var locationName: String = ""
    /// Celsius, as returned by Open-Meteo. Display only when `available` is true.
    var temperature: Double = 0
    var condition: String = ""
    var symbol: String = "cloud"
    /// The model's valid time, rather than the time the request finished.
    var updatedAt: Date? = nil
    var available: Bool = false
    var apparentTemperature: Double? = nil
    var humidity: Double? = nil
    var windSpeed: Double? = nil // km/h
    var timeZoneIdentifier = "UTC"
    var hourly: [WeatherHour] = []
    var daily: [WeatherDay] = []
    var forecastNotice: String? = nil

    var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? .gmt }

    var today: WeatherDay? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return daily.first { calendar.isDateInToday($0.date) }
    }

    var temperatureText: String {
        guard available, temperature.isFinite else { return "—" }
        return temperature.formatted(.number.precision(.fractionLength(0))) + "°C"
    }

    var isStale: Bool {
        guard let updatedAt else { return true }
        let age = Date().timeIntervalSince(updatedAt)
        return !age.isFinite || age < -15 * 60 || age > 60 * 60
    }
}

struct WeatherHour: Codable, Equatable, Identifiable {
    var date: Date
    var temperature: Double?
    var condition: String
    var symbol: String
    var precipitationProbability: Double?
    var id: Date { date }
}

struct WeatherDay: Codable, Equatable, Identifiable {
    /// Noon on the provider's civil forecast date, in the location's time zone.
    var date: Date
    var minimum: Double?
    var maximum: Double?
    var condition: String
    var symbol: String
    var precipitationProbability: Double?
    var sunrise: Date?
    var sunset: Date?
    var daylightDuration: Double? = nil // Seconds, from the provider's daily forecast.
    var id: Date { date }
}

enum CoveWeatherStyle: String, Codable, CaseIterable, Identifiable {
    case conditions, sun, precipitation
    var id: String { rawValue }
    var title: String {
        switch self { case .conditions: return "Conditions"; case .sun: return "Sun"; case .precipitation: return "Precipitation" }
    }
    var symbol: String {
        switch self { case .conditions: return "cloud.sun"; case .sun: return "sun.max"; case .precipitation: return "umbrella" }
    }
}

struct WeatherSunEvent: Codable, Equatable {
    enum Kind: String, Codable {
        case sunrise, sunset
        var title: String { self == .sunrise ? "Sunrise" : "Sunset" }
        var symbol: String { self == .sunrise ? "sunrise.fill" : "sunset.fill" }
    }
    var kind: Kind
    var date: Date
}

enum WeatherSunCondition: String, Codable {
    case events, continuousDaylight, continuousNight, unavailable
}

/// Bounded presentation shared by native views and the opt-in state endpoint.
/// The caller supplies time, so one visible schedule can update every label.
struct WeatherWidgetData: Codable, Equatable {
    let asOf: Date
    let style: CoveWeatherStyle
    var today: WeatherDay?
    var hours: [WeatherHour] = []
    /// Probability timestamps end their one-hour forecast interval.
    var precipitationHours: [WeatherHour] = []
    var nextSunEvent: WeatherSunEvent?
    var sunCondition: WeatherSunCondition = .unavailable
    var daylightProgress: Double?
    var isDaylight: Bool?
    var precipitationProbability: Double?
    var precipitationPeriod: String?

    init(state: WeatherState, style: CoveWeatherStyle, at now: Date) {
        asOf = now
        self.style = style
        guard state.available, now.timeIntervalSince1970.isFinite else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = state.timeZone
        let days = Array(state.daily.prefix(7))
        today = days.first { calendar.isDate($0.date, inSameDayAs: now) }
        if today?.daylightDuration == 86_400 { sunCondition = .continuousDaylight; isDaylight = true }
        else if today?.daylightDuration == 0 { sunCondition = .continuousNight; isDaylight = false }
        else if today?.sunrise != nil || today?.sunset != nil { sunCondition = .events }
        hours = Array(state.hourly.prefix(24).filter { $0.date.addingTimeInterval(3_600) > now }.prefix(3))
        precipitationHours = Array(state.hourly.prefix(24).filter { $0.date > now }.prefix(3))
        let currentHour = precipitationHours.first { $0.date.addingTimeInterval(-3_600) <= now && now < $0.date }
        if let probability = currentHour?.precipitationProbability {
            precipitationProbability = probability
            precipitationPeriod = "hour"
        } else if let probability = today?.precipitationProbability {
            precipitationProbability = probability
            precipitationPeriod = "day"
        }
        nextSunEvent = days.flatMap { day -> [WeatherSunEvent] in
            [day.sunrise.map { WeatherSunEvent(kind: .sunrise, date: $0) },
             day.sunset.map { WeatherSunEvent(kind: .sunset, date: $0) }].compactMap { $0 }
        }.filter { $0.date > now }.min { $0.date < $1.date }
        if let sunrise = today?.sunrise, let sunset = today?.sunset, sunset > sunrise {
            let span = sunset.timeIntervalSince(sunrise)
            let elapsed = now.timeIntervalSince(sunrise)
            if span.isFinite, elapsed.isFinite {
                daylightProgress = min(1, max(0, elapsed / span))
                isDaylight = now >= sunrise && now < sunset
            }
        }
    }
}
