import Foundation

/// A count-up stopwatch. It stores only a start anchor and the paused total,
/// so no timer runs while it counts; views draw the time from the anchor.
@MainActor
final class CoveStopwatch: ObservableObject {
    @Published private(set) var anchor: Date?      // running: the moment that elapsed time counts from
    @Published private(set) var pausedTotal: TimeInterval = 0

    var isRunning: Bool { anchor != nil }
    var isActive: Bool { anchor != nil || pausedTotal > 0 }

    func elapsed(at date: Date = Date()) -> TimeInterval {
        anchor.map { max(0, date.timeIntervalSince($0)) } ?? pausedTotal
    }

    func start() {
        guard anchor == nil else { return }
        anchor = Date().addingTimeInterval(-pausedTotal)
    }

    func pause() {
        guard let anchor else { return }
        pausedTotal = max(0, Date().timeIntervalSince(anchor))
        self.anchor = nil
    }

    func reset() {
        anchor = nil
        pausedTotal = 0
    }
}
