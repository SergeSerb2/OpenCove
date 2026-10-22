// SPDX-License-Identifier: MIT
// End-to-end fixture: a real, silent AVAudioPlayer registered with MediaPlayer.
// It never controls another player and exits after 90 seconds.
import AppKit
import AVFoundation
import MediaPlayer
import Darwin

@main
enum MediaFixture {
    @MainActor static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--help"] {
            print("Usage: MediaFixture --state /absolute/private/state.json [--metadata-duration NONNEGATIVE_SECONDS] [--metadata-style normal|long|oversized] [--rate-controls] [--live-metadata]")
            print("Plays only its own two silent tracks for at most 90 seconds. No arguments and missing/unsafe state paths fail before playback. OPENCOVE_FIXTURE_STATE can supply --state.")
            print("--live-metadata advertises this local fixture's public live flag on its first item; it does not start a network stream. Zero metadata duration represents unavailable timing.")
            return
        }
        var state = ProcessInfo.processInfo.environment["OPENCOVE_FIXTURE_STATE"]
        var duration: Double?
        var metadataStyle = "normal"
        var rateControls = false
        var liveMetadata = false
        var index = 0
        while index < args.count {
            if args[index] == "--rate-controls" { rateControls = true; index += 1; continue }
            if args[index] == "--live-metadata" { liveMetadata = true; index += 1; continue }
            guard index + 1 < args.count else { fail() }
            switch args[index] {
            case "--state": state = args[index + 1]
            case "--metadata-duration":
                guard let value = Double(args[index + 1]), value.isFinite, value >= 0 else { fail() }
                duration = value
            case "--metadata-style":
                guard ["normal", "long", "oversized"].contains(args[index + 1]) else { fail() }
                metadataStyle = args[index + 1]
            default: fail()
            }
            index += 2
        }
        guard let state, state.hasPrefix("/"), !state.contains("\0") else { fail() }
        let url = URL(fileURLWithPath: state)
        var info = stat()
        guard lstat(url.deletingLastPathComponent().path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              lstat(url.path, &info) != 0, errno == ENOENT else { fail() }
        umask(0o077)
        let app = NSApplication.shared
        let delegate = FixtureDelegate(statusURL: url, metadataDuration: duration, metadataStyle: metadataStyle, rateControls: rateControls, liveMetadata: liveMetadata)
        app.delegate = delegate
        app.setActivationPolicy(.prohibited)
        app.run()
        withExtendedLifetime(delegate) {}
    }

    private static func fail() -> Never {
        fputs("MediaFixture needs a fresh state path in an owned private directory. Use --help.\n", stderr)
        exit(2)
    }
}

@MainActor
final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private var player: AVAudioPlayer!
    private var track = 1
    private var timer: Timer?
    private var targets: [(MPRemoteCommand, Any)] = []
    private let statusURL: URL
    private let metadataDuration: Double?
    private let metadataStyle: String
    private let rateControls: Bool
    private let liveMetadata: Bool
    private var players: [AVAudioPlayer] = []
    // Original, local fixture pixels. A large source exercises the app's real
    // artwork transfer and thumbnail path without contacting an image service.
    private lazy var artwork: MPMediaItemArtwork = {
        let image = NSImage(size: NSSize(width: 2048, height: 2048), flipped: false) { bounds in
            NSColor.systemTeal.setFill()
            bounds.fill()
            NSColor.systemIndigo.setFill()
            NSRect(x: 0, y: 0, width: bounds.width / 2, height: bounds.height).fill()
            NSColor.systemOrange.setFill()
            NSRect(x: bounds.width / 2, y: 0, width: bounds.width / 2, height: bounds.height / 2).fill()
            return true
        }
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }()

    init(statusURL: URL, metadataDuration: Double?, metadataStyle: String, rateControls: Bool, liveMetadata: Bool) {
        self.statusURL = statusURL
        self.metadataDuration = metadataDuration
        self.metadataStyle = metadataStyle
        self.rateControls = rateControls
        self.liveMetadata = liveMetadata
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            players = try [120, 125].map { try AVAudioPlayer(data: Self.silence(seconds: $0)) }
            for value in players { value.enableRate = rateControls }
            player = players[0]
            player.prepareToPlay()
            player.play()
            let commands = MPRemoteCommandCenter.shared()
            register(commands.playCommand) { self.player.play() }
            register(commands.pauseCommand) { self.player.pause() }
            register(commands.togglePlayPauseCommand) { if self.player.isPlaying { self.player.pause() } else { self.player.play() } }
            register(commands.nextTrackCommand) { self.changeTrack() }
            register(commands.previousTrackCommand) { self.changeTrack() }
            if rateControls {
                let rate = commands.changePlaybackRateCommand
                rate.supportedPlaybackRates = [0.75, 1, 1.25, 1.5, 2]
                rate.isEnabled = true
                targets.append((rate, rate.addTarget { event in
                    guard let event = event as? MPChangePlaybackRateCommandEvent,
                          [0.75, 1, 1.25, 1.5, 2].contains(event.playbackRate) else { return .commandFailed }
                    let value = event.playbackRate
                    Task { @MainActor in
                        let allowed: [Float] = self.track == 1 ? [0.75, 1, 1.25, 1.5, 2] : [1, 2]
                        guard allowed.contains(value) else { return }
                        self.player.rate = value
                        self.publish()
                    }
                    return .success
                }))
            } else { commands.changePlaybackRateCommand.isEnabled = false }
            let seek = commands.changePlaybackPositionCommand
            seek.isEnabled = true
            targets.append((seek, seek.addTarget { event in
                guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
                let position = event.positionTime
                Task { @MainActor in self.player.currentTime = min(max(0, position), self.player.duration); self.publish() }
                return .success
            }))
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.publish() }
            }
            publish()
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) { NSApp.terminate(nil) }
        } catch {
            fputs("Media fixture could not create silent audio.\n", stderr)
            NSApp.terminate(nil)
        }
    }

    private func changeTrack() {
        let playing = player.isPlaying
        player.stop()
        track = track == 1 ? 2 : 1
        player = players[track - 1]
        player.currentTime = 0
        if rateControls { MPRemoteCommandCenter.shared().changePlaybackRateCommand.supportedPlaybackRates = track == 1 ? [0.75, 1, 1.25, 1.5, 2] : [1, 2] }
        if playing { player.play() }
    }

    private func register(_ command: MPRemoteCommand, action: @escaping @MainActor () -> Void) {
        command.isEnabled = true
        targets.append((command, command.addTarget { _ in
            Task { @MainActor in action(); self.publish() }
            return .success
        }))
    }

    private func publish() {
        guard let player else { return }
        let title: String
        let artist: String
        if metadataStyle == "oversized" {
            title = "OpenCove oversized verification \(track) — " + String(repeating: "Original 🔹 title text. ", count: 600)
            artist = String(repeating: "Original 🔹 artist credit. ", count: 600)
        } else {
            title = "OpenCove verification \(track)" + (metadataStyle == "long"
                ? " — a long original title for checking readable overflow, motion interruption, and native layout" : "")
            artist = metadataStyle == "long"
                ? "Local silent playback with a deliberately long artist credit for the real media interface"
                : "Local silent playback"
        }
        let isLive = liveMetadata && track == 1
        let publishedDuration = isLive ? 0 : metadataDuration ?? player.duration
        var metadata: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyAlbumTitle: "End-to-end fixture",
            MPMediaItemPropertyArtwork: artwork,
            MPMediaItemPropertyPlaybackDuration: publishedDuration,
            MPMediaItemPropertyPersistentID: UInt64(track),
            MPNowPlayingInfoPropertyExternalContentIdentifier: "org.opencove.MediaFixture.track.\(track)",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? Double(player.rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(player.rate),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if liveMetadata { metadata[MPNowPlayingInfoPropertyIsLiveStream] = isLive }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = metadata
        MPNowPlayingInfoCenter.default().playbackState = player.isPlaying ? .playing : .paused
        let state: [String: Any] = ["track": track, "playing": player.isPlaying, "elapsed": player.currentTime, "duration": player.duration, "rate": player.rate, "pid": ProcessInfo.processInfo.processIdentifier, "publishedDuration": publishedDuration, "liveMetadata": isLive]
        if let data = try? JSONSerialization.data(withJSONObject: state) { try? data.write(to: statusURL, options: .atomic) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        player?.stop()
        for (command, target) in targets { command.removeTarget(target) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private static func silence(seconds: UInt32) -> Data {
        let sampleRate: UInt32 = 8000
        let dataBytes: UInt32 = sampleRate * 2 * seconds
        var data = Data()
        func text(_ string: String) { data.append(Data(string.utf8)) }
        func value<T: FixedWidthInteger>(_ number: T) { var n = number.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        text("RIFF"); value(dataBytes + 36); text("WAVEfmt "); value(UInt32(16)); value(UInt16(1)); value(UInt16(1))
        value(sampleRate); value(sampleRate * 2); value(UInt16(2)); value(UInt16(16)); text("data"); value(dataBytes)
        data.append(Data(count: Int(dataBytes)))
        return data
    }
}
