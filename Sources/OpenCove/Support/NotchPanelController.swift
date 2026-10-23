import AppKit
import Combine
import CoreGraphics
import QuartzCore
import SwiftUI

/// Owns ordinary app panels only. Even with showOnLockScreen enabled, a status-bar
/// level window cannot inject content into macOS's secure login/lock-screen UI.
@MainActor
final class NotchPanelController: NSObject {
    private let store: CoveStore
    private var surfaces: [CGDirectDisplayID: CovePanelSurface] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var observations: [(NotificationCenter, NSObjectProtocol)] = []
    private var hoveredDisplays = Set<CGDirectDisplayID>()
    private var hoverTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var layoutTask: Task<Void, Never>?
    private var lastPreferences: CovePreferences?
    private var started = false
    private var screensAsleep = false
    private var sessionActive = false
    private var menuTrackingDepth = 0
    private var lifecycleRevision: UInt = 0
    private var acceptingMiddleClick = false
    struct InputAcceptanceError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private struct LayoutInputs: Equatable {
        var preferences: CovePreferences
        var expanded: Bool
        var tab: CoveTab
        var hud: HUDKind?
        var media: Bool
        var compactActivity: CoveCompactActivity
        var mediaPeek: Bool
        var timer: Bool
        var event: Bool
    }
    private var lastLayoutInputs: LayoutInputs?
    private var layoutInputs: LayoutInputs {
        LayoutInputs(preferences: store.preferences, expanded: store.isExpanded, tab: store.selectedTab,
                     hud: store.hud?.kind,
                     media: store.isCompactActivityVisible(.media),
                     compactActivity: store.compactActivity,
                     mediaPeek: store.showsMediaPeek,
                     timer: store.isCompactActivityVisible(.timer), event: store.isCompactActivityVisible(.calendar))
    }

    init(store: CoveStore) {
        self.store = store
        super.init()
    }

    deinit {
        hoverTask?.cancel()
        collapseTask?.cancel()
        layoutTask?.cancel()
        for (center, token) in observations { center.removeObserver(token) }
        // NSWindow can outlive its owner while ordered in. Explicitly retire it.
        let windows = surfaces.values.map(\.panel)
        DispatchQueue.main.async {
            for window in windows {
                window.onEvent = nil
                if let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .cancel)
                    sheet.orderOut(nil)
                }
                window.orderOut(nil)
                window.contentView = nil
                window.close()
            }
        }
    }

    func start() {
        guard !started else { return }
        lifecycleRevision &+= 1
        started = true
        screensAsleep = false
        sessionActive = currentSessionIsActive()
        lastPreferences = store.preferences

        // Coalesce will-change notifications into one main-actor job. Read the
        // committed values there, without a second run-loop hop before motion.
        for publisher in [store.objectWillChange, store.media.objectWillChange,
                          store.system.objectWillChange, store.activities.objectWillChange] {
            publisher.sink { [weak self] _ in
                self?.scheduleLayout()
            }.store(in: &subscriptions)
        }
        // Retire private content on the incoming lock value, before @Published
        // commits it or a deferred geometry refresh can run.
        store.system.$state.sink { [weak self] state in
            guard let self, self.started else { return }
            if state.isLocked { self.hideForSessionBoundary() }
        }.store(in: &subscriptions)

        observe(NSApplication.didChangeScreenParametersNotification) { $0.refreshLayout() }
        observe(NSApplication.didBecomeActiveNotification) { $0.refreshLayout() }
        for name in [NSWindow.didResignKeyNotification, NSControl.textDidEndEditingNotification, NSText.didEndEditingNotification] {
            observe(name) { controller in
                if controller.hoveredDisplays.isEmpty { controller.scheduleCollapse() }
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSWorkspace.activeSpaceDidChangeNotification, center: workspace) { $0.refreshLayout() }
        observe(NSWorkspace.didActivateApplicationNotification, center: workspace) { $0.refreshLayout() }
        observe(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, center: workspace) { $0.refreshLayout() }
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            observe(name, center: workspace) { controller in
                controller.screensAsleep = true
                controller.hideForSessionBoundary()
            }
        }
        observe(NSWorkspace.sessionDidResignActiveNotification, center: workspace) { controller in
            controller.sessionActive = false
            controller.hideForSessionBoundary()
        }
        observe(NSWorkspace.sessionDidBecomeActiveNotification, center: workspace) { controller in
            controller.sessionActive = controller.currentSessionIsActive()
            controller.refreshLayout()
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            observe(name, center: workspace) { controller in
                controller.screensAsleep = false
                controller.refreshLayout()
            }
        }
        refreshLayout()
    }

    func stop() {
        guard started else { return }
        started = false
        sessionActive = false
        lifecycleRevision &+= 1
        cancelHoverWork()
        layoutTask?.cancel()
        layoutTask = nil
        subscriptions.removeAll()
        for (center, token) in observations { center.removeObserver(token) }
        observations.removeAll()
        for surface in surfaces.values { retire(surface) }
        surfaces.removeAll()
        hoveredDisplays.removeAll()
        lastPreferences = nil
        lastLayoutInputs = nil
    }

    func refreshLayout() {
        guard started else { return }
        layoutTask?.cancel()
        layoutTask = nil
        let preferences = store.preferences
        lastLayoutInputs = layoutInputs
        let preferencesChanged = lastPreferences != preferences
        lastPreferences = preferences

        let selection = CoveDisplays.resolve(preferences)
        store.updateDisplaySelection(selection.state)

        guard !screensAsleep, sessionActive, currentSessionIsActive(), !store.system.state.isLocked else {
            hideForSessionBoundary()
            return
        }

        let screens = selection.screens
        let geometries = screens.map { (id: $0.id, screen: $0.screen, geometry: CovePanelGeometry(screen: $0.screen, preferences: preferences)) }
        let physicalWidth = Double(geometries.map(\.geometry.physicalNotchWidth).max() ?? 0)
        let physicalHeight = Double(geometries.map(\.geometry.physicalNotchHeight).max() ?? 0)
        // A common maximum keeps the shared SwiftUI surface safe on every display.
        // Only publish actual cutouts here; fallback preference sizes are not hardware.
        if store.physicalNotchWidth != physicalWidth { store.physicalNotchWidth = physicalWidth }
        if store.physicalNotchHeight != physicalHeight { store.physicalNotchHeight = physicalHeight }
        let selectedIDs = Set(screens.map(\.id))
        for id in Array(surfaces.keys) where !selectedIDs.contains(id) {
            if let surface = surfaces.removeValue(forKey: id) { retire(surface) }
            hoveredDisplays.remove(id)
        }
        if hoveredDisplays.isEmpty {
            hoverTask?.cancel()
            hoverTask = nil
        }

        let idleHidden = store.hidesCompactWhenIdle
        let fullscreenDisplays = preferences.hideInFullscreen ? fullscreenSizedDisplays(screens) : []
        for (id, screen, geometry) in geometries {
            if fullscreenDisplays.contains(id) {
                if let surface = surfaces.removeValue(forKey: id) { retire(surface) }
                hoveredDisplays.remove(id)
                continue
            }
            let surface = surfaces[id] ?? makeSurface(id: id)
            surfaces[id] = surface
            let cutout = CGSize(width: geometry.physicalNotchWidth, height: geometry.physicalNotchHeight)
            let clearance = CoveNotchCutout.resolve(physical: cutout, preferences: preferences)
            surface.content.updateCutout(cutout, store: store)
            let desiredSize = NotchView.desiredSize(store: store, cutout: cutout)
            let width = max(desiredSize.width, geometry.notchWidth)

            // Keep a transparent, panel-local edge target when idle is hidden.
            // No global mouse monitor, accessibility access, or input tap is used.
            let height = idleHidden ? min(3, geometry.notchHeight) : max(desiredSize.height, geometry.notchHeight)
            // Restore before growing. Retire only after shrinking finishes so
            // content and geometry share the same interruptible transition.
            if !idleHidden { surface.content.hosting.isHidden = false }
            surface.gestureStripHeight = max(32, clearance.height + 40)
            let frame = geometry.frame(width: width, height: height)
            let animate = surface.hasLayout && surface.panel.isVisible
                && surface.screenFrame == screen.frame && surface.scale == geometry.scale
                && !preferences.reduceMotion && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            surface.screenFrame = screen.frame
            surface.scale = geometry.scale
            apply(frame: frame, to: surface, animated: animate, hideContent: idleHidden, preferences: preferences)
            if !surface.panel.isVisible { surface.panel.orderFrontRegardless() }
        }

        if hoveredDisplays.isEmpty {
            hoverTask?.cancel()
            hoverTask = nil
        }

        reconcileHover()
        if preferencesChanged {
            let wasCollapsing = collapseTask != nil
            cancelHoverWork()
            if !hoveredDisplays.isEmpty { scheduleExpansion() }
            else if wasCollapsing { scheduleCollapse() }
        }
        if store.isExpanded {
            hoverTask?.cancel()
            hoverTask = nil
        }
    }

    private func currentSessionIsActive() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool,
              let loginDone = session[kCGSessionLoginDoneKey as String] as? Bool else { return false }
        return onConsole && loginDone
    }

    private func hideForSessionBoundary() {
        cancelHoverWork()
        hoveredDisplays.removeAll()
        for surface in surfaces.values { retire(surface) }
        surfaces.removeAll()
        // Resigning a key panel can synchronously post another collapse request.
        cancelHoverWork()
    }

    private func retire(_ surface: CovePanelSurface) {
        surface.layoutRevision &+= 1
        surface.scroll.reset()
        surface.content.onHover = nil
        surface.panel.onEvent = nil
        if let sheet = surface.panel.attachedSheet {
            surface.panel.endSheet(sheet, returnCode: .cancel)
            sheet.orderOut(nil)
        }
        surface.panel.makeFirstResponder(nil)
        surface.panel.resignKey()
        surface.panel.orderOut(nil)
        surface.panel.contentView = nil
        surface.panel.close()
    }

    /// Public window metadata gives a conservative fullscreen heuristic without
    /// AX or screen capture. A borderless display-sized window is indistinguishable
    /// from fullscreen here; Split View and private space types are not inferred.
    private func fullscreenSizedDisplays(_ screens: [CoveDisplays.Entry]) -> Set<CGDirectDisplayID> {
        guard let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              frontmostPID != ProcessInfo.processInfo.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let frontFrames: [CGRect] = windows.compactMap { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == frontmostPID,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any] else { return nil }
            return CGRect(dictionaryRepresentation: bounds as CFDictionary)
        }
        return Set(screens.compactMap { entry in
            let display = CGDisplayBounds(entry.id)
            return frontFrames.contains { frame in
                abs(frame.minX - display.minX) <= 1 && abs(frame.minY - display.minY) <= 1
                    && abs(frame.width - display.width) <= 1 && abs(frame.height - display.height) <= 1
            } ? entry.id : nil
        })
    }

    private func makeSurface(id: CGDirectDisplayID) -> CovePanelSurface {
        let content = CovePanelTrackingView(store: store)
        let panel = CoveNotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "OpenCove"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        // NotchView draws the black surface; leave its shaped corners transparent.
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.isRestorable = false
        panel.isExcludedFromWindowsMenu = true
        panel.tabbingMode = .disallowed
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.contentView = content
        let surface = CovePanelSurface(panel: panel, content: content)
        content.onHover = { [weak self] inside in self?.setHovered(id: id, inside: inside) }
        panel.onEvent = { [weak self, weak surface] event in
            guard let self, let surface else { return false }
            return self.handle(event, surface: surface)
        }
        return surface
    }

    static func contentIsHidden(in window: NSWindow) -> Bool? {
        (window.contentView as? CovePanelTrackingView)?.hosting.isHidden
    }

    /// Request-scoped native dispatch for the authenticated, opt-in controls.
    /// No global input is posted and no user pointer or focus is moved. Observe
    /// the original window handler synchronously; there is no queued event left
    /// behind after cancellation, timeout, or a later panel lifecycle change.
    func acceptMiddleClick(region: String) throws -> [String: Any] {
        guard ProcessInfo.processInfo.arguments.contains("--control-port"),
              CovePaths.isDevelopment, !acceptingMiddleClick, mayHandleMenuAction else {
            throw InputAcceptanceError(message: "Native input acceptance needs an active development-control launch.")
        }
        let eligible = surfaces.values.filter {
            $0.panel.isVisible && !$0.content.hosting.isHidden && !$0.frameAnimationInFlight
                && $0.panel.attachedSheet == nil && $0.panel.contentView === $0.content
        }
        guard eligible.count == 1, let surface = eligible.first,
              let original = surface.panel.onEvent else {
            throw InputAcceptanceError(message: "Native input acceptance needs exactly one visible, settled owned panel.")
        }
        let bounds = surface.content.bounds
        let y: CGFloat
        switch region {
        case "gestureStrip": y = bounds.maxY - min(bounds.height, surface.gestureStripHeight) / 2
        case "body":
            guard store.isExpanded, bounds.height > surface.gestureStripHeight + 4 else {
                throw InputAcceptanceError(message: "The expanded body is unavailable.")
            }
            y = bounds.minY + (bounds.height - surface.gestureStripHeight) / 2
        default: throw InputAcceptanceError(message: "Choose gestureStrip or body.")
        }
        let point = NSPoint(x: bounds.midX, y: y)
        guard bounds.contains(point), surface.panel.windowNumber > 0,
              let prototype = NSEvent.mouseEvent(with: .otherMouseDown, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: surface.panel.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
              let native = prototype.cgEvent else {
            throw InputAcceptanceError(message: "AppKit could not construct the owned middle-button event.")
        }
        // The AppKit factory has no button-number parameter. Use its public
        // Core Graphics bridge, then require the owned target and local point
        // to survive the conversion before dispatching anything.
        native.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        guard let event = NSEvent(cgEvent: native), event.type == .otherMouseDown,
              event.buttonNumber == 2, event.windowNumber == surface.panel.windowNumber,
              event.locationInWindow == point else {
            throw InputAcceptanceError(message: "The native middle-button conversion did not preserve its owned target.")
        }
        let revision = lifecycleRevision
        acceptingMiddleClick = true
        var receipt: [String: Any]?
        surface.panel.onEvent = { received in
            let handled = original(received)
            if received === event {
                receipt = ["dispatch": "NSApplication.sendEvent", "handlerReceived": true,
                           "buttonNumber": received.buttonNumber, "windowNumber": received.windowNumber,
                           "targetWindowNumber": surface.panel.windowNumber,
                           "pid": ProcessInfo.processInfo.processIdentifier, "region": region,
                           "handled": handled]
            }
            return handled
        }
        defer {
            acceptingMiddleClick = false
            if started, lifecycleRevision == revision, surfaces.values.contains(where: { $0 === surface }) {
                surface.panel.onEvent = original
            }
        }
        NSApp.sendEvent(event)
        guard let receipt else { throw InputAcceptanceError(message: "The owned native window did not receive the event.") }
        return receipt
    }

    private func apply(frame: NSRect, to surface: CovePanelSurface, animated: Bool, hideContent: Bool,
                       preferences: CovePreferences) {
        let duration = animated ? CoveMotion.duration(preferences: preferences, hud: !store.isExpanded && store.hud != nil, kind: store.hud?.kind) : 0
        let wasAnimating = surface.frameAnimationInFlight
        // A replacement HUD or Reduce Motion can change timing without changing
        // the destination. Retarget active motion only when its duration changes.
        guard surface.targetFrame != frame || (wasAnimating && surface.frameAnimationDuration != duration) else { return }
        surface.targetFrame = frame
        surface.hasLayout = true
        surface.layoutRevision &+= 1
        let revision = surface.layoutRevision
        surface.frameAnimationInFlight = duration > 0
        surface.frameAnimationDuration = duration
        if duration > 0 {
            let currentFrame = surface.panel.frame
            let startFrame = CovePanelFrameAnchor(target: frame, screen: surface.screenFrame, scale: surface.scale)
                .startingFrame(from: currentFrame)
            if wasAnimating {
                // Stop the old interpolation at the current size, with its
                // rounded origin corrected before the next animator samples it.
                // The revision already changed, so its completion cannot settle
                // the old target or retire content for the new transition.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    surface.panel.animator().setFrame(startFrame, display: true)
                }
            } else if currentFrame != startFrame {
                surface.panel.setFrame(startFrame, display: true)
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CoveMotion.timingFunction
                // Both endpoints share the target anchor. Leave interpolation
                // to AppKit, with the panel's frame setters inherited unchanged.
                surface.panel.animator().setFrame(frame, display: true)
            } completionHandler: { [weak self, weak surface] in
                Task { @MainActor in
                    guard let self, let surface, surface.layoutRevision == revision, self.started else { return }
                    surface.frameAnimationInFlight = false
                    surface.frameAnimationDuration = 0
                    surface.panel.setFrame(frame, display: true)
                    surface.content.hosting.isHidden = hideContent
                    self.reconcileHover()
                }
            }
        } else {
            if wasAnimating {
                // Replacing the animator's own frame target cancels its pending
                // interpolation. A direct setFrame alone can be overwritten by
                // the next tick of the old animator.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    surface.panel.animator().setFrame(frame, display: true)
                }
            } else {
                surface.panel.setFrame(frame, display: true)
            }
            surface.content.hosting.isHidden = hideContent
        }
    }

    private func scheduleLayout() {
        // Elapsed time, artwork, calendar countdowns, and volume repaint their
        // SwiftUI views directly. They do not require display enumeration or a
        // WindowServer fullscreen query when the panel geometry is unchanged.
        guard started, layoutTask == nil else { return }
        layoutTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            self.layoutTask = nil
            guard self.layoutInputs != self.lastLayoutInputs else { return }
            self.refreshLayout()
        }
    }

    private func observe(_ name: Notification.Name, center: NotificationCenter = .default,
                         action: @escaping @MainActor (NotchPanelController) -> Void) {
        let revision = lifecycleRevision
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.started, self.lifecycleRevision == revision else { return }
                action(self)
            }
        }
        observations.append((center, token))
    }

    private func setHovered(id: CGDirectDisplayID, inside: Bool) {
        guard started, let surface = surfaces[id], surface.panel.isVisible,
              sessionActive, !screensAsleep, !store.system.state.isLocked else { return }
        if inside {
            guard hoveredDisplays.insert(id).inserted else { return }
            collapseTask?.cancel()
            collapseTask = nil
            scheduleExpansion()
        } else {
            guard hoveredDisplays.remove(id) != nil, hoveredDisplays.isEmpty else { return }
            hoverTask?.cancel()
            hoverTask = nil
            scheduleCollapse()
        }
    }

    private func reconcileHover() {
        for (id, surface) in surfaces {
            // This is the panel's own local pointer position, not a global event
            // subscription. It also handles a panel resizing beneath the pointer.
            let inside = surface.panel.isVisible && surface.content.bounds.contains(surface.panel.mouseLocationOutsideOfEventStream)
            setHovered(id: id, inside: inside)
        }
    }

    private func scheduleExpansion() {
        guard hoverTask == nil, !store.isExpanded, store.preferences.expandOnHover, !hoveredDisplays.isEmpty else { return }
        let delay = finite(store.preferences.hoverDelay, fallback: 0.25, range: 0...10)
        hoverTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.hoverTask = nil
            guard self.started, !self.hoveredDisplays.isEmpty,
                  self.store.preferences.expandOnHover, !self.screensAsleep,
                  self.sessionActive, self.currentSessionIsActive(), !self.store.system.state.isLocked else { return }
            self.store.openCompactActivity()
        }
    }

    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
        guard store.isExpanded, hoveredDisplays.isEmpty, menuTrackingDepth == 0 else { return }
        let delay = finite(store.preferences.collapseDelay, fallback: 0.6, range: 0...10)
        collapseTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled, let self, self.started, self.hoveredDisplays.isEmpty, self.menuTrackingDepth == 0 else { return }
            self.collapseTask = nil
            // Do not dismiss a text field or an open sheet while the user edits.
            guard !self.surfaces.values.contains(where: {
                $0.panel.attachedSheet != nil || ($0.panel.isKeyWindow && ($0.panel.firstResponder as? NSTextView)?.isEditable == true)
            }) else { return }
            self.store.collapse()
            for surface in self.surfaces.values where surface.panel.isKeyWindow {
                surface.panel.makeFirstResponder(nil)
                surface.panel.resignKey()
            }
        }
    }

    private func cancelHoverWork() {
        hoverTask?.cancel()
        collapseTask?.cancel()
        hoverTask = nil
        collapseTask = nil
    }

    private func handle(_ event: NSEvent, surface: CovePanelSurface) -> Bool {
        guard started, surface.panel.isVisible, !screensAsleep,
              sessionActive, currentSessionIsActive(), !store.system.state.isLocked else { return false }
        if event.type == .keyDown, event.keyCode == 53 {
            cancelHoverWork()
            store.collapse()
            surface.panel.makeFirstResponder(nil)
            surface.panel.resignKey()
            return true
        }
        let inGestureStrip = !store.isExpanded || event.locationInWindow.y >= surface.panel.frame.height - surface.gestureStripHeight
        guard inGestureStrip else { surface.scroll.reset(); return false }
        switch event.type {
        case .rightMouseDown:
            showContextMenu(event: event, view: surface.content)
            return true
        case .swipe:
            if abs(event.deltaX) > abs(event.deltaY) { changeTab(forward: event.deltaX < 0) }
            else if event.deltaY < 0 { store.expand() }
            else if event.deltaY > 0 { collapseOrDismiss() }
            return true
        case .scrollWheel:
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                surface.scroll.reset()
                return false
            }
            if let gesture = surface.scroll.consume(event) {
                switch gesture {
                case .nextTab: changeTab(forward: true)
                case .previousTab: changeTab(forward: false)
                case .expand: store.expand()
                case .collapse: collapseOrDismiss()
                }
            }
            return true
        default:
            return false
        }
    }

    private var enabledTabs: [CoveTab] { store.enabledTabs }

    private func collapseOrDismiss() {
        cancelHoverWork()
        if store.isExpanded { store.collapse() }
        else if let target = store.compactDismissTarget { store.dismissCompactActivity(target: target) }
    }

    private func changeTab(forward: Bool) {
        let tabs = enabledTabs
        guard !tabs.isEmpty else { return }
        let index = tabs.firstIndex(of: store.selectedTab) ?? (forward ? tabs.count - 1 : 0)
        store.selectTab(tabs[(index + (forward ? 1 : tabs.count - 1)) % tabs.count], expand: true)
    }

    private func showContextMenu(event: NSEvent, view: NSView) {
        cancelHoverWork()
        menuTrackingDepth += 1
        defer {
            menuTrackingDepth -= 1
            reconcileHover()
            if hoveredDisplays.isEmpty { scheduleCollapse() }
        }
        let menu = NSMenu(title: "OpenCove")
        menu.autoenablesItems = false
        let toggle = menu.addItem(withTitle: store.isExpanded ? "Collapse" : "Expand", action: #selector(toggleFromMenu), keyEquivalent: "")
        toggle.target = self
        for tab in enabledTabs {
            let item = menu.addItem(withTitle: tab.title, action: #selector(selectFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tab.rawValue
            item.state = tab == store.selectedTab ? .on : .off
        }
        if let activity = store.compactDismissActivity, let target = store.compactDismissTarget {
            let item = menu.addItem(withTitle: "Dismiss \(activity.title) Activity", action: #selector(dismissFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = target
        }
        if let activity = store.compactRestoreActivity, let target = store.compactRestoreTarget {
            let item = menu.addItem(withTitle: "Restore \(activity.title) Activity", action: #selector(restoreFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = target
        }
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(settingsFromMenu), keyEquivalent: "")
        settings.target = self
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private var mayHandleMenuAction: Bool {
        started && sessionActive && currentSessionIsActive() && !screensAsleep && !store.system.state.isLocked
    }

    @objc private func toggleFromMenu() {
        guard mayHandleMenuAction else { return }
        store.toggleExpanded()
    }
    @objc private func settingsFromMenu() {
        guard mayHandleMenuAction else { return }
        store.openSettings()
    }
    @objc private func dismissFromMenu(_ item: NSMenuItem) {
        guard mayHandleMenuAction, let target = item.representedObject as? String else { return }
        store.dismissCompactActivity(target: target)
    }
    @objc private func restoreFromMenu(_ item: NSMenuItem) {
        guard mayHandleMenuAction, let target = item.representedObject as? String else { return }
        store.restoreCompactActivity(target: target)
    }
    @objc private func selectFromMenu(_ item: NSMenuItem) {
        guard mayHandleMenuAction,
              let raw = item.representedObject as? String, let tab = CoveTab(rawValue: raw),
              enabledTabs.contains(tab) else { return }
        store.selectTab(tab, expand: true)
    }

    private func finite(_ value: Double, fallback: Double, range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value.isFinite ? value : fallback))
    }
}

@MainActor
private final class CoveNotchPanel: NSPanel {
    var onEvent: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if onEvent?(event) == true { return }
        super.sendEvent(event)
    }
}

private struct CovePanelFrameAnchor {
    let target: NSRect
    let screen: NSRect
    let scale: CGFloat

    // Resolve once before a native animation, never on its intermediate frames.
    func startingFrame(from current: NSRect) -> NSRect {
        // Keep settled geometry exactly as resolved by CovePanelGeometry.
        guard current != target else { return target }
        let pixel = 1 / scale
        // Two-pixel width steps retain the target's pixel parity. With the
        // target center fixed, both horizontal edges then stay on pixel bounds.
        let widthStep = 2 * pixel
        let width = min(screen.width, max(pixel,
            target.width + ((current.width - target.width) / widthStep).rounded() * widthStep))
        let height = min(screen.height, max(pixel, (current.height * scale).rounded() / scale))
        // Near a display edge, containment takes precedence over centering an
        // intermediate frame that is wider than the current target.
        let x = min(screen.maxX - width, max(screen.minX, target.midX - width / 2))
        return NSRect(x: x, y: target.maxY - height, width: width, height: height)
    }
}

@MainActor
private final class CovePanelHostingView: NSHostingView<AnyView> {
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class CovePanelTrackingView: NSView {
    let hosting: CovePanelHostingView
    var onHover: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?
    private var cutout: CGSize?

    init(store: CoveStore) {
        hosting = CovePanelHostingView(rootView: AnyView(
            NotchView(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .preferredColorScheme(.dark)
                .ignoresSafeArea()
        ))
        super.init(frame: .zero)
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }

    func updateCutout(_ value: CGSize, store: CoveStore) {
        guard cutout != value else { return }
        cutout = value
        hosting.rootView = AnyView(NotchView(store: store, cutout: value)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .preferredColorScheme(.dark).ignoresSafeArea())
    }

    required init?(coder: NSCoder) { nil }
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if hoverArea == nil {
            let area = NSTrackingArea(rect: .zero,
                                      options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .enabledDuringMouseDrag],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            hoverArea = area
        }
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseMoved(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

@MainActor
private final class CovePanelSurface {
    let panel: CoveNotchPanel
    let content: CovePanelTrackingView
    var hasLayout = false
    var targetFrame: NSRect?
    var screenFrame = NSRect.zero
    var scale: CGFloat = 1
    var layoutRevision: UInt = 0
    var frameAnimationInFlight = false
    var frameAnimationDuration: TimeInterval = 0
    var gestureStripHeight: CGFloat = 32
    var scroll = CovePanelScroll()

    init(panel: CoveNotchPanel, content: CovePanelTrackingView) {
        self.panel = panel
        self.content = content
    }
}

@MainActor
private struct CovePanelGeometry {
    let screenFrame: NSRect
    let scale: CGFloat
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let physicalNotchWidth: CGFloat
    let physicalNotchHeight: CGFloat
    let isAttached: Bool
    let centerX: CGFloat

    init(screen: NSScreen, preferences: CovePreferences) {
        screenFrame = screen.frame
        scale = max(1, screen.backingScaleFactor)
        let top = screen.safeAreaInsets.top
        let left = screen.auxiliaryTopLeftArea ?? .zero
        let right = screen.auxiliaryTopRightArea ?? .zero
        let gap = screen.frame.width - left.width - right.width
        let hasCutout = top > 0 && left.width > 0 && right.width > 0 && gap > 0 && gap < screen.frame.width
        let fallbackWidth = preferences.notchWidth.isFinite ? max(80, preferences.notchWidth) : 190
        let fallbackHeight = preferences.notchHeight.isFinite ? max(16, preferences.notchHeight) : 32
        notchWidth = hasCutout ? gap : fallbackWidth
        notchHeight = top > 0 ? top : fallbackHeight
        physicalNotchWidth = hasCutout ? gap : 0
        physicalNotchHeight = hasCutout ? top : 0
        isAttached = hasCutout || preferences.simulateNotch
        // Auxiliary area widths are in points, just like NSScreen.frame. Add the
        // screen origin explicitly; secondary screens may have negative origins.
        centerX = hasCutout ? screen.frame.minX + left.width + gap / 2 : screen.frame.midX
    }

    func frame(width: CGFloat, height: CGFloat) -> NSRect {
        let width = min(screenFrame.width, ceil((width.isFinite ? max(1, width) : notchWidth) * scale) / scale)
        let height = min(screenFrame.height, ceil((height.isFinite ? max(1, height) : notchHeight) * scale) / scale)
        let x = ((centerX - width / 2) * scale).rounded() / scale
        let alignedX = min(screenFrame.maxX - width, max(screenFrame.minX, x))
        // Automatic notchless presentation floats; simulation attaches at the
        // display edge. This never changes reported physical camera dimensions.
        let top = ((screenFrame.maxY - (isAttached ? 0 : 6)) * scale).rounded() / scale
        return NSRect(x: alignedX, y: top - height, width: width, height: height)
    }
}

private struct CovePanelScroll {
    enum Gesture { case nextTab, previousTab, expand, collapse }
    private var x: CGFloat = 0
    private var y: CGFloat = 0
    private var lastTime: TimeInterval = 0
    private var triggered = false

    mutating func reset() {
        x = 0
        y = 0
        lastTime = 0
        triggered = false
    }

    mutating func consume(_ event: NSEvent) -> Gesture? {
        if event.phase.contains(.cancelled) || event.phase.contains(.ended) {
            x = 0
            y = 0
            triggered = true
            return nil
        }
        // Momentum must not switch another tab or reopen a just-collapsed panel.
        guard event.momentumPhase.isEmpty else { return nil }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) || event.timestamp - lastTime > 0.3 {
            x = 0
            y = 0
            triggered = false
        }
        lastTime = event.timestamp
        guard !event.phase.contains(.cancelled), !triggered else { return nil }
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        x += event.scrollingDeltaX * multiplier
        y += event.scrollingDeltaY * multiplier
        if abs(x) >= 28 && abs(x) > abs(y) * 1.25 {
            triggered = true
            return x < 0 ? .nextTab : .previousTab
        }
        if abs(y) >= 20 && abs(y) > abs(x) * 1.25 {
            triggered = true
            return y < 0 ? .expand : .collapse
        }
        return nil
    }
}
