import Foundation
import IOKit.pwr_mgt

/// Keeps the display (and so the Mac) awake while the user works, for a set
/// time or until turned off. It holds one standard power assertion that macOS
/// lists in `pmset -g assertions`. Closing the lid or choosing Sleep still works.
@MainActor
final class CoveStayAwake: ObservableObject {
    @Published private(set) var isActive = false
    /// nil while active means "until turned off".
    @Published private(set) var endsAt: Date?
    private var assertion: IOPMAssertionID = 0
    private var expiry: Task<Void, Never>?

    static let choices: [(title: String, minutes: Int?)] = [
        ("30 minutes", 30), ("1 hour", 60), ("2 hours", 120), ("4 hours", 240), ("Until turned off", nil)
    ]

    /// Starts or replaces a session. Returns false if macOS refused the assertion.
    @discardableResult
    func start(minutes: Int?) -> Bool {
        if let minutes, !(1...1440).contains(minutes) { return false }
        if assertion == 0 {
            var identifier: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "OpenCove Stay Awake" as CFString, &identifier)
            guard result == kIOReturnSuccess else { return false }
            assertion = identifier
        }
        isActive = true
        expiry?.cancel()
        expiry = nil
        if let minutes {
            let end = Date().addingTimeInterval(Double(minutes) * 60)
            endsAt = end
            expiry = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(end.timeIntervalSinceNow)) } catch { return }
                self?.stop()
            }
        } else {
            endsAt = nil
        }
        return true
    }

    func stop() {
        expiry?.cancel()
        expiry = nil
        if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        isActive = false
        endsAt = nil
    }

    var statusText: String {
        guard isActive else { return "Off" }
        guard let endsAt else { return "On until turned off" }
        return "On until " + endsAt.formatted(date: .omitted, time: .shortened)
    }
}
