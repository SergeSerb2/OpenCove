// SPDX-License-Identifier: MIT
import AppKit
import Combine
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

    private let store: CoveStore
    private var panels: [CGDirectDisplayID: CoveLockPanel] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var observations: [(NotificationCenter, NSObjectProtocol)] = []
    private var started = false
    private var screensAsleep = false
    private var sessionActive = false

    init(store: CoveStore, layout: Layout = Layout()) {
        self.store = store
        self.layout = layout
    }

    deinit {
        for (center, token) in observations { center.removeObserver(token) }
        let windows = Array(panels.values)
        DispatchQueue.main.async {
            for window in windows {
                window.orderOut(nil)
                window.contentView = nil
                window.close()
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        screensAsleep = false
        sessionActive = currentSessionIsActive()

        // Published emits before its stored property changes. Use both incoming
        // values directly so unlock, unknown state, and opt-out retire panels
        // synchronously, rather than waiting for the next main-run-loop turn.
        store.$preferences.combineLatest(store.system.$state)
            .sink { [weak self] preferences, state in
                self?.reconcile(preferences: preferences, state: state)
            }
            .store(in: &subscriptions)

        observe(NSApplication.didChangeScreenParametersNotification) { $0.refreshLayout() }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSWorkspace.activeSpaceDidChangeNotification, center: workspace) { $0.refreshLayout() }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observe(name, center: workspace) { controller in
                controller.screensAsleep = true
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
        subscriptions.removeAll()
        for (center, token) in observations { center.removeObserver(token) }
        observations.removeAll()
        removePanels()
    }

    func refreshLayout() {
        reconcile(preferences: store.preferences, state: store.system.state)
    }

    private func reconcile(preferences: CovePreferences, state: SystemState) {
        guard started, sessionActive, currentSessionIsActive(), !screensAsleep,
              preferences.enablePrivateAPIs, preferences.showOnLockScreen,
              state.lockStateKnown, state.isLocked,
              preferences.enableMedia || preferences.enableCalendar || preferences.enableWeather
                || preferences.enableBattery || preferences.enableFocus || preferences.enableBluetooth else {
            removePanels()
            return
        }

        let screens = selectedScreens(preferences: preferences)
        let selectedIDs = Set(screens.map(\.id))
        for id in Array(panels.keys) where !selectedIDs.contains(id) {
            removePanel(id)
        }
        for (id, screen) in screens {
            guard let frame = widgetFrame(on: screen) else {
                removePanel(id)
                continue
            }
            let panel = panels[id] ?? makePanel()
            panels[id] = panel
            panel.setFrame(frame, display: true)
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }

    private func currentSessionIsActive() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool,
              let loginDone = session[kCGSessionLoginDoneKey as String] as? Bool else { return false }
        return onConsole && loginDone
    }

    private func makePanel() -> CoveLockPanel {
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
        let hosting = CoveLockHostingView(rootView: LockScreenView(store: store, weather: store.weather))
        // The controller owns the bounded authentication-safe frame. Content
        // must scroll within it rather than raise the native window minimum.
        hosting.sizingOptions = []
        panel.contentView = hosting
        return panel
    }

    private func selectedScreens(preferences: CovePreferences) -> [(id: CGDirectDisplayID, screen: NSScreen)] {
        let screens: [(id: CGDirectDisplayID, screen: NSScreen)] = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = number.uint32Value
            guard CGDisplayIsOnline(id) != 0, CGDisplayIsActive(id) != 0, CGDisplayIsAsleep(id) == 0 else { return nil }
            return (id, screen)
        }
        if preferences.showOnAllDisplays { return screens }
        if preferences.preferBuiltInDisplay,
           let builtIn = screens.first(where: { CGDisplayIsBuiltin($0.id) != 0 }) { return [builtIn] }
        if let main = NSScreen.main, let match = screens.first(where: { $0.screen == main }) { return [match] }
        return Array(screens.prefix(1))
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

    private func removePanel(_ id: CGDirectDisplayID) {
        guard let panel = panels.removeValue(forKey: id) else { return }
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
    }

    private func removePanels() {
        for id in Array(panels.keys) { removePanel(id) }
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
