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
    var id: Date { date }
}
