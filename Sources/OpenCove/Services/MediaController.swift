import AppKit
import Combine
import CoreServices
import Darwin
#if canImport(FoundationXML)
import FoundationXML
#endif
import ImageIO
import ObjectiveC

@MainActor
final class MediaController: ObservableObject {
    @Published private(set) var state = MediaState()
    @Published private var errorMessage: String?
    private(set) var lastError: String? {
        get { errorMessage }
        set { if errorMessage != newValue { errorMessage = newValue } }
    }
    // Position updates belong to the visible progress controls. They must not
    // invalidate artwork, transport, compact panels, or panel geometry.
    let playback = CovePlaybackClock()
    var onHUD: ((CoveHUD) -> Void)?

    /// system follows Now Playing; explicit selections never fall through to another app.
    var preferredSource = "system" {
        didSet {
            guard oldValue != preferredSource else { return }
            generation = UUID()
            delayedRefresh?.cancel()
            delayedRefresh = nil
            adapterRefreshRequested = false
            remoteRead?.cancel()
            remoteRead = nil
            scripts.cancelAll()
            adapterWatch.stop()
            adapterSnapshot = nil
            adapterRetryAfter = 0
            localReaderEmpty = false
            localRetryAt = 0
            refreshing = false
            refreshAgain = false
            clearState()
            refresh()
        }
    }

    private enum Backend { case remote, adapter, script }
    private var backend: Backend?
    private var remoteSeekSupported = false
    private var remote: CoveMediaRemote?
    private let scripts = CoveMediaScripts()
    private let adapterWatch = CoveMediaAdapterWatch()
    private var adapterSnapshot: CoveRemoteResult?
    private var adapterItemID: String?
    private var remoteItemID: String?
    private var adapterReceivedAt = 0.0
    private var localReaderEmpty = false
    private var localRetryAt = 0.0
    private var running = false
    private var scriptEnabled = false
    private var adapterRetryAfter = 0.0
    private var adapterError: String?
    private var scriptTrackID: String?
    private var scriptDefinitions: [String: CoveMediaDefinition] = [:]
    private var generation = UUID()
    private var refreshing = false
    private var refreshAgain = false
    private var remoteRead: CoveRemoteRead?
    private var pollTimer: Timer?
    private var delayedRefresh: DispatchWorkItem?
    private var adapterRefreshRequested = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var sourceBundleID: String?
    private var sourcePID: pid_t?
    private var trackIdentity = ""
    private var selectedSeekTarget: String?
    private var artworkDownload: CoveMediaArtworkDownload?
    private var artworkDownloadID = UUID()
    private var remoteArtworkData: Data?
    private var artworkIdentity: String?
    private var nextArtworkAttempt = 0.0

    deinit {
        pollTimer?.invalidate()
        delayedRefresh?.cancel()
        for (center, token) in observers { center.removeObserver(token) }
        scripts.cancelAll()
        adapterWatch.stop()
        artworkDownload?.cancel()
        let reader = remoteRead, bridge = remote
        DispatchQueue.main.async {
            reader?.cancel()
            bridge?.stopNotifications()
        }
    }

    func start(privateAPIs: Bool, appleScript: Bool) {
        stop()
        running = true
        scriptEnabled = appleScript
        adapterRetryAfter = 0
        adapterError = nil
        localReaderEmpty = false
        localRetryAt = 0
        lastError = nil
        if privateAPIs {
            remote = CoveMediaRemote()
            remote?.startNotifications()
            for name in remote?.notificationNames ?? [] {
                observe(.default, name: name)
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didWakeNotification] {
            observe(workspace, name: name)
        }
        if appleScript {
            observe(DistributedNotificationCenter.default(), name: .init("com.apple.Music.playerInfo"))
            observe(DistributedNotificationCenter.default(), name: .init("com.spotify.client.PlaybackStateChanged"))
        }
        reconcileTimers()
        refresh()
    }

    func stop() {
        running = false
        generation = UUID()
        pollTimer?.invalidate()
        pollTimer = nil
        delayedRefresh?.cancel()
        delayedRefresh = nil
        adapterRefreshRequested = false
        remoteRead?.cancel()
        remoteRead = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        remote?.stopNotifications()
        remote = nil
        scripts.cancelAll()
        adapterWatch.stop()
        adapterSnapshot = nil
        adapterReceivedAt = 0
        localReaderEmpty = false
        localRetryAt = 0
        artworkDownload?.cancel()
        artworkDownload = nil
        artworkIdentity = nil
        nextArtworkAttempt = 0
        refreshing = false
        refreshAgain = false
        clearState()
        lastError = nil
    }

    func refresh() {
        guard running else { return }
        guard !refreshing else { refreshAgain = true; return }
        refreshing = true
        let epoch = generation
        if localReaderEmpty, ProcessInfo.processInfo.systemUptime < localRetryAt, remote != nil {
            readAdapterFallback(epoch: epoch, remoteResult: nil, reason: adapterError)
        } else if let remote, remote.canRead {
            remoteRead = remote.read { [weak self] result in
                guard let self, self.running, self.generation == epoch else { return }
                self.remoteRead = nil
                if let snapshot = self.snapshot(from: result) {
                    self.localReaderEmpty = false
                    self.localRetryAt = 0
                    self.apply(snapshot.state, bundleID: snapshot.bundleID, pid: result.pid,
                               backend: .remote, rate: snapshot.rate, identity: snapshot.identity,
                               itemID: snapshot.itemID)
                    self.decodeRemoteArtwork(snapshot.artworkData, identity: snapshot.identity)
                    self.enrichRemoteWithScript(epoch: epoch)
                } else {
                    self.localReaderEmpty = true
                    self.localRetryAt = ProcessInfo.processInfo.systemUptime + (result.denied ? 60 : result.timedOut ? 5 : 15)
                    let reason = result.error ?? (result.timedOut ? "MediaRemote did not answer before the timeout." :
                        (result.pid.map { $0 > 0 } == true || result.bundleID != nil ?
                         "macOS did not provide metadata for the active media source." : nil))
                    self.readAdapterFallback(epoch: epoch, remoteResult: result, reason: reason)
                }
            }
        } else {
            readAdapterFallback(epoch: epoch, remoteResult: nil,
                reason: remote?.loadError ?? (scriptEnabled ? nil :
                    "Media access is disabled. Enable private APIs or AppleScript in Settings."))
        }
    }

    func playPause() { command(.toggle) }
    func next() { command(.next) }
    func previous() { command(.previous) }

    @discardableResult
    func seek(to seconds: Double, target: String? = nil) -> Bool {
        guard seconds.isFinite else { lastError = "The seek time must be finite."; return false }
        guard running, state.available else { lastError = "No media source is available."; return false }
        if let target {
            guard target == state.seekTarget else {
                lastError = "The media item changed. Choose a position on the current item."; return false
            }
        }
        guard state.supportsSeek else { lastError = "This source does not enable seeking."; return false }
        let position = min(max(0, seconds), state.duration)
        if backend == .adapter {
            guard remoteSeekSupported, adapterItemID != nil else {
                lastError = "This source cannot safely identify the item for seeking."; return false
            }
            adapterCommand(["--seek", String(position)])
        } else if backend == .remote {
            guard remoteSeekSupported, let bundleID = sourceBundleID, acceptsSource(bundleID),
                  let remoteItemID, let remote,
                  remote.seek(to: seconds, for: bundleID, itemID: remoteItemID) else {
                remoteSeekSupported = false
                state.supportsSeek = false
                lastError = "The current item changed or cannot be safely identified for seeking. Refresh before trying again."
                scheduleRefresh(after: 0.1)
                return false
            }
            lastError = nil
            scheduleRefresh()
        } else {
            scriptCommand("app.playerPosition = \(position)", requireTrack: true)
        }
        return true // Submission; the source reports the actual result later.
    }

    func toggleShuffle() {
        guard state.supportsShuffle else { lastError = "Shuffle is unavailable for this source."; return }
        if sourceBundleID == "com.apple.Music" {
            scriptCommand("app.shuffleEnabled = !app.shuffleEnabled()")
        } else if sourceBundleID == "com.spotify.client" {
            scriptCommand("if (!app.shufflingEnabled()) throw Error('Shuffle is unavailable in this context.'); app.shuffling = !app.shuffling()")
        }
    }

    func cycleRepeat() {
        guard state.supportsRepeat else { lastError = "Repeat is unavailable for this source."; return }
        if sourceBundleID == "com.apple.Music" {
            scriptCommand("const mode = app.songRepeat(); app.songRepeat = mode === 'off' ? 'all' : mode === 'all' ? 'one' : 'off'")
        } else if sourceBundleID == "com.spotify.client" {
            scriptCommand("if (!app.repeatingEnabled()) throw Error('Repeat is unavailable in this context.'); app.repeating = !app.repeating()")
        }
    }

    func toggleFavorite() {
        guard state.supportsFavorite, sourceBundleID == "com.apple.Music" else {
            lastError = "Favorites are unavailable for this source."; return
        }
        scriptCommand("const track = app.currentTrack(); track.favorited = !track.favorited()", requireTrack: true)
    }

    func copyLink() {
        guard running, state.available, state.supportsCopyLink, let link = state.link,
              let url = Self.mediaLink(link) else { lastError = "This source did not provide a media link."; return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.writeObjects([url as NSURL]) { lastError = nil }
        else { lastError = "The media link could not be copied." }
    }

    @discardableResult
    func setPlaybackSpeed(_ speed: Double, source: String, itemID: String) -> Bool {
        guard speed.isFinite, speed > 0, speed <= 16 else {
            lastError = "The playback speed must be finite, positive, and at most 16×."; return false
        }
        guard running, state.available, state.supportsPlaybackSpeed,
              source == sourceBundleID, itemID == state.contentItemIdentifier,
              let selected = state.supportedPlaybackSpeeds.first(where: { abs($0 - speed) < 0.000001 }) else {
            lastError = "The current media item or its supported speeds changed."; return false
        }
        if backend == .adapter {
            guard adapterItemID != nil, adapterURL?.pathExtension == "js" else {
                lastError = "This source cannot safely identify the item for playback speed."; return false
            }
            adapterCommand(["--rate", String(selected)])
        } else {
            guard backend == .remote, let bundle = sourceBundleID, let item = remoteItemID,
                  remote?.setPlaybackSpeed(selected, for: bundle, itemID: item) == true else {
                lastError = "The source, item, or supported playback speeds changed. Refresh before trying again."
                return false
            }
            lastError = nil
            scheduleRefresh(after: 0.5)
        }
        return true // Submission only. State changes when the real player reports it.
    }

    func openPlayer() {
        guard running, state.available else { lastError = "No media source is available."; return }
        if let pid = sourcePID, let app = NSRunningApplication(processIdentifier: pid),
           app.bundleIdentifier == sourceBundleID, app.activate(options: []) {
            lastError = nil
            return
        }
        guard let bundleID = sourceBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              url.pathExtension == "app", Bundle(url: url)?.bundleIdentifier == bundleID else {
            lastError = "The media source did not identify an installed application."
            return
        }
        let epoch = generation
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self, self.running, self.generation == epoch else { return }
                self.lastError = error.map { "Could not open the media source: \($0.localizedDescription)" }
            }
        }
    }

    /// Call only from an explicit Enable Automation action. Startup and polling never prompt.
    func requestAppleScriptAccess() {
        guard running, scriptEnabled else {
            lastError = "Enable AppleScript in Settings before requesting Automation access."
            return
        }
        let apps = scriptApplications(preferred: sourceBundleID)
        guard !apps.isEmpty else { lastError = "Open Music or Spotify before enabling Automation access."; return }
        let epoch = generation
        for app in apps {
            scripts.authorize(pid: app.processIdentifier) { [weak self] error in
                guard let self, self.running, self.generation == epoch else { return }
                self.lastError = error
                self.refresh()
            }
        }
    }

    private func observe(_ center: NotificationCenter, name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.localReaderEmpty = false
                self?.localRetryAt = 0
                self?.refresh()
            }
        }
        observers.append((center, token))
    }

    private func reconcileTimers() {
        guard running else { return }
        let interval: TimeInterval = state.available ? 4 : 15
        if pollTimer?.timeInterval != interval {
            pollTimer?.invalidate()
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            timer.tolerance = interval * 0.2
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        }
    }

    private func finishRefresh() {
        refreshing = false
        if refreshAgain {
            refreshAgain = false
            // Yield so a burst of notifications cannot recurse through synchronous fallbacks.
            scheduleRefresh(after: 0.1)
        }
    }

    private func scheduleRefresh(after delay: TimeInterval = 0.35, wakeAdapter: Bool = false) {
        delayedRefresh?.cancel()
        adapterRefreshRequested = adapterRefreshRequested || wakeAdapter
        let epoch = generation
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.running, self.generation == epoch else { return }
                self.delayedRefresh = nil
                if self.adapterRefreshRequested {
                    self.adapterRefreshRequested = false
                    self.adapterWatch.requestRefresh()
                }
                self.refresh()
            }
        }
        delayedRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func clearState() {
        let empty = MediaState()
        if state != empty { state = empty }
        reconcileTimers()
        backend = nil
        remoteSeekSupported = false
        sourceBundleID = nil
        sourcePID = nil
        scriptTrackID = nil
        adapterItemID = nil
        remoteItemID = nil
        trackIdentity = ""
        selectedSeekTarget = nil
        scripts.selectItem("")
        playback.update(elapsed: 0, duration: 0, rate: 0)
        artworkDownload?.cancel()
        artworkDownload = nil
        remoteArtworkData = nil
        artworkIdentity = nil
        nextArtworkAttempt = 0
    }

    private func apply(_ value: MediaState, bundleID: String?, pid: pid_t?, backend: Backend,
                       rate: Double, identity: String, itemID: String? = nil) {
        var value = value
        value.sourceBundleIdentifier = bundleID ?? ""
        value.contentItemIdentifier = backend == .script ? nil : itemID
        value.metadataBackend = backend == .script ? "applescript" : backend == .adapter ? "system-adapter" : "mediaremote"
        if backend == .adapter {
            value.sourceDiagnostic = "Reading system media with the isolated system adapter."
        }
        if identity == trackIdentity, value.artworkData == nil { value.artworkData = state.artworkData }
        if identity != trackIdentity || sourceBundleID != bundleID || self.backend != backend || selectedSeekTarget == nil {
            selectedSeekTarget = UUID().uuidString
        }
        value.seekTarget = selectedSeekTarget
        if identity != trackIdentity {
            scriptTrackID = nil
            artworkDownload?.cancel()
            artworkDownload = nil
            remoteArtworkData = nil
            artworkIdentity = nil
            nextArtworkAttempt = 0
        }
        trackIdentity = identity
        scripts.selectItem(identity)
        adapterItemID = backend == .adapter ? itemID : nil
        remoteItemID = backend == .remote ? itemID : nil
        sourceBundleID = bundleID
        sourcePID = pid
        self.backend = backend
        remoteSeekSupported = backend != .script && value.supportsSeek
        playback.update(elapsed: value.elapsed, duration: value.duration,
                        rate: value.isPlaying ? rate : 0)
        // Keep the last published metadata sample. Elapsed-only source updates
        // refresh the separate clock, including seeks while playback is paused.
        var comparable = state
        comparable.elapsed = value.elapsed
        if comparable != value { state = value }
        reconcileTimers()
    }

    private func snapshot(from result: CoveRemoteResult)
        -> (state: MediaState, bundleID: String?, rate: Double, identity: String, artworkData: Data?, itemID: String?)? {
        guard let info = result.info, !info.isEmpty else { return nil }
        func field(_ name: String) -> Any? { info[remote?.key(name) ?? name] }
        func text(_ suffix: String) -> String { field("kMRMediaRemoteNowPlayingInfo" + suffix) as? String ?? "" }
        func number(_ suffix: String) -> Double {
            let value = (field("kMRMediaRemoteNowPlayingInfo" + suffix) as? NSNumber)?.doubleValue ?? 0
            return value.isFinite ? value : 0
        }
        func flag(_ suffix: String) -> Bool? {
            guard let value = field("kMRMediaRemoteNowPlayingInfo" + suffix) as? NSNumber,
                  value.doubleValue == 0 || value.doubleValue == 1 else { return nil }
            return value.boolValue
        }
        let duration = max(0, number("Duration"))
        let title = text("Title"), artist = text("Artist"), album = text("Album")
        guard !title.isEmpty || !artist.isEmpty || !album.isEmpty || duration > 0 else { return nil }
        let rawRate = number("PlaybackRate")
        let hasRate = (field("kMRMediaRemoteNowPlayingInfoPlaybackRate") as? NSNumber)?.doubleValue.isFinite == true
        let playing = hasRate ? rawRate > 0 : (result.isPlaying ?? false)
        let rate = rawRate > 0 ? rawRate : (playing ? 1 : 0)
        var elapsed = max(0, number("ElapsedTime"))
        if playing, let timestamp = field("kMRMediaRemoteNowPlayingInfoTimestamp") as? Date {
            let delta = Date().timeIntervalSince(timestamp)
            let advanced = elapsed + max(0, delta) * rate
            if delta.isFinite, advanced.isFinite { elapsed = advanced }
        }
        if duration > 0 { elapsed = min(duration, elapsed) }
        // The modern item and path are read together. Do not pair its fallback
        // metadata with a PID returned later for a different application.
        let app = result.pid.flatMap { $0 > 0 ? NSRunningApplication(processIdentifier: $0) : nil }
        let bundleID = result.bundleID ?? app?.bundleIdentifier
        guard acceptsSource(bundleID) else { return nil }
        let source = (app?.bundleIdentifier == bundleID ? app?.localizedName : nil) ?? bundleID.flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.localizedName
        } ?? bundleID ?? ""
        let artwork = field("kMRMediaRemoteNowPlayingInfoArtworkData") as? Data
        var value = MediaState(title: title, artist: artist, album: album, isPlaying: playing,
            duration: duration, elapsed: elapsed, artworkData: nil, source: source, available: true)
        let identified = bundleID?.isEmpty == false
        let itemID = Self.mediaItemID(field("kMRMediaRemoteNowPlayingInfoContentItemIdentifier"))
        value.supportsPlayPause = identified && result.enabledCommands.contains("TogglePlayPause")
        value.supportsNext = identified && result.enabledCommands.contains("NextTrack")
        value.supportsPrevious = identified && result.enabledCommands.contains("PreviousTrack")
        value.supportsSeek = identified && duration > 0 && result.supportsSeek &&
            result.canValidateSeekItem && itemID != nil && (result.adapter || remote?.setElapsedTime != nil)
        let defaultRate = (field("kMRMediaRemoteNowPlayingInfoDefaultPlaybackRate") as? NSNumber)?.doubleValue ?? 0
        let shownRate = rawRate > 0 ? rawRate : defaultRate
        value.playbackSpeed = shownRate.isFinite && shownRate > 0 && shownRate <= 16 ? shownRate : nil
        value.supportsPlaybackSpeed = identified && itemID != nil && result.canValidateSeekItem
            && !result.supportedPlaybackSpeeds.isEmpty
            && (result.adapter ? adapterURL?.pathExtension == "js" : remote?.sendCommand != nil)
        value.supportedPlaybackSpeeds = value.supportsPlaybackSpeed ? result.supportedPlaybackSpeeds : []
        value.isExplicit = flag("IsExplicitTrack")
        // MediaPlayer's public live-stream property arrives under IsAlwaysLive
        // on current macOS. Keep the older source field as a fallback.
        value.isLive = flag("IsAlwaysLive") ?? flag("IsLiveStream")
        value.audioFormat = field("kMRMediaRemoteNowPlayingInfoAudioFormat") as? String
        let link = Self.mediaLink(text("ExternalContentIdentifier"))
        value.link = link?.absoluteString
        value.supportsCopyLink = link != nil
        let identity = [bundleID ?? "", text("ContentItemIdentifier"), title, artist, album,
                        String(duration)].joined(separator: "\u{1F}")
        return (value, bundleID, rate, identity, artwork, itemID)
    }

    private func decodeRemoteArtwork(_ data: Data?, identity: String) {
        guard let data, data.count <= 12 * 1024 * 1024, data != remoteArtworkData else { return }
        remoteArtworkData = data
        let epoch = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let image = Self.artwork(data)
            DispatchQueue.main.async {
                guard let self, self.running, self.generation == epoch, self.trackIdentity == identity,
                      self.remoteArtworkData == data else { return }
                self.state.artworkData = image
            }
        }
    }

    private enum Command: Int32 {
        case toggle = 2, next = 4, previous = 5
        var script: String {
            switch self {
            case .toggle: return "app.playpause()"
            case .next: return "app.nextTrack()"
            case .previous: return "app.previousTrack()"
            }
        }
    }

    private func command(_ command: Command) {
        guard running, state.available else { lastError = "No media source is available."; return }
        if backend == .adapter {
            let action = command == .toggle ? "--toggle" : command == .next ? "--next" : "--previous"
            adapterCommand([action])
        } else if backend == .remote {
            guard let sourceBundleID, !sourceBundleID.isEmpty, let remote,
                  remote.currentBundleID == sourceBundleID else {
                lastError = "The active media source changed. Refresh before using this command."
                scheduleRefresh(after: 0.1)
                return
            }
            let name = command == .toggle ? "TogglePlayPause" : command == .next ? "NextTrack" : "PreviousTrack"
            guard remote.commandEnabled(name, for: sourceBundleID) else {
                lastError = "This source does not enable that media command."
                return
            }
            guard let send = remote.sendCommand, send(command.rawValue, nil) else {
                lastError = "MediaRemote rejected the media command."
                return
            }
            lastError = nil
            scheduleRefresh()
        } else {
            let enabled = command == .toggle ? state.supportsPlayPause : command == .next ? state.supportsNext : state.supportsPrevious
            guard enabled else { lastError = "This source does not enable that media command."; return }
            scriptCommand(command.script)
        }
    }

    private func scriptCommand(_ command: String, requireTrack: Bool = false) {
        guard scriptEnabled else {
            lastError = "This media command is unavailable. The optional AppleScript fallback is disabled."
            return
        }
        guard let bundleID = sourceBundleID, CoveMediaScripts.supported.contains(bundleID),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            lastError = "The AppleScript fallback supports running Music and Spotify applications only."
            return
        }
        let epoch = generation
        let selectedIdentity = trackIdentity
        let trackCheck: String
        if requireTrack {
            guard let scriptTrackID = Self.mediaItemID(scriptTrackID),
                  let expression = Self.scriptItemExpression(bundleID: bundleID) else {
                lastError = "This source did not identify the current track."; return
            }
            let literal = Self.javaScriptLiteral(scriptTrackID)
            trackCheck = "const currentID = \(expression); if (typeof currentID !== 'string' || currentID !== \(literal)) throw Error('The current track has changed or cannot be identified.');"
        } else { trackCheck = "" }
        // The application ID and command are fixed by this service, never by media metadata.
        scripts.run(pid: app.processIdentifier,
            source: "const app = Application('\(bundleID)'); if (app.running()) { \(trackCheck) \(command); } else { throw Error('The player has quit.'); }",
            expectedItem: requireTrack ? selectedIdentity : nil) {
            [weak self] result in
            guard let self, self.running, self.generation == epoch, self.trackIdentity == selectedIdentity else { return }
            switch result {
            case .success: self.lastError = nil; self.scheduleRefresh()
            case .failure(let error): self.lastError = error.localizedDescription
            }
        }
    }

    private func scriptApplications(preferred: String?) -> [NSRunningApplication] {
        if let explicit = preferredBundleID {
            return NSRunningApplication.runningApplications(withBundleIdentifier: explicit)
        }
        let active = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let order = ([preferred, active].compactMap { $0 } + CoveMediaScripts.supported)
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return order.filter { CoveMediaScripts.supported.contains($0) }.compactMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
        }
    }

    private struct ScriptTrack: Decodable {
        var available: Bool
        var title: String?
        var artist: String?
        var album: String?
        var isPlaying: Bool?
        var duration: Double?
        var elapsed: Double?
        var artworkURL: String?
        var trackID: String?
        var isShuffling: Bool?
        var shuffleEnabled: Bool?
        var repeatMode: String?
        var repeatEnabled: Bool?
        var isFavorited: Bool?
        var audioFormat: String?
        var link: String?
    }

    private struct ScriptSnapshot {
        var state: MediaState
        var bundleID: String
        var pid: pid_t
        var artworkURL: String?
        var trackID: String?
        var identity: String
    }

    private var preferredBundleID: String? {
        switch preferredSource.lowercased() {
        case "system": return nil
        case "music": return "com.apple.Music"
        case "spotify": return "com.spotify.client"
        default: return "" // An invalid explicit selection must not choose an unrelated source.
        }
    }

    private func acceptsSource(_ bundleID: String?) -> Bool {
        preferredBundleID.map { !$0.isEmpty && $0 == bundleID } ?? true
    }

    private func definition(for app: NSRunningApplication) -> CoveMediaDefinition {
        guard let id = app.bundleIdentifier else { return CoveMediaDefinition() }
        if let cached = scriptDefinitions[id] { return cached }
        let value = CoveMediaDefinition(bundleURL: app.bundleURL)
        scriptDefinitions[id] = value
        return value
    }

    private func scriptReadSource(bundleID: String, definition: CoveMediaDefinition) -> String {
        let spotify = bundleID == "com.spotify.client"
        func get(_ kind: String, _ property: String, _ expression: String) -> String {
            definition.has(kind, property) ? "read(() => \(expression))" : "null"
        }
        let shuffle = spotify ? get("application", "shuffling", "app.shuffling()") :
            get("application", "shuffle enabled", "app.shuffleEnabled()")
        let repeatValue = spotify ? get("application", "repeating", "app.repeating()") :
            get("application", "song repeat", "app.songRepeat()")
        let favorite = spotify ? get("track", "starred", "track.starred()") :
            get("track", "favorited", "track.favorited()")
        let link = spotify ? get("track", "spotify url", "track.spotifyUrl()") :
            get("URL track", "address", "track.address()")
        return """
        (() => {
            const app = Application('\(bundleID)');
            if (!app.running()) return JSON.stringify({available: false});
            const status = app.playerState();
            if (status === 'stopped') return JSON.stringify({available: false});
            const read = fn => { try { const x = fn(); return x === undefined ? null : x; } catch (_) { return null; } };
            const track = app.currentTrack();
            const itemID = read(() => \(spotify ? "track.id()" : "track.persistentID()"));
            const repeat = \(repeatValue);
            const result = {available: true, title: read(() => track.name()), artist: read(() => track.artist()),
                album: read(() => track.album()), isPlaying: status === 'playing',
                duration: read(() => Number(track.duration()) / \(spotify ? 1000 : 1)),
                elapsed: \(get("application", "player position", "Number(app.playerPosition())")),
                trackID: typeof itemID === 'string' && itemID.trim().length > 0 ? itemID : null,
                artworkURL: \(spotify ? "read(() => track.artworkUrl())" : "null"),
                isShuffling: \(shuffle),
                shuffleEnabled: \(spotify ? get("application", "shuffling enabled", "app.shufflingEnabled()") : "null"),
                repeatMode: \(spotify ? "typeof repeat === 'boolean' ? (repeat ? 'all' : 'off') : null" : "repeat"),
                repeatEnabled: \(spotify ? get("application", "repeating enabled", "app.repeatingEnabled()") : "null"),
                isFavorited: \(favorite), audioFormat: \(get("track", "kind", "track.kind()")), link: \(link)};
            if (result.trackID !== null && read(() => \(spotify ? "app.currentTrack().id()" : "app.currentTrack().persistentID()")) !== itemID)
                throw Error('The current track changed during the metadata read.');
            return JSON.stringify(result);
        })()
        """
    }

    private func populateScriptCapabilities(_ value: inout MediaState, track: ScriptTrack,
                                            definition: CoveMediaDefinition, bundleID: String, includeTransport: Bool = true) {
        let spotify = bundleID == "com.spotify.client"
        if includeTransport {
            value.supportsPlayPause = definition.hasCommand("playpause")
            value.supportsNext = definition.hasCommand("next track")
            value.supportsPrevious = definition.hasCommand("previous track")
        }
        value.supportsSeek = value.duration > 0 && track.elapsed?.isFinite == true &&
            Self.mediaItemID(track.trackID) != nil &&
            definition.has(spotify ? "track" : "item", spotify ? "id" : "persistent ID") &&
            definition.has("application", "player position", writable: true)
        value.isShuffling = track.isShuffling
        value.supportsShuffle = track.isShuffling != nil &&
            definition.has("application", spotify ? "shuffling" : "shuffle enabled", writable: true) &&
            (!spotify || track.shuffleEnabled == true)
        if let mode = track.repeatMode, ["off", "all", "one"].contains(mode) {
            value.repeatMode = mode
            value.isRepeating = mode != "off"
            value.supportsRepeat = definition.has("application", spotify ? "repeating" : "song repeat", writable: true) &&
                (!spotify || track.repeatEnabled == true)
        }
        value.isFavorited = track.isFavorited
        value.supportsFavorite = !spotify && track.isFavorited != nil && track.trackID?.isEmpty == false &&
            definition.has("track", "favorited", writable: true)
        if let format = track.audioFormat, !format.isEmpty { value.audioFormat = format }
        if let link = track.link.flatMap(Self.mediaLink) {
            value.link = link.absoluteString
            value.supportsCopyLink = true
        }
    }

    /// A successful, already authorized read can supplement the same remote track.
    /// An unavailable/denied optional script must not discard valid system metadata.
    private func enrichRemoteWithScript(epoch: UUID) {
        lastError = nil
        guard scriptEnabled, let bundleID = sourceBundleID, CoveMediaScripts.supported.contains(bundleID),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            finishRefresh(); return
        }
        let identity = trackIdentity, definition = definition(for: app)
        scripts.run(pid: app.processIdentifier, source: scriptReadSource(bundleID: bundleID, definition: definition)) { [weak self] result in
            guard let self, self.running, self.generation == epoch else { return }
            if self.trackIdentity == identity, case .success(let data) = result,
               let track = try? JSONDecoder().decode(ScriptTrack.self, from: data), track.available,
               track.title == self.state.title, track.artist == self.state.artist {
                var value = self.state
                let remoteSeek = value.supportsSeek
                self.populateScriptCapabilities(&value, track: track, definition: definition, bundleID: bundleID, includeTransport: false)
                // Direct and adapter seeks must use their own item checks. Script
                // enrichment cannot make an unidentifiable remote item seekable.
                value.supportsSeek = remoteSeek
                self.scriptTrackID = track.trackID
                if self.state != value { self.state = value }
            }
            self.finishRefresh()
        }
    }

    private static func javaScriptLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }

    fileprivate static func mediaItemID(_ value: Any?) -> String? {
        guard let value = value as? String, value.utf8.count <= 8_192,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func scriptItemExpression(bundleID: String) -> String? {
        switch bundleID {
        case "com.apple.Music": return "app.currentTrack().persistentID()"
        case "com.spotify.client": return "app.currentTrack().id()"
        default: return nil
        }
    }

    private static func mediaLink(_ text: String) -> URL? {
        guard text.utf8.count <= 8_192, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["https", "http", "spotify"].contains(scheme),
              url.user == nil, url.password == nil,
              scheme == "spotify" ? !url.absoluteString.dropFirst(8).isEmpty : url.host?.isEmpty == false else { return nil }
        return url
    }

    private var adapterURL: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let name = FileManager.default.isReadableFile(atPath: resources.appendingPathComponent("OpenCoveMediaAdapter.js").path)
            ? "OpenCoveMediaAdapter.js" : "OpenCoveMediaAdapter.swift"
        let url = resources.appendingPathComponent(name)
        guard FileManager.default.isReadableFile(atPath: url.path),
              url.resolvingSymlinksInPath().deletingLastPathComponent() == resources.resolvingSymlinksInPath() else { return nil }
        return url
    }

    private func readAdapterFallback(epoch: UUID, remoteResult: CoveRemoteResult?, reason: String?) {
        guard remote != nil else { readScriptFallback(epoch: epoch, remoteResult: remoteResult, reason: reason); return }
        let now = ProcessInfo.processInfo.systemUptime
        if !adapterWatch.isRunning, now >= adapterRetryAfter {
            if let url = adapterURL {
                adapterWatch.start(url: url, onPayload: { [weak self] payload in
                    guard let self, self.running, self.generation == epoch, self.remote != nil else { return }
                    let result = CoveRemoteResult(payload: payload)
                    if self.adapterSnapshot?.bundleID != result.bundleID {
                        self.localReaderEmpty = false
                        self.localRetryAt = 0
                    }
                    self.adapterSnapshot = result
                    self.adapterReceivedAt = ProcessInfo.processInfo.systemUptime
                    self.adapterError = self.adapterSnapshot?.error
                    self.refresh()
                }, onExit: { [weak self] error in
                    guard let self, self.running, self.generation == epoch else { return }
                    self.adapterRetryAfter = ProcessInfo.processInfo.systemUptime + (error == nil ? 1 : 60)
                    self.adapterError = error
                    // A normal lease renewal can reuse the last fresh snapshot.
                    // A failed child must not leave apparently live metadata behind.
                    if error != nil { self.adapterSnapshot = nil }
                    self.refresh()
                    // A normal lease expiry must not wait for the 15-second
                    // empty-source poll before creating its replacement.
                    if error == nil { self.scheduleRefresh(after: 1.1) }
                })
            } else {
                adapterRetryAfter = now + 60
                adapterError = "The packaged system media adapter is missing."
            }
        }
        if let result = adapterSnapshot, now - adapterReceivedAt <= 35,
           let snapshot = snapshot(from: result) {
            apply(snapshot.state, bundleID: snapshot.bundleID, pid: result.pid, backend: .adapter,
                  rate: snapshot.rate, identity: snapshot.identity, itemID: snapshot.itemID)
            decodeRemoteArtwork(snapshot.artworkData, identity: snapshot.identity)
            enrichRemoteWithScript(epoch: epoch)
        } else {
            let explicit = preferredBundleID
            let message = explicit != nil && adapterSnapshot?.bundleID != explicit ?
                "The preferred player is not the active system media source. Enable already authorized AppleScript to read that player directly." :
                adapterError ?? reason ?? "Waiting for the system media adapter."
            readScriptFallback(epoch: epoch, remoteResult: remoteResult ?? adapterSnapshot, reason: message)
        }
    }

    private func adapterCommand(_ action: [String]) {
        guard running, remote != nil, backend == .adapter, let bundleID = sourceBundleID, let url = adapterURL else {
            lastError = "The system media adapter is unavailable."; return
        }
        let epoch = generation, identity = trackIdentity
        let itemCommand = action.first == "--seek" || action.first == "--rate"
        var arguments = action + ["--source", bundleID]
        if itemCommand {
            guard let adapterItemID else { lastError = "This source did not identify the current item."; return }
            arguments += ["--item", adapterItemID]
        }
        scripts.runAdapter(url: url, arguments: arguments, expectedItem: itemCommand ? identity : nil) { [weak self] result in
            guard let self, self.running, self.generation == epoch, self.trackIdentity == identity else { return }
            switch result {
            case .success(let data):
                if let payload = CoveMediaAdapterWatch.payload(from: data) {
                    self.lastError = payload["error"] as? String
                    if self.lastError == nil { self.scheduleRefresh(after: 0.05, wakeAdapter: true) }
                } else { self.lastError = "The system media adapter returned an unreadable response." }
            case .failure(let error): self.lastError = error.localizedDescription
            }
        }
    }

    private func readScriptFallback(epoch: UUID, remoteResult: CoveRemoteResult?, reason: String?) {
        guard scriptEnabled else {
            clearState()
            lastError = reason
            finishRefresh()
            return
        }
        let apps = scriptApplications(preferred: remoteResult?.bundleID ?? sourceBundleID)
        readScriptCandidate(apps, index: 0, best: nil, errors: [], epoch: epoch, reason: reason)
    }

    private func readScriptCandidate(_ apps: [NSRunningApplication], index: Int, best: ScriptSnapshot?,
                                     errors: [String], epoch: UUID, reason: String?) {
        guard running, generation == epoch else { return }
        guard index < apps.count else {
            if let best {
                apply(best.state, bundleID: best.bundleID, pid: best.pid, backend: .script,
                      rate: best.state.isPlaying ? 1 : 0, identity: best.identity)
                scriptTrackID = best.trackID
                lastError = nil
                fetchScriptArtwork(best)
            } else {
                clearState()
                lastError = errors.isEmpty ? reason : errors.joined(separator: " ")
            }
            finishRefresh()
            return
        }
        let app = apps[index]
        guard let bundleID = app.bundleIdentifier else {
            readScriptCandidate(apps, index: index + 1, best: best, errors: errors, epoch: epoch, reason: reason)
            return
        }
        let definition = definition(for: app)
        let source = scriptReadSource(bundleID: bundleID, definition: definition)
        scripts.run(pid: app.processIdentifier, source: source) { [weak self] result in
            guard let self, self.running, self.generation == epoch else { return }
            var nextBest = best, nextErrors = errors
            switch result {
            case .failure(let error): nextErrors.append(error.localizedDescription)
            case .success(let data):
                do {
                    let track = try JSONDecoder().decode(ScriptTrack.self, from: data)
                    if track.available {
                        let duration = max(0, (track.duration?.isFinite == true ? track.duration : nil) ?? 0)
                        let position = max(0, (track.elapsed?.isFinite == true ? track.elapsed : nil) ?? 0)
                        var value = MediaState(title: track.title ?? "", artist: track.artist ?? "",
                            album: track.album ?? "", isPlaying: track.isPlaying ?? false, duration: duration,
                            elapsed: duration > 0 ? min(position, duration) : position, artworkData: nil,
                            source: app.localizedName ?? bundleID, available: true)
                        populateScriptCapabilities(&value, track: track, definition: definition, bundleID: bundleID)
                        if !value.title.isEmpty || !value.artist.isEmpty || duration > 0 {
                            let identity = [bundleID, track.trackID ?? "", value.title, value.artist, value.album,
                                            String(duration)].joined(separator: "\u{1F}")
                            if best == nil || (!best!.state.isPlaying && value.isPlaying) {
                                nextBest = ScriptSnapshot(state: value, bundleID: bundleID,
                                    pid: app.processIdentifier, artworkURL: track.artworkURL,
                                    trackID: track.trackID, identity: identity)
                            }
                        }
                    }
                } catch { nextErrors.append("\(app.localizedName ?? bundleID) returned unreadable media metadata.") }
            }
            self.readScriptCandidate(apps, index: index + 1, best: nextBest, errors: nextErrors,
                                     epoch: epoch, reason: reason)
        }
    }

    private func fetchScriptArtwork(_ snapshot: ScriptSnapshot) {
        guard state.artworkData == nil,
              artworkIdentity != snapshot.identity || ProcessInfo.processInfo.systemUptime >= nextArtworkAttempt else { return }
        artworkIdentity = snapshot.identity
        nextArtworkAttempt = ProcessInfo.processInfo.systemUptime + 30
        let epoch = generation, identity = snapshot.identity
        if snapshot.bundleID == "com.apple.Music" {
            let script = """
            with timeout of 2 seconds
                tell application id "com.apple.Music"
                    if not running then return ""
                    try
                        if persistent ID of current track is not \(Self.appleScriptLiteral(snapshot.trackID ?? "")) then return ""
                        return raw data of artwork 1 of current track
                    on error
                        return ""
                    end try
                end tell
            end timeout
            """
            scripts.run(pid: snapshot.pid, source: script, language: "AppleScript") { [weak self] result in
                guard let self, self.running, self.generation == epoch, self.trackIdentity == identity,
                      case .success(let output) = result else { return }
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let image = Self.appleScriptData(output).flatMap(Self.artwork)
                    DispatchQueue.main.async {
                        guard let self, self.running, self.generation == epoch,
                              self.trackIdentity == identity, let image else { return }
                        self.state.artworkData = image
                    }
                }
            }
        } else if let string = snapshot.artworkURL, string.utf8.count <= 8_192,
                  let url = URL(string: string), CoveMediaArtworkDownload.allows(url) {
            artworkDownload?.cancel()
            let downloadID = UUID()
            artworkDownloadID = downloadID
            artworkDownload = CoveMediaArtworkDownload(url: url) { [weak self] data in
                let image = data.flatMap(Self.artwork)
                DispatchQueue.main.async {
                    guard let self, self.running, self.generation == epoch, self.trackIdentity == identity,
                          self.artworkDownloadID == downloadID else { return }
                    self.artworkDownload = nil
                    if let image { self.state.artworkData = image }
                }
            }
        }
    }

    nonisolated private static func artwork(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count <= 12 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    nonisolated private static func appleScriptData(_ output: Data) -> Data? {
        guard let text = String(data: output, encoding: .utf8), let start = text.range(of: "«data "),
              let end = text[start.upperBound...].firstIndex(of: "»") else { return nil }
        let hex = text[start.upperBound..<end].dropFirst(4).filter { !$0.isWhitespace }
        guard hex.count.isMultiple(of: 2), hex.count <= 24 * 1024 * 1024 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}

/// Downloads use Spotify's supplied CDN URL. Redirects, cookies,
/// credential storage, caches, and responses larger than 12 MiB are disabled.
/// The data delegate applies the size limit as bytes arrive, before decoding.
private final class CoveMediaArtworkDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let limit = 12 * 1024 * 1024
    private let lock = NSLock()
    private var data = Data()
    private var completion: ((Data?) -> Void)?
    private var session: URLSession?
    private var task: URLSessionDataTask?

    static func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return host == "i.scdn.co" || host.hasSuffix(".scdn.co")
    }

    init(url: URL, completion: @escaping (Data?) -> Void) {
        self.completion = completion
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        let task = session.dataTask(with: url)
        self.task = task
        task.resume()
    }

    func cancel() { finish(success: false, notify: false) }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // A valid initial CDN host must not authorize contacting another host.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let url = response.url, Self.allows(url), response.expectedContentLength <= Int64(Self.limit) else {
            completionHandler(.cancel)
            finish(success: false)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        guard completion != nil else { lock.unlock(); return }
        guard chunk.count <= Self.limit - data.count else {
            lock.unlock()
            finish(success: false)
            return
        }
        data.append(chunk)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(success: error == nil)
    }

    private func finish(success: Bool, notify: Bool = true) {
        lock.lock()
        let callback = completion
        completion = nil
        let result = success && !data.isEmpty ? data : nil
        data = Data()
        let session = session
        self.session = nil
        task = nil
        lock.unlock()
        session?.invalidateAndCancel()
        // Cancellation may originate on the main actor. Image decoding never does.
        if notify, let callback { DispatchQueue.global(qos: .utility).async { callback(result) } }
    }
}

/// Inspect only installed, public scripting dictionaries. Do not infer writable
/// controls from app identity, a current value, or Spotify's read-only starred flag.
private final class CoveMediaDefinition: NSObject, XMLParserDelegate {
    private var properties: [String: Bool] = [:]
    private var commands = Set<String>()
    private var currentClass: String?

    override init() { super.init() }

    convenience init(bundleURL: URL?) {
        self.init()
        guard let bundleURL, let bundle = Bundle(url: bundleURL),
              let name = bundle.object(forInfoDictionaryKey: "OSAScriptingDefinition") as? String,
              let resource = bundle.resourceURL?.appendingPathComponent(name),
              let data = try? Data(contentsOf: resource), data.count < 2 * 1024 * 1024 else { return }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        if !parser.parse() { properties.removeAll(); commands.removeAll() }
    }

    func has(_ kind: String, _ property: String, writable: Bool = false) -> Bool {
        guard let canWrite = properties[kind + ":" + property] else { return false }
        return !writable || canWrite
    }

    func hasCommand(_ name: String) -> Bool { commands.contains(name) }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if name == "class" { currentClass = attributes["name"] }
        if name == "command", let command = attributes["name"] { commands.insert(command) }
        if name == "property", let currentClass, let property = attributes["name"] {
            properties[currentClass + ":" + property] = attributes["access"] != "r"
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "class" { currentClass = nil }
    }
}

// The private ABI is confined to this adapter. Nothing is statically linked to MediaRemote.
@MainActor
private final class CoveMediaRemote {
    typealias Info = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    typealias PID = @convention(c) (DispatchQueue, @escaping @convention(block) (pid_t) -> Void) -> Void
    typealias Playing = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
    typealias Send = @convention(c) (Int32, CFDictionary?) -> Bool
    typealias Seek = @convention(c) (Double) -> Void
    typealias Register = @convention(c) (DispatchQueue) -> Void
    typealias Unregister = @convention(c) () -> Void

    // Keep the image loaded for the process lifetime: the framework may retain asynchronous blocks.
    private static let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY | RTLD_LOCAL)
    private let getInfo: Info?
    private let getPID: PID?
    private let getPlaying: Playing?
    let sendCommand: Send?
    let setElapsedTime: Seek?
    private let register: Register?
    private let unregister: Unregister?
    private var registered = false
    let loadError: String?

    init() {
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let handle = Self.handle, let address = dlsym(handle, name) else { return nil }
            return unsafeBitCast(address, to: type)
        }
        getInfo = symbol("MRMediaRemoteGetNowPlayingInfo", as: Info.self)
        getPID = symbol("MRMediaRemoteGetNowPlayingApplicationPID", as: PID.self)
        getPlaying = symbol("MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: Playing.self)
        sendCommand = symbol("MRMediaRemoteSendCommand", as: Send.self)
        setElapsedTime = symbol("MRMediaRemoteSetElapsedTime", as: Seek.self)
        register = symbol("MRMediaRemoteRegisterForNowPlayingNotifications", as: Register.self)
        unregister = symbol("MRMediaRemoteUnregisterForNowPlayingNotifications", as: Unregister.self)
        let localGetter = NSClassFromString("MRNowPlayingRequest").flatMap {
            class_getClassMethod($0, NSSelectorFromString("localNowPlayingItem"))
        }.map { method -> Bool in
            let type = method_copyReturnType(method)
            defer { free(type) }
            return method_getNumberOfArguments(method) == 2 && Self.isObjectEncoding(type)
        } ?? false
        let asyncReader = NSClassFromString("MRNowPlayingRequest").flatMap {
            class_getInstanceMethod($0, NSSelectorFromString("requestNowPlayingInfoOnQueue:completion:"))
        }.map(Self.isRequestMethod) ?? false
        loadError = Self.handle == nil ? "MediaRemote is not available on this macOS version." :
            (getInfo == nil && !localGetter && !asyncReader ?
             "This macOS version does not expose a supported Now Playing reader." : nil)
    }

    var canRead: Bool { loadError == nil }

    var currentBundleID: String? {
        guard let cls = NSClassFromString("MRNowPlayingRequest"),
              let path = Self.object(cls, "localNowPlayingPlayerPath"), let client = Self.object(path, "client") else { return nil }
        return Self.object(client, "bundleIdentifier") as? String
    }

    func commandEnabled(_ name: String, for bundleID: String) -> Bool {
        guard !bundleID.isEmpty, currentBundleID == bundleID,
              let cls = NSClassFromString("MRNowPlayingRequest") else { return false }
        let commands = (Self.object(cls, "localSupportedCommands") as? [AnyObject] ?? []).compactMap {
            Self.object($0, "dictionaryRepresentation") as? [String: Any]
        }
        return currentBundleID == bundleID && CoveRemoteResult.enabled(name, commands: commands)
    }

    func setPlaybackSpeed(_ speed: Double, for bundleID: String, itemID: String) -> Bool {
        guard speed.isFinite, speed > 0, speed <= 16, let sendCommand,
              MediaController.mediaItemID(itemID) != nil, currentBundleID == bundleID,
              let cls = NSClassFromString("MRNowPlayingRequest") else { return false }
        let commands = (Self.object(cls, "localSupportedCommands") as? [AnyObject] ?? []).compactMap {
            Self.object($0, "dictionaryRepresentation") as? [String: Any]
        }
        guard let selected = CoveRemoteResult.playbackRates(commands).first(where: { abs($0 - speed) < 0.000001 }),
              let current = currentItemInfo(for: bundleID),
              MediaController.mediaItemID(current[key("kMRMediaRemoteNowPlayingInfoContentItemIdentifier")]) == itemID,
              currentBundleID == bundleID else { return false }
        return sendCommand(19, [key("kMRMediaRemoteOptionPlaybackRate"): selected] as CFDictionary)
    }

    /// The global setter cannot compare an item and seek atomically. Keep the
    /// final immediate source/item/duration read adjacent to the actual write,
    /// after capability discovery, and reject stale or unidentifiable targets.
    func seek(to seconds: Double, for bundleID: String, itemID: String) -> Bool {
        guard seconds.isFinite, MediaController.mediaItemID(itemID) != nil, let seek = setElapsedTime,
              commandEnabled("SeekToPlaybackPosition", for: bundleID),
              let current = currentItemInfo(for: bundleID),
              MediaController.mediaItemID(current[key("kMRMediaRemoteNowPlayingInfoContentItemIdentifier")]) == itemID,
              let duration = (current[key("kMRMediaRemoteNowPlayingInfoDuration")] as? NSNumber)?.doubleValue,
              duration.isFinite, duration > 0, currentBundleID == bundleID else { return false }
        seek(min(max(0, seconds), duration))
        return true // Submission only; there is no player acknowledgement API.
    }

    private func currentItemInfo(for bundleID: String) -> [String: Any]? {
        guard !bundleID.isEmpty, currentBundleID == bundleID,
              let cls = NSClassFromString("MRNowPlayingRequest"),
              let item = Self.object(cls, "localNowPlayingItem"),
              let info = Self.object(item, "nowPlayingInfo") as? [String: Any],
              MediaController.mediaItemID(info[key("kMRMediaRemoteNowPlayingInfoContentItemIdentifier")]) != nil,
              currentBundleID == bundleID else { return nil }
        return info
    }

    func key(_ symbol: String) -> String {
        guard let handle = Self.handle, let address = dlsym(handle, symbol),
              let value = address.assumingMemoryBound(to: NSString?.self).pointee else { return symbol }
        return value as String
    }

    var notificationNames: [Notification.Name] {
        ["kMRMediaRemoteNowPlayingInfoDidChangeNotification",
         "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
         "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
         "kMRMediaRemoteNowPlayingPlaybackQueueDidChangeNotification"].map { .init(key($0)) }
    }

    func startNotifications() {
        guard !registered, let register, unregister != nil else { return }
        register(.main)
        registered = true
    }

    func stopNotifications() {
        if registered { unregister?(); registered = false }
    }

    func read(completion: @escaping (CoveRemoteResult) -> Void) -> CoveRemoteRead {
        let modern = localSnapshot()
        let ticket = CoveRemoteRead(fallback: modern.info, bundleID: modern.bundleID, validateSource: { [weak self] pid in
            guard let self, self.currentBundleID == modern.bundleID else { return false }
            guard let pid else { return true }
            guard let bundle = modern.bundleID else { return false }
            return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundle
        }, completion: completion)
        ticket.supportsSeek = modern.supportsSeek
        ticket.canValidateSeekItem = modern.canValidateSeekItem
        ticket.enabledCommands = modern.enabledCommands
        ticket.supportedPlaybackSpeeds = modern.supportedPlaybackSpeeds
        // A coherent modern item supplies its own rate. Never merge it with
        // later legacy metadata/PID/playing callbacks from a different source.
        if modern.info?.isEmpty == false {
            DispatchQueue.main.async { ticket.finish(timedOut: false) }
            return ticket
        }
        ticket.pending = 1
        ticket.armTimeout()
        if requestInfo({ info, error in
            ticket.info = info
            ticket.readError = error?.localizedDescription
            ticket.denied = error?.domain == "kMRMediaRemoteFrameworkErrorDomain" && error?.code == 3
            ticket.received()
        }) { return ticket }
        ticket.pending = (getInfo == nil ? 0 : 1) + (getPID == nil ? 0 : 1) + (getPlaying == nil ? 0 : 1)
        getInfo?(.main) { value in
            DispatchQueue.main.async { ticket.info = value as? [String: Any]; ticket.received() }
        }
        getPID?(.main) { value in
            DispatchQueue.main.async { ticket.pid = value > 0 ? value : nil; ticket.received() }
        }
        getPlaying?(.main) { value in
            DispatchQueue.main.async { ticket.isPlaying = value; ticket.received() }
        }
        if ticket.pending == 0 { DispatchQueue.main.async { ticket.finish(timedOut: false) } }
        return ticket
    }

    private func localSnapshot() -> (info: [String: Any]?, bundleID: String?, supportsSeek: Bool,
                                     enabledCommands: Set<String>, canValidateSeekItem: Bool, supportedPlaybackSpeeds: [Double]) {
        guard let cls = NSClassFromString("MRNowPlayingRequest") else { return (nil, nil, false, [], false, []) }
        let before = currentBundleID
        let item = Self.object(cls, "localNowPlayingItem")
        let info = item.flatMap { Self.object($0, "nowPlayingInfo") } as? [String: Any]
        let commands = (Self.object(cls, "localSupportedCommands") as? [AnyObject] ?? []).compactMap {
            Self.object($0, "dictionaryRepresentation") as? [String: Any]
        }
        guard before == currentBundleID else { return (nil, before, false, [], false, []) }
        let itemKey = key("kMRMediaRemoteNowPlayingInfoContentItemIdentifier")
        let itemID = MediaController.mediaItemID(info?[itemKey])
        let canValidate = before.flatMap { currentItemInfo(for: $0) }.map {
            itemID != nil && MediaController.mediaItemID($0[itemKey]) == itemID
        } ?? false
        return (info, before, CoveRemoteResult.enabled("SeekToPlaybackPosition", commands: commands),
                CoveRemoteResult.enabledNames(commands), canValidate, CoveRemoteResult.playbackRates(commands))
    }

    private func requestInfo(_ completion: @escaping ([String: Any]?, NSError?) -> Void) -> Bool {
        guard let cls = NSClassFromString("MRNowPlayingRequest") as? NSObject.Type,
              let method = class_getInstanceMethod(cls, NSSelectorFromString("requestNowPlayingInfoOnQueue:completion:")),
              Self.isRequestMethod(method) else { return false }
        typealias Request = @convention(c) (AnyObject, Selector, DispatchQueue, @escaping @convention(block) (AnyObject?, AnyObject?) -> Void) -> Void
        let request = cls.init()
        unsafeBitCast(method_getImplementation(method), to: Request.self)(request,
            NSSelectorFromString("requestNowPlayingInfoOnQueue:completion:"), .main) { info, error in
            withExtendedLifetime(request) {
                DispatchQueue.main.async { completion(info as? [String: Any], error as? NSError) }
            }
        }
        return true
    }

    private static func isRequestMethod(_ method: Method) -> Bool {
        guard method_getNumberOfArguments(method) == 4 else { return false }
        let result = method_copyReturnType(method)
        let queue = method_copyArgumentType(method, 2), block = method_copyArgumentType(method, 3)
        defer { free(result); free(queue); free(block) }
        return String(cString: result) == "v" && queue.map { isObjectEncoding($0) } == true &&
            block.map { String(cString: $0) == "@?" } == true
    }

    /// Validate a no-argument Objective-C object getter before invoking its current implementation.
    private static func object(_ object: AnyObject, _ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard let cls = object_getClass(object), let method = class_getInstanceMethod(cls, selector),
              method_getNumberOfArguments(method) == 2 else { return nil }
        let returnType = method_copyReturnType(method)
        defer { free(returnType) }
        guard isObjectEncoding(returnType) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        return unsafeBitCast(method_getImplementation(method), to: Getter.self)(object, selector)?.takeUnretainedValue()
    }

    private static func isObjectEncoding(_ encoding: UnsafePointer<CChar>) -> Bool {
        let value = String(cString: encoding)
        return value == "@" || (value.hasPrefix("@\"") && value.hasSuffix("\""))
    }
}

private struct CoveRemoteResult {
    var info: [String: Any]?
    var pid: pid_t?
    var isPlaying: Bool?
    var bundleID: String?
    var timedOut: Bool
    var supportsSeek = false
    var enabledCommands = Set<String>()
    var supportedPlaybackSpeeds: [Double] = []
    var adapter = false
    var canValidateSeekItem = false
    var error: String? = nil
    var denied = false

    static func enabled(_ name: String, commands: [[String: Any]]) -> Bool {
        commands.contains {
            guard $0["command"] as? String == name else { return false }
            return ($0["enabled"] as? NSNumber)?.boolValue ?? (($0["enabled"] as? String)?.uppercased() == "YES")
        }
    }

    static func enabledNames(_ commands: [[String: Any]]) -> Set<String> {
        Set(commands.compactMap { item in
            guard let name = item["command"] as? String, enabled(name, commands: [item]) else { return nil }
            return name
        })
    }

    static func playbackRates(_ commands: [[String: Any]]) -> [Double] {
        guard let command = commands.first(where: { $0["command"] as? String == "ChangePlaybackRateCommand"
            && enabled("ChangePlaybackRateCommand", commands: [$0]) }),
              let options = command["options"] as? [String: Any],
              let rates = options["kMRMediaRemoteCommandInfoSupportedPlaybackRates"] as? [Any],
              rates.count <= 32 else { return [] }
        var result: [Double] = []
        for raw in rates {
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { continue }
            let value = number.doubleValue
            if value.isFinite, value > 0, value <= 16, !result.contains(value) { result.append(value) }
        }
        return result.sorted()
    }

    init(payload: [String: Any]) {
        info = payload["info"] as? [String: Any]
        bundleID = payload["bundleID"] as? String
        pid = nil
        isPlaying = nil
        timedOut = false
        supportsSeek = Self.enabled("SeekToPlaybackPosition", commands: payload["commands"] as? [[String: Any]] ?? [])
        enabledCommands = Self.enabledNames(payload["commands"] as? [[String: Any]] ?? [])
        supportedPlaybackSpeeds = Self.playbackRates(payload["commands"] as? [[String: Any]] ?? [])
        adapter = true
        canValidateSeekItem = payload["canValidateSeekItem"] as? Bool == true
        error = payload["error"] as? String
    }

    init(info: [String: Any]?, pid: pid_t?, isPlaying: Bool?, bundleID: String?, timedOut: Bool, supportsSeek: Bool = false) {
        self.info = info; self.pid = pid; self.isPlaying = isPlaying
        self.bundleID = bundleID; self.timedOut = timedOut; self.supportsSeek = supportsSeek
    }
}

@MainActor
private final class CoveRemoteRead {
    var pending = 0
    var info: [String: Any]?
    var pid: pid_t?
    var isPlaying: Bool?
    var supportsSeek = false
    var canValidateSeekItem = false
    var enabledCommands = Set<String>()
    var supportedPlaybackSpeeds: [Double] = []
    var readError: String?
    var denied = false
    private let fallback: [String: Any]?
    private let bundleID: String?
    private let validateSource: (pid_t?) -> Bool
    private var completion: ((CoveRemoteResult) -> Void)?
    private var timeout: DispatchWorkItem?

    init(fallback: [String: Any]?, bundleID: String?, validateSource: @escaping (pid_t?) -> Bool,
         completion: @escaping (CoveRemoteResult) -> Void) {
        self.fallback = fallback
        self.bundleID = bundleID
        self.validateSource = validateSource
        self.completion = completion
    }

    func armTimeout() {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finish(timedOut: true) }
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func received() {
        pending -= 1
        if pending <= 0 { finish(timedOut: false) }
    }

    func finish(timedOut: Bool) {
        let callback = completion
        let valid = validateSource(pid)
        var result = CoveRemoteResult(info: valid ? (info?.isEmpty == false ? info : fallback) : nil,
                                     pid: valid ? pid : nil, isPlaying: valid ? isPlaying : nil,
                                     bundleID: valid ? bundleID : nil, timedOut: timedOut,
                                     supportsSeek: valid && supportsSeek)
        result.error = valid ? readError : "The active source changed during the metadata read."
        result.enabledCommands = valid ? enabledCommands : []
        result.supportedPlaybackSpeeds = valid ? supportedPlaybackSpeeds : []
        result.canValidateSeekItem = valid && canValidateSeekItem
        result.denied = denied
        cancel()
        callback?(result)
    }

    func cancel() {
        timeout?.cancel()
        timeout = nil
        completion = nil
    }
}

/// One owned interpreter per controller. Media contents are never sent to logs.
/// A failed launch backs off in the controller; normal polling reuses this process.
private final class CoveMediaAdapterWatch: @unchecked Sendable {
    private let queue = DispatchQueue(label: "OpenCove.media.system-adapter", qos: .utility)
    private let lock = NSLock()
    private var epoch = 0
    private var process: Process?
    private var active = false
    private var lastFrameAt = 0.0
    private var receivedFrame = false
    private var pendingPayload: [String: Any]?
    private var deliveryScheduled = false
    // The reader queue owns both ends. Writers borrow this descriptor only
    // under lock; it is unpublished under that lock before either end closes.
    private var readerWake: (token: Int, descriptor: Int32)?
    private var refreshInput: (token: Int, descriptor: Int32)?

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return active }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        wakeReaderLocked(token: epoch)
        readerWake = nil
        refreshInput = nil
        epoch += 1
        active = false
        pendingPayload = nil
        deliveryScheduled = false
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process = nil
    }

    func requestRefresh() {
        lock.lock(); defer { lock.unlock() }
        guard active, let refreshInput, refreshInput.token == epoch, process?.isRunning == true else { return }
        // One nonblocking byte requests metadata only. The child coalesces
        // bursts; EAGAIN means it already has pending refresh requests.
        var byte: UInt8 = 1
        var count: Int
        repeat { count = Darwin.write(refreshInput.descriptor, &byte, 1) } while count < 0 && errno == EINTR
    }

    private func wakeReaderLocked(token: Int) {
        guard let readerWake, readerWake.token == token else { return }
        // Nonblocking, one-byte writes cannot wait for a busy reader. EAGAIN
        // means a wake is already pending. The read end stays open under lock.
        var byte: UInt8 = 1
        var count: Int
        repeat { count = Darwin.write(readerWake.descriptor, &byte, 1) } while count < 0 && errno == EINTR
    }

    static func payload(from line: Data) -> [String: Any]? {
        guard line.count <= 23 * 1024 * 1024,
              let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: String],
              let encoded = record["snapshot"], let data = Data(base64Encoded: encoded), data.count <= 16 * 1024 * 1024 else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }

    func start(url: URL, onPayload: @escaping ([String: Any]) -> Void, onExit: @escaping (String?) -> Void) {
        lock.lock()
        guard !active else { lock.unlock(); return }
        active = true
        epoch += 1
        let token = epoch
        lastFrameAt = ProcessInfo.processInfo.systemUptime
        receivedFrame = false
        pendingPayload = nil
        deliveryScheduled = false
        lock.unlock()
        queue.async { [self] in
            guard url.pathExtension != "swift" || Self.hasSwiftToolchain() else {
                exited(token: token, error: "The optional Swift media adapter requires installed Xcode or Command Line Tools.", callback: onExit)
                return
            }
            var wakeDescriptors = [Int32](repeating: -1, count: 2)
            guard Darwin.pipe(&wakeDescriptors) == 0 else {
                exited(token: token, error: "Could not create the system media adapter wake pipe.", callback: onExit)
                return
            }
            let wakeRead = wakeDescriptors[0], wakeWrite = wakeDescriptors[1]
            defer {
                lock.lock()
                if readerWake?.token == token { readerWake = nil }
                lock.unlock()
                Darwin.close(wakeWrite)
                Darwin.close(wakeRead)
            }
            // Neither end may survive exec. Configure before publishing the
            // writer or launching the child; only the reader queue closes them.
            for descriptor in wakeDescriptors {
                let flags = fcntl(descriptor, F_GETFD)
                guard flags >= 0, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
                    exited(token: token, error: "Could not configure the system media adapter wake pipe.", callback: onExit)
                    return
                }
            }
            let wakeFlags = fcntl(wakeWrite, F_GETFL)
            guard wakeFlags >= 0, fcntl(wakeWrite, F_SETFL, wakeFlags | O_NONBLOCK) == 0 else {
                exited(token: token, error: "Could not configure the system media adapter wake pipe.", callback: onExit)
                return
            }
            let task = Process(), output = Pipe()
            defer {
                try? output.fileHandleForReading.close()
                try? output.fileHandleForWriting.close()
            }
            let javaScript = url.pathExtension == "js"
            let input = javaScript ? Pipe() : nil
            defer {
                lock.lock()
                if refreshInput?.token == token { refreshInput = nil }
                lock.unlock()
                try? input?.fileHandleForReading.close()
                try? input?.fileHandleForWriting.close()
            }
            if let input {
                let writer = input.fileHandleForWriting.fileDescriptor
                for handle in [input.fileHandleForReading, input.fileHandleForWriting] {
                    let flags = fcntl(handle.fileDescriptor, F_GETFD)
                    guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
                        exited(token: token, error: "Could not configure the media refresh pipe.", callback: onExit)
                        return
                    }
                }
                let flags = fcntl(writer, F_GETFL)
                guard flags >= 0, fcntl(writer, F_SETFL, flags | O_NONBLOCK) == 0,
                      fcntl(writer, F_SETNOSIGPIPE, 1) == 0 else {
                    exited(token: token, error: "Could not configure the media refresh writer.", callback: onExit)
                    return
                }
            }
            task.executableURL = URL(fileURLWithPath: javaScript ? "/usr/bin/osascript" : "/usr/bin/swift")
            task.arguments = (javaScript ? ["-l", "JavaScript", url.path] : ["-swift-version", "5", url.path]) + ["--watch"]
            task.currentDirectoryURL = url.deletingLastPathComponent()
            if let input { task.standardInput = input }
            else { task.standardInput = FileHandle.nullDevice }
            task.standardOutput = output
            task.standardError = FileHandle.nullDevice
            task.terminationHandler = { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); defer { self.lock.unlock() }
                self.wakeReaderLocked(token: token)
            }
            lock.lock()
            guard epoch == token, active else { lock.unlock(); return }
            readerWake = (token, wakeWrite)
            do { try task.run() } catch {
                lock.unlock()
                exited(token: token, error: "Could not start the system media adapter.", callback: onExit)
                return
            }
            process = task
            if let input { refreshInput = (token, input.fileHandleForWriting.fileDescriptor) }
            lock.unlock()
            var buffer = Data(), failure: String?
            var artworkKey: [String]?
            var artwork: Data?
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            let fd = output.fileHandleForReading.fileDescriptor
            let flags = fcntl(fd, F_GETFL)
            if flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 {
                failure = "Could not configure the system media adapter response pipe."
            }
            // Wait for data, cancellation/child exit, or the watchdog deadline.
            // Child exit also wakes the reader if a descendant retains stdout.
            // Nonblocking reads drain available output without awaiting that writer.
            while true {
                if failure != nil { break }
                lock.lock()
                let current = epoch == token && active
                let limit = receivedFrame ? 45.0 : 12.0
                let remaining = lastFrameAt + limit - ProcessInfo.processInfo.systemUptime
                lock.unlock()
                guard current else { break }
                if remaining <= 0 { failure = "The system media adapter stopped answering before the timeout."; break }
                let timeout = task.isRunning ? Int32(min(ceil(remaining * 1_000), Double(Int32.max))) : 0
                var descriptors = [pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0),
                                   pollfd(fd: wakeRead, events: Int16(POLLIN | POLLHUP), revents: 0)]
                let ready = descriptors.withUnsafeMutableBufferPointer {
                    Darwin.poll($0.baseAddress, nfds_t($0.count), timeout)
                }
                if ready < 0 {
                    if errno == EINTR { continue }
                    failure = "Could not poll the system media adapter response."
                    break
                }
                if ready == 0 {
                    if !task.isRunning { break }
                    continue
                }
                lock.lock()
                let stillCurrent = epoch == token && active
                lock.unlock()
                guard stillCurrent else { break }
                if descriptors.contains(where: { $0.revents & Int16(POLLERR | POLLNVAL) != 0 }) {
                    failure = "Could not poll the system media adapter response."
                    break
                }
                // A current-epoch wake means child exit. Leave that byte pending
                // while draining stdout, so an inherited writer cannot delay exit.
                if descriptors[0].revents == 0 {
                    if descriptors[1].revents != 0 { break }
                    continue
                }
                let count = bytes.withUnsafeMutableBytes {
                    Darwin.read(fd, $0.baseAddress!, $0.count)
                }
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    failure = "Could not read the system media adapter response."
                    break
                }
                buffer.append(contentsOf: bytes.prefix(count))
                guard buffer.count <= 23 * 1024 * 1024 else { failure = "The system media adapter exceeded its output limit."; break }
                while let end = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<end])
                    buffer.removeSubrange(...end)
                    guard var payload = Self.payload(from: line) else { failure = "The system media adapter returned an unreadable snapshot."; break }
                    // Merge artwork deltas on the reader queue, before the
                    // newest-frame delivery can replace an earlier image frame.
                    if var info = payload["info"] as? [String: Any],
                       let bundle = payload["bundleID"] as? String,
                       let item = info["kMRMediaRemoteNowPlayingInfoContentItemIdentifier"] as? String, !item.isEmpty {
                        let key = [bundle, item, info["kMRMediaRemoteNowPlayingInfoArtworkIdentifier"] as? String ?? ""]
                        if artworkKey != key { artwork = nil; artworkKey = key }
                        if let data = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data, data.count <= 12 * 1024 * 1024 {
                            artwork = data
                        }
                        info["kMRMediaRemoteNowPlayingInfoArtworkData"] = artwork
                        payload["info"] = info
                    } else { artworkKey = nil; artwork = nil }
                    lock.lock()
                    let current = epoch == token
                    if current {
                        lastFrameAt = ProcessInfo.processInfo.systemUptime
                        receivedFrame = true
                    }
                    lock.unlock()
                    if current { deliver(payload, token: token, callback: onPayload) }
                }
                if failure != nil { break }
            }
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
            task.waitUntilExit()
            lock.lock()
            let current = epoch == token
            if current { process = nil }
            lock.unlock()
            if current {
                let message = failure ?? (task.terminationStatus == 0 ? nil :
                    "The system media adapter stopped unexpectedly.")
                exited(token: token, error: message, callback: onExit)
            }
        }
    }

    private func exited(token: Int, error: String?, callback: @escaping (String?) -> Void) {
        DispatchQueue.main.async { [self] in
            lock.lock()
            guard epoch == token else { lock.unlock(); return }
            // Keep the lease active until this delivery. A final queued frame
            // must not restart the watcher before its failure/backoff is applied.
            active = false
            lock.unlock()
            callback(error)
        }
    }

    private func deliver(_ payload: [String: Any], token: Int, callback: @escaping ([String: Any]) -> Void) {
        lock.lock()
        guard epoch == token, active else { lock.unlock(); return }
        pendingPayload = payload
        guard !deliveryScheduled else { lock.unlock(); return }
        deliveryScheduled = true
        lock.unlock()
        DispatchQueue.main.async { [self] in
            lock.lock()
            guard epoch == token else { lock.unlock(); return }
            let payload = pendingPayload
            pendingPayload = nil
            deliveryScheduled = false
            lock.unlock()
            if let payload { callback(payload) }
        }
    }

    /// The /usr/bin/swift stub can offer a tools install when no toolchain exists.
    /// xcode-select -p is a read-only preflight and never opens that installer.
    static func hasSwiftToolchain() -> Bool {
        let check = Process(), output = Pipe()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        check.arguments = ["--print-path"]
        check.standardOutput = output
        check.standardError = FileHandle.nullDevice
        check.standardInput = FileHandle.nullDevice
        do { try check.run() } catch { return false }
        let timeout = DispatchWorkItem { if check.isRunning { kill(check.processIdentifier, SIGKILL) } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: timeout)
        check.waitUntilExit()
        timeout.cancel()
        guard check.terminationStatus == 0,
              let data = try? output.fileHandleForReading.read(upToCount: 8_192),
              let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return false }
        return ["usr/bin/swift-frontend", "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend"].contains {
            FileManager.default.isExecutableFile(atPath: URL(fileURLWithPath: path).appendingPathComponent($0).path)
        }
    }
}

/// Serial, bounded OSA subprocesses keep Apple Events off the UI thread and can be stopped.
private final class CoveMediaScripts: @unchecked Sendable {
    static let supported = ["com.apple.Music", "com.spotify.client"]
    private let queue = DispatchQueue(label: "OpenCove.media.apple-events", qos: .utility)
    private let lock = NSLock()
    private var epoch = 0
    private var itemEpoch = 0
    private var selectedItem = ""
    private var process: Process?

    private struct Token {
        var epoch: Int
        var itemEpoch: Int?
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func cancelAll() {
        lock.lock()
        epoch += 1
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process = nil
        lock.unlock()
    }

    /// Invalidate item-bound work even if A changes to B and back to A while
    /// the subprocess queue is busy. Ordinary metadata/transport work is retained.
    func selectItem(_ identity: String) {
        lock.lock(); defer { lock.unlock() }
        guard selectedItem != identity else { return }
        selectedItem = identity
        itemEpoch += 1
    }

    private func token(expectedItem: String? = nil) -> Token? {
        lock.lock(); defer { lock.unlock() }
        guard expectedItem == nil || (!selectedItem.isEmpty && expectedItem == selectedItem) else { return nil }
        return Token(epoch: epoch, itemEpoch: expectedItem == nil ? nil : itemEpoch)
    }

    func authorize(pid: pid_t, completion: @escaping (String?) -> Void) {
        guard let token = token() else { return }
        queue.async { [self] in
            guard isCurrent(token) else { return }
            let error = permissionError(pid: pid, prompt: true)
            DispatchQueue.main.async { completion(error) }
        }
    }

    func run(pid: pid_t, source: String, language: String = "JavaScript", expectedItem: String? = nil,
             completion: @escaping (Result<Data, Error>) -> Void) {
        guard let token = token(expectedItem: expectedItem) else { return }
        queue.async { [self] in
            guard isCurrent(token) else { return }
            let result: Result<Data, Error>
            if let message = permissionError(pid: pid, prompt: false) {
                result = .failure(Failure(message: message))
            } else {
                result = execute(source: source, language: language, token: token)
            }
            guard isCurrent(token) else { return }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func runAdapter(url: URL, arguments: [String], expectedItem: String? = nil,
                    completion: @escaping (Result<Data, Error>) -> Void) {
        guard let token = token(expectedItem: expectedItem) else { return }
        queue.async { [self] in
            guard isCurrent(token) else { return }
            let result = execute(source: "", language: "", token: token, adapterURL: url, adapterArguments: arguments)
            guard isCurrent(token) else { return }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func isCurrent(_ token: Token) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return epoch == token.epoch && (token.itemEpoch == nil || token.itemEpoch == itemEpoch)
    }

    private func permissionError(pid: pid_t, prompt: Bool) -> String? {
        guard Bundle.main.object(forInfoDictionaryKey: "NSAppleEventsUsageDescription") as? String != nil else {
            return "The app bundle needs NSAppleEventsUsageDescription before it can use the AppleScript fallback."
        }
        let descriptor = NSAppleEventDescriptor(processIdentifier: pid)
        let status = AEDeterminePermissionToAutomateTarget(descriptor.aeDesc, AEEventClass(typeWildCard),
                                                         AEEventID(typeWildCard), prompt)
        switch status {
        case noErr: return nil
        case -1744: return "Automation access is not granted. Use Enable Automation to request access to Music or Spotify."
        case -1743: return "Automation access was denied. Allow OpenCove in System Settings > Privacy & Security > Automation."
        case OSStatus(procNotFound): return "The media application has quit."
        default: return "Could not check Automation permission (macOS error \(status))."
        }
    }

    private func execute(source: String, language: String, token: Token,
                         adapterURL: URL? = nil, adapterArguments: [String] = []) -> Result<Data, Error> {
        if adapterURL?.pathExtension == "swift", !CoveMediaAdapterWatch.hasSwiftToolchain() {
            return .failure(Failure(message: "The optional Swift media adapter requires installed Xcode or Command Line Tools."))
        }
        let task = Process()
        let output = Pipe(), errors = Pipe()
        let usesSwift = adapterURL?.pathExtension == "swift"
        task.executableURL = URL(fileURLWithPath: usesSwift ? "/usr/bin/swift" : "/usr/bin/osascript")
        task.arguments = adapterURL.map { (usesSwift ? ["-swift-version", "5", $0.path] : ["-l", "JavaScript", $0.path]) + adapterArguments } ?? ["-l", language, "-e", source]
        if let adapterURL { task.currentDirectoryURL = adapterURL.deletingLastPathComponent() }
        task.standardOutput = output
        task.standardError = adapterURL == nil ? errors : FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        lock.lock()
        guard token.epoch == epoch, token.itemEpoch == nil || token.itemEpoch == itemEpoch else {
            lock.unlock(); return .failure(CancellationError())
        }
        do { try task.run() } catch { lock.unlock(); return .failure(error) }
        process = task
        lock.unlock()
        defer {
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
            task.waitUntilExit()
            lock.lock()
            if process === task { process = nil }
            lock.unlock()
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
        }
        // Drain both pipes together. A child must not block on full stderr while
        // its parent waits for stdout EOF. Both byte counts and wall time are bounded.
        let handles = adapterURL == nil ? [output.fileHandleForReading, errors.fileHandleForReading] : [output.fileHandleForReading]
        var descriptors = handles.map { pollfd(fd: $0.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0) }
        for descriptor in descriptors {
            let flags = fcntl(descriptor.fd, F_GETFL)
            guard flags >= 0, fcntl(descriptor.fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                return .failure(Failure(message: "Could not configure the media response pipes."))
            }
        }
        var captured = handles.map { _ in Data() }
        let limits = [25 * 1024 * 1024, 64 * 1024]
        let deadline = ProcessInfo.processInfo.systemUptime + (adapterURL == nil ? 4 : 8)
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while descriptors.contains(where: { $0.fd >= 0 }) {
            guard isCurrent(token) else { return .failure(CancellationError()) }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                return .failure(Failure(message: "The media request timed out."))
            }
            let ready = descriptors.withUnsafeMutableBufferPointer { Darwin.poll($0.baseAddress, nfds_t($0.count), 100) }
            if ready < 0 {
                if errno == EINTR { continue }
                return .failure(Failure(message: "Could not poll the media response pipes."))
            }
            if ready == 0, !task.isRunning { break }
            for index in descriptors.indices where descriptors[index].fd >= 0 && descriptors[index].revents != 0 {
                let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptors[index].fd, $0.baseAddress!, $0.count) }
                if count == 0 { descriptors[index].fd = -1; continue }
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return .failure(Failure(message: "Could not read the media response."))
                }
                guard count <= limits[index] - captured[index].count else {
                    return .failure(Failure(message: index == 0 ? "The player exceeded the media output limit." : "The player exceeded the media error output limit."))
                }
                captured[index].append(contentsOf: bytes.prefix(count))
            }
        }
        // EOF alone is not an exit acknowledgement. The child can close its pipes
        // before exiting; continue to enforce cancellation and the same deadline.
        while task.isRunning {
            guard isCurrent(token) else { return .failure(CancellationError()) }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                return .failure(Failure(message: "The media request timed out."))
            }
            _ = Darwin.poll(nil, 0, 20)
        }
        task.waitUntilExit()
        let data = captured[0]
        guard task.terminationStatus == 0 else {
            if adapterURL != nil, let payload = CoveMediaAdapterWatch.payload(from: data), let message = payload["error"] as? String {
                return .failure(Failure(message: message))
            }
            let details = adapterURL == nil ? String(data: captured[1], encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                : "The optional Swift adapter requires a working Xcode or Command Line Tools installation."
            return .failure(Failure(message: task.terminationReason == .uncaughtSignal ?
                "The media AppleScript request timed out or was cancelled." :
                "The player rejected the AppleScript request: \(String(details.prefix(500)))"))
        }
        return .success(data)
    }
}
