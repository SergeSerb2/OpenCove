// SPDX-License-Identifier: MIT
import AppKit
import Combine
import SwiftUI

@MainActor
struct OnboardingView: View {
    @ObservedObject var store: CoveStore
    @ObservedObject private var activities: ActivityController
    @ObservedObject private var notificationMirror: NotificationMirror
    @StateObject private var permissions = CovePermissionAccess()
    @Environment(\.dismiss) private var dismiss
    @State private var step: CoveOnboardingStep = .welcome

    init(store: CoveStore) {
        self.store = store
        self.activities = store.activities
        self.notificationMirror = store.notificationMirror
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("OpenCove", systemImage: "rectangle.topthird.inset.filled")
                    .font(.headline)
                Spacer()
                Text("\(step.rawValue + 1) of \(CoveOnboardingStep.allCases.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 18)

            Divider()

            if let error = store.lastError {
                CoveSettingsError(error)
                    .padding(.horizontal, 28)
                    .padding(.top, 12)
            }
            if let error = activities.lastError {
                CoveSettingsError(error)
                    .padding(.horizontal, 28)
                    .padding(.top, 12)
            }
            if let notice = activities.lastNotice {
                CoveSettingsNote(notice)
                    .padding(.horizontal, 28)
                    .padding(.top, 12)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: step.symbol)
                            .font(.system(size: 34, weight: .medium))
                            .foregroundStyle(CovePreferenceAccent.color(for: store.preferences.accent))
                            .accessibilityHidden(true)
                        Text(step.title)
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                        Text(step.subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    switch step {
                    case .welcome: welcomeContent
                    case .permissions: permissionContent
                    case .ready: readyContent
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
            }

            Divider()

            HStack(spacing: 12) {
                if step != .welcome {
                    Button("Back") { move(to: step.rawValue - 1) }
                        .keyboardShortcut(.leftArrow, modifiers: .command)
                }
                Spacer()
                if step == .permissions {
                    Text("All access is optional.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(step == .ready ? "Get Started" : "Continue") {
                    if step == .ready {
                        if store.completeOnboarding() {
                            dismiss()
                        }
                    } else {
                        move(to: step.rawValue + 1)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
        }
        .frame(minWidth: 620, idealWidth: 700, maxWidth: .infinity,
               minHeight: 500, idealHeight: 550, maxHeight: .infinity)
        .tint(CovePreferenceAccent.color(for: store.preferences.accent))
        .onAppear(perform: refreshPermissions)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private var welcomeContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            CoveOnboardingFeature(
                symbol: "play.rectangle", title: "Playback within reach",
                detail: "See the current track and control a supported player."
            )
            CoveOnboardingFeature(
                symbol: "calendar.badge.clock", title: "Room for your next task",
                detail: "Check upcoming meetings, run a timer, or keep files in the optional tray."
            )
            CoveOnboardingFeature(
                symbol: "slider.horizontal.3", title: "Your Mac, at a glance",
                detail: "Choose overlays for volume, brightness, battery, audio devices, and Focus."
            )
            Divider()
            CoveSettingsNote("An independent app under the MIT license. Not affiliated with or endorsed by Alcove.")
        }
    }

    private var permissionContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if store.preferences.enableCalendar {
                CovePermissionRow(
                    title: "Calendar", symbol: "calendar",
                    detail: "Read upcoming events and meeting links.",
                    status: activities.calendarAuthorization
                ) {
                    Button("Allow Calendar Access") { activities.requestCalendarAccess() }
                        .disabled(["Restricted", "Unavailable", "Disabled", "Saved calendar settings need review"].contains(activities.calendarAuthorization))
                    Button("System Settings…") {
                        CovePermissionAccess.openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
                    }
                }
                if activities.calendarAuthorization == "Saved calendar settings need review" {
                    CoveCalendarSourceRecovery(activities: activities)
                }
            }

            if store.preferences.enableNotifications {
                CovePermissionRow(
                    title: "Notifications", symbol: "bell.badge",
                    detail: "Allow OpenCove alerts, including timer alerts.",
                    status: activities.notificationAuthorization
                ) {
                    if !activities.nativeNotificationsEnabled {
                        Button("Allow Notifications") { activities.requestNotificationAccess() }
                    }
                    Button("System Settings…") { permissions.openNotificationSettings() }
                }
            }

            DisclosureGroup("Optional Accessibility access") {
                CovePermissionRow(
                    title: "Accessibility", symbol: "accessibility",
                    detail: "Needed only for optional notification banner mirroring. Granting access does not enable mirroring.",
                    status: permissions.accessibilityGranted ? "Allowed" : "Not allowed"
                ) {
                    if !permissions.accessibilityGranted {
                        Button("Request Access") {
                            notificationMirror.requestAccess()
                            permissions.refresh()
                        }
                    }
                    Button("System Settings…") {
                        CovePermissionAccess.openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                    }
                }
                .padding(.top, 8)
            }

            if let error = activities.lastError {
                CoveSettingsNote(error, symbol: "exclamationmark.triangle")
            }
            CoveSettingsNote("Permission buttons open macOS access requests. You can continue without granting access.", symbol: "hand.raised")
        }
    }

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Show media controls", isOn: preference(\.enableMedia))
            Toggle("Expand the panel on hover", isOn: preference(\.expandOnHover))
            Toggle("Launch at login", isOn: preference(\.launchAtLogin))
                .disabled(CovePaths.isDevelopment)
            if CovePaths.isDevelopment {
                CoveSettingsNote("Launch at login is available in the release app.")
            }
            Picker("Expanded layout", selection: preference(\.expandedLayout)) {
                Text("Now Playing").tag("media")
                Text("Calendar").tag("calendar")
                Text("Media & Calendar").tag("duo")
            }
            Divider()
            Toggle("Enable private macOS integrations", isOn: preference(\.enablePrivateAPIs))
            CoveSettingsNote("Now Playing, brightness, and Focus can use undocumented system interfaces. Support varies by Mac and macOS version, and an update can disable these features. This does not bypass system permissions.", symbol: "info.circle")
            CoveSettingsNote("Settings includes opt-in weather, notification mirroring, and live system audio levels. Live levels need Screen & System Audio Recording access. Automatic audio mixing is controlled by your player.")
        }
    }

    private func move(to rawValue: Int) {
        guard let next = CoveOnboardingStep(rawValue: rawValue) else { return }
        step = next
        if next == .permissions { refreshPermissions() }
    }

    private func preference<Value>(_ keyPath: WritableKeyPath<CovePreferences, Value>) -> Binding<Value> {
        Binding(
            get: { store.preferences[keyPath: keyPath] },
            set: { value in
                store.updatePreferences { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func refreshPermissions() {
        permissions.refresh()
        activities.refreshCalendar()
    }
}

private enum CoveOnboardingStep: Int, CaseIterable {
    case welcome, permissions, ready

    var symbol: String {
        switch self {
        case .welcome: return "rectangle.topthird.inset.filled"
        case .permissions: return "hand.raised"
        case .ready: return "checkmark.circle"
        }
    }

    var title: String {
        switch self {
        case .welcome: return "A little space. A useful place."
        case .permissions: return "Choose what to share."
        case .ready: return "Make yourself at home."
        }
    }

    var subtitle: String {
        switch self {
        case .welcome: return "OpenCove brings playback, system status, and small tasks to the top of your display."
        case .permissions: return "Grant access for the features you want. Your Mac remains in control."
        case .ready: return "Choose a few defaults, then open the panel to get started."
        }
    }
}

private struct CoveOnboardingFeature: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 27)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
