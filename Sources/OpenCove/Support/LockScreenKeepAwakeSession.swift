// SPDX-License-Identifier: MIT
import Combine
import Foundation
import IOKit.pwr_mgt

/// A one-way capability lifetime, separate from the controller's actor lifetime.
/// Deinit can revoke synchronously; the process root still owns every handle.
final class LockScreenKeepAwakeLifetime: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var valid = true
    private var generation: UUID?

    var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    func own(_ generation: UUID) {
        lock.lock(); defer { lock.unlock() }
        self.generation = generation
    }
    func invalidate() -> UUID? {
        lock.lock(); defer { lock.unlock() }
        valid = false
        return generation
    }
}

struct LockScreenKeepAwakeRetirementReceipt: Codable {
    let sessionID: UUID
    let generation: UUID
    let reason: String
    let attemptContinuous: Double
    let offReturnContinuous: Double
    let releaseReturnContinuous: Double
    let offIOReturn: Int32
    let releaseIOReturn: Int32
}

struct LockScreenKeepAwakeReceipt: Codable {
    let requestID: UUID?
    let creationRequestID: UUID?
    let resultCode: String
    let origin: String
    let sessionID: UUID?
    let generation: UUID?
    let purpose: String
    let durationMinutes: Int?
    let durationSeconds: Int?
    let assertionType: String?
    let timeoutAction: String?
    let contextRevisions: LockScreenKeepAwakeSession.Revisions?
    // Seconds from this owner's fixed ContinuousClock origin, never wall time.
    let attemptContinuous: Double?
    let returnContinuous: Double?
    let applicationDeadline: Double?
    let OSDeadlineLowerBound: Double?
    let OSDeadlineUpperBound: Double?
    let createIOReturn: Int32?
    let offIOReturn: Int32?
    let releaseIOReturn: Int32?
    let retirementAttemptContinuous: Double?
    let offReturnContinuous: Double?
    let releaseReturnContinuous: Double?
    let retirementReason: String?
    // At most two: old replacement retirement, then stale new-handle retirement.
    let retirements: [LockScreenKeepAwakeRetirementReceipt]
    let intentState: String
    let handleState: String
    let effectEvidence: String
    let createAttemptCount: UInt64
    let retireAttemptCount: UInt64
    let apiAttempted: Bool

    var httpStatus: Int {
        switch resultCode {
        case "PREPARED", "STARTED", "REPLACED", "STOPPED", "IDLE", "RETIRED": return 200
        case "INVALID_ARGUMENT": return 400
        case "API_CREATE_FAILED", "API_RETIRE_FAILED": return 500
        default: return 409
        }
    }
}

struct LockScreenKeepAwakeProjection: Codable {
    var handleState = "idle"
    var sessionID: UUID?
    var durationMinutes: Int?
    var expectedEnd: Date?
    var applicationDeadlinePassed = false
    var finiteUpperBoundPassed = false
    var message = "Start a finite session from an available lock-screen card."
    var createAttemptCount: UInt64 = 0
    var retireAttemptCount: UInt64 = 0
    var lastOutcome: LockScreenKeepAwakeReceipt?
}

/// Read-only projection plus a volatile presentation draft. An inert instance is
/// safe for offscreen views: it owns no controller, timer, capability or power.
@MainActor
final class LockScreenKeepAwakeStatus: @MainActor ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private(set) var projection = LockScreenKeepAwakeProjection()
    private(set) var draftMinutes = 5
    fileprivate func publish(_ value: LockScreenKeepAwakeProjection) {
        // Store first: reentrant observers cannot let an outer willSet overwrite
        // the newer outcome or a synchronous retirement projection.
        projection = value
        objectWillChange.send()
    }
    func setDraft(_ minutes: Int) {
        guard (1...120).contains(minutes), minutes != draftMinutes else { return }
        draftMinutes = minutes
        objectWillChange.send()
    }
    func resetDraft() { setDraft(5) }
}

/// Sole process-rooted power owner. Only direct, finite user intent reaches the
/// create call. A controller supplies real current authority, never a fake state.
@MainActor
final class LockScreenKeepAwakeSession {
    struct Revisions: Codable, Equatable {
        let processOwnerID: UUID
        let controllerLifetimeID: UUID
        let lockEpoch: UUID
        let presentationID: UUID
        let mountID: UUID
        let presentationRevision: UInt64
        let snapshotSequence: UInt64
        let admissionRevision: UInt64
        let displayID: UInt32
        let selectedDisplayIDs: [UInt32]
    }

    struct Context {
        let revisions: Revisions
        let lifetime: LockScreenKeepAwakeLifetime
        let preferences: CovePreferences
        let state: SystemState
        let purpose: String
        let minutes: Int
        let seconds: Int
        let expectedSessionID: UUID?
        let origin: String
    }

    struct Payload: Equatable {
        let action: String
        var intentToken: String? = nil
        var expectedSessionID: String? = nil
        var minutes: Int? = nil
        var displayID: UInt32? = nil
    }

    private enum Phase: String { case provisional, active, retiring, quarantined }
    private struct Attempt {
        let context: Context
        let requestID: UUID
        let sessionID: UUID
        let generation: UUID
        let properties: NSDictionary
        let t0: ContinuousClock.Instant
        let t1: ContinuousClock.Instant
        let deadline: ContinuousClock.Instant
        let upperBound: ContinuousClock.Instant
        let expectedEnd: Date
        let code: IOReturn
    }
    private struct Retirement {
        let reason: String
        let t0: ContinuousClock.Instant
        let offReturn: ContinuousClock.Instant
        let releaseReturn: ContinuousClock.Instant
        let off: IOReturn
        let release: IOReturn
    }
    private struct Owned {
        let id: IOPMAssertionID
        let attempt: Attempt
        var phase: Phase
        var retirement: Retirement?
    }
    private struct Replay {
        let id: UUID
        let payload: Payload
        let outcome: LockScreenKeepAwakeReceipt
    }

    let id = UUID()
    let status = LockScreenKeepAwakeStatus()
    private(set) var intentRevision = UUID()
    private let clock = ContinuousClock()
    private let clockOrigin = ContinuousClock.now
    private var running = true
    private var busy = false
    private var slot: Owned?
    private var creationFault: Attempt?
    private var lastRetirement: (attempt: Attempt, retirement: Retirement)?
    private var expiry: Task<Void, Never>?
    private var replay: Replay?
    private var lastOutcome: LockScreenKeepAwakeReceipt?
    private var createAttempts: UInt64 = 0
    private var retireAttempts: UInt64 = 0

    var currentSessionID: UUID? { slot?.attempt.sessionID }
    var isBusy: Bool { busy }

    func originMatches(controllerID: UUID, presentationID: UUID) -> Bool {
        slot?.attempt.context.lifetime.id == controllerID
            && slot?.attempt.context.revisions.presentationID == presentationID
    }

    private func increment(_ value: inout UInt64) { if value < .max { value += 1 } }
    private func time(_ instant: ContinuousClock.Instant) -> Double {
        let parts = clockOrigin.duration(to: instant).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    func replayed(requestID: UUID, payload: Payload) -> LockScreenKeepAwakeReceipt? {
        guard let replay, replay.id == requestID else { return nil }
        if replay.payload == payload { return replay.outcome }
        let outcome = receipt("INVALID_ARGUMENT", requestID: requestID, purpose: payload.action,
                              origin: "command", intent: "rejected")
        cache(outcome, publish: !busy) // Preserve the original replay entry.
        return outcome
    }

    /// Cache before publication or response encoding. Tokens and full tuples
    /// never enter this receipt. Keep just one outcome and one replay entry.
    @discardableResult
    func reject(_ code: String, requestID: UUID? = nil, payload: Payload? = nil,
                purpose: String, origin: String, context: Context? = nil,
                intent: String = "rejected") -> LockScreenKeepAwakeReceipt {
        let outcome = receipt(code, requestID: requestID, purpose: purpose, origin: origin,
                              context: context, intent: intent)
        // Cache even a reentrant rejection before encoding. Do not publish in
        // the middle of an operation; its final outcome becomes newest later.
        cache(outcome, requestID: requestID, payload: payload, publish: !busy)
        return outcome
    }

    func perform(requestID: UUID, payload: Payload, context: Context,
                 validate: (Context) -> String?) -> LockScreenKeepAwakeReceipt {
        if let previous = replayed(requestID: requestID, payload: payload) { return previous }
        guard !busy else {
            return reject("OPERATION_IN_PROGRESS", requestID: requestID, payload: payload,
                          purpose: context.purpose, origin: context.origin)
        }
        busy = true
        defer { busy = false }
        var attempted = false
        var result: String
        var evidence: Owned?
        var attemptEvidence: Attempt?
        var retirements: [LockScreenKeepAwakeRetirementReceipt] = []
        if !running { result = "OWNER_UNAVAILABLE" }
        else if creationFault != nil { result = "API_CREATE_FAILED" }
        else if slot?.phase == .quarantined { result = "CLEANUP_UNCONFIRMED" }
        else if let owned = slot, clock.now >= owned.attempt.deadline { result = "OPERATION_IN_PROGRESS" }
        else if context.purpose == "start", slot != nil { result = "ALREADY_ACTIVE" }
        else if context.purpose == "replace", context.expectedSessionID == nil || context.expectedSessionID != currentSessionID {
            result = "SESSION_MISMATCH"
        } else if let failure = validate(context) { result = failure }
        else {
            result = "STARTED"
            if context.purpose == "replace" {
                evidence = retire(reason: "explicitRestart")
                if let evidence { retirements.append(retirementReceipt(evidence.attempt, evidence.retirement!)) }
                attempted = evidence != nil
                if slot != nil { result = "API_RETIRE_FAILED" }
                else if let failure = validate(context) { result = failure }
                else { result = "REPLACED" }
            }
            if result == "STARTED" || result == "REPLACED" {
                // Last veto immediately before the real call. Stored getters
                // can only reject this retained incoming context.
                if let failure = validate(context) { result = failure }
                else if !running || !context.lifetime.isValid { result = "OWNER_UNAVAILABLE" }
                else {
                    attempted = true
                    let created = create(requestID: requestID, context: context)
                    attemptEvidence = created
                    if created.code != kIOReturnSuccess { result = "API_CREATE_FAILED" }
                    else {
                        // create() has already rooted the provisional handle.
                        let validationFailure = validate(context)
                        let failure: String? = !running ? "OWNER_UNAVAILABLE" : validationFailure
                            ?? (slot?.attempt.generation == created.generation && slot?.phase == .provisional
                                && context.lifetime.isValid ? nil : "STALE_CONTEXT")
                        if let failure {
                            evidence = retire(reason: "staleSuccessfulCreate")
                            if let lastRetirement, lastRetirement.attempt.generation == created.generation {
                                retirements.append(retirementReceipt(lastRetirement.attempt, lastRetirement.retirement))
                            }
                            result = slot == nil ? failure : "API_RETIRE_FAILED"
                        } else if clock.now >= created.deadline {
                            evidence = retire(reason: "lateSuccessfulCreate")
                            if let evidence { retirements.append(retirementReceipt(evidence.attempt, evidence.retirement!)) }
                            result = slot == nil ? "OPERATION_IN_PROGRESS" : "API_RETIRE_FAILED"
                        } else {
                            slot?.phase = .active
                            scheduleExpiry(created)
                            evidence = slot
                        }
                    }
                }
            }
        }
        let outcome = receipt(result, requestID: requestID, purpose: context.purpose, origin: context.origin,
                              context: context, evidence: evidence, attemptEvidence: attemptEvidence,
                              retirements: retirements, intent: "consumed", attempted: attempted)
        cache(outcome, requestID: requestID, payload: payload)
        return outcome
    }

    func stop(requestID: UUID, payload: Payload, expected: UUID?, origin: String) -> LockScreenKeepAwakeReceipt {
        if let previous = replayed(requestID: requestID, payload: payload) { return previous }
        guard !busy else { return reject("OPERATION_IN_PROGRESS", requestID: requestID, payload: payload, purpose: "stop", origin: origin) }
        busy = true
        defer { busy = false }
        let result: String
        var evidence: Owned?
        if slot?.phase == .quarantined { result = "CLEANUP_UNCONFIRMED" }
        else if expected != currentSessionID { result = "SESSION_MISMATCH" }
        else if slot == nil { result = creationFault == nil ? "IDLE" : "API_CREATE_FAILED" }
        else { evidence = retire(reason: "explicitStop"); result = slot == nil ? "STOPPED" : "API_RETIRE_FAILED" }
        let outcome = receipt(result, requestID: requestID, purpose: "stop", origin: origin,
                              evidence: evidence, intent: "consumed", attempted: evidence != nil)
        cache(outcome, requestID: requestID, payload: payload)
        return outcome
    }

    func revoke(controllerID: UUID, reason: String, generation: UUID? = nil) {
        guard let owned = slot, owned.attempt.context.lifetime.id == controllerID,
              generation == nil || owned.attempt.generation == generation,
              owned.phase != .quarantined, owned.phase != .retiring else { return }
        // Reentrant revocation must still retire synchronously before panel
        // teardown. During a create there is no slot yet; post-create validation
        // catches its revoked context. During retirement the phase blocks entry.
        let wasBusy = busy
        busy = true
        defer { busy = wasBusy }
        let evidence = retire(reason: reason)
        let outcome = receipt(slot == nil ? "RETIRED" : "API_RETIRE_FAILED", purpose: "retire",
                              origin: "lifecycle", evidence: evidence, intent: "revoked", attempted: true)
        cache(outcome)
    }

    func shutdown() {
        running = false
        intentRevision = UUID()
        if let owned = slot { revoke(controllerID: owned.attempt.context.lifetime.id, reason: "applicationTermination") }
    }

    private func create(requestID: UUID, context: Context) -> Attempt {
        // No property update, re-arm, overlap or renewal path exists.
        precondition(slot == nil && creationFault == nil)
        let properties: NSDictionary = [
            kIOPMAssertionTypeKey as String: kIOPMAssertionTypePreventUserIdleDisplaySleep,
            kIOPMAssertionLevelKey as String: NSNumber(value: kIOPMAssertionLevelOn),
            kIOPMAssertionNameKey as String: "OpenCove Lock Screen Keep Awake",
            kIOPMAssertionDetailsKey as String: "Explicit finite lock-screen session: \(context.seconds) seconds",
            kIOPMAssertionTimeoutKey as String: NSNumber(value: context.seconds),
            kIOPMAssertionTimeoutActionKey as String: kIOPMAssertionTimeoutActionTurnOff
        ]
        let sessionID = UUID(), generation = UUID()
        var output: IOPMAssertionID = 0 // Not owned, inspected or used on error.
        increment(&createAttempts)
        let expectedEnd = Date().addingTimeInterval(TimeInterval(context.seconds))
        let t0 = clock.now
        let code = IOPMAssertionCreateWithProperties(properties as CFDictionary, &output)
        let t1 = clock.now
        let attempt = Attempt(context: context, requestID: requestID, sessionID: sessionID,
                              generation: generation, properties: properties, t0: t0, t1: t1,
                              deadline: t0.advanced(by: .seconds(context.seconds)),
                              upperBound: t1.advanced(by: .seconds(context.seconds)),
                              expectedEnd: expectedEnd, code: code)
        if code == kIOReturnSuccess {
            // Own before any observable publication or post-call validation.
            slot = Owned(id: output, attempt: attempt, phase: .provisional)
            context.lifetime.own(generation)
        } else {
            // The API does not transfer a valid output handle on error.
            creationFault = attempt
        }
        return attempt
    }

    private func scheduleExpiry(_ attempt: Attempt) {
        precondition(expiry == nil)
        let deadline = attempt.deadline, generation = attempt.generation, sessionID = attempt.sessionID
        let lifetime = attempt.context.lifetime
        expiry = Task { @MainActor [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            guard !Task.isCancelled, let self, let owned = self.slot,
                  owned.phase == .active, owned.attempt.sessionID == sessionID,
                  owned.attempt.generation == generation, owned.attempt.deadline == deadline,
                  owned.attempt.context.lifetime === lifetime else { return }
            self.revoke(controllerID: lifetime.id,
                        reason: lifetime.isValid ? "applicationDeadline" : "controllerLifetimeEnded",
                        generation: generation)
        }
    }

    /// Exactly one Off followed by exactly one Release. Release failure freezes
    /// the complete record. No later path may operate on that numeric ID again.
    private func retire(reason: String) -> Owned? {
        guard var owned = slot, owned.phase == .active || owned.phase == .provisional else { return nil }
        intentRevision = UUID() // Revoke all prepared command intent before calls.
        owned.phase = .retiring
        slot = owned
        expiry?.cancel()
        expiry = nil
        increment(&retireAttempts)
        let t0 = clock.now
        let off = IOPMAssertionSetProperty(owned.id, kIOPMAssertionLevelKey as CFString,
                                          NSNumber(value: kIOPMAssertionLevelOff))
        let offReturn = clock.now
        let release = IOPMAssertionRelease(owned.id)
        let releaseReturn = clock.now
        owned.retirement = Retirement(reason: reason, t0: t0, offReturn: offReturn,
                                      releaseReturn: releaseReturn, off: off, release: release)
        lastRetirement = (owned.attempt, owned.retirement!)
        if release == kIOReturnSuccess { slot = nil }
        else { owned.phase = .quarantined; slot = owned }
        return owned
    }

    private func receipt(_ code: String, requestID: UUID? = nil, purpose: String, origin: String,
                         context: Context? = nil, evidence: Owned? = nil,
                         attemptEvidence: Attempt? = nil,
                         retirements: [LockScreenKeepAwakeRetirementReceipt] = [],
                         intent: String, attempted: Bool = false) -> LockScreenKeepAwakeReceipt {
        let owned = evidence ?? slot
        let attempt = attemptEvidence ?? (code == "API_CREATE_FAILED" ? creationFault : nil) ?? owned?.attempt
        let records = !retirements.isEmpty ? retirements : owned.flatMap { record in
            record.retirement.map { [retirementReceipt(record.attempt, $0)] }
        } ?? []
        let retirement = records.last
        let handleState = creationFault != nil ? "creationUnconfirmed"
            : slot?.phase.rawValue ?? (retirement?.releaseIOReturn == kIOReturnSuccess ? "released" : "idle")
        let effect: String
        if handleState == "creationUnconfirmed" { effect = "Creation failed; output ownership and physical effect are unconfirmed. Relaunch required." }
        else if handleState == "quarantined" {
            effect = retirement?.offIOReturn == kIOReturnSuccess ? "Off accepted; cleanup unconfirmed."
                : "Off and Release failed; may remain awake until the original finite limit."
        } else if handleState == "released" { effect = "Release accepted by API; hardware behavior unverified." }
        else if handleState == "active" { effect = "Create accepted by API; hardware and secure visibility unverified." }
        else { effect = "No new power API attempt for this outcome." }
        return LockScreenKeepAwakeReceipt(requestID: requestID, creationRequestID: attempt?.requestID,
            resultCode: code, origin: origin,
            sessionID: attempt?.sessionID, generation: attempt?.generation, purpose: purpose,
            durationMinutes: context?.minutes ?? attempt?.context.minutes,
            durationSeconds: context?.seconds ?? attempt?.context.seconds,
            assertionType: attempt == nil ? nil : "PreventUserIdleDisplaySleep",
            timeoutAction: attempt == nil ? nil : "TimeoutActionTurnOff",
            contextRevisions: context?.revisions ?? attempt?.context.revisions,
            attemptContinuous: attempt.map { time($0.t0) }, returnContinuous: attempt.map { time($0.t1) },
            applicationDeadline: attempt.map { time($0.deadline) },
            OSDeadlineLowerBound: attempt.map { time($0.deadline) },
            OSDeadlineUpperBound: attempt.map { time($0.upperBound) }, createIOReturn: attempt?.code,
            offIOReturn: retirement?.offIOReturn, releaseIOReturn: retirement?.releaseIOReturn,
            retirementAttemptContinuous: retirement?.attemptContinuous,
            offReturnContinuous: retirement?.offReturnContinuous,
            releaseReturnContinuous: retirement?.releaseReturnContinuous, retirementReason: retirement?.reason,
            retirements: records,
            intentState: intent, handleState: handleState, effectEvidence: effect,
            createAttemptCount: createAttempts, retireAttemptCount: retireAttempts, apiAttempted: attempted)
    }

    private func retirementReceipt(_ attempt: Attempt, _ retirement: Retirement) -> LockScreenKeepAwakeRetirementReceipt {
        LockScreenKeepAwakeRetirementReceipt(sessionID: attempt.sessionID, generation: attempt.generation,
            reason: retirement.reason, attemptContinuous: time(retirement.t0),
            offReturnContinuous: time(retirement.offReturn), releaseReturnContinuous: time(retirement.releaseReturn),
            offIOReturn: retirement.off, releaseIOReturn: retirement.release)
    }

    private func cache(_ outcome: LockScreenKeepAwakeReceipt, requestID: UUID? = nil,
                       payload: Payload? = nil, publish: Bool = true) {
        lastOutcome = outcome
        if let requestID, let payload { replay = Replay(id: requestID, payload: payload, outcome: outcome) }
        if publish { status.publish(projection()) }
    }

    /// Pure local read. No cleanup, context mint, publication or power query.
    func projection() -> LockScreenKeepAwakeProjection {
        var value = LockScreenKeepAwakeProjection()
        value.lastOutcome = lastOutcome
        value.createAttemptCount = createAttempts
        value.retireAttemptCount = retireAttempts
        if let fault = creationFault {
            value.handleState = "creationUnconfirmed"
            value.message = "Couldn’t start Keep Awake. Quit OpenCove and try again."
            value.finiteUpperBoundPassed = clock.now >= fault.upperBound
        } else if let owned = slot {
            value.handleState = owned.phase.rawValue
            value.sessionID = owned.attempt.sessionID
            value.durationMinutes = owned.attempt.context.minutes
            value.expectedEnd = owned.attempt.expectedEnd
            value.applicationDeadlinePassed = clock.now >= owned.attempt.deadline
            value.finiteUpperBoundPassed = clock.now >= owned.attempt.upperBound
            if owned.phase == .quarantined {
                if value.finiteUpperBoundPassed { value.message = "Time limit reached; cleanup unconfirmed. Quit OpenCove before starting again." }
                else if owned.retirement?.off == kIOReturnSuccess {
                    value.message = "Ending was accepted, but cleanup could not finish. Quit OpenCove before starting again."
                } else {
                    value.message = "Couldn’t confirm Keep Awake ended. It may stay on until this session’s time limit. Quit OpenCove before starting again."
                }
            } else { value.message = value.applicationDeadlinePassed ? "Time limit reached; ending is pending." : "Keep Awake · \(owned.attempt.context.minutes) min session" }
        } else if lastOutcome?.handleState == "released" { value.message = "Keep Awake ended. Release was accepted." }
        return value
    }
}
