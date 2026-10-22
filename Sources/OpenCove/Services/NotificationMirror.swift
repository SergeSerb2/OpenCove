// SPDX-License-Identifier: MIT
import AppKit
import ApplicationServices
import Combine

/// Opt-in, read-only access to newly created Notification Center banner windows.
/// The parent owns consent, presentation, and the lifetime of delivered text.
@MainActor
final class NotificationMirror: ObservableObject {
    @Published private(set) var status: String = "Notification mirroring is off."
    /// True only after this process has exposed a readable banner in this session.
    @Published private(set) var available: Bool = false
    var onNotification: ((String, String) -> Void)?
    var onCollectionStopped: (() -> Void)?
    /// The owner must confirm consent and session state before every AX read.
    var canCollect: () -> Bool = { false }

    private var enabled = false
    private var observations: [pid_t: NotificationMirrorObservation] = [:]
    private var failures: [pid_t: (retryAfter: TimeInterval, error: AXError)] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []
    private var heartbeat: Timer?
    private var pending: [UUID: Task<Void, Never>] = [:]
    // Hasher uses a process-random seed. No notification text is kept here.
    private var recent: [Int: TimeInterval] = [:]

    // Construction has no permission checks, observers, timers, or other effects.
    func start(enabled: Bool) {
        guard enabled else { stop(); return }
        guard !self.enabled else { reconcile(); return }
        self.enabled = true

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.reconcile() }
            })
        }
        // This checks permission and process lifetime only. It never polls content.
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcile() }
        }
        heartbeat = timer
        RunLoop.main.add(timer, forMode: .common)
        reconcile()
    }

    func stop() {
        enabled = false
        heartbeat?.invalidate()
        heartbeat = nil
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.forEach { center.removeObserver($0) }
        workspaceTokens.removeAll()
        clearObservations()
        status = "Notification mirroring is off."
    }

    /// Call only from an explicit user action, such as a Grant Access button.
    /// Granting permission does not opt the user into mirroring.
    func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if enabled {
            reconcile()
        } else {
            status = trusted
                ? "Accessibility access is granted. Notification mirroring is off."
                : "Notification mirroring is off. Allow Accessibility access in System Settings if desired."
        }
    }

    deinit {
        heartbeat?.invalidate()
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.forEach { center.removeObserver($0) }
        pending.values.forEach { $0.cancel() }
        // Observation resources tear down their run-loop sources on the main queue.
    }

    private func clearObservations() {
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        observations.values.forEach { $0.invalidate() }
        observations.removeAll()
        failures.removeAll()
        recent.removeAll()
        available = false
        onCollectionStopped?()
    }

    private func reconcile() {
        guard enabled else { return }
        guard canCollect() else { stop(); return }
        guard AXIsProcessTrusted() else {
            clearObservations()
            status = "Accessibility access is required. Use the access button to request it."
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        recent = recent.filter { now - $0.value < 12 }
        let applications = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && Self.isNotificationCenter($0)
        }.prefix(4)
        let pids = Set(applications.map(\.processIdentifier))
        for pid in Array(observations.keys) where !pids.contains(pid) || observations[pid]?.application.isTerminated == true {
            if let observation = observations.removeValue(forKey: pid) {
                for id in observation.pendingIDs { pending.removeValue(forKey: id)?.cancel() }
                observation.invalidate()
            }
        }
        failures = failures.filter { pids.contains($0.key) }

        for application in applications {
            let pid = application.processIdentifier
            guard observations[pid] == nil, now >= (failures[pid]?.retryAfter ?? 0) else { continue }
            attach(to: application, now: now)
        }
        updateStatus()
    }

    private static func isNotificationCenter(_ application: NSRunningApplication) -> Bool {
        if application.bundleIdentifier?.lowercased() == "com.apple.notificationcenterui" { return true }
        // Also cover system versions with another or missing bundle ID.
        // Do not match arbitrary apps by their localized display title.
        guard let url = application.executableURL else { return false }
        return url.path.hasPrefix("/System/Library/") && ["NotificationCenter", "NotificationCenterUI"].contains(url.lastPathComponent)
    }

    private func attach(to application: NSRunningApplication, now: TimeInterval) {
        let observation = NotificationMirrorObservation(application: application, owner: self)
        var observer: AXObserver?
        var error = AXObserverCreate(application.processIdentifier, notificationMirrorAXCallback, &observer)
        guard error == .success, let observer else {
            failures[application.processIdentifier] = (now + 15, error)
            return
        }
        observation.observer = observer
        AXUIElementSetMessagingTimeout(observation.element, 0.1)

        // Remember existing window identities without reading their text. Do not replay them.
        var windows: CFArray?
        if AXUIElementCopyAttributeValues(observation.element, kAXWindowsAttribute as CFString, 0, 64, &windows) == .success,
           let windows = windows as? [AXUIElement] {
            observation.seenWindows = windows
        }

        let context = Unmanaged.passUnretained(observation.context).toOpaque()
        for name in [kAXWindowCreatedNotification, kAXCreatedNotification] {
            error = AXObserverAddNotification(observer, observation.element, name as CFString, context)
            if error == .success {
                observation.names.append(name as CFString)
            }
        }
        guard !observation.names.isEmpty else {
            failures[application.processIdentifier] = (now + 30, error)
            observation.invalidate()
            return
        }
        observations[application.processIdentifier] = observation
        failures.removeValue(forKey: application.processIdentifier)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func updateStatus() {
        available = observations.values.contains { $0.readableBannerSeen }
        if available {
            status = "Mirroring readable notification banners (best effort)."
        } else if observations.values.contains(where: { $0.creationEventSeen }) {
            status = "AX window events arrived, but no readable banner was exposed. Mirroring is unconfirmed."
        } else if !observations.isEmpty {
            status = "AX observer attached; waiting for a readable banner. macOS support is unconfirmed."
        } else if let failure = failures.values.first {
            status = "Notification Center AX creation events are unavailable (AX error \(failure.error.rawValue)). Retrying."
        } else {
            status = "Waiting for the Notification Center process."
        }
    }

    fileprivate func receive(_ window: AXUIElement, context: NotificationMirrorContext) {
        guard enabled, let observation = observations[context.pid], observation.context === context else { return }
        guard canCollect() else { stop(); return }
        guard AXIsProcessTrusted() else { reconcile(); return }
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success, pid == context.pid else { return }
        AXUIElementSetMessagingTimeout(window, 0.04)
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) == .success,
              role as? String == kAXWindowRole else { return }
        // AXCreated also fires for child controls. Only new window objects qualify.
        guard !observation.seenWindows.contains(where: { CFEqual($0, window) }) else { return }
        observation.seenWindows.append(window)
        if observation.seenWindows.count > 128 { observation.seenWindows.removeFirst() }
        observation.creationEventSeen = true
        updateStatus()
        guard enabled, observations[context.pid] === observation, pending.count < 4 else { return }

        let id = UUID()
        observation.pendingIDs.insert(id)
        pending[id] = Task { @MainActor [weak self, weak observation] in
            defer {
                self?.pending.removeValue(forKey: id)
                observation?.pendingIDs.remove(id)
            }
            // Banner content may not exist at window creation. Retry a bounded number
            // of times, keeping window references rather than notification text.
            for delay in [0.12, 0.3, 0.6] {
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
                guard let self, let observation, !Task.isCancelled,
                      self.enabled, self.observations[context.pid] === observation else { break }
                guard self.canCollect() else { self.stop(); return }
                guard AXIsProcessTrusted() else { self.reconcile(); return }
                var reader = NotificationMirrorReader()
                if let text = reader.bannerText(in: window) {
                    observation.readableBannerSeen = true
                    self.updateStatus()
                    self.deliver(title: text.title, body: text.body, observation: observation)
                    break
                }
            }
        }
    }

    private func deliver(title: String, body: String, observation: NotificationMirrorObservation) {
        guard enabled, observations[observation.context.pid] === observation, canCollect(), AXIsProcessTrusted() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        recent = recent.filter { now - $0.value < 12 }
        var hash = Hasher()
        hash.combine(title)
        hash.combine(body)
        let fingerprint = hash.finalize()
        guard recent[fingerprint] == nil else { return }
        if recent.count >= 128, let oldest = recent.min(by: { $0.value < $1.value })?.key {
            recent.removeValue(forKey: oldest)
        }
        recent[fingerprint] = now
        onNotification?(title, body)
    }
}

private final class NotificationMirrorContext {
    weak var owner: NotificationMirror?
    let pid: pid_t

    init(owner: NotificationMirror, pid: pid_t) {
        self.owner = owner
        self.pid = pid
    }
}

// This source is installed only on the main run loop. The context is owned by
// the observation until its source has been removed on the same queue.
private func notificationMirrorAXCallback(_ observer: AXObserver, _ element: AXUIElement, _ name: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let context = Unmanaged<NotificationMirrorContext>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { context.owner?.receive(element, context: context) }
}

private final class NotificationMirrorObservation {
    let application: NSRunningApplication
    let element: AXUIElement
    let context: NotificationMirrorContext
    var observer: AXObserver?
    var names: [CFString] = []
    var seenWindows: [AXUIElement] = []
    var pendingIDs: Set<UUID> = []
    var creationEventSeen = false
    var readableBannerSeen = false

    init(application: NSRunningApplication, owner: NotificationMirror) {
        self.application = application
        element = AXUIElementCreateApplication(application.processIdentifier)
        context = NotificationMirrorContext(owner: owner, pid: application.processIdentifier)
    }

    /// Called by the service on the main actor, before dropping the context.
    func invalidate() {
        context.owner = nil
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        for name in names { AXObserverRemoveNotification(observer, element, name) }
        self.observer = nil
        names.removeAll()
        seenWindows.removeAll()
    }

    deinit {
        // A caller can release the service without stop(). Retain the callback
        // context until source removal, even if destruction occurs off the main queue.
        guard let observer else { return }
        let element = element
        let names = names
        let context = context
        DispatchQueue.main.async {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            for name in names { AXObserverRemoveNotification(observer, element, name) }
            withExtendedLifetime(context) {}
        }
    }
}

/// An AX read can fail, time out, or return a partial tree. None is a notification.
private struct NotificationMirrorReader {
    private var remainingNodes = 96
    private var remainingReads = 256
    private let deadline = ProcessInfo.processInfo.systemUptime + 0.15

    mutating func bannerText(in window: AXUIElement) -> (title: String, body: String)? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited: [AXUIElement] = []
        while !queue.isEmpty, canRead, remainingNodes > 0 {
            let (element, depth) = queue.removeFirst()
            guard !visited.contains(where: { CFEqual($0, element) }) else { continue }
            visited.append(element)
            remainingNodes -= 1
            AXUIElementSetMessagingTimeout(element, 0.04)
            // This system-owned subrole is a conservative compatibility heuristic,
            // not a documented Apple banner API. Never treat arbitrary window text
            // (for example widgets or the history panel) as a notification.
            if string(element, kAXSubroleAttribute) == "AXNotificationCenterBanner" {
                return text(in: element, depth: depth)
            }
            if depth < 6 { queue += children(element).map { ($0, depth + 1) } }
        }
        return nil
    }

    private mutating func text(in banner: AXUIElement, depth: Int) -> (title: String, body: String)? {
        var queue: [(AXUIElement, Int)] = [(banner, depth)]
        var visited: [AXUIElement] = []
        var labels: [String] = []
        while !queue.isEmpty, canRead, remainingNodes > 0, labels.count < 16 {
            let (element, depth) = queue.removeFirst()
            guard !visited.contains(where: { CFEqual($0, element) }) else { continue }
            visited.append(element)
            remainingNodes -= 1
            AXUIElementSetMessagingTimeout(element, 0.04)
            let role = string(element, kAXRoleAttribute)
            if role == kAXStaticTextRole {
                // AXValue is read only for static text, never input fields.
                for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                    if let label = string(element, attribute), !label.isEmpty {
                        if !labels.contains(label) { labels.append(label) }
                        break
                    }
                }
            }
            // Do not descend into buttons, editors, menus, or other action controls.
            if depth < 6, [kAXGroupRole, kAXWindowRole, kAXScrollAreaRole, kAXLayoutAreaRole].contains(role ?? "") {
                queue += children(element).map { ($0, depth + 1) }
            }
        }
        if labels.isEmpty {
            for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
                if let label = string(banner, attribute), !label.isEmpty {
                    labels.append(label)
                    break
                }
            }
        }
        guard let first = labels.first else { return nil }
        return (String(first.prefix(256)), String(labels.dropFirst().joined(separator: "\n").prefix(2048)))
    }

    private var canRead: Bool {
        remainingReads > 0 && ProcessInfo.processInfo.systemUptime < deadline
    }

    private mutating func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard canRead else { return nil }
        remainingReads -= 1
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value = value as? String else { return nil }
        // Drop empty labels and cap output. Never log or retain the full AX value.
        return String(value.prefix(512)).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private mutating func children(_ element: AXUIElement) -> [AXUIElement] {
        guard canRead, remainingNodes > 0 else { return [] }
        remainingReads -= 1
        var value: CFArray?
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, min(16, remainingNodes), &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }
}
