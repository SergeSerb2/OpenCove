import SwiftUI
import AppKit

private enum CoveCompactMode: Hashable {
    case activity(CoveCompactActivity)
    case hud(HUDKind)
    case peek
}

private enum CovePanelMode: Equatable {
    case expanded
    case compact(CoveCompactMode)
}

private struct CovePanelPresentation {
    var mode: CovePanelMode = .compact(.activity(.clock))
    var immediate = false
    var mediaAvailable = false
    var timerAvailable = false
    var calendarAvailable = false
    var calendarDetailsVisible = false
    var peekEnabled = false
    var hud: HUDKind?

    func mayRetain(_ mode: CovePanelMode) -> Bool {
        switch mode {
        case .expanded: return true
        case .compact(.activity(.media)): return mediaAvailable
        case .compact(.activity(.timer)): return timerAvailable
        case .compact(.activity(.calendar)): return calendarAvailable && calendarDetailsVisible
        case .compact(.activity(.clock)): return true
        case .compact(.peek): return mediaAvailable && peekEnabled
        case .compact(.hud(let kind)): return hud == kind
        }
    }
}

private struct CovePanelPresentationKey: EnvironmentKey {
    static let defaultValue = CovePanelPresentation()
}

private extension EnvironmentValues {
    var covePanelPresentation: CovePanelPresentation {
        get { self[CovePanelPresentationKey.self] }
        set { self[CovePanelPresentationKey.self] = newValue }
    }
}

/// Read the current presentation even inside a retained outgoing transition.
/// Reduce Motion must reveal the active controls and clear departing controls
/// immediately, rather than waiting for an already scheduled fade or delay.
private struct CovePanelFade: AnimatableModifier {
    var opacity: Double
    let mode: CovePanelMode
    @Environment(\.covePanelPresentation) private var presentation

    var animatableData: Double {
        get { opacity }
        set { opacity = newValue }
    }

    func body(content: Content) -> some View {
        let active = mode == presentation.mode
        let permitted = active || presentation.mayRetain(mode)
        content.opacity(!permitted ? 0 : presentation.immediate ? (active ? 1 : 0) : opacity)
            .transaction { $0.animation = nil }
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
    }
}

private struct CoveExpandedSection: Hashable {
    let tab: CoveTab?
    let duo: Bool
}

private struct CoveExpandedSectionIdentity: Hashable {
    let section: CoveExpandedSection
    let revision: UInt64
}

private struct CoveExpandedSectionPresentation: Equatable {
    var active: CoveExpandedSectionIdentity
    var outgoing: CoveExpandedSectionIdentity?
    var settled = false

    init(section: CoveExpandedSection) {
        active = CoveExpandedSectionIdentity(section: section, revision: 0)
    }

    func targeting(_ section: CoveExpandedSection) -> Self {
        guard section != active.section else { return self }
        var next = self
        next.outgoing = active
        next.active = CoveExpandedSectionIdentity(section: section, revision: active.revision &+ 1)
        next.settled = false
        return next
    }
}

private struct CoveExpandedSectionPermissions {
    var mediaEnabled = false
    var mediaAvailable = false
    var calendarEnabled = false
    var calendarDetailsVisible = false
    var filesEnabled = false
    var timerEnabled = false

    func permits(_ section: CoveExpandedSection, outgoing: Bool) -> Bool {
        switch section.tab {
        case .media:
            return mediaEnabled && (!outgoing || mediaAvailable)
                && (!section.duo || (calendarEnabled && (!outgoing || calendarDetailsVisible)))
        case .calendar: return calendarEnabled && (!outgoing || calendarDetailsVisible)
        case .files: return filesEnabled
        case .timer: return timerEnabled
        case nil: return true
        }
    }
}

private struct CoveExpandedSectionContext {
    var presentation = CoveExpandedSectionPresentation(section: CoveExpandedSection(tab: nil, duo: false))
    var permissions = CoveExpandedSectionPermissions()
    var expanded = false
}

private struct CoveExpandedSectionKey: EnvironmentKey {
    static let defaultValue = CoveExpandedSectionContext()
}

private extension EnvironmentValues {
    var coveExpandedSection: CoveExpandedSectionContext {
        get { self[CoveExpandedSectionKey.self] }
        set { self[CoveExpandedSectionKey.self] = newValue }
    }
}

/// Keep permission and input checks live inside SwiftUI's retained exit tree.
/// Drop the subtree when it is no longer permitted, so opacity cannot keep
/// disabled or private content mounted.
private struct CoveExpandedSectionContent<Content: View>: View {
    let identity: CoveExpandedSectionIdentity
    @ViewBuilder var content: () -> Content
    @Environment(\.coveExpandedSection) private var context

    var body: some View {
        let selected = identity == context.presentation.active
        let active = selected && context.expanded
        let retained = identity == context.presentation.outgoing && !context.presentation.settled
        Group {
            if (selected || retained) && context.permissions.permits(identity.section, outgoing: !selected) {
                content()
                    .disabled(!active)
                    .allowsHitTesting(active)
                    .accessibilityHidden(!active)
            }
        }
        // Section motion belongs to the wrapper, never nested data or
        // permission changes (including calendar's privacy branches).
        .transaction { $0.animation = nil }
    }
}

/// Input and accessibility depend on lifecycle changes, not opacity samples.
/// Keep their modifier body separate from the per-frame transition body.
private struct CoveExpandedSectionInputGate: ViewModifier {
    let identity: CoveExpandedSectionIdentity
    @Environment(\.coveExpandedSection) private var context

    func body(content: Content) -> some View {
        let selected = identity == context.presentation.active
        let retained = identity == context.presentation.outgoing && !context.presentation.settled
        let permitted = (selected || retained) && context.permissions.permits(identity.section, outgoing: !selected)
        let active = selected && context.expanded && permitted
        content
            .disabled(!active)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
    }
}

private struct CoveExpandedSectionFade: AnimatableModifier {
    var opacity: Double
    let identity: CoveExpandedSectionIdentity
    @Environment(\.coveExpandedSection) private var context

    var animatableData: Double {
        get { opacity }
        set { opacity = newValue }
    }

    func body(content: Content) -> some View {
        let selected = identity == context.presentation.active
        let retained = identity == context.presentation.outgoing && !context.presentation.settled
        let permitted = (selected || retained) && context.permissions.permits(identity.section, outgoing: !selected)
        // SwiftUI can retain a rendered exit tree after its content is removed.
        // Fence that image at the transition itself as well as the live subtree.
        content.opacity(!permitted ? 0 : context.presentation.settled ? (selected ? 1 : 0) : opacity)
            .transaction { $0.animation = nil }
            .modifier(CoveExpandedSectionInputGate(identity: identity))
    }
}

/// Retained outgoing trees must revoke their native marker as well as SwiftUI
/// hit testing. The controller also compares this identity with live state.
private struct CoveMediaSkipRegionGate: ViewModifier {
    let context: CoveMediaSkipContext?
    let kind: CoveMediaSkipContext.Kind
    let mode: CovePanelMode
    var section: CoveExpandedSectionIdentity? = nil
    @Environment(\.covePanelPresentation) private var panel
    @Environment(\.coveExpandedSection) private var expanded

    func body(content: Content) -> some View {
        let activeSection = section.map { $0 == expanded.presentation.active && expanded.expanded
            && expanded.permissions.permits($0.section, outgoing: false) } ?? true
        let active = panel.mode == mode && activeSection && context?.kind == kind
        content.background(CoveMediaRegionMarker(context: active ? context : nil))
    }
}

@MainActor
struct NotchView: View {
    @ObservedObject var store: CoveStore
    private let cutout: CGSize?
    @ObservedObject private var media: MediaController
    @ObservedObject private var system: SystemController
    @ObservedObject private var activities: ActivityController
    private let waveform: AudioWaveformController
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var settledPresentation: CovePanelMode?
    @State private var lastExpandedSection: CoveExpandedSectionPresentation?

    init(store: CoveStore, cutout: CGSize? = nil) {
        self.store = store
        self.cutout = cutout
        _media = ObservedObject(wrappedValue: store.media)
        _system = ObservedObject(wrappedValue: store.system)
        _activities = ObservedObject(wrappedValue: store.activities)
        waveform = store.waveform
    }

    /// The window owner can use the same dimensions as the rendered surface.
    static func desiredSize(store: CoveStore, cutout: CGSize? = nil, expanded: Bool? = nil) -> CGSize {
        let width = max(160, store.preferences.notchWidth)
        let clearance = presentationCutout(store: store, physical: cutout)
        let cutoutWidth = Double(clearance.width)
        let cutoutHeight = Double(clearance.height)
        let height = max(32, store.preferences.notchHeight, cutoutHeight)
        if expanded ?? store.isExpanded {
            let active = store.visibleTab
            let contentHeight: Double = active == .media ? (store.showsExpandedDuo ? 240 : 205)
                : active == .calendar ? 235 : 260
            return CGSize(width: max(440, width, cutoutWidth + 80), height: max(contentHeight + cutoutHeight, height))
        }
        if store.hud != nil {
            return CGSize(width: max(310, width, cutoutWidth > 0 ? cutoutWidth + 240 : 0), height: max(40, height))
        }
        if store.showsMediaPeek {
            return CGSize(width: max(360, width, cutoutWidth + 80), height: max(height, cutoutHeight + 56))
        }
        if store.compactActivity == .media {
            if store.isCompactActivityVisible(.timer) ||
                store.isCompactActivityVisible(.calendar) {
                return CGSize(width: max(300, width, cutoutWidth > 0 ? cutoutWidth + 220 : 0), height: height)
            }
            return CGSize(width: max(250, width, cutoutWidth > 0 ? cutoutWidth + 140 : 0), height: height)
        }
        if store.compactActivity == .timer {
            return CGSize(width: max(250, width, cutoutWidth > 0 ? cutoutWidth + 145 : 0), height: height)
        }
        if store.compactActivity == .calendar {
            return CGSize(width: max(300, width, cutoutWidth > 0 ? cutoutWidth + 200 : 0), height: height)
        }
        return CGSize(width: max(width, cutoutWidth > 0 ? cutoutWidth + 160 : 0), height: height)
    }

    private var motion: Animation? {
        guard !systemReduceMotion && !store.preferences.reduceMotion else { return nil }
        return CoveMotion.animation(preferences: store.preferences, hud: !store.isExpanded && store.hud != nil, kind: store.hud?.kind)
    }

    private var compactMode: CoveCompactMode {
        if let hud = store.hud { return .hud(hud.kind) }
        if store.showsMediaPeek { return .peek }
        return .activity(store.compactActivity)
    }

    private var panelMode: CovePanelMode {
        store.isExpanded ? .expanded : .compact(compactMode)
    }

    private var usesImmediateMotion: Bool {
        systemReduceMotion || store.preferences.reduceMotion
            || (!store.isExpanded && store.hud != nil && store.preferences.speed(for: store.hud?.kind) == "instant")
    }

    private var compactMotion: Animation? {
        guard !systemReduceMotion && !store.preferences.reduceMotion else { return nil }
        return CoveMotion.contentAnimation(preferences: store.preferences, hud: !store.isExpanded && store.hud != nil, entering: false, kind: store.hud?.kind)
    }

    private func contentTransition(mode: CovePanelMode) -> AnyTransition {
        let reduced = systemReduceMotion || store.preferences.reduceMotion
        guard !reduced else { return .identity }
        let fade = AnyTransition.modifier(active: CovePanelFade(opacity: 0, mode: mode),
                                         identity: CovePanelFade(opacity: 1, mode: mode))
        // Compact controls already fit the viewport. Crossfade them together;
        // only expanded controls wait for the native window to open first.
        if case .compact = mode { return fade.animation(compactMotion) }
        return .asymmetric(
            insertion: fade.animation(CoveMotion.contentAnimation(
                preferences: store.preferences, hud: !store.isExpanded && store.hud != nil, entering: true, kind: store.hud?.kind)),
            removal: fade.animation(CoveMotion.contentAnimation(
                preferences: store.preferences, hud: !store.isExpanded && store.hud != nil, entering: false, kind: store.hud?.kind)))
    }

    private var enabledTabs: [CoveTab] { store.enabledTabs }
    private var visibleTab: CoveTab? { store.visibleTab }

    private var showsDuo: Bool {
        store.showsExpandedDuo
    }

    private var expandedSectionPermissions: CoveExpandedSectionPermissions {
        CoveExpandedSectionPermissions(
            mediaEnabled: store.preferences.enableMedia && !system.state.isLocked,
            mediaAvailable: media.state.available,
            calendarEnabled: store.preferences.enableCalendar && activities.calendarEnabled,
            calendarDetailsVisible: !activities.calendarDetailsHidden,
            filesEnabled: store.preferences.enableFileTray,
            timerEnabled: store.preferences.enableTimer)
    }

    private var expandedSectionPresentation: CoveExpandedSectionPresentation {
        let section = CoveExpandedSection(tab: visibleTab, duo: showsDuo)
        var next = lastExpandedSection?.targeting(section) ?? CoveExpandedSectionPresentation(section: section)
        if usesImmediateMotion {
            next.settled = true
            next.outgoing = nil
        }
        if let outgoing = next.outgoing,
           !expandedSectionPermissions.permits(outgoing.section, outgoing: true) {
            next.outgoing = nil
        }
        return next
    }

    private var expandedSectionMotion: Animation? {
        guard !systemReduceMotion && !store.preferences.reduceMotion else { return nil }
        // Replacements use the existing short fade, with no viewport-open delay.
        return CoveMotion.contentAnimation(preferences: store.preferences, hud: false, entering: false)
    }

    private func expandedSectionTransition(_ identity: CoveExpandedSectionIdentity) -> AnyTransition {
        .modifier(active: CoveExpandedSectionFade(opacity: 0, identity: identity),
                  identity: CoveExpandedSectionFade(opacity: 1, identity: identity))
            .animation(expandedSectionMotion)
    }

    private static func presentationCutout(store: CoveStore, physical: CGSize?) -> CGSize {
        CoveNotchCutout.resolve(physical: physical ?? CGSize(width: store.physicalNotchWidth,
            height: store.physicalNotchHeight), preferences: store.preferences)
    }

    private var cutoutHeight: Double { Double(Self.presentationCutout(store: store, physical: cutout).height) }
    private var compactGap: Double { Double(Self.presentationCutout(store: store, physical: cutout).width) }
    private var surfaceShape: CoveNotchShape {
        CoveNotchShape(radius: store.isExpanded ? max(24, store.preferences.cornerRadius) : store.preferences.cornerRadius,
                       floating: cutoutHeight == 0)
    }

    var body: some View {
        let section = expandedSectionPresentation
        surface
            .environment(\.colorScheme, .dark)
            .environment(\.coveExpandedSection, CoveExpandedSectionContext(
                presentation: section, permissions: expandedSectionPermissions, expanded: store.isExpanded))
            .environment(\.covePanelPresentation, CovePanelPresentation(
                mode: panelMode,
                immediate: usesImmediateMotion || settledPresentation == panelMode,
                mediaAvailable: store.preferences.enableMedia && media.state.available,
                timerAvailable: store.preferences.enableTimer && activities.timer.remaining > 0,
                calendarAvailable: store.preferences.enableCalendar && activities.eventActivity != nil,
                calendarDetailsVisible: !activities.calendarDetailsHidden,
                peekEnabled: store.preferences.peekOnSongChange, hud: store.hud?.kind))
            .onChange(of: usesImmediateMotion) { _, immediate in
                // Keep an interrupted fade settled if Reduce Motion is turned
                // off again before SwiftUI retires the old transition.
                if immediate { settledPresentation = panelMode }
            }
            .onChange(of: panelMode) { _, mode in
                settledPresentation = usesImmediateMotion ? mode : nil
            }
            .onChange(of: section, initial: true) { _, presentation in
                // Persist revocations and Reduce Motion settlement. A later
                // distinct section gets a fresh revision and can animate again.
                lastExpandedSection = presentation
            }
            .onExitCommand(perform: store.collapse)
    }

    private var surface: some View {
        let size = Self.desiredSize(store: store, cutout: cutout)
        return GeometryReader { viewport in
            content
                .animation(motion, value: store.isExpanded)
                .animation(motion, value: store.hud?.kind)
                .animation(motion, value: store.showsMediaPeek)
                .animation(compactMotion, value: compactMode)
                // Lay out controls at their destination size once. AppKit owns the
                // moving viewport; proposing every intermediate window size to the
                // controls makes labels, spacers and sliders reflow during a morph.
                // Keep this frame outside the content's animation transaction.
                .frame(width: size.width, height: size.height, alignment: .top)
                .frame(width: viewport.size.width, height: viewport.size.height, alignment: .top)
                .background(Color.black, in: surfaceShape)
                .clipShape(surfaceShape)
                .overlay {
                    // Clip a doubled stroke to keep the full 1 pt outline inside
                    // the existing surface. It adds no window area or input region.
                    let outlined = store.preferences.showContrastOutline || contrast == .increased
                    Group {
                        if outlined {
                            let outlineColor = store.preferences.useAccentOutline && contrast != .increased
                                ? CoveNotchStyle.accent(store.preferences.accent) : Color.white
                            surfaceShape.stroke(outlineColor.opacity(contrast == .increased ? 1 : 0.45), lineWidth: 2)
                                .clipShape(surfaceShape)
                        } else {
                            surfaceShape.stroke(Color.white.opacity(store.isExpanded ? 0.085 : 0.035), lineWidth: 0.6)
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .foregroundStyle(Color.white)
                .tint(CoveNotchStyle.accent(store.preferences.accent))
                .opacity(store.hidesCompactWhenIdle ? 0 : 1)
                .animation(motion, value: store.hidesCompactWhenIdle)
        }
    }

    @ViewBuilder private var content: some View {
        let expandedSize = Self.desiredSize(store: store, cutout: cutout, expanded: true)
        let compactSize = Self.desiredSize(store: store, cutout: cutout, expanded: false)
        let compactMode = self.compactMode
        ZStack(alignment: .top) {
            if store.isExpanded {
                expanded
                    .frame(width: expandedSize.width, height: expandedSize.height)
                    .transition(contentTransition(mode: .expanded))
            } else {
                Button {
                    guard !store.isExpanded, compactMode == self.compactMode else { return }
                    store.openCompactActivity()
                } label: {
                    compact(mode: compactMode)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(compactAccessibilityLabel)
                .accessibilityHint("Show OpenCove controls")
                .accessibilityActions {
                    if let activity = store.compactDismissActivity, let target = store.compactDismissTarget {
                        Button("Dismiss \(activity.title) Activity") { store.dismissCompactActivity(target: target) }
                    }
                    if let activity = store.compactRestoreActivity, let target = store.compactRestoreTarget {
                        Button("Restore \(activity.title) Activity") { store.restoreCompactActivity(target: target) }
                    }
                }
                .frame(width: compactSize.width, height: compactSize.height)
                .id(compactMode)
                .transition(contentTransition(mode: .compact(compactMode)))
            }
        }
    }

    private func compactArtworkData(mode: CoveCompactMode) -> Data? {
        guard store.preferences.enableMedia, media.state.available else { return nil }
        guard mode == .peek || mode == .activity(.media) else { return nil }
        return media.state.artworkData
    }

    private func compact(mode: CoveCompactMode) -> some View {
        CoveArtworkReader(data: compactArtworkData(mode: mode)) { artwork in
            compactContent(mode: mode, artwork: artwork)
        }
    }

    private func mediaAccent(artwork: CoveArtworkThumbnail?) -> Color {
        (store.preferences.musicColorAccent ? artwork?.tint : nil)
            ?? CoveNotchStyle.accent(store.preferences.accent)
    }

    @ViewBuilder private func compactContent(mode: CoveCompactMode, artwork: CoveArtworkThumbnail?) -> some View {
        if store.hidesCompactWhenIdle && mode == compactMode {
            Color.clear
        } else if case .hud(let kind) = mode, let hud = store.hud, hud.kind == kind {
            CoveCompactHUD(hud: hud, accent: CoveNotchStyle.accent(store.preferences.accent), centerGap: compactGap,
                           showLabels: store.preferences.showHUDLabels, showPercentage: store.preferences.showHUDPercentage,
                           brightnessHUDGlow: store.preferences.brightnessHUDGlow)
                .padding(.horizontal, 18)
        } else if mode == .peek && store.preferences.enableMedia && media.state.available {
            mediaPeek(artwork: artwork)
        } else if mode == .activity(.media) && store.preferences.enableMedia && media.state.available {
            HStack(spacing: 0) {
                CoveArtwork(thumbnail: artwork, size: 23, radius: 6,
                            sourceIdentifier: media.state.sourceBundleIdentifier,
                            isPlaying: media.state.isPlaying,
                            reduceMotion: store.preferences.reduceMotion)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: compactGap)
                    .background(CoveMediaRegionMarker(blocksInput: true))
                HStack(spacing: 8) {
                if store.preferences.enableFocus && system.state.focusAvailable && system.state.focusEnabled {
                    Image(systemName: "moon.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.indigo.opacity(0.9))
                }
                if store.preferences.showPlaybackIndicator {
                    if store.preferences.showLiveWaveform {
                        LiveWaveformView(controller: waveform, isPlaying: media.state.isPlaying,
                                         color: mediaAccent(artwork: artwork))
                    } else {
                        CoveAudioBars(isPlaying: media.state.isPlaying,
                                      reduceMotion: systemReduceMotion || store.preferences.reduceMotion,
                                      color: mediaAccent(artwork: artwork))
                    }
                }
                if store.isCompactActivityVisible(.timer) ||
                    store.isCompactActivityVisible(.calendar) {
                    VStack(alignment: .trailing, spacing: 1) {
                        if store.isCompactActivityVisible(.timer) {
                            Label { CoveTimerText(timer: activities.timer) } icon: { Image(systemName: "timer") }
                        }
                        if store.isCompactActivityVisible(.calendar), let activity = activities.eventActivity {
                            Label((activity.phase == .startingSoon ? "in " : "") + CoveNotchStyle.duration(Double(activity.remainingSeconds)),
                                  systemImage: "calendar")
                        }
                    }
                    .font(.system(size: 9, weight: .medium, design: .rounded)).monospacedDigit()
                    .foregroundStyle(CoveNotchStyle.secondary).lineLimit(1)
                    .background(CoveMediaRegionMarker(blocksInput: true))
                }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 15)
            .modifier(CoveMediaSkipRegionGate(context: CoveMediaSkipContext.current(in: store),
                kind: .compact, mode: .compact(.activity(.media))))
        } else if mode == .activity(.timer) && store.preferences.enableTimer && activities.timer.remaining > 0 {
            HStack(spacing: 0) {
                Image(systemName: activities.timer.running ? "timer" : "pause.fill")
                    .foregroundStyle(CoveNotchStyle.accent(store.preferences.accent))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: compactGap)
                CoveTimerText(timer: activities.timer)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 18)
        } else if mode == .activity(.calendar), store.preferences.enableCalendar, let activity = activities.eventActivity {
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
        } else if mode == .activity(.clock) {
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
        } else {
            Color.clear
        }
    }

    private func mediaPeek(artwork: CoveArtworkThumbnail?) -> some View {
        HStack(spacing: 10) {
            CoveArtwork(thumbnail: artwork, size: 36, radius: 8,
                        sourceIdentifier: media.state.sourceBundleIdentifier,
                        isPlaying: media.state.isPlaying,
                        reduceMotion: store.preferences.reduceMotion)
            VStack(alignment: .leading, spacing: 3) {
                Text(CoveNotchStyle.metadataLabel(media.state.title.isEmpty ? "Untitled" : media.state.title, limit: 96))
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(CoveNotchStyle.metadataLabel(media.state.artist.isEmpty ? media.state.source : media.state.artist, limit: 96))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(CoveNotchStyle.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if store.preferences.showPlaybackIndicator {
                if store.preferences.showLiveWaveform {
                    LiveWaveformView(controller: waveform, isPlaying: media.state.isPlaying,
                                     color: mediaAccent(artwork: artwork))
                } else {
                    CoveAudioBars(isPlaying: media.state.isPlaying,
                                  reduceMotion: systemReduceMotion || store.preferences.reduceMotion,
                                  color: mediaAccent(artwork: artwork))
                }
            }
        }
        .padding(.horizontal, 18)
        .modifier(CoveMediaSkipRegionGate(context: CoveMediaSkipContext.current(in: store),
            kind: .peek, mode: .compact(.peek)))
        .padding(.top, cutoutHeight + 8)
        .padding(.bottom, 12)
    }

    private var expanded: some View {
        let identity = expandedSectionPresentation.active
        return VStack(spacing: 0) {
            ZStack {
                CoveExpandedSectionContent(identity: identity) {
                    expandedContent(identity: identity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(identity)
                .transition(expandedSectionTransition(identity))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(expandedSectionMotion, value: identity)
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
                        Button { store.selectTab(tab) } label: {
                            Label(tab == .media && showsDuo ? "Media & Calendar" : tab.title, systemImage: tab.symbol)
                        }
                    }
                    Divider()
                    if let activity = store.compactRestoreActivity, let target = store.compactRestoreTarget {
                        Button("Restore \(activity.title) Activity") { store.restoreCompactActivity(target: target) }
                    }
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
    }

    @ViewBuilder private func expandedContent(identity: CoveExpandedSectionIdentity) -> some View {
        let section = identity.section
        switch section.tab {
        case .media:
            if section.duo {
                HStack(alignment: .top, spacing: 13) {
                    CoveMediaSurface(media: media, system: system, waveform: waveform,
                                     showMediaTotalDuration: store.preferences.showMediaTotalDuration,
                                     showPlaybackIndicator: store.preferences.showPlaybackIndicator,
                                     showLiveWaveform: store.preferences.showLiveWaveform, condensed: true,
                                     musicColorAccent: store.preferences.musicColorAccent,
                                     reduceMotion: store.preferences.reduceMotion)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .modifier(CoveMediaSkipRegionGate(context: CoveMediaSkipContext.current(in: store),
                            kind: .duo, mode: .expanded, section: identity))
                    Rectangle().fill(.white.opacity(0.09)).frame(width: 1)
                    CoveCalendarView(activities: activities, showCalendarList: store.preferences.showCalendarList,
                                     showCalendarEventIndicators: store.preferences.showCalendarEventIndicators,
                                     useCalendarViewSourceColors: store.preferences.useCalendarViewSourceColors,
                                     condensed: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                CoveMediaSurface(media: media, system: system, waveform: waveform,
                                 showMediaTotalDuration: store.preferences.showMediaTotalDuration,
                                 showPlaybackIndicator: store.preferences.showPlaybackIndicator,
                                 showLiveWaveform: store.preferences.showLiveWaveform,
                                 musicColorAccent: store.preferences.musicColorAccent,
                                 reduceMotion: store.preferences.reduceMotion)
                    .modifier(CoveMediaSkipRegionGate(context: CoveMediaSkipContext.current(in: store),
                        kind: .expanded, mode: .expanded, section: identity))
            }
        case .calendar:
            CoveCalendarView(activities: activities, showCalendarList: store.preferences.showCalendarList,
                             showCalendarEventIndicators: store.preferences.showCalendarEventIndicators,
                             useCalendarViewSourceColors: store.preferences.useCalendarViewSourceColors)
        case .files:
            CoveFileSurface(activities: activities)
        case .timer:
            CoveTimerSurface(activities: activities, color: CoveNotchStyle.accent(store.preferences.accent),
                             reduceMotion: systemReduceMotion || store.preferences.reduceMotion)
        case nil:
            CoveEmptySurface(symbol: "sparkle", title: "Your quiet space",
                             message: "Choose what appears here in Settings.",
                             actionTitle: "Open Settings", action: store.openSettings)
        }
    }

    private var timerAccessibilityText: Text {
        let timer = activities.timer
        if timer.running, let deadline = timer.endsAt {
            return Text(timerInterval: min(Date(), deadline)...deadline, countsDown: true,
                        showsHours: timer.duration >= 3600)
        }
        return Text(CoveNotchStyle.duration(timer.remaining))
    }

    private var compactAccessibilityLabel: Text {
        if let hud = store.hud {
            return Text([hud.title, hud.subtitle].filter { !$0.isEmpty }.joined(separator: ", "))
        }
        if store.showsMediaPeek {
            return Text("New playing item, \(media.state.title), \(media.state.artist)")
        }
        if store.compactActivity == .media {
            let label = "\(media.state.isPlaying ? "Playing" : "Paused"), \(media.state.title), \(media.state.artist)"
            var calendar = ""
            if store.isCompactActivityVisible(.calendar), let activity = activities.eventActivity {
                calendar = ", \(activity.event.title), \(activity.phase == .current ? "ends" : "starts") in \(CoveNotchStyle.duration(Double(activity.remainingSeconds)))"
            }
            if store.isCompactActivityVisible(.timer) {
                return Text("\(label), timer \(timerAccessibilityText) remaining\(calendar)")
            }
            return Text(label + calendar)
        }
        if store.compactActivity == .timer {
            return Text("Timer, \(timerAccessibilityText) remaining")
        }
        if store.compactActivity == .calendar, let activity = activities.eventActivity {
            return Text("\(activity.event.title), \(activity.phase == .current ? "ends" : "starts") in \(CoveNotchStyle.duration(Double(activity.remainingSeconds)))")
        }
        return Text("OpenCove, \(Date.now.formatted(date: .abbreviated, time: .shortened))")
    }
}
