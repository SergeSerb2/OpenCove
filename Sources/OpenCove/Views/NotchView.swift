import SwiftUI
import AppKit

@MainActor
struct NotchView: View {
    @ObservedObject var store: CoveStore
    private let cutout: CGSize?
    @ObservedObject private var media: MediaController
    @ObservedObject private var system: SystemController
    @ObservedObject private var activities: ActivityController
    private let waveform: AudioWaveformController
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    init(store: CoveStore, cutout: CGSize? = nil) {
        self.store = store
        self.cutout = cutout
        _media = ObservedObject(wrappedValue: store.media)
        _system = ObservedObject(wrappedValue: store.system)
        _activities = ObservedObject(wrappedValue: store.activities)
        waveform = store.waveform
    }

    /// The window owner can use the same dimensions as the rendered surface.
    static func desiredSize(store: CoveStore, cutout: CGSize? = nil) -> CGSize {
        let width = max(160, store.preferences.notchWidth)
        let cutoutWidth = max(0, cutout.map { Double($0.width) } ?? store.physicalNotchWidth)
        let cutoutHeight = max(0, cutout.map { Double($0.height) } ?? store.physicalNotchHeight)
        let height = max(32, store.preferences.notchHeight, cutoutHeight)
        if store.isExpanded {
            let tab = CoveTab.allCases.first { tab in
                switch tab {
                case .media: return store.preferences.enableMedia
                case .calendar: return store.preferences.enableCalendar
                case .files: return store.preferences.enableFileTray
                case .timer: return store.preferences.enableTimer
                }
            }
            let selected = store.selectedTab
            let active: CoveTab? = {
                switch selected {
                case .media: return store.preferences.enableMedia ? selected : tab
                case .calendar: return store.preferences.enableCalendar ? selected : tab
                case .files: return store.preferences.enableFileTray ? selected : tab
                case .timer: return store.preferences.enableTimer ? selected : tab
                }
            }()
            let contentHeight: Double = active == .media ? (store.preferences.expandedLayout == "duo" ? 240 : 205)
                : active == .calendar ? 235 : 260
            return CGSize(width: max(440, width, cutoutWidth + 80), height: max(contentHeight + cutoutHeight, height))
        }
        if store.hud != nil {
            return CGSize(width: max(310, width, cutoutWidth > 0 ? cutoutWidth + 240 : 0), height: max(40, height))
        }
        if store.preferences.enableMedia && store.media.state.available {
            if store.preferences.enableTimer && store.activities.timer.remaining > 0 ||
                store.preferences.enableCalendar && store.activities.eventActivity != nil {
                return CGSize(width: max(300, width, cutoutWidth > 0 ? cutoutWidth + 220 : 0), height: height)
            }
            return CGSize(width: max(250, width, cutoutWidth > 0 ? cutoutWidth + 140 : 0), height: height)
        }
        if store.preferences.enableTimer && store.activities.timer.remaining > 0 {
            return CGSize(width: max(250, width, cutoutWidth > 0 ? cutoutWidth + 145 : 0), height: height)
        }
        if store.preferences.enableCalendar && store.activities.eventActivity != nil {
            return CGSize(width: max(300, width, cutoutWidth > 0 ? cutoutWidth + 200 : 0), height: height)
        }
        return CGSize(width: max(width, cutoutWidth > 0 ? cutoutWidth + 160 : 0), height: height)
    }

    private var motion: Animation? {
        guard !systemReduceMotion && !store.preferences.reduceMotion else { return nil }
        return CoveMotion.animation(preferences: store.preferences, hud: store.hud != nil)
    }

    private var enabledTabs: [CoveTab] {
        CoveTab.allCases.filter { tab in
            switch tab {
            case .media: return store.preferences.enableMedia
            case .calendar: return store.preferences.enableCalendar
            case .files: return store.preferences.enableFileTray
            case .timer: return store.preferences.enableTimer
            }
        }
    }

    private var visibleTab: CoveTab? {
        enabledTabs.contains(store.selectedTab) ? store.selectedTab : enabledTabs.first
    }

    private var showsDuo: Bool {
        store.preferences.expandedLayout == "duo" && visibleTab == .media
            && store.preferences.enableMedia && store.preferences.enableCalendar
    }

    private var cutoutHeight: Double { max(0, cutout.map { Double($0.height) } ?? store.physicalNotchHeight) }
    private var compactGap: Double { max(0, cutout.map { Double($0.width) } ?? store.physicalNotchWidth) }
    private var surfaceShape: CoveNotchShape {
        CoveNotchShape(radius: store.isExpanded ? max(24, store.preferences.cornerRadius) : store.preferences.cornerRadius,
                       floating: cutoutHeight == 0)
    }

    var body: some View {
        surface
            .environment(\.colorScheme, .dark)
            .animation(motion, value: store.isExpanded)
            .animation(motion, value: store.hud?.kind)
            .animation(motion, value: Self.desiredSize(store: store, cutout: cutout))
            .onAppear(perform: applyInitialLayout)
            .onChange(of: store.preferences.expandedLayout) { _, _ in applyExpandedLayout() }
            .onExitCommand(perform: store.collapse)
    }

    private func applyExpandedLayout() {
        store.selectedTab = store.preferences.expandedLayout == "calendar" ? .calendar : .media
    }

    private func applyInitialLayout() {
        if store.selectedTab == .media && store.preferences.expandedLayout == "calendar" {
            store.selectedTab = .calendar
        }
    }

    private var surface: some View {
        let size = Self.desiredSize(store: store, cutout: cutout)
        return content
            .frame(maxWidth: size.width, maxHeight: size.height)
            .background(Color.black, in: surfaceShape)
            .clipShape(surfaceShape)
            .overlay {
                surfaceShape.stroke(Color.white.opacity(store.isExpanded ? 0.085 : 0.035), lineWidth: 0.6)
                    .allowsHitTesting(false)
            }
            .foregroundStyle(Color.white)
            .tint(CoveNotchStyle.accent(store.preferences.accent))
    }

    @ViewBuilder private var content: some View {
        Group {
            if store.isExpanded {
                expanded
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            } else {
                Button(action: store.toggleExpanded) {
                    compact
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(compactAccessibilityLabel)
                .accessibilityHint("Show OpenCove controls")
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder private var compact: some View {
        if let hud = store.hud {
            CoveCompactHUD(hud: hud, accent: CoveNotchStyle.accent(store.preferences.accent), centerGap: compactGap)
                .padding(.horizontal, 18)
        } else if store.preferences.enableMedia && media.state.available {
            HStack(spacing: 0) {
                CoveArtwork(data: media.state.artworkData, size: 23, radius: 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: compactGap)
                HStack(spacing: 8) {
                if store.preferences.enableFocus && system.state.focusAvailable && system.state.focusEnabled {
                    Image(systemName: "moon.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.indigo.opacity(0.9))
                }
                if store.preferences.showLiveWaveform {
                    LiveWaveformView(controller: waveform, isPlaying: media.state.isPlaying,
                                     color: CoveNotchStyle.accent(store.preferences.accent))
                } else {
                    CoveAudioBars(isPlaying: media.state.isPlaying,
                                  reduceMotion: systemReduceMotion || store.preferences.reduceMotion,
                                  color: CoveNotchStyle.accent(store.preferences.accent))
                }
                if store.preferences.enableTimer && activities.timer.remaining > 0 ||
                    store.preferences.enableCalendar && activities.eventActivity != nil {
                    VStack(alignment: .trailing, spacing: 1) {
                        if store.preferences.enableTimer && activities.timer.remaining > 0 {
                            Label(CoveNotchStyle.duration(activities.timer.remaining), systemImage: "timer")
                        }
                        if store.preferences.enableCalendar, let activity = activities.eventActivity {
                            Label((activity.phase == .startingSoon ? "in " : "") + CoveNotchStyle.duration(Double(activity.remainingSeconds)),
                                  systemImage: "calendar")
                        }
                    }
                    .font(.system(size: 9, weight: .medium, design: .rounded)).monospacedDigit()
                    .foregroundStyle(CoveNotchStyle.secondary).lineLimit(1)
                }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 15)
        } else if store.preferences.enableTimer && activities.timer.remaining > 0 {
            HStack(spacing: 0) {
                Image(systemName: activities.timer.running ? "timer" : "pause.fill")
                    .foregroundStyle(CoveNotchStyle.accent(store.preferences.accent))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: compactGap)
                Text(CoveNotchStyle.duration(activities.timer.remaining))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 18)
        } else if store.preferences.enableCalendar, let activity = activities.eventActivity {
            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: activity.phase == .current ? "calendar.badge.clock" : "calendar")
                        .foregroundStyle(CoveNotchStyle.calendarColor(activity.event.colorHex))
                    Text(activity.event.title.isEmpty ? "Calendar event" : activity.event.title)
                        .font(.system(size: 10, weight: .medium)).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: compactGap)
                Text((activity.phase == .startingSoon ? "in " : "") + CoveNotchStyle.duration(Double(activity.remainingSeconds)))
                    .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }.padding(.horizontal, 16)
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(spacing: 0) {
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: compactGap)
                    HStack(spacing: 5) {
                        Text(context.date, format: .dateTime.weekday(.abbreviated).day())
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(CoveNotchStyle.secondary)
                            .lineLimit(1)
                        if store.preferences.enableFocus && system.state.focusAvailable && system.state.focusEnabled {
                            Image(systemName: "moon.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.indigo)
                        } else if store.preferences.enableBattery && system.state.hasBattery && system.state.batteryAvailable {
                            CoveBatteryMark(percent: system.state.batteryPercent, charging: system.state.isCharging)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var expanded: some View {
        VStack(spacing: 0) {
            Group {
                switch visibleTab {
                case .media:
                    if showsDuo {
                        HStack(alignment: .top, spacing: 13) {
                            CoveMediaSurface(media: media, system: system, waveform: waveform,
                                             showLiveWaveform: store.preferences.showLiveWaveform, condensed: true,
                                             musicColorAccent: store.preferences.musicColorAccent,
                                             reduceMotion: store.preferences.reduceMotion)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            Rectangle().fill(.white.opacity(0.09)).frame(width: 1)
                            CoveCalendarView(activities: activities, condensed: true)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        CoveMediaSurface(media: media, system: system, waveform: waveform,
                                         showLiveWaveform: store.preferences.showLiveWaveform,
                                         musicColorAccent: store.preferences.musicColorAccent,
                                         reduceMotion: store.preferences.reduceMotion)
                    }
                case .calendar:
                    CoveCalendarView(activities: activities)
                case .files:
                    CoveFileSurface(activities: activities)
                case .timer:
                    CoveTimerSurface(activities: activities)
                case nil:
                    CoveEmptySurface(symbol: "sparkle", title: "Your quiet space",
                                     message: "Choose what appears here in Settings.",
                                     actionTitle: "Open Settings", action: store.openSettings)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(visibleTab)
            .transition(.opacity)
            .padding(.bottom, 6)
            HStack(spacing: 8) {
                if let hud = store.hud {
                    Label(hud.title + (hud.value.map { " \(Int((CoveNotchStyle.fraction($0) * 100).rounded()))%" } ?? ""), systemImage: hud.symbol)
                        .font(.system(size: 10, weight: .medium)).lineLimit(1)
                        .foregroundStyle(CoveNotchStyle.accent(store.preferences.accent))
                        .help([hud.title, hud.subtitle].filter { !$0.isEmpty }.joined(separator: " · "))
                } else {
                    CoveSystemIndicators(system: system, preferences: store.preferences)
                }
                Spacer(minLength: 0)
                if store.preferences.enableNotifications { CoveNotificationButton(activities: activities) }
                Menu {
                    ForEach(enabledTabs) { tab in
                        Button { store.selectedTab = tab } label: {
                            Label(tab == .media && showsDuo ? "Media & Calendar" : tab.title, systemImage: tab.symbol)
                        }
                    }
                    Divider()
                    Button("Settings…", action: store.openSettings)
                    Button("Collapse", action: store.collapse)
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 18) }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("OpenCove sections and settings")
            }.frame(height: 18)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16 + cutoutHeight)
        .padding(.bottom, 10)
        .animation(motion, value: visibleTab)
    }

    private var compactAccessibilityLabel: String {
        if let hud = store.hud {
            return [hud.title, hud.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
        }
        if store.preferences.enableMedia && media.state.available {
            var label = "\(media.state.isPlaying ? "Playing" : "Paused"), \(media.state.title), \(media.state.artist)"
            if store.preferences.enableTimer && activities.timer.remaining > 0 {
                label += ", timer \(CoveNotchStyle.duration(activities.timer.remaining)) remaining"
            }
            if store.preferences.enableCalendar, let activity = activities.eventActivity {
                label += ", \(activity.event.title), \(activity.phase == .current ? "ends" : "starts") in \(CoveNotchStyle.duration(Double(activity.remainingSeconds)))"
            }
            return label
        }
        if store.preferences.enableTimer && activities.timer.remaining > 0 {
            return "Timer, \(CoveNotchStyle.duration(activities.timer.remaining)) remaining"
        }
        if store.preferences.enableCalendar, let activity = activities.eventActivity {
            return "\(activity.event.title), \(activity.phase == .current ? "ends" : "starts") in \(CoveNotchStyle.duration(Double(activity.remainingSeconds)))"
        }
        return "OpenCove, \(Date.now.formatted(date: .abbreviated, time: .shortened))"
    }
}
