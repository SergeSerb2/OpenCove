// SPDX-License-Identifier: MIT
import AppKit
import Combine
import Sparkle
import SwiftUI

/// Owns the real Sparkle controller. Never constructs it for ordinary development
/// or control launches, even if Sparkle preferences were enabled in an earlier run.
@MainActor
final class CoveUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var allowsAutomaticUpdates = false
    @Published private(set) var status = "Updates are unavailable in this build."
    private(set) var controller: SPUStandardUpdaterController?

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let arguments = ProcessInfo.processInfo.arguments
        let isolated = info["OpenCoveUpdaterMode"] as? String == "isolated-test"
        if isolated {
            guard arguments.contains("--enable-isolated-updater"),
                  ProcessInfo.processInfo.environment["OPENCOVE_DATA_DIR"] != nil,
                  CovePaths.dataDirectoryConfigurationError == nil,
                  (info["SUDefaultsDomain"] as? String)?.hasPrefix("org.opencove.OpenCove.updater-test.") == true else {
                status = "Updates are off. This test build needs an isolated data directory and explicit updater opt-in."
                return
            }
        } else {
            guard !CovePaths.isDevelopment, !arguments.contains("--control-port"),
                  info["OpenCoveBuildConfiguration"] as? String == "release",
                  info["OpenCoveUpdaterMode"] as? String == "release" else {
                status = "Updates are off for development and verification launches."
                return
            }
        }
        guard Bundle.main.bundleURL.pathExtension == "app",
              let feed = info["SUFeedURL"] as? String, Self.validFeed(feed, isolated: isolated),
              let key = info["SUPublicEDKey"] as? String,
              let bytes = Data(base64Encoded: key), bytes.count == 32,
              bytes.contains(where: { $0 != 0 }), bytes.base64EncodedString() == key,
              let build = info["CFBundleVersion"] as? String,
              build.range(of: "^[1-9][0-9]{0,3}$", options: .regularExpression) != nil,
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true else {
            status = "Updates are unavailable: the signed bundle has invalid feed, public key, or version configuration."
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloadsUpdates)
        updater.publisher(for: \.allowsAutomaticUpdates).assign(to: &$allowsAutomaticUpdates)
        do {
            // Use the throwing core start method to report configuration failures
            // without Sparkle scheduling a delayed configuration-error alert.
            try updater.start()
            status = isolated ? "Isolated Sparkle update verification is enabled." : "Updates use Sparkle. Automatic checks start after you give permission."
        } catch {
            self.controller = nil
            canCheckForUpdates = false
            automaticallyChecksForUpdates = false
            automaticallyDownloadsUpdates = false
            allowsAutomaticUpdates = false
            status = "The updater could not start. Check this build’s release configuration."
        }
    }

    private static func validFeed(_ value: String, isolated: Bool) -> Bool {
        guard let url = URLComponents(string: value), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil, url.query == nil,
              url.path.hasSuffix(".xml"), !value.contains(where: { $0.isWhitespace }) else { return false }
        let loopback = ["127.0.0.1", "localhost", "[::1]"].contains(host.lowercased())
        if isolated { return loopback && ["http", "https"].contains(url.scheme ?? "") }
        return url.scheme == "https" && !loopback && host.contains(".") &&
            !["example.com", "example.org", "example.net"].contains(host.lowercased()) &&
            ![".example", ".invalid", ".test", ".localhost"].contains(where: { host.lowercased().hasSuffix($0) })
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticDownloads(_ enabled: Bool) {
        guard allowsAutomaticUpdates else { return }
        controller?.updater.automaticallyDownloadsUpdates = enabled
    }

    func makeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: "")
        if let controller {
            // Sparkle performs native NSMenuItem validation using canCheckForUpdates.
            item.target = controller
            item.action = #selector(SPUStandardUpdaterController.checkForUpdates(_:))
        } else { item.isEnabled = false }
        return item
    }
}

@MainActor
struct CoveUpdaterSettings: View {
    @ObservedObject var updater: CoveUpdater

    var body: some View {
        Toggle("Automatically check for updates", isOn: Binding(
            get: { updater.automaticallyChecksForUpdates }, set: updater.setAutomaticChecks))
            .disabled(updater.controller == nil)
        Toggle("Automatically download and install updates", isOn: Binding(
            get: { updater.automaticallyDownloadsUpdates }, set: updater.setAutomaticDownloads))
            .disabled(updater.controller == nil || !updater.allowsAutomaticUpdates)
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!updater.canCheckForUpdates)
        CoveSettingsNote(updater.status)
    }
}
