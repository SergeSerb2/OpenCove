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
