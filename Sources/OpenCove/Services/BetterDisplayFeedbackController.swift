// SPDX-License-Identifier: MIT
import Foundation

/// Default-off, receive-only Foundation transport. Construction has no effects.
/// The store supplies consent, session policy and an existing display snapshot.
@MainActor
final class BetterDisplayFeedbackController {
    fileprivate static let osd = Notification.Name("pro.betterdisplay.BetterDisplay.osd")
    fileprivate static let launched = Notification.Name("pro.betterdisplay.BetterDisplay.launched")
    fileprivate static let terminated = Notification.Name("pro.betterdisplay.BetterDisplay.terminated")

    var onFeedback: ((BetterDisplayFeedback) -> Void)?
    var onInvalidation: (() -> Void)?
    /// Existing owner state only; never performs a session or display query.
    var canReceive: () -> Bool = { false }

    private var observer: BetterDisplayFeedbackObserver?
    private var selection: CoveDisplaySelection?
    private var identity: BetterDisplayFeedback.Identity?
    private var cached: BetterDisplayFeedback?
    private var generation: UInt64 = 0
    private var providerTerminated = false

    func configure(selection: CoveDisplaySelection?, enabled: Bool) {
        guard enabled, let selection,
              let display = BetterDisplayFeedback.Display.selected(in: selection) else { stop(); return }
        guard self.selection != selection || observer == nil else { return }
        retire()
        self.selection = selection
        identity = .init(display: display, generation: generation)
        installObserver()
    }

    func stop() {
        guard observer != nil || selection != nil || cached != nil else { return }
        retire()
        selection = nil
        identity = nil
        // A future explicit enabled session cannot infer provider lifetime from
        // notifications that were intentionally not observed while stopped.
        providerTerminated = false
    }

    /// Cache and clock only. Expiry is checked lazily, with no timer or polling.
    func eligibleReport() -> BetterDisplayFeedback? {
        guard canReceive(), observer != nil, !providerTerminated, let identity, let cached,
              cached.isEligible(for: identity, now: ContinuousClock().now) else { return nil }
        return cached
    }

    var awaitingProviderLaunch: Bool { providerTerminated }

    private func retire() {
        generation &+= 1
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        cached = nil
        onInvalidation?()
    }

    private func installObserver() {
        let observer = BetterDisplayFeedbackObserver(owner: self, generation: generation)
        self.observer = observer
        let center = DistributedNotificationCenter.default()
        // Subscribe to one current OSD namespace. After orderly termination,
        // keep lifecycle reception only until the provider reports a new launch.
        let names = providerTerminated ? [Self.launched, Self.terminated] : [Self.osd, Self.launched, Self.terminated]
        for name in names {
            center.addObserver(observer, selector: #selector(BetterDisplayFeedbackObserver.receive(_:)),
                               name: name, object: nil, suspensionBehavior: .drop)
        }
    }

    fileprivate func receive(_ notification: Notification, generation: UInt64) {
        guard observer != nil, generation == self.generation, let identity else { return }
        guard canReceive() else { stop(); return }
        if notification.name == Self.terminated || notification.name == Self.launched {
            // Lifecycle object contents are deliberately ignored. Retire every
            // queued callback and report even on a repeated launch notification.
            providerTerminated = notification.name == Self.terminated
            retire()
            self.identity = .init(display: identity.display, generation: self.generation)
            installObserver()
            return
        }
        guard notification.name == Self.osd, !providerTerminated,
              let payload = BetterDisplayFeedback.Payload.decode(notification.object),
              payload.displayID == identity.display.currentID else { return }
        let report = BetterDisplayFeedback(identity: identity, controlTarget: payload.controlTarget,
                                          fraction: payload.fraction, receivedAt: ContinuousClock().now)
        cached = report
        onFeedback?(report)
    }

    deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }
}

/// Each registration has an immutable generation. Removed/late registrations
/// cannot enter a new consent, session or display generation. DNC delivery is
/// on the main thread on supported macOS; never enqueue external payloads.
private final class BetterDisplayFeedbackObserver: NSObject {
    weak var owner: BetterDisplayFeedbackController?
    let generation: UInt64

    init(owner: BetterDisplayFeedbackController, generation: UInt64) {
        self.owner = owner
        self.generation = generation
    }

    @objc func receive(_ notification: Notification) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { owner?.receive(notification, generation: generation) }
    }
}
