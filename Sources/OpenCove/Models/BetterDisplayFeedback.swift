// SPDX-License-Identifier: MIT
import Foundation

/// Presentation data from an unauthenticated local notification. This is never
/// a native brightness reading, physical readback, or writable capability.
struct BetterDisplayFeedback {
    enum Provider { case betterDisplay }
    enum ControlTarget: String, Decodable { case hardwareBrightness }

    struct Display: Equatable {
        let uuid: UUID
        let currentID: UInt32

        /// Use only the existing public display snapshot. No display discovery.
        static func selected(in selection: CoveDisplaySelection) -> Self? {
            guard selection.mode == "selected", !selection.isFallback,
                  selection.selectedDisplayIDs.count == 1,
                  let id = selection.selectedDisplayIDs.first, id > 0,
                  let uuid = UUID(uuidString: selection.requestedUUID) else { return nil }
            let matches = selection.available.filter { $0.uuid.flatMap(UUID.init(uuidString:)) == uuid }
            guard matches.count == 1, let display = matches.first,
                  display.id == id, display.canSelect, !display.isBuiltIn,
                  selection.available.filter({ $0.id == id }).count == 1 else { return nil }
            return Self(uuid: uuid, currentID: id)
        }
    }

    struct Identity: Equatable {
        let display: Display
        let generation: UInt64
    }

    static let origin = "betterDisplayFeedback"
    static let previewOrigin = "betterDisplayFeedbackPreview"
    // OpenCove receipt policy only. DNC has no source timestamp, delivery bound,
    // sender authentication, or guarantee of physical measurement freshness.
    static let receiptTTL: Duration = .seconds(5)

    let provider: Provider = .betterDisplay
    let identity: Identity
    let controlTarget: ControlTarget
    let fraction: Double
    let receivedAt: ContinuousClock.Instant

    func isEligible(for identity: Identity, now: ContinuousClock.Instant) -> Bool {
        let age = receivedAt.duration(to: now)
        return self.identity == identity && age >= .zero && age < Self.receiptTTL
    }

    /// Decode only supported fields; never retain external text, symbols,
    /// commands, paths, sizing or fade instructions. Reject nonnumeric reports.
    struct Payload: Decodable {
        static let maximumBytes = 16_384
        let displayID: UInt32
        let controlTarget: ControlTarget
        let value: Double
        let maxValue: Double
        let lock: Bool?

        static func decode(_ object: Any?) -> Self? {
            guard let json = object as? String,
                  json.utf8.prefix(maximumBytes + 1).count <= maximumBytes,
                  let result = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)),
                  result.displayID > 0, result.lock != true,
                  result.value.isFinite, result.maxValue.isFinite,
                  result.maxValue > 0, result.value >= 0, result.value <= result.maxValue else { return nil }
            return result
        }

        // Derive only after strict decode and finite range validation above.
        var fraction: Double { value / maxValue }
    }
}
