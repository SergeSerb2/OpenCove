import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum CoveNotchStyle {
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
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(CoveQuietButtonStyle())
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

struct CoveArtwork: View {
    var data: Data?
    var size: Double
    var radius: Double = 12
    @State private var thumbnail: CoveArtworkThumbnail?

    var body: some View {
        Group {
            if let thumbnail {
                Image(decorative: thumbnail.image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: radius)
                    .fill(LinearGradient(colors: [.white.opacity(0.12), .white.opacity(0.035)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.32, weight: .medium))
                            .foregroundStyle(.white.opacity(0.35))
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius).stroke(.white.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
        .task(id: data) {
            thumbnail = nil
            guard let data else { return }
            let decoded = await CoveArtworkCache.shared.thumbnail(data)
            guard !Task.isCancelled else { return }
            thumbnail = decoded
        }
    }
}

struct CoveAudioBars: View {
    var isPlaying: Bool
    var reduceMotion: Bool
    var color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !isPlaying || reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<5) { index in
                    Capsule()
                        .fill(color.opacity(isPlaying ? 0.95 : 0.5))
                        .frame(width: 2.5, height: barHeight(index: index, time: time))
                }
            }
            .frame(width: 23, height: 20)
        }
        // This is a playback indicator, not a measured audio waveform.
        .accessibilityLabel(isPlaying ? "Playing" : "Paused")
    }

    private func barHeight(index: Int, time: Double) -> Double {
        guard isPlaying else { return 3 }
        guard !reduceMotion else { return [7, 13, 18, 11, 6][index] }
        return 4 + (sin(time * (3.4 + Double(index) * 0.45) + Double(index) * 1.6) + 1) * 7
    }
}

struct CoveCompactHUD: View {
    let hud: CoveHUD
    let accent: Color
    var centerGap: Double = 0

    var body: some View {
        if centerGap > 0 {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: hud.symbol).foregroundStyle(accent)
                    Text(hud.title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: centerGap)
                VStack(alignment: .trailing, spacing: 4) {
                    if let value = hud.value {
                        Text("\(Int((CoveNotchStyle.fraction(value) * 100).rounded()))%")
                            .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                        ProgressView(value: CoveNotchStyle.fraction(value)).tint(accent)
                            .progressViewStyle(.linear).frame(width: 70)
                            .accessibilityHidden(true)
                    } else {
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
            Image(systemName: hud.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(hud.kind == .battery ? .green : accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(hud.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let value = hud.value {
                        Text("\(Int((CoveNotchStyle.fraction(value) * 100).rounded()))%")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(CoveNotchStyle.secondary)
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
                } else if !hud.subtitle.isEmpty {
                    Text(hud.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(CoveNotchStyle.secondary)
                        .lineLimit(1)
                }
            }
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
        TimelineView(.animation(minimumInterval: 0.5, paused: !clock.isAdvancing)) { _ in
            content(clock.elapsed)
        }
    }
}

@MainActor
struct CoveMediaSurface: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @ObservedObject var media: MediaController
    let system: SystemController
    let waveform: AudioWaveformController
    var showLiveWaveform = false
    var condensed = false
    var musicColorAccent = true
    var reduceMotion = false
    @State private var scrubbing = false
    @State private var scrubTime = 0.0
    @State private var scrubIdentity: CoveMediaScrubIdentity?
    @State private var acceptsSliderChanges = false
    @State private var artworkTint: Color?
    @State private var showsOutput = false

    private var duration: Double {
        let seconds = media.state.duration
        return seconds.isFinite && seconds > 0 && seconds < Double(Int.max / 2) ? seconds : 0
    }
    private var identity: CoveMediaScrubIdentity { CoveMediaScrubIdentity(state: media.state) }
    private var canSeek: Bool { media.state.available && media.state.supportsSeek && duration > 0 }

    var body: some View {
        if media.state.available {
            VStack(spacing: condensed ? 6 : 8) {
                HStack(alignment: .center, spacing: condensed ? 9 : 15) {
                    Button(action: media.openPlayer) {
                        CoveArtwork(data: media.state.artworkData, size: condensed ? 46 : 54,
                                    radius: condensed ? 9 : 12)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open media player")
                    VStack(alignment: .leading, spacing: 5) {
                        CoveScrollingMediaText(text: media.state.title.isEmpty ? "Untitled" : media.state.title,
                                               size: condensed ? 12 : 15, weight: .semibold,
                                               reduceMotion: reduceMotion || systemReduceMotion)
                        CoveScrollingMediaText(text: media.lastError != nil ? "Open player to retry controls" : (media.state.artist.isEmpty ? media.state.source : media.state.artist),
                                               size: condensed ? 10 : 11, weight: .medium,
                                               color: media.lastError != nil ? .systemOrange : CoveNotchStyle.secondaryNative,
                                               reduceMotion: reduceMotion || systemReduceMotion || media.lastError != nil,
                                               helpText: media.lastError)
                        if let format = media.state.audioFormat, !format.isEmpty {
                            Text(format).font(.system(size: 8, weight: .semibold)).foregroundStyle(CoveNotchStyle.secondary)
                        }
                        if media.state.isLive == true {
                            Label("LIVE", systemImage: "dot.radiowaves.left.and.right")
                                .font(.system(size: 8, weight: .bold)).foregroundStyle(.red)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !condensed {
                        if showLiveWaveform {
                            LiveWaveformView(controller: waveform, isPlaying: media.state.isPlaying,
                                             color: musicColorAccent ? artworkTint ?? .mint : .mint)
                        } else {
                            CoveAudioBars(isPlaying: media.state.isPlaying,
                                          reduceMotion: reduceMotion || systemReduceMotion,
                                          color: musicColorAccent ? artworkTint ?? .white : .white)
                        }
                    }
                    if !condensed {
                        Menu {
                            if media.state.supportsFavorite {
                                Button(media.state.isFavorited == true ? "Remove Favorite" : "Favorite", action: media.toggleFavorite)
                            }
                            if media.state.supportsCopyLink { Button("Copy Track Link", action: media.copyLink) }
                            if media.state.supportsPlaybackSpeed {
                                ForEach(media.state.supportedPlaybackSpeeds, id: \.self) { speed in
                                    Button("\(speed.formatted())× Speed") { media.setPlaybackSpeed(speed) }
                                }
                            }
                            Button("Open Player", action: media.openPlayer)
                        } label: { Image(systemName: "ellipsis.circle").font(.system(size: 13)) }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel("More playback actions")
                    }
                }
                progress
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    transport
                    Spacer(minLength: 0)
                    if !condensed {
                        CoveIconButton(symbol: "hifispeaker", label: "Audio output and volume") { showsOutput.toggle() }
                            .popover(isPresented: $showsOutput, arrowEdge: .bottom) {
                                CoveOutputControls(system: system)
                                    .padding(14).frame(width: 330)
                                    .preferredColorScheme(.dark)
                            }
                    }
                }
            }
            .tint(musicColorAccent ? artworkTint : nil)
            .onAppear {
                acceptsSliderChanges = true
            }
            .task(id: media.state.artworkData) {
                artworkTint = nil
                guard let data = media.state.artworkData, musicColorAccent else { return }
                let thumbnail = await CoveArtworkCache.shared.thumbnail(data)
                guard !Task.isCancelled else { return }
                artworkTint = thumbnail?.tint
            }
            .onChange(of: identity) { _, _ in cancelScrubbing() }
            .onChange(of: canSeek) { _, available in if !available { cancelScrubbing() } }
            .onDisappear {
                acceptsSliderChanges = false
                scrubbing = false
                scrubIdentity = nil
            }
        } else {
            CoveEmptySurface(symbol: "music.note", title: "Nothing playing",
                             message: media.lastError ?? "Play something in your favorite app.",
                             actionTitle: "Refresh", action: media.refresh)
        }
    }

    private var progress: some View {
        CovePlaybackTimeline(clock: media.playback) { elapsed in
            let displayedPosition = scrubbing && scrubIdentity == identity
                ? min(duration, max(0, scrubTime)) : min(duration, max(0, elapsed))
            VStack(spacing: 1) {
                Slider(value: Binding(get: { displayedPosition }, set: { value in
                    guard acceptsSliderChanges, canSeek, value.isFinite,
                          !scrubbing || scrubIdentity == identity else { return }
                    scrubTime = min(duration, max(0, value))
                    if !scrubbing { media.seek(to: scrubTime) }
                }),
                       in: 0...max(1, duration), onEditingChanged: { editing in
                    if editing {
                        guard acceptsSliderChanges, canSeek else { return }
                        scrubTime = min(duration, max(0, media.playback.elapsed))
                        scrubIdentity = identity
                        scrubbing = true
                    } else {
                        let shouldSeek = acceptsSliderChanges && scrubbing && canSeek && scrubIdentity == identity
                        scrubbing = false
                        scrubIdentity = nil
                        if shouldSeek { media.seek(to: min(duration, max(0, scrubTime))) }
                    }
                })
                .controlSize(.mini)
                .disabled(!canSeek)
                .accessibilityLabel("Playback position")
                .accessibilityValue(duration > 0 ? "\(CoveNotchStyle.duration(displayedPosition)) of \(CoveNotchStyle.duration(duration))" : "Position unavailable")
                HStack {
                    Text(duration > 0 ? CoveNotchStyle.duration(displayedPosition) : "—")
                    Spacer()
                    Text(duration > 0 ? "−\(CoveNotchStyle.duration(duration - displayedPosition))" : media.state.source)
                        .lineLimit(1)
                }
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(CoveNotchStyle.tertiary)
            }
        }
    }

    private var transport: some View {
        HStack(spacing: condensed ? 15 : 18) {
            if media.state.supportsShuffle && !condensed {
                CoveIconButton(symbol: "shuffle", label: "Toggle shuffle", action: media.toggleShuffle)
                    .foregroundStyle(media.state.isShuffling == true ? Color.mint : Color.white.opacity(0.5))
            }
            CoveIconButton(symbol: "backward.fill", label: "Previous track", size: 15,
                           action: media.previous)
                .disabled(!media.state.supportsPrevious)
            Button(action: media.playPause) {
                Image(systemName: media.state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: condensed ? 19 : 25, weight: .semibold))
                    .frame(width: 44, height: 36)
            }
            .buttonStyle(CoveQuietButtonStyle())
            .accessibilityLabel(media.state.isPlaying ? "Pause" : "Play")
            .disabled(!media.state.supportsPlayPause)
            CoveIconButton(symbol: "forward.fill", label: "Next track", size: 15,
                           action: media.next)
                .disabled(!media.state.supportsNext)
            if media.state.supportsRepeat && !condensed {
                CoveIconButton(symbol: media.state.repeatMode == "one" ? "repeat.1" : "repeat", label: "Cycle repeat mode", action: media.cycleRepeat)
                    .foregroundStyle(media.state.isRepeating == true ? Color.mint : Color.white.opacity(0.5))
            }
        }
    }

    private func cancelScrubbing() {
        // Keep the gesture active until its end callback. Otherwise its later
        // value callbacks would be mistaken for keyboard edits on the new track.
        scrubIdentity = nil
    }


}

private struct CoveMediaScrubIdentity: Equatable {
    let source: String
    let title: String
    let artist: String
    let album: String
    let duration: Double

    init(state: MediaState) {
        source = state.sourceBundleIdentifier
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
    private let presets: [Double] = [60, 300, 900, 1500]

    var body: some View {
        if activities.timer.remaining > 0 {
            HStack(spacing: 23) {
                ZStack {
                    Circle().stroke(.white.opacity(0.08), lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: CoveNotchStyle.fraction(activities.timer.remaining / max(1, activities.timer.duration)))
                        .stroke(.tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: activities.timer.running ? "timer" : "pause.fill")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tint)
                }
                .frame(width: 93, height: 93)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 9) {
                    Text(activities.timer.running ? "Time remaining" : "Timer paused")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(CoveNotchStyle.secondary)
                    Text(CoveNotchStyle.duration(activities.timer.remaining))
                        .font(.system(size: 36, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                        .accessibilityLabel("\(CoveNotchStyle.duration(activities.timer.remaining)) remaining")
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
