// SPDX-License-Identifier: MIT
import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

// Panel section views and media extras: artwork glow, compact progress,
// lock-screen volume, Shortcuts, System stats, Notes, Clipboard, file tray
// thumbnails and the empty media state.

/// A soft light cast by the artwork into the panel. It draws a small,
/// pre-blurred image made once per cover, so it costs nothing while playing.
struct CoveArtworkGlow: View {
    let artwork: CoveArtworkThumbnail
    var condensed = false

    var body: some View {
        if let glow = artwork.glow {
            let size: Double = condensed ? 230 : 330
            Image(decorative: glow, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .opacity(0.5)
                .offset(x: -size * 0.36, y: -size * 0.4)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .id(ObjectIdentifier(glow))
                .transition(.opacity)
        }
    }
}

/// A hairline of playback progress along the bottom of the compact media pill.
/// It redraws once a second only while playback advances.
@MainActor
struct CoveCompactProgressLine: View {
    @ObservedObject var clock: CovePlaybackClock
    let duration: Double
    let color: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: clock.isAdvancing ? 1 : 3600)) { _ in
            GeometryReader { geometry in
                let fraction = CoveNotchStyle.fraction(clock.elapsed / max(1, duration))
                Capsule().fill(.white.opacity(0.1))
                    .overlay(alignment: .leading) {
                        Capsule().fill(color.opacity(0.85)).frame(width: geometry.size.width * fraction)
                    }
            }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A small volume slider for the lock-screen media widget.
@MainActor
struct CoveLockVolumeControl: View {
    @ObservedObject var system: SystemController

    var body: some View {
        if system.state.volumeAvailable {
            HStack(spacing: 6) {
                Image(systemName: system.state.isMuted || system.state.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
                Slider(value: Binding(get: { CoveNotchStyle.fraction(system.state.volume) }, set: { system.setVolume($0) }), in: 0...1)
                    .controlSize(.mini)
                    .frame(width: 90)
                    .disabled(!system.state.canSetVolume)
                    .accessibilityLabel("Volume")
                    .accessibilityValue("\(Int((CoveNotchStyle.fraction(system.state.volume) * 100).rounded())) percent")
            }
            .background(CoveMediaRegionMarker(blocksInput: true))
        }
    }
}

/// Pinned macOS Shortcuts as one-tap tiles. A tile shows progress while its
/// shortcut runs; the result appears as an overlay after the panel closes.
@MainActor
struct CoveShortcutsSurface: View {
    @ObservedObject var controller: ShortcutsController
    let pinned: [String]
    let accent: Color
    let openSettings: () -> Void

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8),
                           GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        if pinned.isEmpty {
            CoveEmptySurface(symbol: "square.grid.2x2", title: "Pin your shortcuts",
                             message: "Choose up to eight macOS Shortcuts to run from here.",
                             actionTitle: "Choose Shortcuts", action: openSettings)
        } else {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(pinned, id: \.self) { name in tile(name) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func tile(_ name: String) -> some View {
        let running = controller.running.contains(name)
        let failed = controller.lastOutcome.map { $0.name == name && !$0.succeeded } ?? false
        return Button { controller.run(name) } label: {
            VStack(spacing: 7) {
                ZStack {
                    Circle().fill(accent.opacity(0.18)).frame(width: 30, height: 30)
                    if running {
                        ProgressView().controlSize(.small).tint(accent)
                    } else {
                        Image(systemName: failed ? "exclamationmark.triangle.fill" : "bolt.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(failed ? Color.orange : accent)
                    }
                }
                Text(name)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 26, alignment: .top)
            }
            .padding(.vertical, 10).padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .background(CoveNotchStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(CoveQuietButtonStyle())
        .disabled(running)
        .help("Run \(name)")
        .accessibilityLabel(running ? "\(name), running" : "Run \(name)")
    }
}

/// The empty media state, with one-click launchers for installed players.
@MainActor
struct CoveNothingPlaying: View {
    let message: String
    let refresh: () -> Void

    private struct Player: Identifiable {
        let id: String
        let name: String
        let url: URL
        let icon: NSImage
    }

    private static let candidates = [("com.apple.Music", "Music"), ("com.spotify.client", "Spotify"),
                                     ("com.apple.podcasts", "Podcasts"), ("com.apple.TV", "TV")]

    @State private var players: [Player] = []

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
            Text("Nothing playing").font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 11)).foregroundStyle(CoveNotchStyle.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                ForEach(players) { player in
                    Button {
                        NSWorkspace.shared.openApplication(at: player.url, configuration: .init())
                    } label: {
                        Image(nsImage: player.icon).resizable().frame(width: 30, height: 30)
                    }
                    .buttonStyle(CoveQuietButtonStyle())
                    .help("Open \(player.name)")
                    .accessibilityLabel("Open \(player.name)")
                }
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium))
                        .frame(width: 30, height: 30)
                        .background(CoveNotchStyle.surface, in: Circle())
                }
                .buttonStyle(CoveQuietButtonStyle())
                .help("Refresh")
                .accessibilityLabel("Refresh media")
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard players.isEmpty else { return }
            players = Self.candidates.compactMap { identifier, name in
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return nil }
                return Player(id: identifier, name: name, url: url, icon: NSWorkspace.shared.icon(forFile: url.path))
            }
        }
    }
}

/// CPU, memory, network and disk at a glance. The view holds a sampling lease
/// while it is on screen, so nothing is measured while the section is closed.
@MainActor
struct CoveSystemStatsSurface: View {
    @ObservedObject var controller: SystemStatsController
    @ObservedObject var stayAwake: CoveStayAwake
    let accent: Color

    private static func bytes(_ value: Double?, style: ByteCountFormatter.CountStyle = .memory) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        // Non-adaptive output keeps tiles short: "133 GB" rather than "132.99 GB".
        let formatter = ByteCountFormatter()
        formatter.countStyle = style
        formatter.isAdaptive = false
        return formatter.string(fromByteCount: Int64(value))
    }

    private static func rate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        if value < 1_024 * 1_024 { return "\(Int((value / 1_024).rounded())) KB/s" }
        return String(format: "%.1f MB/s", value / (1_024 * 1_024))
    }

    var body: some View {
        let stats = controller.snapshot
        let memory = stats.memoryUsed.map { $0 / max(1, stats.memoryTotal) }
        let disk = stats.diskFree.flatMap { free in stats.diskTotal.map { 1 - free / max(1, $0) } }
        VStack(spacing: 10) {
        HStack(spacing: 10) {
            ring("CPU", value: stats.cpu, detail: stats.cpu.map { "\(Int(($0 * 100).rounded()))%" } ?? "—", symbol: "cpu")
            ring("Memory", value: memory, detail: Self.bytes(stats.memoryUsed), symbol: "memorychip")
            VStack(alignment: .leading, spacing: 6) {
                Label("Network", systemImage: "network").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CoveNotchStyle.secondary)
                Label(Self.rate(stats.downloadRate), systemImage: "arrow.down")
                Label(Self.rate(stats.uploadRate), systemImage: "arrow.up")
            }
            .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.75)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CoveNotchStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Network, download \(Self.rate(stats.downloadRate)), upload \(Self.rate(stats.uploadRate))")
            ring("Disk", value: disk, detail: Self.bytes(stats.diskFree, style: .file) + " free", symbol: "internaldrive")
            if let health = stats.batteryHealth {
                VStack(spacing: 6) {
                    Image(systemName: "battery.100percent").font(.system(size: 18)).foregroundStyle(health < 0.8 ? Color.orange : accent)
                        .frame(height: 44)
                    Text("\(Int((health * 100).rounded()))% health").font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit().lineLimit(1)
                    Text(stats.batteryCycles.map { "\($0) cycles" } ?? "Battery").font(.system(size: 9))
                        .foregroundStyle(CoveNotchStyle.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(CoveNotchStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxHeight: 112)
            stayAwakeRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: controller.acquire)
        .onDisappear(perform: controller.release)
    }

    private var stayAwakeRow: some View {
        HStack(spacing: 8) {
            Text(Image(systemName: stayAwake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer"))
                .foregroundStyle(stayAwake.isActive ? accent : CoveNotchStyle.secondary)
            Text("Stay Awake").font(.system(size: 11, weight: .medium))
            Text(stayAwake.statusText).font(.system(size: 10)).foregroundStyle(CoveNotchStyle.secondary)
            Spacer()
            Menu(stayAwake.isActive ? "Change" : "Start") {
                ForEach(CoveStayAwake.choices, id: \.title) { choice in
                    Button(choice.title) { stayAwake.start(minutes: choice.minutes) }
                }
                if stayAwake.isActive {
                    Divider()
                    Button("Turn Off", action: stayAwake.stop)
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
            .controlSize(.small)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(CoveNotchStyle.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .help("Keeps your Mac and display awake. Closing the lid or choosing Sleep still works.")
    }

    private func ring(_ title: String, value: Double?, detail: String, symbol: String) -> some View {
        let level = CoveNotchStyle.fraction(value ?? 0)
        let color = level > 0.9 ? Color.red : level > 0.75 ? Color.orange : accent
        return VStack(spacing: 6) {
            ZStack {
                Circle().stroke(.white.opacity(0.1), lineWidth: 5)
                Circle().trim(from: 0, to: level)
                    .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(color)
            }
            .frame(width: 44, height: 44)
            Text(detail).font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
            Text(title).font(.system(size: 9)).foregroundStyle(CoveNotchStyle.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CoveNotchStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(detail)")
    }
}

/// A scratchpad for quick thoughts. It saves on this Mac as you type.
@MainActor
struct CoveNotesSurface: View {
    @ObservedObject var notes: CoveNotesStore
    @State private var confirmingClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(get: { notes.text }, set: { notes.update($0) }))
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .accessibilityLabel("Notes")
                if notes.text.isEmpty {
                    Text("Jot something down…")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .background(CoveNotchStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack {
                if let error = notes.lastError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else {
                    Text(notes.hasUnsavedChanges ? "Saving…" : "Saved on this Mac")
                }
                Spacer()
                Text("\(notes.text.count) characters").monospacedDigit()
                if !notes.text.isEmpty {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(notes.text, forType: .string)
                    }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.75))
                    .help("Copy all notes")
                    Button(confirmingClear ? "Confirm Clear" : "Clear") {
                        if confirmingClear { notes.update(""); confirmingClear = false } else { confirmingClear = true }
                    }
                    .buttonStyle(.plain).foregroundStyle(confirmingClear ? Color.orange : .white.opacity(0.75))
                    .help("Clear all notes")
                }
            }
            .onChange(of: notes.text) { _, _ in confirmingClear = false }
            .font(.system(size: 9))
            .foregroundStyle(CoveNotchStyle.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A Quick Look thumbnail for images, PDFs and other previewable files,
/// with the file's icon until (or unless) a thumbnail is ready.
@MainActor
struct CoveFileThumbnail: View {
    let url: URL
    let available: Bool
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFill()
                    .frame(width: 25, height: 25)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().scaledToFit().frame(width: 25, height: 25)
            }
        }
        .task(id: url) {
            // Text and other documents look clearer as their icon than as a tiny page.
            guard available, let type = UTType(filenameExtension: url.pathExtension),
                  type.conforms(to: .image) || type.conforms(to: .pdf) || type.conforms(to: .audiovisualContent) else { return }
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 50, height: 50),
                                                       scale: 2, representationTypes: .thumbnail)
            if let result = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                thumbnail = result.nsImage
            }
        }
    }
}

/// "PDF document · 1.2 MB", read once per file.
@MainActor
struct CoveFileDetail: View {
    let url: URL
    @State private var text = ""

    var body: some View {
        Text(text).font(.system(size: 9)).foregroundStyle(CoveNotchStyle.secondary).lineLimit(1)
            .task(id: url) {
                let values = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .fileSizeKey, .isDirectoryKey])
                var parts: [String] = []
                if let kind = values?.localizedTypeDescription { parts.append(kind) }
                if values?.isDirectory != true, let size = values?.fileSize {
                    parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                }
                text = parts.joined(separator: " · ")
            }
    }
}

/// Recently copied text. Click an item to copy it again.
@MainActor
struct CoveClipboardSurface: View {
    @ObservedObject var history: ClipboardHistory
    let accent: Color
    @State private var copied: UUID?

    var body: some View {
        if history.items.isEmpty {
            CoveEmptySurface(symbol: "doc.on.clipboard", title: "Nothing copied yet",
                             message: "Text you copy appears here. It is kept in memory only.")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(history.items.count) recent").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CoveNotchStyle.secondary)
                    Spacer()
                    Button("Clear", action: history.clear).buttonStyle(.plain)
                        .font(.system(size: 11)).foregroundStyle(CoveNotchStyle.secondary)
                }
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(history.items) { item in row(item) }
                    }
                }
                .scrollIndicators(.hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func row(_ item: ClipboardHistory.Item) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                history.copy(item)
                copied = item.id
            } label: {
                HStack(alignment: .top) {
                    Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 11)).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(item.date, style: .relative).font(.system(size: 9))
                        .foregroundStyle(CoveNotchStyle.secondary).lineLimit(1).fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy again")
            .accessibilityLabel("Copy: \(item.text.prefix(80))")
            Button { history.remove(item.id) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain).foregroundStyle(CoveNotchStyle.secondary)
            .accessibilityLabel("Remove from history")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(CoveNotchStyle.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(accent.opacity(copied == item.id ? 0.6 : 0), lineWidth: 1))
    }
}

/// App icons for media sources, looked up once per bundle identifier.
@MainActor
enum CoveSourceIcon {
    private static var cache: [String: NSImage?] = [:]

    static func icon(for bundleIdentifier: String) -> NSImage? {
        guard !bundleIdentifier.isEmpty else { return nil }
        if let cached = cache[bundleIdentifier] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleIdentifier] = icon
        return icon
    }
}
