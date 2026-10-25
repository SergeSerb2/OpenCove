// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI

/// Widget content only. macOS owns the clock and all authentication controls.
/// The controller decides whether this view may be mounted on a locked display;
/// the development renderer may also render it offscreen without changing lock state.
@MainActor
struct LockScreenView: View {
    @ObservedObject var store: CoveStore
    @ObservedObject var weather: WeatherController
    @ObservedObject private var keepAwakeStatus: LockScreenKeepAwakeStatus
    private let keepAwakeControl: LockScreenKeepAwakeControl?

    init(store: CoveStore, weather: WeatherController,
         keepAwakeStatus: LockScreenKeepAwakeStatus? = nil,
         keepAwakeControl: LockScreenKeepAwakeControl? = nil) {
        self.store = store
        self.weather = weather
        self.keepAwakeStatus = keepAwakeStatus ?? LockScreenKeepAwakeStatus()
        self.keepAwakeControl = keepAwakeControl
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let keepAwakeControl {
                    CoveMountedKeepAwakeSection(status: keepAwakeStatus, control: keepAwakeControl)
                } else {
                    CoveKeepAwakeSection(status: keepAwakeStatus, available: false, action: nil)
                }
                if store.preferences.showsLockWidget(.media) {
                    CoveMediaSurface(media: store.media, system: store.system, waveform: store.waveform,
                                     showMediaTotalDuration: store.preferences.showMediaTotalDuration,
                                     showPlaybackIndicator: store.preferences.showPlaybackIndicator,
                                     showLiveWaveform: store.preferences.usesLiveWaveform, locked: true,
                                     musicColorAccent: store.preferences.musicColorAccent,
                                     reduceMotion: store.preferences.reduceMotion)
                }
                if store.preferences.showsLockWidget(.calendar) || store.preferences.showsLockWidget(.weather) {
                    HStack(alignment: .top, spacing: 18) {
                        if store.preferences.showsLockWidget(.calendar) {
                            CoveLockCalendarSection(controller: store.activities,
                                                    showPrivateContent: store.preferences.showLockScreenPrivateContent)
                        }
                        if store.preferences.showsLockWidget(.weather) {
                            CoveLockWeatherSection(controller: weather,
                                style: CoveWeatherStyle(rawValue: store.preferences.weatherStyle) ?? .conditions,
                                motion: store.preferences.reduceMotion ? nil : CoveMotion.animation(preferences: store.preferences, hud: false))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if store.preferences.showsLockWidget(.battery) || store.preferences.showsLockWidget(.focus) || store.preferences.showsLockWidget(.bluetooth) {
                    CoveLockSystemSection(controller: store.system,
                                          showBattery: store.preferences.showsLockWidget(.battery),
                                          showFocus: store.preferences.showsLockWidget(.focus),
                                          showConnectivity: store.preferences.showsLockWidget(.bluetooth))
                }
            }
            .padding(18)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.top)
        .frame(maxWidth: 560, maxHeight: .infinity, alignment: .top)
        .modifier(CoveLockSurfaceStyle(style: store.preferences.nowPlayingStyle))
        .foregroundStyle(.primary)
        .preferredColorScheme(.dark)
    }
}

private struct CoveLockSurfaceStyle: ViewModifier {
    let style: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), style != "frosted" {
            content.glassEffect((style == "clear" ? Glass.clear : Glass.regular).interactive(),
                                in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        } else {
            content
                .background(style == "frosted" ? .regularMaterial : .ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
    }
}

@MainActor
private struct CoveLockCalendarSection: View {
    @ObservedObject var controller: ActivityController
    let showPrivateContent: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let authorized = controller.calendarAuthorization == "Authorized"
            let upcoming = authorized ? controller.events.filter { $0.end > context.date }.sorted { $0.start < $1.start } : []
            VStack(alignment: .leading, spacing: 4) {
                Label("Calendar", systemImage: "calendar")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                if !authorized {
                    Text(controller.calendarAuthorization == "Saved calendar settings need review" ? "Review calendar sources after unlocking" : "Calendar access is off").font(.system(size: 11))
                } else if upcoming.isEmpty {
                    Text("No upcoming events").font(.system(size: 11))
                } else if showPrivateContent, let event = upcoming.first {
                    // No event title, time, location, calendar name, URL, help,
                    // or accessibility value is built in the hidden branch below.
                    Text(event.title.isEmpty ? "Untitled event" : event.title)
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                        .privacySensitive()
                    Group {
                        if event.isAllDay {
                            Text("All day")
                        } else {
                            Text(event.start, format: .dateTime.month(.abbreviated).day().hour().minute())
                        }
                    }
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .environment(\.timeZone, event.timeZone)
                    .privacySensitive()
                } else {
                    Label("Event details hidden", systemImage: "lock.fill")
                        .font(.system(size: 11))
                    Text("\(upcoming.count) upcoming")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor
private struct CoveLockWeatherSection: View {
    @ObservedObject var controller: WeatherController
    let style: CoveWeatherStyle
    let motion: Animation?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        Group {
            if controller.state.available {
                TimelineView(.periodic(from: .now, by: 60)) { context in content(at: context.date) }
            } else { content(at: Date()) }
        }
        .animation(systemReduceMotion ? nil : motion, value: style)
    }

    private func content(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(style.title, systemImage: style == .conditions && controller.state.available ? controller.state.symbol : style.symbol)
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            if controller.state.available {
                // A chosen location name can contain personal text. Keep it out
                // of this locked surface, including accessibility and help.
                CoveWeatherSummary(state: controller.state,
                    data: WeatherWidgetData(state: controller.state, style: style, at: now),
                    compact: true, showsLocation: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.state.isStale ? "Saved weather · Open-Meteo · CC BY 4.0" : "Open-Meteo · CC BY 4.0")
                    Text(verbatim: "https://open-meteo.com")
                    Text(verbatim: "https://creativecommons.org/licenses/by/4.0")
                    Text("Model forecast summarized; values rounded.")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                // Literal text keeps both URLs readable without activating a
                // browser or another app from this locked surface.
            } else {
                Text(controller.isLoading ? "Loading weather…" : "Weather unavailable")
                    .font(.system(size: 11))
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private struct CoveLockSystemSection: View {
    @ObservedObject var controller: SystemController
    let showBattery: Bool
    let showFocus: Bool
    let showConnectivity: Bool

    var body: some View {
        HStack(spacing: 12) {
            if showBattery {
                VStack(alignment: .leading, spacing: 2) {
                    item(batteryText, symbol: batterySymbol)
                    if let estimate = batteryTimeEstimate {
                        Text(estimate.visible)
                            .font(.system(size: 9))
                            .lineLimit(2)
                            .accessibilityLabel(estimate.spoken)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if showFocus {
                item(controller.state.focusAvailable ? (controller.state.focusEnabled ? "Focus on" : "Focus off") : "Focus unavailable",
                     symbol: controller.state.focusEnabled ? "moon.fill" : "moon")
            }
            if showConnectivity {
                item(connectivityText, symbol: "antenna.radiowaves.left.and.right")
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
    }

    private func item(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .lineLimit(1).minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var batteryText: String {
        guard controller.state.batteryAvailable else { return "Battery unavailable" }
        guard controller.state.hasBattery else { return controller.state.isOnACPower ? "AC power" : "No battery" }
        return "\(min(100, max(0, controller.state.batteryPercent)))%\(controller.state.isCharging ? " charging" : "")"
    }

    private var batterySymbol: String {
        guard controller.state.batteryAvailable, controller.state.hasBattery else { return "bolt" }
        if controller.state.isCharging { return "battery.100percent.bolt" }
        let percent = min(100, max(0, controller.state.batteryPercent))
        let level = percent <= 10 ? 0 : percent <= 35 ? 25 : percent <= 60 ? 50 : percent <= 85 ? 75 : 100
        return "battery.\(level)percent"
    }

    private var batteryTimeEstimate: (visible: String, spoken: String)? {
        let state = controller.state
        guard state.batteryAvailable, state.hasBattery, !state.isCharging, !state.isOnACPower,
              let minutes = state.batteryTimeToEmptyMinutes, minutes >= 0, minutes <= Int(Int32.max) else { return nil }
        // Preserve a reported zero without inventing sub-minute precision.
        if minutes == 0 {
            return ("0 min remaining (est.)", "Estimated battery time remaining: zero minutes")
        }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.zeroFormattingBehavior = .dropAll
        formatter.unitsStyle = .abbreviated
        let interval = TimeInterval(minutes) * 60
        guard let visible = formatter.string(from: interval) else { return nil }
        formatter.unitsStyle = .full
        guard let spoken = formatter.string(from: interval) else { return nil }
        return ("\(visible) remaining (est.)", "Estimated battery time remaining: \(spoken)")
    }

    private var connectivityText: String {
        if controller.state.bluetoothAvailable {
            let count = controller.state.bluetoothDevices.count
            return count == 0 ? "No Bluetooth devices" : "Bluetooth · \(count) connected"
        }
        return controller.state.audioOutputIsBluetooth ? "Bluetooth audio" : "Bluetooth unavailable"
    }
}

@MainActor
private struct CoveMountedKeepAwakeSection: View {
    @ObservedObject var status: LockScreenKeepAwakeStatus
    @ObservedObject var control: LockScreenKeepAwakeControl
    var body: some View {
        CoveKeepAwakeSection(status: status, available: control.available, control: control) { purpose, expected, minutes in
            control.activate(purpose, minutes: minutes, expected: expected)
        }
    }
}

@MainActor
private struct CoveKeepAwakeSection: View {
    @ObservedObject var status: LockScreenKeepAwakeStatus
    let available: Bool
    var control: LockScreenKeepAwakeControl? = nil
    let action: ((String, UUID?, Int) -> Void)?
    private var active: Bool { status.projection.handleState == "active" }
    private var faulted: Bool {
        ["quarantined", "creationUnconfirmed", "retiring", "provisional"].contains(status.projection.handleState)
    }
    var body: some View {
        let displayedSessionID = status.projection.sessionID
        let displayedMinutes = status.draftMinutes
        VStack(alignment: .leading, spacing: 6) {
            Label("Keep Awake", systemImage: "display")
                .font(.system(size: 11, weight: .semibold))
            if active {
                Text(status.projection.message)
                if let end = status.projection.expectedEnd {
                    Text("Expected end: \(end, format: .dateTime.hour().minute())")
                        .foregroundStyle(.secondary)
                }
            } else if faulted {
                Text(status.projection.message)
            } else {
                Text("Keep displays awake for \(status.draftMinutes) min")
            }
            Slider(value: Binding(get: { Double(status.draftMinutes) }, set: { value in
                guard value.isFinite, value.rounded(.towardZero) == value, (1...120).contains(value) else { return }
                status.setDraft(Int(value))
            }), in: 1...120, step: 1) {
                Text("Duration, 1 to 120 minutes")
            }
            .accessibilityLabel("Duration, 1 to 120 minutes")
            .accessibilityValue("\(status.draftMinutes) minutes")
            .focusable(false)
            .disabled(!available || faulted || action == nil)
            if active {
                Text("Duration applies to Restart: \(status.draftMinutes) min")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                if active {
                    // Separate deliberate actions. Neither gets a key equivalent.
                    Button("Stop") { action?("stop", displayedSessionID, displayedMinutes) }
                        .disabled(!available || action == nil)
                    Button("Restart for \(status.draftMinutes) min") {
                        action?("replace", displayedSessionID, displayedMinutes)
                    }
                    .disabled(!available || action == nil || status.projection.applicationDeadlinePassed)
                } else {
                    Button("Start for \(status.draftMinutes) min") { action?("start", nil, displayedMinutes) }
                        .disabled(!available || faulted || action == nil)
                }
            }
            .background {
                // Admission tracks the mounted action row, not a visible heading
                // or disclosure while all action buttons have scrolled away.
                if let control { CoveKeepAwakeRowAttachment(control: control) }
            }
            if !available { Text("Keep Awake is unavailable here.").foregroundStyle(.secondary) }
            if let outcome = status.projection.lastOutcome,
               !["PREPARED", "STARTED", "REPLACED", "RETIRED", "STOPPED", "IDLE"].contains(outcome.resultCode), !faulted {
                Text("Keep Awake action: \(outcome.resultCode)").foregroundStyle(.secondary)
            }
            Text("Prevents automatic display sleep on this Mac. Stops when this lock-screen session ends. Closing the lid or choosing Sleep still works.")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 10))
        .buttonStyle(.bordered)
        .controlSize(.small)
        .focusable(false)
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A passive native row attachment. Mount/layout can only register or revoke
/// capability; only the explicit controls above can request power.
@MainActor
private struct CoveKeepAwakeRowAttachment: NSViewRepresentable {
    let control: LockScreenKeepAwakeControl
    func makeNSView(context: Context) -> CoveKeepAwakeRowView { CoveKeepAwakeRowView(control: control) }
    func updateNSView(_ view: CoveKeepAwakeRowView, context: Context) {}
    static func dismantleNSView(_ view: CoveKeepAwakeRowView, coordinator: ()) { view.detach() }
}

@MainActor
private final class CoveKeepAwakeRowView: NSView {
    private let control: LockScreenKeepAwakeControl
    private var observations: [NSObjectProtocol] = []
    init(control: LockScreenKeepAwakeControl) {
        self.control = control
        super.init(frame: .zero)
        postsFrameChangedNotifications = true
        postsBoundsChangedNotifications = true
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { detach() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil { detach() }
        super.viewWillMove(toSuperview: newSuperview)
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attach() }
    override func layout() { super.layout(); control.geometryChanged() }
    private func attach() {
        for token in observations { NotificationCenter.default.removeObserver(token) }
        observations.removeAll()
        guard window != nil, superview != nil else { return }
        control.mounted(self)
        var ancestor: NSView? = self
        while let view = ancestor {
            view.postsFrameChangedNotifications = true
            view.postsBoundsChangedNotifications = true
            for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
                observations.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak control] _ in
                    MainActor.assumeIsolated { control?.geometryChanged() }
                })
            }
            ancestor = view.superview
        }
        if let window {
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeOcclusionStateNotification] {
                observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak control] _ in
                    MainActor.assumeIsolated { control?.geometryChanged() }
                })
            }
        }
    }
    func detach() {
        control.removed(self)
        for token in observations { NotificationCenter.default.removeObserver(token) }
        observations.removeAll()
    }
    deinit { for token in observations { NotificationCenter.default.removeObserver(token) } }
}
