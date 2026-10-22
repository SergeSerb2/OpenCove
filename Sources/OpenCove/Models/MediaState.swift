import Foundation

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
