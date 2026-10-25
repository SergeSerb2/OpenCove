// SPDX-License-Identifier: MIT
import AppKit
import Combine
import CoreFoundation
import CoreGraphics
import SwiftUI

/// Hosts opt-in widgets in ordinary app panels. This does not replace loginwindow,
/// authenticate a user, or alter the native clock, password field, or lock state.
///
/// `canBecomeVisibleWithoutLogin` is public AppKit API (macOS 10.5+):
/// https://developer.apple.com/documentation/appkit/nswindow/canbecomevisiblewithoutlogin
/// It permits presentation, but does not promise that an ordinary app's panel will
/// appear over every macOS secure lock screen. Actual visibility and placement
/// remain unverified until the user observes their own lock screen. FileVault's
/// pre-boot login screen cannot run this app. No private window API is used here;
/// SystemController separately controls access to its lock-state integration.
@MainActor
final class LockScreenController {
    struct Layout {
        var width: CGFloat = 460
        var height: CGFloat = 250
        /// AppKit coordinates start at the bottom of the display.
        var verticalCenterFraction: CGFloat = 0.55
    }

    var layout: Layout {
        didSet { refreshLayout() }
    }

    private struct Snapshot: Equatable {
        let preferences: CovePreferences
        let state: SystemState
    }
    private struct Presentation {
        let id: UUID
        let panel: CoveLockPanel
        let control: LockScreenKeepAwakeControl
    }
    private struct Intent {
        let token: UUID
        let context: LockScreenKeepAwakeSession.Context
        let issued: ContinuousClock.Instant
        let expires: ContinuousClock.Instant
        let ownerIntentRevision: UUID
    }
    struct CommandResult {
        let outcome: LockScreenKeepAwakeReceipt
        var intentToken: String? = nil
        var validForSeconds: Int? = nil
    }

    private let store: CoveStore
    private let keepAwake: LockScreenKeepAwakeSession
    private var lifetime = LockScreenKeepAwakeLifetime()
    private var presentations: [CGDirectDisplayID: Presentation] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var observations: [(NotificationCenter, NSObjectProtocol)] = []
    private var started = false
    private var screensAsleep = false
    private var sessionActive = false
    private var winner: Snapshot?
    private var snapshotSequence: UInt64 = 0
    private var admissionRevision: UInt64 = 0
    private var presentationRevision: UInt64 = 0
    private var revisionExhausted = false
    private var reconciliationDepth = 0
    private var reconciliationWinner = UUID()
    private var lockEpoch = UUID()
    private var pending: Intent?

    init(store: CoveStore, keepAwake: LockScreenKeepAwakeSession, layout: Layout = Layout()) {
        self.store = store
        self.keepAwake = keepAwake
        self.layout = layout
    }

    deinit {
        // Revoke on this thread before dispatching anything. No controller is
        // retained by the cleanup closure and no new lifetime can reuse this ID.
        let generation = lifetime.invalidate()
        let lifetimeID = lifetime.id
        let owner = keepAwake
        for (center, token) in observations { center.removeObserver(token) }
        let windows = presentations.values.map(\.panel)
        DispatchQueue.main.async {
            if let generation { owner.revoke(controllerID: lifetimeID, reason: "controllerDeinit", generation: generation) }
            for window in windows {
                window.orderOut(nil)
                window.contentView = nil
                window.close()
            }
        }
    }

    func start() {
        guard !started else { return }
        lifetime = LockScreenKeepAwakeLifetime()
        lockEpoch = UUID()
        winner = nil
        pending = nil
        started = true
        screensAsleep = false
        sessionActive = currentSessionIsActive()
        keepAwake.status.resetDraft()

        // Published emits in willSet. Retain BOTH complete incoming values
        // before reconciliation effects; getters can never provide a grant.
        store.$preferences.combineLatest(store.system.$state)
            .sink { [weak self] preferences, state in
                self?.receive(preferences: preferences, state: state)
            }
            .store(in: &subscriptions)

        observe(NSApplication.didChangeScreenParametersNotification) { $0.refreshLayout() }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSWorkspace.activeSpaceDidChangeNotification, center: workspace) { $0.refreshLayout() }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observe(name, center: workspace) { controller in
                controller.screensAsleep = true
                controller.invalidatePresentation()
                controller.retire("screensAsleep")
                controller.removePanels()
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observe(name, center: workspace) { controller in
                controller.screensAsleep = false
                controller.refreshLayout()
            }
        }
        observe(NSWorkspace.sessionDidResignActiveNotification, center: workspace) { controller in
            controller.sessionActive = false
            controller.invalidatePresentation()
            controller.retire("sessionInactive")
            controller.removePanels()
        }
        observe(NSWorkspace.sessionDidBecomeActiveNotification, center: workspace) { controller in
            controller.sessionActive = controller.currentSessionIsActive()
            controller.refreshLayout()
        }
        refreshLayout()
    }

    func stop() {
        started = false
        sessionActive = false
        pending = nil
        _ = lifetime.invalidate()
        retire("controllerStop")
        subscriptions.removeAll()
        for (center, token) in observations { center.removeObserver(token) }
        observations.removeAll()
        removePanels()
    }

    private func advance(_ value: inout UInt64) {
        if value < .max { value += 1 }
        else { revisionExhausted = true }
    }

    private func invalidatePresentation() {
        pending = nil
        advance(&presentationRevision)
    }

    private func retire(_ reason: String) {
        pending = nil
        keepAwake.revoke(controllerID: lifetime.id, reason: reason)
    }

    private func receive(preferences: CovePreferences, state: SystemState) {
        let previous = winner
        // Newest incoming tuple wins, even if a panel/publication reenters.
        winner = Snapshot(preferences: preferences, state: state)
        advance(&snapshotSequence)
        advance(&admissionRevision)
        pending = nil
        let sequence = snapshotSequence
        let pass = UUID()
        reconciliationWinner = pass
        reconciliationDepth += 1
        defer { reconciliationDepth -= 1 }
        if state.lockStateKnown && state.isLocked,
           previous?.state.lockStateKnown != true || previous?.state.isLocked != true {
            lockEpoch = UUID()
            keepAwake.status.resetDraft()
        }
        guard sequence == snapshotSequence, pass == reconciliationWinner else { return }
        if let previous, revokes(previous.preferences, preferences) { retire("effectivePreferencesRevoked") }
        guard sequence == snapshotSequence, pass == reconciliationWinner else { return }
        reconcile(sequence: sequence, pass: pass)
    }

    private func revokes(_ old: CovePreferences, _ new: CovePreferences) -> Bool {
        (old.enablePrivateAPIs && !new.enablePrivateAPIs)
            || (old.showOnLockScreen && !new.showOnLockScreen)
            || old.lockWidgetsFollowActivities != new.lockWidgetsFollowActivities
            || (old.showLockScreenPrivateContent && !new.showLockScreenPrivateContent)
            || old.showOnAllDisplays != new.showOnAllDisplays
            || old.preferBuiltInDisplay != new.preferBuiltInDisplay
            || old.selectedDisplayUUID != new.selectedDisplayUUID
            || CoveLockWidget.allCases.contains { old.showsLockWidget($0) && !new.showsLockWidget($0) }
    }

    func refreshLayout() {
        // Layout never rereads old getters during a Combine willSet delivery.
        guard winner != nil else { return }
        invalidatePresentation()
        let sequence = snapshotSequence
        let pass = UUID()
        reconciliationWinner = pass
        reconciliationDepth += 1
        defer { reconciliationDepth -= 1 }
        reconcile(sequence: sequence, pass: pass)
    }

    private func policyFailure(_ snapshot: Snapshot) -> String? {
        guard started, lifetime.isValid, !revisionExhausted else { return "OWNER_UNAVAILABLE" }
        guard snapshot.preferences.enablePrivateAPIs, snapshot.preferences.showOnLockScreen else { return "POLICY_DISABLED" }
        guard snapshot.state.lockStateKnown else { return "LOCK_STATE_UNKNOWN" }
        guard snapshot.state.isLocked else { return "NOT_LOCKED" }
        guard sessionActive, currentSessionIsActive() else { return "SESSION_INACTIVE" }
        guard !screensAsleep else { return "SCREENS_ASLEEP" }
        guard CoveLockWidget.allCases.contains(where: snapshot.preferences.showsLockWidget) else { return "NO_ADMITTED_WIDGET" }
        return nil
    }

    private func reconcile(sequence: UInt64, pass: UUID) {
        guard sequence == snapshotSequence, pass == reconciliationWinner, let snapshot = winner else { return }
        guard policyFailure(snapshot) == nil else {
            retire("admissionRevoked")
            guard sequence == snapshotSequence, pass == reconciliationWinner else { return }
            removePanels(sequence: sequence, pass: pass)
            return
        }
        let screens = CoveDisplays.resolve(snapshot.preferences).screens
        let selectedIDs = Set(screens.map(\.id))
        for id in Array(presentations.keys) where !selectedIDs.contains(id) {
            guard sequence == snapshotSequence, pass == reconciliationWinner else { return }
            removePanel(id, sequence: sequence, pass: pass)
        }
        for entry in screens {
            guard sequence == snapshotSequence, pass == reconciliationWinner else { return }
            let id = entry.id, screen = entry.screen
            guard let frame = widgetFrame(on: screen) else { removePanel(id, sequence: sequence, pass: pass); continue }
            let presentation: Presentation
            if let existing = presentations[id] { presentation = existing }
            else {
                let presentationID = UUID()
                let control = LockScreenKeepAwakeControl(controller: self, displayID: id, presentationID: presentationID)
                let panel = makePanel(control: control)
                presentation = Presentation(id: presentationID, panel: panel, control: control)
                guard sequence == snapshotSequence, pass == reconciliationWinner else { panel.contentView = nil; panel.close(); return }
                presentations[id] = presentation
                invalidatePresentation()
            }
            let panel = presentation.panel
            if panel.frame != frame { invalidatePresentation(); panel.setFrame(frame, display: true) }
            guard sequence == snapshotSequence, pass == reconciliationWinner, presentations[id]?.panel === panel else { return }
            if !panel.isVisible { panel.orderFrontRegardless() }
            guard sequence == snapshotSequence, pass == reconciliationWinner, presentations[id]?.panel === panel else { return }
            if let row = presentation.control.candidateRow { mounted(row, control: presentation.control) }
            rowGeometryChanged(presentation.control)
        }
    }

    fileprivate func mounted(_ row: NSView, control: LockScreenKeepAwakeControl) {
        reconciliationDepth += 1
        defer { reconciliationDepth -= 1 }
        guard let card = presentations[control.displayID], card.control === control,
              card.id == control.presentationID, row.window === card.panel,
              let content = card.panel.contentView, row.isDescendant(of: content) else { return }
        if control.row !== row {
            if control.row != nil { rowRemoved(control) }
            guard presentations[control.displayID]?.control === control, row.window === card.panel,
                  let content = card.panel.contentView, row.isDescendant(of: content) else { return }
            control.row = row
            control.mountID = UUID()
            invalidatePresentation()
        }
        rowGeometryChanged(control)
    }

    fileprivate func rowRemoved(_ control: LockScreenKeepAwakeControl) {
        reconciliationDepth += 1
        defer { reconciliationDepth -= 1 }
        guard let card = presentations[control.displayID], card.control === control else { return }
        control.row = nil
        control.geometry = nil
        invalidatePresentation()
        if keepAwakeOriginIs(control) { retire("originRowRemoved") }
        if control.row == nil { control.setAvailable(false) }
    }

    fileprivate func rowGeometryChanged(_ control: LockScreenKeepAwakeControl) {
        reconciliationDepth += 1
        defer { reconciliationDepth -= 1 }
        guard let card = presentations[control.displayID], card.control === control else { return }
        let geometry = control.currentGeometry(in: card.panel)
        if geometry != control.geometry {
            control.geometry = geometry
            invalidatePresentation()
        }
        let available = geometry?.visible == true && winner.map { policyFailure($0) == nil } == true
        control.setAvailable(available)
    }

    private func keepAwakeOriginIs(_ control: LockScreenKeepAwakeControl) -> Bool {
        keepAwake.originMatches(controllerID: lifetime.id, presentationID: control.presentationID)
    }

    private func makeContext(purpose: String, minutes: Int, displayID: UInt32, expected: UUID?,
                         origin: String) -> (LockScreenKeepAwakeSession.Context?, String?) {
        guard reconciliationDepth == 0, !keepAwake.isBusy else { return (nil, "OPERATION_IN_PROGRESS") }
        guard (1...120).contains(minutes) else { return (nil, "INVALID_ARGUMENT") }
        let product = minutes.multipliedReportingOverflow(by: 60)
        guard !product.overflow, (60...7200).contains(product.partialValue) else { return (nil, "INVALID_ARGUMENT") }
        guard let snapshot = winner else { return (nil, "OWNER_UNAVAILABLE") }
        if let failure = policyFailure(snapshot) { return (nil, failure) }
        guard let card = presentations[displayID] else { return (nil, "NO_ADMITTED_PANEL") }
        rowGeometryChanged(card.control)
        guard card.control.geometry?.visible == true else { return (nil, "CONTROL_NOT_MOUNTED") }
        let selected = CoveDisplays.resolve(snapshot.preferences).screens
        guard selected.contains(where: { $0.id == displayID && widgetFrame(on: $0.screen) == card.panel.frame }) else { return (nil, "NO_ADMITTED_PANEL") }
        let revisions = LockScreenKeepAwakeSession.Revisions(processOwnerID: keepAwake.id,
            controllerLifetimeID: lifetime.id, lockEpoch: lockEpoch, presentationID: card.id,
            mountID: card.control.mountID, presentationRevision: presentationRevision,
            snapshotSequence: snapshotSequence, admissionRevision: admissionRevision,
            displayID: displayID, selectedDisplayIDs: selected.map(\.id).sorted())
        let result = LockScreenKeepAwakeSession.Context(revisions: revisions, lifetime: lifetime,
            preferences: snapshot.preferences, state: snapshot.state, purpose: purpose,
            minutes: minutes, seconds: product.partialValue, expectedSessionID: expected, origin: origin)
        return (result, validate(result))
    }

    private func validate(_ context: LockScreenKeepAwakeSession.Context) -> String? {
        guard reconciliationDepth == 0 else { return "OPERATION_IN_PROGRESS" }
        guard let snapshot = winner else { return "OWNER_UNAVAILABLE" }
        if let failure = policyFailure(snapshot) { return failure }
        // Veto only. Neither getter can replace or promote the incoming winner.
        guard store.preferences == snapshot.preferences, store.system.state == snapshot.state,
              context.preferences == snapshot.preferences, context.state == snapshot.state,
              context.lifetime === lifetime, lifetime.isValid else { return "STALE_CONTEXT" }
        let r = context.revisions
        guard let card = presentations[r.displayID], card.id == r.presentationID,
              card.control.mountID == r.mountID else { return "STALE_CONTEXT" }
        rowGeometryChanged(card.control)
        guard card.control.geometry?.visible == true else { return "CONTROL_NOT_MOUNTED" }
        let screens = CoveDisplays.resolve(snapshot.preferences).screens
        guard r.processOwnerID == keepAwake.id, r.controllerLifetimeID == lifetime.id,
              r.lockEpoch == lockEpoch, r.snapshotSequence == snapshotSequence,
              r.admissionRevision == admissionRevision, r.presentationRevision == presentationRevision,
              r.selectedDisplayIDs == screens.map(\.id).sorted(),
              screens.contains(where: { $0.id == r.displayID && widgetFrame(on: $0.screen) == card.panel.frame }),
              ["start", "replace"].contains(context.purpose), (1...120).contains(context.minutes),
              context.seconds == context.minutes * 60,
              context.purpose != "replace" || context.expectedSessionID != nil else { return "STALE_CONTEXT" }
        // Repeat after geometry/display callbacks. This is the final veto used
        // immediately before create and after success, before active publication.
        guard winner == snapshot, store.preferences == snapshot.preferences,
              store.system.state == snapshot.state, reconciliationDepth == 0,
              lifetime.isValid, r.snapshotSequence == snapshotSequence,
              r.presentationRevision == presentationRevision else { return "STALE_CONTEXT" }
        return nil
    }

    fileprivate func native(_ purpose: String, minutes: Int, control: LockScreenKeepAwakeControl, expected: UUID?) {
        guard let card = presentations[control.displayID], card.control === control else { return }
        let requestID = UUID()
        let payload = LockScreenKeepAwakeSession.Payload(action: purpose, expectedSessionID: expected?.uuidString,
                                                        minutes: minutes, displayID: control.displayID)
        if purpose == "stop" {
            rowGeometryChanged(control)
            guard control.available else { return }
            pending = nil
            _ = keepAwake.stop(requestID: requestID, payload: payload, expected: expected, origin: "native")
            return
        }
        guard minutes == keepAwake.status.draftMinutes else {
            keepAwake.reject("STALE_CONTEXT", requestID: requestID, payload: payload, purpose: purpose, origin: "native")
            return
        }
        let (context, failure) = makeContext(purpose: purpose, minutes: minutes,
                                         displayID: control.displayID, expected: expected, origin: "native")
        pending = nil
        guard let context, failure == nil else {
            keepAwake.reject(failure ?? "STALE_CONTEXT", requestID: requestID, payload: payload,
                             purpose: purpose, origin: "native")
            return
        }
        _ = keepAwake.perform(requestID: requestID, payload: payload, context: context, validate: validate)
    }

    /// The sole authenticated command route. No state, geometry, clock, permission
    /// or power-result injection is accepted. Preparation does not schedule work.
    func keepAwakeCommand(_ values: [String: Any]) -> CommandResult {
        let action = values["action"] as? String ?? ""
        func reject(_ code: String, requestID: UUID? = nil, payload: LockScreenKeepAwakeSession.Payload? = nil,
                    intent: String = "rejected") -> CommandResult {
            CommandResult(outcome: keepAwake.reject(code, requestID: requestID, payload: payload,
                                                    purpose: action, origin: "command", intent: intent))
        }
        func uuid(_ value: Any?) -> UUID? {
            guard let text = value as? String, text.utf8.count == 36 else { return nil }
            return UUID(uuidString: text)
        }
        func integer(_ value: Any?, range: ClosedRange<Double>) -> Double? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let d = number.doubleValue
            guard d.isFinite, d.rounded(.towardZero) == d, range.contains(d),
                  number.compare(NSNumber(value: Int64(d))) == .orderedSame else { return nil }
            return d
        }
        if action == "keepAwake.prepare" {
            pending = nil // Every new prepare invalidates the prior token.
            guard let operation = values["operation"] as? String, ["start", "replace"].contains(operation) else { return reject("INVALID_ARGUMENT") }
            let keys: Set<String> = operation == "start" ? ["action", "operation", "minutes", "displayID"]
                : ["action", "operation", "minutes", "displayID", "expectedSessionID"]
            guard Set(values.keys) == keys,
                  let minutes = integer(values["minutes"], range: 1...120),
                  let display = integer(values["displayID"], range: 1...Double(UInt32.max)) else { return reject("INVALID_ARGUMENT") }
            let expected = uuid(values["expectedSessionID"])
            guard operation != "replace" || expected != nil else { return reject("INVALID_ARGUMENT") }
            if operation == "replace", expected != keepAwake.currentSessionID { return reject("SESSION_MISMATCH") }
            let (context, failure) = makeContext(purpose: operation, minutes: Int(minutes), displayID: UInt32(display),
                                             expected: expected, origin: "command")
            guard let context, failure == nil else { return reject(failure ?? "STALE_CONTEXT") }
            let now = ContinuousClock.now
            let intent = Intent(token: UUID(), context: context, issued: now, expires: now.advanced(by: .seconds(10)),
                                ownerIntentRevision: keepAwake.intentRevision)
            pending = intent
            let outcome = keepAwake.reject("PREPARED", purpose: operation, origin: "command", context: context, intent: "prepared")
            return CommandResult(outcome: outcome, intentToken: intent.token.uuidString, validForSeconds: 10)
        }
        if action == "keepAwake.start" || action == "keepAwake.replace" {
            guard Set(values.keys) == ["action", "intentToken", "requestID"],
                  let requestID = uuid(values["requestID"]), let token = uuid(values["intentToken"]),
                  let tokenText = values["intentToken"] as? String else { return reject("INVALID_ARGUMENT") }
            let payload = LockScreenKeepAwakeSession.Payload(action: action, intentToken: tokenText)
            if let previous = keepAwake.replayed(requestID: requestID, payload: payload) { return CommandResult(outcome: previous) }
            guard let intent = pending, intent.token == token else { return reject("INTENT_USED", requestID: requestID, payload: payload, intent: "unavailable") }
            pending = nil // Consume once before expiry/purpose/admission validation.
            guard ContinuousClock.now < intent.expires else { return reject("INTENT_EXPIRED", requestID: requestID, payload: payload, intent: "expired") }
            guard intent.ownerIntentRevision == keepAwake.intentRevision else {
                return reject("STALE_CONTEXT", requestID: requestID, payload: payload, intent: "revoked")
            }
            let purpose = action == "keepAwake.start" ? "start" : "replace"
            guard intent.context.purpose == purpose else { return reject("STALE_CONTEXT", requestID: requestID, payload: payload, intent: "consumed") }
            return CommandResult(outcome: keepAwake.perform(requestID: requestID, payload: payload,
                                                          context: intent.context, validate: validate))
        }
        if action == "keepAwake.stop" {
            guard Set(values.keys) == ["action", "requestID", "expectedSessionID"],
                  let requestID = uuid(values["requestID"]) else { return reject("INVALID_ARGUMENT") }
            let expected = uuid(values["expectedSessionID"])
            guard values["expectedSessionID"] is NSNull || expected != nil else { return reject("INVALID_ARGUMENT") }
            let payload = LockScreenKeepAwakeSession.Payload(action: action, expectedSessionID: values["expectedSessionID"] as? String)
            if let previous = keepAwake.replayed(requestID: requestID, payload: payload) { return CommandResult(outcome: previous) }
            pending = nil
            return CommandResult(outcome: keepAwake.stop(requestID: requestID, payload: payload, expected: expected, origin: "command"))
        }
        return reject("INVALID_ARGUMENT")
    }

    private func currentSessionIsActive() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool,
              let loginDone = session[kCGSessionLoginDoneKey as String] as? Bool else { return false }
        return onConsole && loginDone
    }

    private func makePanel(control: LockScreenKeepAwakeControl) -> CoveLockPanel {
        let panel = CoveLockPanel(contentRect: .zero,
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        panel.title = "OpenCove widgets"
        panel.isReleasedWhenClosed = false
        panel.canBecomeVisibleWithoutLogin = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.isRestorable = false
        panel.isExcludedFromWindowsMenu = true
        panel.tabbingMode = .disallowed
        panel.animationBehavior = .none
        // Only this bounded card receives pointer events. There is no full-screen
        // input shield, key equivalent, global event monitor, or activation call.
        let hosting = CoveLockHostingView(rootView: LockScreenView(store: store, weather: store.weather, keepAwakeStatus: keepAwake.status, keepAwakeControl: control))
        // The controller owns the bounded authentication-safe frame. Content
        // must scroll within it rather than raise the native window minimum.
        hosting.sizingOptions = []
        panel.contentView = hosting
        return panel
    }

    private func widgetFrame(on screen: NSScreen) -> NSRect? {
        let bounds = screen.frame
        // Leave the bottom 36% to native authentication and the top 24% to the
        // native clock. These are conservative layout margins, not measured
        // loginwindow geometry: macOS exposes no supported auth-field frame.
        // Keep the card small, and omit it if the display cannot fit this band.
        let safeBottom = bounds.minY + max(180, bounds.height * 0.36)
        let safeTop = bounds.maxY - max(100, bounds.height * 0.24)
        let width = min(finite(layout.width, fallback: 460, range: 320...560), bounds.width - 64)
        let height = min(finite(layout.height, fallback: 250, range: 180...280), safeTop - safeBottom)
        guard width >= 320, height >= 180 else { return nil }
        let center = bounds.minY + bounds.height * finite(layout.verticalCenterFraction, fallback: 0.55, range: 0.45...0.65)
        let y = min(max(center - height / 2, safeBottom), safeTop - height)
        let scale = max(1, screen.backingScaleFactor)
        return NSRect(x: (bounds.midX - width / 2) * scale, y: y * scale,
                      width: width * scale, height: height * scale).integral
            .applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
    }

    private func finite(_ value: CGFloat, fallback: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        min(range.upperBound, max(range.lowerBound, value.isFinite ? value : fallback))
    }

    private func removePanel(_ id: CGDirectDisplayID, sequence: UInt64? = nil, pass: UUID? = nil) {
        guard let card = presentations[id] else { return }
        // Revoke while the origin panel/content is still retained and before
        // any AppKit operation can reenter. A surviving card cannot inherit it.
        invalidatePresentation()
        if keepAwakeOriginIs(card.control) { retire("originPanelRemoved") }
        if let sequence, sequence != snapshotSequence { return }
        if let pass, pass != reconciliationWinner { return }
        guard presentations[id]?.panel === card.panel else { return }
        presentations.removeValue(forKey: id)
        card.control.setAvailable(false)
        card.panel.orderOut(nil)
        card.panel.contentView = nil
        card.panel.close()
        if presentations.isEmpty { keepAwake.status.resetDraft() }
    }

    private func removePanels(sequence: UInt64? = nil, pass: UUID? = nil) {
        for id in Array(presentations.keys) {
            if let sequence, sequence != snapshotSequence { return }
            if let pass, pass != reconciliationWinner { return }
            removePanel(id, sequence: sequence, pass: pass)
        }
    }

    private func observe(_ name: Notification.Name, center: NotificationCenter = .default,
                         action: @escaping @MainActor (LockScreenController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.started else { return }
                action(self)
            }
        }
        observations.append((center, token))
    }
}

@MainActor
private final class CoveLockPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class CoveLockHostingView: NSHostingView<LockScreenView> {
    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Opaque per-card route. Only the real controller creates one; the renderer's
/// default view has none. It holds neither controller nor native row strongly.
@MainActor
final class LockScreenKeepAwakeControl: ObservableObject {
    struct Geometry: Equatable {
        let rowInWindow: NSRect
        let visibleRect: NSRect
        let contentBounds: NSRect
        let clipBounds: NSRect?
        let panelFrame: NSRect
        let visible: Bool
    }
    private weak var controller: LockScreenController?
    fileprivate let displayID: UInt32
    fileprivate let presentationID: UUID
    fileprivate weak var row: NSView?
    fileprivate weak var candidateRow: NSView?
    fileprivate var mountID = UUID()
    fileprivate var geometry: Geometry?
    let objectWillChange = ObservableObjectPublisher()
    private(set) var available = false

    fileprivate init(controller: LockScreenController, displayID: UInt32, presentationID: UUID) {
        self.controller = controller
        self.displayID = displayID
        self.presentationID = presentationID
    }
    fileprivate func setAvailable(_ value: Bool) {
        guard available != value else { return }
        available = value
        objectWillChange.send()
    }
    func mounted(_ row: NSView) {
        candidateRow = row
        controller?.mounted(row, control: self)
    }
    func removed(_ row: NSView) {
        if candidateRow === row { candidateRow = nil }
        if self.row === row { controller?.rowRemoved(self) }
    }
    func geometryChanged() { controller?.rowGeometryChanged(self) }
    func activate(_ purpose: String, minutes: Int, expected: UUID? = nil) {
        controller?.native(purpose, minutes: minutes, control: self, expected: expected)
    }

    fileprivate func currentGeometry(in panel: NSPanel) -> Geometry? {
        guard let row, row.window === panel, let content = panel.contentView,
              row.isDescendant(of: content) else { return nil }
        let inContent = row.convert(row.bounds, to: content)
        let intersection = inContent.intersection(content.visibleRect)
        let visible = panel.isVisible && !row.isHiddenOrHasHiddenAncestor && row.alphaValue > 0
            && !row.visibleRect.isEmpty && !intersection.isEmpty
            && row.bounds.width > 0 && row.bounds.height > 0
        return Geometry(rowInWindow: row.convert(row.bounds, to: nil), visibleRect: row.visibleRect,
                        contentBounds: content.bounds, clipBounds: row.enclosingScrollView?.contentView.bounds,
                        panelFrame: panel.frame, visible: visible)
    }
}
