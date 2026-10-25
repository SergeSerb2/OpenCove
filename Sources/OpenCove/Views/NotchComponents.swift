import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum CoveNotchStyle {
    static func metadataLabel(_ text: String, limit: Int = 32) -> String {
        let limit = min(160, max(0, limit))
        let units = Array(text.utf16.prefix(limit + 1))
        let prefix = String(decoding: units.prefix(limit), as: UTF16.self)
        return units.count > limit ? prefix + "…" : prefix
    }
    private static let secondaryTone = 0.52
    static let secondary = Color.white.opacity(secondaryTone)
    static let secondaryNative = NSColor(srgbRed: secondaryTone, green: secondaryTone,
                                         blue: secondaryTone, alpha: 1)
    static let tertiary = Color.white.opacity(0.30)
    static let surface = Color.white.opacity(0.065)

    static func accent(_ name: String) -> Color {
        switch name.lowercased() {
        case "blue": return .cyan
        case "purple": return Color(red: 0.73, green: 0.61, blue: 1)
        case "pink": return .pink
        case "orange": return .orange
        case "white": return .white
        default: return Color(red: 0.55, green: 0.95, blue: 0.77)
        }
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max / 2) else { return "—" }
        let value = Int(seconds.rounded(.up))
        if value >= 3600 {
            return "\(value / 3600):" + String(format: "%02d:%02d", (value / 60) % 60, value % 60)
        }
        return "\(value / 60):" + String(format: "%02d", value % 60)
    }

    static func fraction(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }

    static func calendarColor(_ hex: String) -> Color {
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard value.count == 6, let number = UInt64(value, radix: 16) else { return .mint }
        return Color(red: Double((number >> 16) & 255) / 255,
                     green: Double((number >> 8) & 255) / 255,
                     blue: Double(number & 255) / 255)
    }
}

/// The small upper shoulders meet the menu bar; the lower corners stay continuous.
struct CoveNotchShape: Shape {
    var radius: Double
    var floating = false

    var animatableData: Double {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        if floating {
            return RoundedRectangle(cornerRadius: min(radius, rect.height / 2), style: .continuous).path(in: rect)
        }
        let r = min(max(8, radius), min(rect.width / 3, rect.height * 0.7))
        let shoulder = min(9.0, r * 0.45)
        return Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - shoulder, y: rect.minY + shoulder),
                              control: CGPoint(x: rect.maxX - shoulder, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - shoulder, y: rect.maxY - r))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - shoulder - r, y: rect.maxY),
                              control: CGPoint(x: rect.maxX - shoulder, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + shoulder + r, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.minX + shoulder, y: rect.maxY - r),
                              control: CGPoint(x: rect.minX + shoulder, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + shoulder, y: rect.minY + shoulder))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY),
                              control: CGPoint(x: rect.minX + shoulder, y: rect.minY))
            path.closeSubpath()
        }
    }

}

struct CoveIconButton: View {
    var symbol: String
    var label: String
    var size: Double = 11
    var allowsKeyboardFocus = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(CoveQuietButtonStyle())
        .focusable(allowsKeyboardFocus)
        .accessibilityLabel(label)
        .help(label)
    }
}

struct CoveQuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.55 : 0.8))
            .background(.white.opacity(configuration.isPressed ? 0.12 : 0),
                        in: RoundedRectangle(cornerRadius: 7))
            .opacity(enabled ? 1 : 0.35)
    }
}

struct CovePillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.6 : 0.9))
            .background(.white.opacity(configuration.isPressed ? 0.15 : 0.085), in: Capsule())
            .opacity(enabled ? 1 : 0.35)
    }
}

/// Each surface shares one cache request for its cover and color. Match the
/// result to the rendered bytes before the replacement task has even started.
@MainActor
struct CoveArtworkReader<Content: View>: View {
    var data: Data?
    @ViewBuilder var content: (CoveArtworkThumbnail?) -> Content
    @State private var resolved: ResolvedArtwork?

    private struct ResolvedArtwork {
        let data: Data
        let thumbnail: CoveArtworkThumbnail?
    }

    var body: some View {
        content(resolved?.data == data ? resolved?.thumbnail : nil)
            .task(id: data) {
                guard !Task.isCancelled else { return }
                guard let data else {
                    resolved = nil
                    return
                }
                let thumbnail = await CoveArtworkCache.shared.thumbnail(data)
                guard !Task.isCancelled else { return }
                resolved = ResolvedArtwork(data: data, thumbnail: thumbnail)
            }
    }
}

struct CoveArtwork: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.isEnabled) private var isEnabled
    var thumbnail: CoveArtworkThumbnail?
    var size: Double
    var radius: Double = 12
    var sourceIdentifier: String?
    var isPlaying: Bool
    var reduceMotion = false
    @State private var first: RetainedArtwork?
    @State private var second: RetainedArtwork?
    @State private var showsSecond = false
    @State private var fadeRevision: UInt64 = 0
    @State private var fadePhase = FadePhase.idle
    @State private var decodeGap: UUID?

    private enum FadePhase: Equatable {
        case idle
        case fading(UInt64)
        case completed(UInt64)
    }

    private struct RetainedArtwork {
        let source: String
        let thumbnail: CoveArtworkThumbnail
    }

    private struct Input: Hashable {
        let source: String?
        let image: ObjectIdentifier?
    }

    private var input: Input {
        Input(source: sourceIdentifier, image: thumbnail.map { ObjectIdentifier($0.image) })
    }

    private var current: RetainedArtwork? { showsSecond ? second : first }
    private var immediate: Bool { reduceMotion || systemReduceMotion || !isEnabled }
    private var hasRetainedSource: Bool {
        guard let sourceIdentifier, !sourceIdentifier.isEmpty else { return false }
        return current?.source == sourceIdentifier
    }

    // Immediate rendering keeps the target cover during a same-source decode gap.
    // This never supplies cached bytes or tint as the current item's artwork.
    private var displayed: CoveArtworkThumbnail? {
        thumbnail ?? (hasRetainedSource ? current?.thumbnail : nil)
    }

    private var artworkOpacity: Double { isPlaying ? 1.0 : 0.60 }

    var body: some View {
        Group {
            if !immediate && hasRetainedSource {
                // Fixed slots retarget on A/B/A without accumulating removal
                // transitions. An opaque lower slot prevents a dark midpoint.
                CoveArtworkTransition(first: retainedImage(first), second: retainedImage(second),
                                      inputIdentity: input.image,
                                      showsSecond: showsSecond, sourceIdentifier: sourceIdentifier,
                                      revision: fadeRevision, fading: fadePhase == .fading(fadeRevision), size: size) { revision in
                    guard fadeRevision == revision, fadePhase == .fading(revision) else { return }
                    fadePhase = .completed(revision)
                }
                .opacity(artworkOpacity)
                .transition(.identity)
            } else if let thumbnail = displayed {
                image(thumbnail).opacity(artworkOpacity).transition(.identity)
            } else {
                RoundedRectangle(cornerRadius: radius)
                    .fill(LinearGradient(colors: [.white.opacity(0.12), .white.opacity(0.035)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.32, weight: .medium))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    .transition(.identity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .transaction {
            if immediate || !hasRetainedSource {
                $0.animation = nil
                $0.disablesAnimations = true
            }
        }
        .onAppear { updateArtwork() }
        .onChange(of: input) { _, _ in updateArtwork() }
        .onChange(of: immediate) { _, immediate in
            if immediate { updateArtwork() }
        }
        .onChange(of: fadePhase) { _, phase in
            guard case .completed(let revision) = phase, fadeRevision == revision else { return }
            if showsSecond { first = nil } else { second = nil }
            fadePhase = .idle
            // Read the latest view input here. The native completion reports
            // only a phase and never reads a thumbnail from the fade's start.
            updateArtwork()
        }
        .task(id: decodeGap) {
            guard !Task.isCancelled, let gap = decodeGap else { return }
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            guard !Task.isCancelled, decodeGap == gap else { return }
            decodeGap = nil
            settle(to: nil)
        }
        .onDisappear {
            decodeGap = nil
            settle(to: nil)
        }
        .overlay(RoundedRectangle(cornerRadius: radius).stroke(.white.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private func image(_ thumbnail: CoveArtworkThumbnail) -> some View {
        Image(decorative: thumbnail.image, scale: 1).resizable().scaledToFill()
    }

    private func retainedImage(_ cover: RetainedArtwork?) -> CGImage? {
        // Suppress old-source pixels before the input callback settles state.
        guard let cover, cover.source == sourceIdentifier else { return nil }
        return cover.thumbnail.image
    }

    private func settle(to cover: RetainedArtwork?) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            fadeRevision &+= 1
            fadePhase = .idle
            first = cover
            second = nil
            showsSecond = false
        }
    }

    private func updateArtwork() {
        guard let sourceIdentifier, !sourceIdentifier.isEmpty else {
            decodeGap = nil
            settle(to: nil)
            return
        }
        guard let thumbnail else {
            // Motion/section changes must not extend an existing decode hold.
            if hasRetainedSource {
                if decodeGap == nil { decodeGap = UUID() }
                // Preserve both visible slots until the unfinished fade ends.
                if immediate { settle(to: current) }
            } else {
                decodeGap = nil
                settle(to: nil)
            }
            return
        }
        decodeGap = nil
        let next = RetainedArtwork(source: sourceIdentifier, thumbnail: thumbnail)
        guard hasRetainedSource, !immediate else { settle(to: next); return }
        if let current, current.thumbnail.image === thumbnail.image { return }
        let outgoing = showsSecond ? first : second
        if outgoing?.thumbnail.image !== thumbnail.image {
            // A third cover must not replace a slot that still contributes to
            // the blend. Coalesce in the live input, without retaining a third
            // cover; the completed phase above will pick up the latest one.
            guard fadePhase == .idle else { return }
            if showsSecond { first = next } else { second = next }
        }
        fadeRevision &+= 1
        let revision = fadeRevision
        fadePhase = .fading(revision)
        showsSecond.toggle()
    }
}

struct CoveCompactHUD: View {
    let hud: CoveHUD
    let accent: Color
    var centerGap: Double = 0
    var showLabels = true
    var showPercentage = true
    var brightnessHUDGlow = false

    private var percentage: String? {
        guard showPercentage, let value = hud.value, value.isFinite else { return nil }
        return "\(Int((CoveNotchStyle.fraction(value) * 100).rounded()))%"
    }

    @ViewBuilder private var hudSymbol: some View {
        if hud.kind == .brightness && brightnessHUDGlow {
            // OpenCove's static symbol glow stays inside the existing surface clip.
            Image(systemName: hud.symbol)
                .shadow(color: accent.opacity(0.65), radius: 2, x: 0, y: 0)
        } else {
            Image(systemName: hud.symbol)
        }
    }

    var body: some View {
        if centerGap > 0 {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    hudSymbol.foregroundStyle(accent)
                    if showLabels {
                        Text(hud.title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: centerGap)
                VStack(alignment: .trailing, spacing: 4) {
                    if let value = hud.value {
                        if let percentage {
                            Text(percentage)
                                .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                        }
                        ProgressView(value: CoveNotchStyle.fraction(value)).tint(accent)
                            .progressViewStyle(.linear).frame(width: 70)
                            .accessibilityHidden(true)
                    } else if showLabels {
                        Text(hud.subtitle.isEmpty ? hud.title : hud.subtitle)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(CoveNotchStyle.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        } else { continuousHUD }
    }

    private var continuousHUD: some View {
        HStack(spacing: 11) {
            hudSymbol
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(hud.kind == .battery ? .green : accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                if showLabels || percentage != nil {
                    HStack(spacing: 8) {
                        if showLabels {
                            Text(hud.title)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if let percentage {
                            Text(percentage)
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(CoveNotchStyle.secondary)
                        }
                    }
                }
                if let value = hud.value {
                    GeometryReader { geometry in
                        Capsule().fill(.white.opacity(0.14))
                            .overlay(alignment: .leading) {
                                Capsule().fill(accent)
                                    .frame(width: geometry.size.width * CoveNotchStyle.fraction(value))
                            }
                    }
                    .frame(height: 3)
                    .accessibilityHidden(true)
                } else if showLabels && !hud.subtitle.isEmpty {
                    Text(hud.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(CoveNotchStyle.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct CoveBatteryMark: View {
    var percent: Int
    var charging: Bool
    var showPercent = false

    private var symbol: String {
        if charging { return "battery.100percent.bolt" }
        switch percent {
        case ...10: return "battery.0percent"
        case 11...35: return "battery.25percent"
        case 36...60: return "battery.50percent"
        case 61...85: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if showPercent {
                Text("\(min(100, max(0, percent)))%")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
            Image(systemName: symbol).font(.system(size: 13))
        }
        .foregroundStyle(charging ? Color.green : percent <= 20 ? Color.orange : CoveNotchStyle.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(percent) percent\(charging ? ", charging" : "")")
        .help("Battery: \(percent)%\(charging ? " · Charging" : "")")
    }
}

@MainActor
struct CoveSystemIndicators: View {
    @ObservedObject var system: SystemController
    var preferences: CovePreferences

    var body: some View {
        HStack(spacing: 8) {
            if system.state.isLocked {
                Image(systemName: "lock.fill").accessibilityLabel("Screen locked")
            }
            if preferences.enableFocus && system.state.focusAvailable && system.state.focusEnabled {
                Image(systemName: "moon.fill")
                    .foregroundStyle(.indigo)
                    .accessibilityLabel("Focus is on")
                    .help("Focus is on")
            }
            if preferences.enableBluetooth && !system.state.bluetoothDevices.isEmpty {
                Image(systemName: system.state.audioOutputIsBluetooth ? "headphones" : "dot.radiowaves.left.and.right")
                    .accessibilityLabel("Connected: \(system.state.bluetoothDevices.joined(separator: ", "))")
                    .help(system.state.bluetoothDevices.joined(separator: ", "))
            }
            if preferences.enableBattery && system.state.hasBattery && system.state.batteryAvailable {
                CoveBatteryMark(percent: system.state.batteryPercent, charging: system.state.isCharging)
            }
        }
        .foregroundStyle(CoveNotchStyle.secondary)
        .font(.system(size: 11, weight: .medium))
    }
}

struct CoveEmptySurface: View {
    var symbol: String
    var title: String
    var message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 25, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(CoveNotchStyle.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(CovePillButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Mount the refresh schedule only around the progress controls. The model has
/// no elapsed timer, and a paused source stops this schedule completely.
@MainActor
struct CovePlaybackTimeline<Content: View>: View {
    @ObservedObject var clock: CovePlaybackClock
    @ViewBuilder var content: (Double) -> Content

    var body: some View {
        TimelineView(CovePlaybackSchedule(paused: !clock.isAdvancing)) { _ in
            content(clock.elapsed)
        }
    }
}

/// A finite paused sequence stops scheduling without replacing the progress
/// subtree. Periodic entries avoid a display link for twice-per-second labels.
private struct CovePlaybackSchedule: TimelineSchedule {
    var paused: Bool

    func entries(from startDate: Date, mode: Mode) -> AnySequence<Date> {
        if paused { return AnySequence([startDate]) }
        return AnySequence(PeriodicTimelineSchedule(from: startDate, by: 0.5)
            .entries(from: startDate, mode: mode))
    }
}

@MainActor
struct CoveMediaSurface: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @ObservedObject var media: MediaController
    let system: SystemController
    let waveform: AudioWaveformController
    var showPlaybackIndicator = true
    var showLiveWaveform = false
    var condensed = false
    var locked = false
    var musicColorAccent = true
    var reduceMotion = false
    @State private var scrubbing = false
    @State private var scrubTime = 0.0
    @State private var scrubIdentity: CoveMediaScrubIdentity?
    @State private var acceptsSliderChanges = false
    @State private var showsOutput = false

    private var duration: Double {
        let seconds = media.state.duration
        return seconds.isFinite && seconds > 0 && seconds < Double(Int.max / 2) ? seconds : 0
    }
    private var identity: CoveMediaScrubIdentity { CoveMediaScrubIdentity(state: media.state) }
    private var canSeek: Bool { media.state.available && media.state.supportsSeek && media.state.seekTarget != nil && duration > 0 }

    var body: some View {
        if media.state.available {
            CoveArtworkReader(data: media.state.artworkData) { artwork in
                VStack(spacing: condensed ? 6 : 8) {
                    header(artwork: artwork)
                    progress
                    HStack(spacing: 12) {
                        Spacer(minLength: 0)
                        transport
                        Spacer(minLength: 0)
                        if !condensed && !locked {
                            CoveIconButton(symbol: "hifispeaker", label: "Audio output and volume") { showsOutput.toggle() }
                                .popover(isPresented: $showsOutput, arrowEdge: .bottom) {
                                    CoveOutputControls(system: system)
                                        .padding(14).frame(width: 330)
                                        .preferredColorScheme(.dark)
                                }
                                .background(CoveMediaRegionMarker(blocksInput: true))
                        }
                    }
                }
                .tint(musicColorAccent ? artwork?.tint : nil)
                .background(CoveMediaRegionMarker(blocksInput: scrubbing || showsOutput))
            }
            .onAppear {
                acceptsSliderChanges = true
            }
            .onChange(of: identity) { _, _ in cancelScrubbing() }
            .onChange(of: canSeek) { _, available in if !available { cancelScrubbing() } }
            .onDisappear {
                acceptsSliderChanges = false
                scrubbing = false
                scrubIdentity = nil
            }
        } else {
            if locked {
                CoveEmptySurface(symbol: "music.note", title: "Nothing playing",
                                 message: "Start playback after unlocking.")
            } else {
                CoveEmptySurface(symbol: "music.note", title: "Nothing playing",
                                 message: media.lastError ?? "Play something in your favorite app.",
                                 actionTitle: "Refresh", action: media.refreshFromUser)
            }
        }
    }

    private func header(artwork: CoveArtworkThumbnail?) -> some View {
        let artworkTint = musicColorAccent ? artwork?.tint : nil
        return HStack(alignment: .center, spacing: condensed ? 9 : 15) {
            if locked {
                CoveArtwork(thumbnail: artwork, size: 54, radius: 12,
                            sourceIdentifier: media.state.sourceBundleIdentifier,
                            isPlaying: media.state.isPlaying, reduceMotion: reduceMotion)
            } else {
                Button(action: media.openPlayer) {
                    CoveArtwork(thumbnail: artwork, size: condensed ? 46 : 54,
                                radius: condensed ? 9 : 12,
                                sourceIdentifier: media.state.sourceBundleIdentifier,
                                isPlaying: media.state.isPlaying, reduceMotion: reduceMotion)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open media player")
                .background(CoveMediaRegionMarker(blocksInput: true))
            }
            metadata
            if !condensed && showPlaybackIndicator {
                if showLiveWaveform {
                    LiveWaveformView(controller: waveform, isPlaying: media.state.isPlaying,
                                     color: artworkTint ?? .mint)
                } else {
                    CoveAudioBars(isPlaying: media.state.isPlaying,
                                  reduceMotion: reduceMotion || systemReduceMotion,
                                  color: artworkTint ?? .white)
                }
            }
            if !condensed && !locked {
                Menu {
                    if media.state.supportsFavorite {
                        Button(media.state.isFavorited == true ? "Remove Favorite" : "Favorite", action: media.toggleFavorite)
                    }
                    if media.state.supportsCopyLink { Button("Copy Track Link", action: media.copyLink) }
                    if media.state.supportsPlaybackSpeed, let item = media.state.contentItemIdentifier {
                        let source = media.state.sourceBundleIdentifier
                        Menu("Playback Speed") {
                            ForEach(media.state.supportedPlaybackSpeeds, id: \.self) { speed in
                                Button { media.setPlaybackSpeed(speed, source: source, itemID: item) } label: {
                                    if let current = media.state.playbackSpeed, abs(current - speed) < 0.000001 {
                                        Label("\(speed.formatted())×", systemImage: "checkmark")
                                    } else { Text("\(speed.formatted())×") }
                                }
                            }
                        }
                    }
                    Button("Open Player", action: media.openPlayer)
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 13)) }
                .menuStyle(.borderlessButton)
                .background(CoveMediaRegionMarker(blocksInput: true))
                .fixedSize()
                .accessibilityLabel("More playback actions")
            }
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 5) {
            CoveScrollingMediaText(text: media.state.title.isEmpty ? "Untitled" : media.state.title,
                                   size: condensed ? 12 : 15, weight: .semibold,
                                   reduceMotion: reduceMotion || systemReduceMotion)
            CoveScrollingMediaText(text: media.lastError != nil ? (locked ? "Playback controls unavailable" : "Open player to retry controls") : (media.state.artist.isEmpty ? media.state.source : media.state.artist),
                                   size: condensed ? 10 : 11, weight: .medium,
                                   color: media.lastError != nil ? .systemOrange : CoveNotchStyle.secondaryNative,
                                   reduceMotion: reduceMotion || systemReduceMotion || media.lastError != nil,
                                   helpText: locked ? nil : media.lastError)
            HStack(spacing: 6) {
                if media.state.isExplicit == true {
                    Text("E")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 3).padding(.vertical, 1)
                        .background(.white.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 2))
                        .foregroundStyle(.white.opacity(0.8))
                        .fixedSize()
                        .accessibilityLabel("Explicit content")
                        .help("The player marks this item as explicit.")
                }
                if let format = media.state.audioFormat, !format.isEmpty {
                    Text(CoveNotchStyle.metadataLabel(format))
                        .font(.system(size: 8, weight: .semibold)).foregroundStyle(CoveNotchStyle.secondary)
                        .lineLimit(1).truncationMode(.tail)
                        .help(CoveNotchStyle.metadataLabel(format, limit: 160))
                }
                if media.state.isLive == true {
                    Label("LIVE", systemImage: "dot.radiowaves.left.and.right")
                        .font(.system(size: 8, weight: .bold)).foregroundStyle(.red)
                        .fixedSize()
                        .accessibilityLabel("Live stream")
                        .help("Live-stream status supplied by the player")
                }
                if let speed = media.state.playbackSpeed, media.state.supportsPlaybackSpeed {
                    Text("\(speed.formatted(.number.precision(.fractionLength(0...2))))×")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(CoveNotchStyle.secondary)
                        .fixedSize()
                        .accessibilityLabel("Playback speed \(speed.formatted()) times")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var progress: some View {
        if duration > 0 {
            CovePlaybackTimeline(clock: media.playback) { elapsed in
                progressControls(elapsed: elapsed)
            }
        } else {
            // No position or remaining time is displayed. Do not mount an
            // observing clock/timeline for this static, unavailable state.
            progressControls(elapsed: 0)
        }
    }

    private func progressControls(elapsed: Double) -> some View {
        // Capture this rendered control's target, including keyboard callbacks
        // that can arrive after its source item has already changed.
        let target = media.state.seekTarget
        let displayedPosition = scrubbing && scrubIdentity == identity
            ? min(duration, max(0, scrubTime)) : min(duration, max(0, elapsed))
        return VStack(spacing: 1) {
            Slider(value: Binding(get: { displayedPosition }, set: { value in
                guard acceptsSliderChanges, canSeek, value.isFinite, let target, target == media.state.seekTarget,
                      !scrubbing || scrubIdentity == identity else { return }
                scrubTime = min(duration, max(0, value))
                if !scrubbing { media.seek(to: scrubTime, target: target) }
            }),
                   in: 0...max(1, duration), onEditingChanged: { editing in
                if editing {
                    guard acceptsSliderChanges, canSeek, let target, target == media.state.seekTarget else { return }
                    scrubTime = min(duration, max(0, media.playback.elapsed))
                    scrubIdentity = identity
                    scrubbing = true
                } else {
                    let shouldSeek = acceptsSliderChanges && scrubbing && canSeek && scrubIdentity == identity
                        && target != nil && target == media.state.seekTarget
                    scrubbing = false
                    scrubIdentity = nil
                    if shouldSeek { media.seek(to: min(duration, max(0, scrubTime)), target: target) }
                }
            })
            .controlSize(.mini)
            .focusable(!locked)
            .disabled(!canSeek)
            .accessibilityLabel("Playback position")
            .accessibilityValue(duration > 0 ? "\(CoveNotchStyle.duration(displayedPosition)) of \(CoveNotchStyle.duration(duration))" : "Position unavailable")
            .background(CoveMediaRegionMarker(blocksInput: true))
            HStack {
                Text(duration > 0 ? CoveNotchStyle.duration(displayedPosition) : "—")
                Spacer()
                Text(duration > 0 ? "−\(CoveNotchStyle.duration(duration - displayedPosition))" : media.state.source)
                    .lineLimit(1)
            }
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(CoveNotchStyle.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: condensed ? 15 : 18) {
            if media.state.supportsShuffle && !condensed {
                CoveIconButton(symbol: "shuffle", label: "Toggle shuffle", allowsKeyboardFocus: !locked, action: media.toggleShuffle)
                    .foregroundStyle(media.state.isShuffling == true ? Color.mint : Color.white.opacity(0.5))
            }
            CoveIconButton(symbol: "backward.fill", label: "Previous track", size: 15,
                           allowsKeyboardFocus: !locked,
                           action: media.previous)
                .disabled(!media.state.supportsPrevious)
            Button(action: media.playPause) {
                Image(systemName: media.state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: condensed ? 19 : 25, weight: .semibold))
                    .frame(width: 44, height: 36)
            }
            .buttonStyle(CoveQuietButtonStyle())
            .focusable(!locked)
            .accessibilityLabel(media.state.isPlaying ? "Pause" : "Play")
            .disabled(!media.state.supportsPlayPause)
            CoveIconButton(symbol: "forward.fill", label: "Next track", size: 15,
                           allowsKeyboardFocus: !locked,
                           action: media.next)
                .disabled(!media.state.supportsNext)
            if media.state.supportsRepeat && !condensed {
                CoveIconButton(symbol: media.state.repeatMode == "one" ? "repeat.1" : "repeat", label: "Cycle repeat mode", allowsKeyboardFocus: !locked, action: media.cycleRepeat)
                    .foregroundStyle(media.state.isRepeating == true ? Color.mint : Color.white.opacity(0.5))
            }
        }
        .background(CoveMediaRegionMarker(blocksInput: true))
    }

    private func cancelScrubbing() {
        // Keep the gesture active until its end callback. Otherwise its later
        // value callbacks would be mistaken for keyboard edits on the new track.
        scrubIdentity = nil
    }


}

private struct CoveMediaScrubIdentity: Equatable {
    let source: String
    let target: String?
    let title: String
    let artist: String
    let album: String
    let duration: Double

    init(state: MediaState) {
        source = state.sourceBundleIdentifier
        target = state.seekTarget
        title = state.title
        artist = state.artist
        album = state.album
        duration = state.duration.isFinite ? state.duration : 0
    }
}

@MainActor
struct CoveOutputControls: View {
    @ObservedObject var system: SystemController
    var condensed = false

    var body: some View {
        HStack(spacing: 7) {
            AudioOutputPicker(system: system)
                .frame(maxWidth: condensed ? 85 : 165, alignment: .leading)
            Spacer(minLength: condensed ? 0 : 8)
            CoveIconButton(symbol: (system.state.muteAvailable && system.state.isMuted) || (system.state.volumeAvailable && system.state.volume == 0) ? "speaker.slash.fill" : "speaker.wave.2.fill",
                           label: system.state.isMuted ? "Unmute" : "Mute", action: system.toggleMute)
                .disabled(!system.state.canSetMute)
            if system.state.volumeAvailable {
            Slider(value: Binding(get: { CoveNotchStyle.fraction(system.state.volume) }, set: { system.setVolume($0) }), in: 0...1)
                .controlSize(.mini)
                .frame(width: condensed ? 56 : 98)
                .disabled(!system.state.canSetVolume)
                .help(system.state.canSetVolume ? "Output volume" : "Use the output device’s own volume controls.")
                .accessibilityLabel("Output volume")
                .accessibilityValue(system.state.volumeAvailable ? "\(Int(CoveNotchStyle.fraction(system.state.volume) * 100)) percent" : "Unavailable")
            } else {
                Text("Unavailable")
                    .font(.system(size: 9))
                    .frame(width: condensed ? 56 : 98)
                    .help("Use the output device’s own volume controls.")
            }
        }
        .foregroundStyle(CoveNotchStyle.secondary)
    }
}

@MainActor
struct CoveFileSurface: View {
    @ObservedObject var activities: ActivityController
    @State private var dropTargeted = false
    @State private var filePicker: NSOpenPanel?
    @State private var sharingAnchor = CoveFileShareReference()

    var body: some View {
        VStack(spacing: 8) {
            if activities.files.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: dropTargeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(dropTargeted ? Color.mint : .white.opacity(0.4))
                    Text(dropTargeted ? "Release to add files" : "Keep files within reach")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Drop files here to open, reveal, or AirDrop.")
                        .font(.system(size: 10)).foregroundStyle(CoveNotchStyle.secondary)
                    Button("Choose Files…", action: chooseFiles)
                        .buttonStyle(CovePillButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    Text("\(activities.files.count) \(activities.files.count == 1 ? "file" : "files")")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CoveNotchStyle.secondary)
                    Spacer()
                    CoveIconButton(symbol: "plus", label: "Add files to tray", action: chooseFiles)
                    Button("AirDrop", systemImage: "airdrop", action: activities.airDropFiles)
                        .buttonStyle(CovePillButtonStyle())
                        .accessibilityLabel("AirDrop tray files")
                    CoveIconButton(symbol: "square.and.arrow.up", label: "Share tray files") {
                        guard let view = sharingAnchor.view else {
                            activities.lastError = "The file tray must be visible before sharing. Open the tray and try again."
                            return
                        }
                        activities.shareFiles(relativeTo: view)
                    }
                    CoveIconButton(symbol: "trash", label: "Clear file tray", action: activities.clearFiles)
                }
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(activities.files, id: \.id) { file in
                            CoveTrayFileRow(file: file, activities: activities)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                Text(dropTargeted ? "Release to add files" : "Drop more files here")
                    .font(.system(size: 9)).foregroundStyle(CoveNotchStyle.tertiary)
            }
            if let error = activities.lastError {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(error).font(.system(size: 9)).lineLimit(2).help(error)
                    Spacer(minLength: 0)
                    CoveIconButton(symbol: "xmark", label: "Dismiss file action error", size: 8) {
                        activities.lastError = nil
                    }
                }
                .foregroundStyle(CoveNotchStyle.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white.opacity(dropTargeted ? 0.08 : 0.025), in: RoundedRectangle(cornerRadius: 14))
        .background(CoveFileShareAnchor(reference: sharingAnchor).allowsHitTesting(false))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(dropTargeted ? Color.mint.opacity(0.7) : .white.opacity(0.12),
                              style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .allowsHitTesting(false)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            activities.addFiles(files)
            return true
        } isTargeted: { dropTargeted = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("File tray. Drop files to add them.")
        .onDisappear {
            let panel = filePicker
            filePicker = nil
            panel?.cancel(nil)
            dropTargeted = false
        }
    }

    private func chooseFiles() {
        guard filePicker == nil else { return }
        let panel = NSOpenPanel()
        filePicker = panel
        panel.title = "Add to File Tray"
        panel.prompt = "Add Files"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        let completion: (NSApplication.ModalResponse) -> Void = { [weak panel] response in
            guard let panel, filePicker === panel else { return }
            filePicker = nil
            guard response == .OK else { return }
            activities.addFiles(panel.urls)
        }
        if let window = sharingAnchor.view?.window {
            // The notch owner keeps an expanded panel alive while its sheet is open.
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            filePicker = nil
            activities.lastError = "Open the file tray before choosing files."
        }
    }
}

@MainActor
private final class CoveFileShareReference {
    weak var view: NSView?
}

private struct CoveFileShareAnchor: NSViewRepresentable {
    let reference: CoveFileShareReference

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        reference.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { reference.view = view }
}

@MainActor
struct CoveTrayFileRow: View {
    let file: TrayFile
    @ObservedObject var activities: ActivityController

    var body: some View {
        HStack(spacing: 7) {
            if file.isAvailable {
                openButton.onDrag { NSItemProvider(object: file.url as NSURL) }
            } else {
                openButton.disabled(true)
            }
            CoveIconButton(symbol: "folder", label: "Reveal \(file.name) in Finder") {
                activities.revealFile(file.id)
            }
            .disabled(!file.isAvailable)
            CoveIconButton(symbol: "xmark", label: "Remove \(file.name) from tray", size: 9) {
                activities.removeFile(file.id)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(CoveNotchStyle.surface, in: RoundedRectangle(cornerRadius: 9))
        .contextMenu {
            Button("Open") { activities.openFile(file.id) }
                .disabled(!file.isAvailable)
            Button("Reveal in Finder") { activities.revealFile(file.id) }
                .disabled(!file.isAvailable)
            Divider()
            Button("Remove from Tray") { activities.removeFile(file.id) }
        }
    }

    private var openButton: some View {
        Button { activities.openFile(file.id) } label: {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                    .resizable().scaledToFit().frame(width: 25, height: 25)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    if !file.isAvailable {
                        Text("Add this file again to restore access.")
                            .font(.system(size: 9)).foregroundStyle(.orange).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(file.isAvailable ? "Open \(file.name)" : "\(file.name), unavailable. Add this file again to restore access.")
        .help(file.isAvailable ? file.url.path : "Add this file again to restore access.")
    }
}

@MainActor
struct CoveTimerSurface: View {
    @ObservedObject var activities: ActivityController
    var color: Color = .accentColor
    var reduceMotion = false
    private let presets: [Double] = [60, 300, 900, 1500]

    var body: some View {
        if activities.timer.remaining > 0 {
            HStack(spacing: 23) {
                ZStack {
                    Circle().stroke(.white.opacity(0.08), lineWidth: 5)
                    CoveTimerRing(timer: activities.timer, clockRevision: activities.timerClockRevision,
                                  reduceMotion: reduceMotion, color: color)
                    Image(systemName: activities.timer.running ? "timer" : "pause.fill")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tint)
                }
                .frame(width: 93, height: 93)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 9) {
                    Text(activities.timer.running ? "Time remaining" : "Timer paused")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(CoveNotchStyle.secondary)
                    CoveTimerText(timer: activities.timer)
                        .font(.system(size: 36, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                    HStack(spacing: 8) {
                        Button(activities.timer.running ? "Pause" : "Resume",
                               systemImage: activities.timer.running ? "pause.fill" : "play.fill") {
                            if activities.timer.running { activities.pauseTimer() }
                            else { activities.resumeTimer() }
                        }
                        .buttonStyle(CovePillButtonStyle())
                        Button("Cancel", action: activities.cancelTimer)
                            .buttonStyle(CovePillButtonStyle())
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
        } else {
            VStack(spacing: 13) {
                HStack(spacing: 10) {
                    Image(systemName: "timer")
                        .font(.system(size: 30, weight: .ultraLight))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Start a timer").font(.system(size: 15, weight: .semibold))
                        Text("A moment to focus. A reminder to pause.")
                            .font(.system(size: 10)).foregroundStyle(CoveNotchStyle.secondary)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    ForEach(presets, id: \.self) { seconds in
                        Button { activities.startTimer(seconds: seconds) } label: {
                            VStack(spacing: 4) {
                                Text("\(Int(seconds / 60))")
                                    .font(.system(size: 22, weight: .light, design: .rounded))
                                Text("MIN").font(.system(size: 8, weight: .semibold)).tracking(1)
                                    .foregroundStyle(CoveNotchStyle.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 63)
                            .background(CoveNotchStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(CoveQuietButtonStyle())
                        .accessibilityLabel("Start \(Int(seconds / 60)) minute timer")
                    }
                }
            }
        }
    }
}

@MainActor
struct CoveNotificationButton: View {
    @ObservedObject var activities: ActivityController
    @State private var presented = false

    var body: some View {
        CoveIconButton(symbol: activities.notifications.isEmpty ? "bell" : "bell.badge",
                       label: "Notifications, \(activities.notifications.count)") { presented.toggle() }
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Notifications").font(.system(size: 13, weight: .semibold))
                    if activities.notifications.isEmpty {
                        Text("You’re all caught up.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 65)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 13) {
                                ForEach(activities.notifications.sorted { $0.date > $1.date }, id: \.id) { notification in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(notification.title).font(.system(size: 12, weight: .semibold))
                                            Spacer()
                                            Text(notification.date, style: .relative)
                                                .font(.system(size: 9)).foregroundStyle(.secondary)
                                        }
                                        Text(notification.body).font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                    .accessibilityElement(children: .combine)
                                }
                            }
                        }
                        .frame(maxHeight: 230)
                    }
                }
                .padding(17)
                .frame(width: 300)
                .preferredColorScheme(.dark)
            }
    }
}
