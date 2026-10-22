import AppKit
import SwiftUI

@main
enum OpenCoveApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = OpenCoveDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class OpenCoveDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var store: CoveStore!
    private var notch: NotchPanelController?
    private var lockWidgets: LockScreenController?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var control: DevelopmentServer?
    private var instanceLock: InstanceLock?
    private var readyForIncomingURLs = false
    private var startupFailed = false
    private var pendingURLs: [URL] = []
    private var pendingURLOverflow = false
    private let incomingURLLimit = 20

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { instanceLock = try InstanceLock(directory: CovePaths.dataDirectory) }
        catch {
            startupFailed = true
            pendingURLs.removeAll()
            pendingURLOverflow = false
            reportStartupFailure(error)
            NSApp.terminate(nil)
            return
        }
        store = CoveStore()
        store.onOpenSettings = { [weak self] in self?.showSettings() }
        store.onPreferencesChange = { [weak self] in self?.notch?.refreshLayout(); self?.lockWidgets?.refreshLayout() }
        configureStatusItem()
        store.start()
        notch = NotchPanelController(store: store)
        notch?.start()
        lockWidgets = LockScreenController(store: store)
        lockWidgets?.start()
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--control-port") {
            let valueIndex = index + 1
            let port = arguments.indices.contains(valueIndex) ? UInt16(arguments[valueIndex]) ?? 0 : 0
            control = DevelopmentServer(store: store, port: port)
            do { try control?.start() } catch {
                control?.reportFailure(error)
            }
        }
        // AppKit may deliver an initial URL event before finish-launch. Services
        // and their callbacks must exist before either cold or warm URLs run.
        readyForIncomingURLs = true
        let incoming = pendingURLs
        let overflow = pendingURLOverflow
        pendingURLs.removeAll()
        pendingURLOverflow = false
        handleIncomingURLs(incoming, overflow: overflow)
        if !store.preferences.completedOnboarding && !arguments.contains("--no-onboarding") { showSettings() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        startupFailed = true
        readyForIncomingURLs = false
        pendingURLs.removeAll()
        pendingURLOverflow = false
        control?.stop()
        notch?.stop()
        lockWidgets?.stop()
        store?.stop()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !startupFailed else { return }
        guard readyForIncomingURLs else {
            let remaining = incomingURLLimit - pendingURLs.count
            pendingURLs.append(contentsOf: urls.prefix(remaining))
            pendingURLOverflow = pendingURLOverflow || urls.count > remaining
            return
        }
        handleIncomingURLs(urls)
    }

    private func handleIncomingURLs(_ urls: [URL], overflow: Bool = false) {
        guard readyForIncomingURLs, let store else { return }
        let incoming = Array(urls.prefix(incomingURLLimit))
        let files = incoming.filter(\.isFileURL)
        if !files.isEmpty {
            if store.preferences.enableFileTray {
                store.activities.addFiles(files)
                store.selectTab(.files, expand: true)
            } else {
                store.activities.lastError = "The file tray is off. Enable File tray in Activities settings, then add the files again."
                store.openSettings()
            }
        }
        var rejected = false
        for url in incoming where !url.isFileURL {
            if !store.activities.handleIncomingURL(url) {
                if store.activities.lastError == nil {
                    store.activities.lastError = "This link is not a supported OpenCove notification URL."
                }
                rejected = true
            }
        }
        if overflow || urls.count > incoming.count {
            store.activities.lastError = "OpenCove accepts up to 20 files or links at once. Add the remaining items in a separate action."
            rejected = true
        }
        if rejected { store.openSettings() }
    }

    private func reportStartupFailure(_ error: Error) {
        let failure = error as NSError
        let reason: String
        let recovery: String
        if let configuration = CovePaths.dataDirectoryConfigurationError {
            reason = configuration
            recovery = "Set OPENCOVE_DATA_DIR to a new absolute private directory, or remove that override."
        } else if failure.domain == NSCocoaErrorDomain, failure.code == CocoaError.fileLocking.rawValue {
            reason = "The data-directory lock could not be acquired. Another instance may be using this directory."
            recovery = "Quit the other copy using this directory, or select a different private data directory."
        } else {
            reason = "The data directory or its lock could not be opened safely."
            recovery = "Check its owner, permissions, and file type, or select a new private data directory. OpenCove did not change existing permissions."
        }
        let directoryDetail = CovePaths.dataDirectoryConfigurationError == nil
            ? "Data directory: \(CovePaths.dataDirectory.path)" : "No data directory was opened."
        let detail = "\(reason)\n\(failure.localizedDescription) (\(failure.domain) \(failure.code))\n\(directoryDetail)\n\(recovery)"
        fputs("OpenCove could not start.\n\(detail)\n", stderr)

        // Ordinary installed-app launches need a visible failure too. Explicit
        // developer and unattended launches must exit without a modal dialog.
        let arguments = ProcessInfo.processInfo.arguments
        guard !CovePaths.isDevelopment, !arguments.contains("--no-onboarding"),
              !arguments.contains("--control-port"), Bundle.main.bundleURL.pathExtension == "app" else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "OpenCove could not start"
        alert.informativeText = detail
        alert.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.tophalf.filled", accessibilityDescription: "OpenCove")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open OpenCove", action: #selector(toggleNotch), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(settingsAction), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Refresh Activities", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit OpenCove", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleNotch() { store.toggleExpanded() }
    @objc private func settingsAction() { store.openSettings() }
    @objc private func refresh() { store.media.refresh(); store.system.refresh(); store.activities.refreshCalendar() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func showSettings() {
        store.settingsVisible = true
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let content = OpenCoveSettingsRoot(store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 580), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "OpenCove"
        window.identifier = NSUserInterfaceItemIdentifier("OpenCove.Settings")
        window.contentView = NSHostingView(rootView: content)
        window.contentMinSize = NSSize(width: 700, height: 500)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
        store.settingsVisible = true
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        store.settingsVisible = false
    }
}

private struct OpenCoveSettingsRoot: View {
    @ObservedObject var store: CoveStore
    var body: some View {
        Group {
            if store.preferences.completedOnboarding { SettingsView(store: store) }
            else { OnboardingView(store: store) }
        }
    }
}
