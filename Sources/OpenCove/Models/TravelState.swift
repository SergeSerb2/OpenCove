// SPDX-License-Identifier: MIT
import Foundation

/// A route is actionable only while `available` is true and its ETA is fresh.
/// Event content and route results are not saved to the travel settings file.
struct TravelState: Codable, Equatable {
    var enabled: Bool = false
    var available: Bool = false
    var eventTitle: String = ""
    var destination: String = ""
    var travelSeconds: Double = 0
    var leaveAt: Date? = nil
    var source: String = ""
    var updatedAt: Date? = nil

    static let freshnessInterval: TimeInterval = 15 * 60

    var isStale: Bool {
        guard let updatedAt else { return true }
        let age = Date().timeIntervalSince(updatedAt)
        return age < 0 || age >= Self.freshnessInterval
    }
}

/// These are the travel modes supported by this directions integration.
enum CoveTravelMode: String, CaseIterable, Identifiable, Codable {
    case automobile
    case walking

    var id: String { rawValue }
    var title: String { self == .automobile ? "Driving" : "Walking" }
    var symbol: String { self == .automobile ? "car.fill" : "figure.walk" }
}
