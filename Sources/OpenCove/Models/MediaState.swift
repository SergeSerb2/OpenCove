import Foundation
import Combine

/// A monotonic playback anchor with no timer. Only progress views observe it;
/// API snapshots read its current position directly, even with no view mounted.
@MainActor
final class CovePlaybackClock: ObservableObject {
    private struct Sample {
        var elapsed = 0.0
        var duration = 0.0
        var rate = 0.0
        var uptime = ProcessInfo.processInfo.systemUptime
    }
    private var sample = Sample()
    private(set) var receivedSamples: UInt64 = 0
    @Published private(set) var changeNotifications: UInt64 = 0

    var isAdvancing: Bool { sample.rate != 0 }

    var elapsed: Double {
        position(at: ProcessInfo.processInfo.systemUptime)
    }

    private func position(at uptime: Double) -> Double {
        let delta = max(0, uptime - sample.uptime)
        let advanced = sample.elapsed + delta * sample.rate
        let value = max(0, advanced.isFinite ? advanced : sample.elapsed)
        return sample.duration > 0 ? min(value, sample.duration) : value
    }

    func update(elapsed: Double, duration: Double, rate: Double) {
        receivedSamples &+= 1
        let elapsed = elapsed.isFinite ? max(0, elapsed) : 0
        let duration = duration.isFinite ? max(0, duration) : 0
        let rate = rate.isFinite ? rate : 0
        // A stationary source does not need repeated identical anchors.
        if rate == 0, sample.rate == 0, sample.elapsed == elapsed,
           sample.duration == duration { return }
        // Every accepted source sample stays authoritative for API reads and
        // the next visible progress tick. Stable playback need not also wake
        // observers between those ticks. Publish real corrections immediately;
        // paused position changes, duration and rate changes always publish.
        let uptime = ProcessInfo.processInfo.systemUptime
        let correction = abs(elapsed - position(at: uptime))
        if rate != sample.rate || duration != sample.duration
            || (rate == 0 && elapsed != sample.elapsed) || correction > 0.1 {
            changeNotifications &+= 1
        }
        sample = Sample(elapsed: elapsed, duration: duration, rate: rate, uptime: uptime)
    }
}

struct MediaState: Codable, Equatable {
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var isPlaying: Bool = false
    var duration: Double = 0
    var elapsed: Double = 0
    var artworkData: Data? = nil
    var source: String = ""
    var available: Bool = false
    var supportsPlayPause = false
    var supportsNext = false
    var supportsPrevious = false
    var supportsSeek = false
    var supportsShuffle = false
    var supportsRepeat = false
    var supportsFavorite = false
    var supportsCopyLink = false
    // nil means the source did not supply this status, rather than "off".
    var isShuffling: Bool? = nil
    var isRepeating: Bool? = nil
    var isFavorited: Bool? = nil
    var repeatMode: String? = nil // Music: off/one/all; Spotify: off/all.
    var sourceBundleIdentifier = ""
    /// Opaque source-provided identity for item-bound command submissions.
    var contentItemIdentifier: String? = nil
    /// Ephemeral identity for delayed seek submissions. Renewed on item/source
    /// changes and media restarts; callers must read a new target after them.
    var seekTarget: String? = nil
    var audioFormat: String? = nil
    var isExplicit: Bool? = nil
    var isLive: Bool? = nil
    var playbackSpeed: Double? = nil
    var supportsPlaybackSpeed = false
    var supportedPlaybackSpeeds: [Double] = []
    var link: String? = nil
    var metadataBackend = ""
    var sourceDiagnostic: String? = nil
}

// New fields keep their defaults when decoding state saved by an older version.
extension MediaState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        album = try c.decodeIfPresent(String.self, forKey: .album) ?? ""
        isPlaying = try c.decodeIfPresent(Bool.self, forKey: .isPlaying) ?? false
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        elapsed = try c.decodeIfPresent(Double.self, forKey: .elapsed) ?? 0
        artworkData = try c.decodeIfPresent(Data.self, forKey: .artworkData)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        available = try c.decodeIfPresent(Bool.self, forKey: .available) ?? false
        supportsPlayPause = try c.decodeIfPresent(Bool.self, forKey: .supportsPlayPause) ?? false
        supportsNext = try c.decodeIfPresent(Bool.self, forKey: .supportsNext) ?? false
        supportsPrevious = try c.decodeIfPresent(Bool.self, forKey: .supportsPrevious) ?? false
        supportsSeek = try c.decodeIfPresent(Bool.self, forKey: .supportsSeek) ?? false
        supportsShuffle = try c.decodeIfPresent(Bool.self, forKey: .supportsShuffle) ?? false
        supportsRepeat = try c.decodeIfPresent(Bool.self, forKey: .supportsRepeat) ?? false
        supportsFavorite = try c.decodeIfPresent(Bool.self, forKey: .supportsFavorite) ?? false
        supportsCopyLink = try c.decodeIfPresent(Bool.self, forKey: .supportsCopyLink) ?? false
        isShuffling = try c.decodeIfPresent(Bool.self, forKey: .isShuffling)
        isRepeating = try c.decodeIfPresent(Bool.self, forKey: .isRepeating)
        isFavorited = try c.decodeIfPresent(Bool.self, forKey: .isFavorited)
        repeatMode = try c.decodeIfPresent(String.self, forKey: .repeatMode)
        sourceBundleIdentifier = try c.decodeIfPresent(String.self, forKey: .sourceBundleIdentifier) ?? ""
        contentItemIdentifier = try c.decodeIfPresent(String.self, forKey: .contentItemIdentifier)
        seekTarget = try c.decodeIfPresent(String.self, forKey: .seekTarget)
        audioFormat = try c.decodeIfPresent(String.self, forKey: .audioFormat)
        isExplicit = try c.decodeIfPresent(Bool.self, forKey: .isExplicit)
        isLive = try c.decodeIfPresent(Bool.self, forKey: .isLive)
        playbackSpeed = try c.decodeIfPresent(Double.self, forKey: .playbackSpeed)
        supportsPlaybackSpeed = try c.decodeIfPresent(Bool.self, forKey: .supportsPlaybackSpeed) ?? false
        supportedPlaybackSpeeds = try c.decodeIfPresent([Double].self, forKey: .supportedPlaybackSpeeds) ?? []
        link = try c.decodeIfPresent(String.self, forKey: .link)
        metadataBackend = try c.decodeIfPresent(String.self, forKey: .metadataBackend) ?? ""
        sourceDiagnostic = try c.decodeIfPresent(String.self, forKey: .sourceDiagnostic)
    }
}
