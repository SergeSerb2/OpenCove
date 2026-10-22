import AppKit
import Combine
import CoreGraphics
import Darwin
import ServiceManagement

@MainActor
final class CoveStore: ObservableObject {
    @Published var preferences: CovePreferences
    @Published private(set) var selectedTab: CoveTab = .media
    @Published var isExpanded = false
    @Published private(set) var compactMediaVisible = false
    @Published private(set) var mediaPeekVisible = false
    @Published var hud: CoveHUD?
    @Published var settingsVisible = false
    @Published var lastError: String?
    @Published var loginItemStatus = "Disabled"
    @Published var physicalNotchWidth = 0.0
    @Published var physicalNotchHeight = 0.0
    @Published private(set) var displaySelection = CoveDisplaySelection()
    let media = MediaController()
    let system = SystemController()
    let activities = ActivityController()
    let weather = WeatherController()
    let waveform = AudioWaveformController()
    let travel = TravelController()
    let notificationMirror = NotificationMirror()
    lazy var hardwareKeys = HardwareKeyController(system: system)
    var onOpenSettings: (() -> Void)?
    var onPreferencesChange: (() -> Void)?

    var enabledTabs: [CoveTab] {
        CoveTab.allCases.filter { tab in
            switch tab {
            case .media: return preferences.enableMedia
            case .calendar: return preferences.enableCalendar
            case .files: return preferences.enableFileTray
            case .timer: return preferences.enableTimer
            }
        }
    }

    private var defaultTab: CoveTab { preferences.expandedLayout == "calendar" ? .calendar : .media }

    var visibleTab: CoveTab? {
        let enabled = enabledTabs
        if enabled.contains(selectedTab) { return selectedTab }
        return enabled.contains(defaultTab) ? defaultTab : enabled.first
    }

    /// A preference changes priority, never enables a feature or invents an
    /// activity. Preserve the existing automatic order when it is unavailable.
    var compactActivity: CoveCompactActivity {
        let media = preferences.enableMedia && compactMediaVisible && self.media.state.available
        let timer = preferences.enableTimer && activities.timer.remaining > 0
        let calendar = preferences.enableCalendar && activities.eventActivity != nil
        switch preferences.compactActivity {
        case "media" where media: return .media
        case "calendar" where calendar: return .calendar
        case "timer" where timer: return .timer
        default: break
        }
        if media { return .media }
        if timer { return .timer }
        if calendar { return .calendar }
        return .clock
    }

    func openCompactActivity() {
        // A transient HUD must not replace the prior expanded section.
        if showsMediaPeek { selectTab(.media) }
        else if hud == nil {
            switch compactActivity {
            case .media: selectTab(.media)
            case .calendar: selectTab(.calendar)
            case .timer: selectTab(.timer)
            case .clock: break
            }
        }
        expand()
    }

    @discardableResult func selectTab(_ tab: CoveTab, expand: Bool = false) -> Bool {
        guard enabledTabs.contains(tab) else { return false }
        if selectedTab != tab { selectedTab = tab }
        if expand { self.expand() }
        return true
    }

    /// Defaults belong to app state, not view mounting. A preview or another
    /// display must not undo a user's explicit section selection.
    private func reconcileActivitySelection(resetToDefault: Bool) {
        let enabled = enabledTabs
        let requested = resetToDefault ? defaultTab : selectedTab
        let next = enabled.contains(requested) ? requested
            : enabled.contains(defaultTab) ? defaultTab : enabled.first ?? defaultTab
        if selectedTab != next { selectedTab = next }
    }

    func updateDisplaySelection(_ value: CoveDisplaySelection) {
        if displaySelection != value { displaySelection = value }
    }
    @discardableResult func chooseDisplay(_ choice: String) -> Result<Void, CoveDisplayError> {
        var value = preferences
        switch choice {
        case "all": value.showOnAllDisplays = true
        case "builtIn", "main":
            value.showOnAllDisplays = false
            value.selectedDisplayUUID = ""
            value.preferBuiltInDisplay = choice == "builtIn"
        default:
            guard let uuid = UUID(uuidString: choice)?.uuidString else {
                let error = CoveDisplayError.invalidChoice
                lastError = error.localizedDescription
                return .failure(error)
            }
            let current = CoveDisplays.resolve(preferences).state
            updateDisplaySelection(current)
            guard current.available.contains(where: { $0.canSelect && $0.uuid == uuid }) else {
                let error = CoveDisplayError.unavailable
                lastError = error.localizedDescription
                return .failure(error)
            }
            value.showOnAllDisplays = false
            value.selectedDisplayUUID = uuid
        }
        preferences = value
        return savePreferences() ? .success(()) : .failure(.saveFailed(lastError ?? "Display settings could not be saved."))
    }
    private var hudDismiss: Task<Void, Never>?
    private var appliedPreferences: CovePreferences
    private var subscriptions = Set<AnyCancellable>()
    private var started = false
    private var sessionActive = false
    private var needsPreferencesBackup = false
    private let mediaIdleClock = ContinuousClock()
    private var mediaIdleInput: CompactMediaInput?
    private var mediaPausedAt: ContinuousClock.Instant?
    private var mediaIdleDeadline: ContinuousClock.Instant?
    private var mediaIdleTask: Task<Void, Never>?
    private var mediaIdleRevision: UInt64 = 0
    private var mediaPeekInput: CompactMediaInput?
    private var mediaPeekTask: Task<Void, Never>?
    private var mediaPeekRevision: UInt64 = 0
    private var mediaPeekDeadline: ContinuousClock.Instant?

    var showsMediaPeek: Bool {
        mediaPeekVisible && mayPresentMediaPeek && media.state.available && media.state.isPlaying
    }

    var mediaPeekRemaining: Double? {
        guard showsMediaPeek, let mediaPeekDeadline else { return nil }
        let remaining = mediaIdleClock.now.duration(to: mediaPeekDeadline).components
        return max(0, Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18)
    }

    private var mayPresentMediaPeek: Bool {
        started && sessionActive && !system.state.isLocked && preferences.enableMedia
            && preferences.peekOnSongChange && !isExpanded && hud == nil
    }

    /// Elapsed position, artwork and rate changes must not restart the grace.
    private struct CompactMediaInput: Equatable {
        var available: Bool
        var playing: Bool
        var source: String
        var item: String?
        var title: String
        var artist: String
        var album: String

        init(_ state: MediaState) {
            available = state.available; playing = state.isPlaying
            source = state.sourceBundleIdentifier; item = state.contentItemIdentifier
            title = state.title; artist = state.artist; album = state.album
        }
    }

    private var mayMirror: Bool {
        started && sessionActive && preferences.mirrorSystemNotifications && preferences.enableNotifications
            && preferences.enablePrivateAPIs && system.state.lockStateKnown && !system.state.isLocked
    }

    var hidesCompactWhenIdle: Bool {
        preferences.hideWhenIdle && !isExpanded && hud == nil
            && !(preferences.enableMedia && compactMediaVisible && media.state.available)
            && !(preferences.enableTimer && activities.timer.remaining > 0)
            && !(preferences.enableCalendar && activities.eventActivity != nil)
    }

    var mirroringStatus: String {
        guard preferences.mirrorSystemNotifications && preferences.enableNotifications else { return "Notification mirroring is off." }
        guard preferences.enablePrivateAPIs else { return "Mirroring needs the session lock integration to protect notification text." }
        guard system.state.lockStateKnown else { return "Waiting for a confirmed unlocked session. Lock and unlock your Mac to enable mirroring." }
        guard sessionActive && !system.state.isLocked else { return "Notification mirroring is paused while locked." }
        return notificationMirror.status
    }

    init() {
        CovePaths.prepare()
        let path = CovePaths.dataDirectory.appendingPathComponent("preferences.json")
        let loaded: CovePreferences
        var loadError: String?
        var needsBackup = false
        do {
            let recovered = try Self.readPreferences(at: path)
            loaded = recovered.preferences
            if !recovered.repairedFields.isEmpty {
                needsBackup = true
                loadError = "Some saved settings were invalid and were repaired for this session: \(recovered.repairedFields.joined(separator: ", ")). The original file will be backed up before saving."
            }
        }
        catch {
            loaded = .recoveryDefaults
            needsBackup = true
            loadError = "Saved settings could not be read. Calendar, media, and private integrations are off. The original file will be backed up before saving new settings."
        }
        preferences = loaded
        appliedPreferences = loaded
        lastError = loadError
        needsPreferencesBackup = needsBackup
        reconcileActivitySelection(resetToDefault: true)
        media.onHUD = { [weak self] in self?.showHUD($0) }
        media.$state.map { CompactMediaInput($0) }.removeDuplicates()
            .receive(on: RunLoop.main).sink { [weak self] observed in
                guard let self else { return }
                // Keep an observed resume/item change even if a second source
                // update arrives before this deferred main-run-loop delivery.
                self.reconcileCompactMedia(resetGrace: observed != self.mediaIdleInput)
                self.observeMediaPeek(observed)
            }.store(in: &subscriptions)
        system.onHUD = { [weak self] in self?.showHUD($0) }
        activities.onHUD = { [weak self] value in
            guard let self, value.origin != "calendar" || self.preferences.enableCalendar else { return }
            self.showHUD(value)
        }
        travel.onHUD = { [weak self] value in
            guard let self, self.preferences.enableCalendar else { return }
            self.showHUD(value)
        }
        activities.onRoutingEvents = { [weak self] events in
            guard let self else { return }
            self.travel.updateEvents(self.preferences.enableCalendar ? events : [])
        }
        notificationMirror.onNotification = { [weak self] title, body in
            guard let self, self.mayMirror else { return }
            self.activities.notifications.insert(CoveNotification(title: title, body: body, source: "System"), at: 0)
            self.activities.notifications = Array(self.activities.notifications.prefix(30))
            self.showHUD(CoveHUD(kind: .notification, title: title, subtitle: body, symbol: "bell.fill", origin: "systemMirror"))
        }
        notificationMirror.canCollect = { [weak self] in
            guard let self else { return false }
            self.refreshSessionActivity()
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            let allowed = self.mayMirror && (session?["CGSSessionScreenIsLocked"] as? Bool != true)
            if !allowed { self.clearMirroredContent() }
            return allowed
        }
        notificationMirror.onCollectionStopped = { [weak self] in self?.clearMirroredContent() }
        system.onLockChange = { [weak self] locked in
            guard let self else { return }
            if locked { self.collapse() }
            self.refreshSessionActivity()
            self.resetMediaPeek()
            self.reconcileCalendarPrivacy()
            self.reconcileMirroring()
            self.objectWillChange.send()
            self.onPreferencesChange?()
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.sessionDidResignActiveNotification).sink { [weak self] _ in
            self?.sessionActive = false
            self?.collapse()
            self?.resetMediaPeek()
            self?.reconcileCalendarPrivacy()
            self?.reconcileMirroring()
        }.store(in: &subscriptions)
        workspace.publisher(for: NSWorkspace.sessionDidBecomeActiveNotification).sink { [weak self] _ in
            self?.refreshSessionActivity()
            self?.resetMediaPeek()
            self?.system.refresh()
            self?.reconcileCalendarPrivacy()
            self?.reconcileMirroring()
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).sink { [weak self] _ in
            self?.reconcileLoginItem()
        }.store(in: &subscriptions)
        reconcileLoginItem()
        refreshSessionActivity()
    }

    func start() {
        guard !started else { return }
        started = true
        resetMediaPeek()
        refreshSessionActivity()
        media.preferredSource = preferences.preferredMusicApp
        activities.preferredCalendarApp = preferences.preferredCalendarApp
        activities.setCalendarEnabled(preferences.enableCalendar)
        if preferences.enableMedia { media.start(privateAPIs: preferences.enablePrivateAPIs, appleScript: preferences.allowAppleScript) }
        system.start(privateAPIs: preferences.enablePrivateAPIs)
        reconcileCalendarPrivacy()
        activities.start()
        if preferences.enableCalendar { travel.start() }
        travel.updateEvents(preferences.enableCalendar ? activities.routingEvents : [])
        if preferences.enableWeather { weather.start() }
        if preferences.showLiveWaveform { waveform.start() }
        hardwareKeys.volumeEnabled = preferences.enableVolumeHUD
        hardwareKeys.brightnessEnabled = preferences.enableBrightnessHUD
        hardwareKeys.start(enabled: preferences.replaceSystemHUDs && preferences.enablePrivateAPIs)
        reconcileMirroring()
        appliedPreferences = preferences
        reconcileCompactMedia()
    }

    func stop() {
        started = false
        dismissMediaPeek()
        mediaPeekInput = nil
        cancelMediaIdleDeadline()
        mediaIdleInput = nil
        mediaPausedAt = nil
        setCompactMediaVisible(false)
        hudDismiss?.cancel()
        media.stop(); system.stop(); activities.stop(); weather.stop()
        waveform.stop(); travel.stop(); hardwareKeys.stop()
        reconcileMirroring()
        hud = nil
    }

    private func setCompactMediaVisible(_ visible: Bool) {
        if compactMediaVisible != visible { compactMediaVisible = visible }
    }

    private func cancelMediaIdleDeadline() {
        mediaIdleRevision &+= 1
        mediaIdleTask?.cancel()
        mediaIdleTask = nil
        mediaIdleDeadline = nil
    }

    private func reconcileCompactMedia(resetGrace: Bool = false) {
        let input = CompactMediaInput(media.state)
        guard started, preferences.enableMedia, input.available else {
            cancelMediaIdleDeadline()
            mediaIdleInput = nil
            mediaPausedAt = nil
            setCompactMediaVisible(false)
            return
        }
        if resetGrace || input != mediaIdleInput {
            mediaIdleInput = input
            mediaPausedAt = input.playing ? nil : mediaIdleClock.now
        }
        guard !input.playing, preferences.hidePausedMedia else {
            cancelMediaIdleDeadline()
            setCompactMediaVisible(true)
            return
        }
        let pausedAt = mediaPausedAt ?? mediaIdleClock.now
        mediaPausedAt = pausedAt
        let deadline = pausedAt.advanced(by: .seconds(preferences.pausedMediaDelay))
        if mediaIdleClock.now >= deadline {
            cancelMediaIdleDeadline()
            setCompactMediaVisible(false)
            return
        }
        setCompactMediaVisible(true)
        guard mediaIdleTask == nil || mediaIdleDeadline != deadline else { return }
        cancelMediaIdleDeadline()
        mediaIdleDeadline = deadline
        let revision = mediaIdleRevision, clock = mediaIdleClock
        mediaIdleTask = Task { @MainActor [weak self] in
            do { try await clock.sleep(until: deadline) } catch { return }
            guard !Task.isCancelled, let self, self.started, self.mediaIdleRevision == revision else { return }
            self.mediaIdleTask = nil
            self.mediaIdleDeadline = nil
            // Re-read current state and preferences at the deadline. Never hide
            // a resumed player or a new item based on an old queued pause.
            self.reconcileCompactMedia()
        }
    }

    private func dismissMediaPeek() {
        mediaPeekRevision &+= 1
        mediaPeekTask?.cancel()
        mediaPeekTask = nil
        mediaPeekDeadline = nil
        if mediaPeekVisible { mediaPeekVisible = false }
    }

    private func resetMediaPeek() {
        dismissMediaPeek()
        mediaPeekInput = CompactMediaInput(media.state)
    }

    private func observeMediaPeek(_ observed: CompactMediaInput) {
        // Deferred obsolete samples must not overwrite a preference/session
        // baseline or briefly present metadata from an item already replaced.
        guard observed == CompactMediaInput(media.state) else { return }
        let previous = mediaPeekInput
        mediaPeekInput = observed
        guard mayPresentMediaPeek, observed.available, observed.playing else {
            dismissMediaPeek()
            return
        }
        // Discovery/reconnection is quiet. Metadata/position/rate/artwork
        // corrections for the same opaque item do not extend its deadline.
        guard let previous, previous.available else { return }
        let changed: Bool
        if previous.source != observed.source { changed = true }
        else if let before = previous.item, !before.isEmpty, let after = observed.item, !after.isEmpty {
            changed = before != after
        } else {
            changed = previous.title != observed.title || previous.artist != observed.artist || previous.album != observed.album
        }
        guard changed else { return }
        dismissMediaPeek()
        mediaPeekVisible = true
        let revision = mediaPeekRevision, clock = mediaIdleClock
        let deadline = clock.now.advanced(by: .seconds(preferences.mediaPeekDuration))
        mediaPeekDeadline = deadline
        mediaPeekTask = Task { @MainActor [weak self] in
            do { try await clock.sleep(until: deadline) } catch { return }
            guard !Task.isCancelled, let self, self.mediaPeekRevision == revision else { return }
            self.mediaPeekTask = nil
            self.mediaPeekDeadline = nil
            if self.mediaPeekVisible { self.mediaPeekVisible = false }
        }
    }

    func expand() { dismissMediaPeek(); isExpanded = true }
    func collapse() { dismissMediaPeek(); isExpanded = false }
    func toggleExpanded() { isExpanded ? collapse() : expand() }
    func openSettings() { settingsVisible = true; onOpenSettings?() }

    private func reconcileMirroring() {
        notificationMirror.start(enabled: mayMirror)
        guard !mayMirror else { return }
        clearMirroredContent()
    }

    private func clearMirroredContent() {
        activities.notifications.removeAll { $0.source == "System" }
        if hud?.origin == "systemMirror" { hudDismiss?.cancel(); hud = nil }
    }

    private func reconcileCalendarPrivacy() {
        let restrictedSession = !sessionActive || system.state.isLocked
        let hideDetails = !sessionActive || !preferences.showLockScreenPrivateContent
        activities.setCalendarPrivacy(isLocked: restrictedSession, hideSensitiveDetails: hideDetails)
        travel.setCalendarPrivacy(isLocked: restrictedSession, hideSensitiveDetails: hideDetails)
        if hud?.origin == "calendar" && (activities.calendarDetailsHidden || !preferences.enableCalendar) {
            hudDismiss?.cancel()
            hud = nil
        }
    }

    private func refreshSessionActivity() {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool,
              let loginDone = session[kCGSessionLoginDoneKey as String] as? Bool else {
            sessionActive = false
            return
        }
        sessionActive = onConsole && loginDone
    }

    private static func readPreferences(at url: URL) throws -> (preferences: CovePreferences, repairedFields: [String]) {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return (CovePreferences(), []) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= 65_536, let data = try file.read(upToCount: 65_537), data.count <= 65_536 else {
            throw CocoaError(.coderReadCorrupt)
        }
        return try CovePreferences.recover(data)
    }

    private func backupDamagedPreferences() throws -> URL? {
        let source = CovePaths.dataDirectory.appendingPathComponent("preferences.json")
        let descriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { needsPreferencesBackup = false; return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= 8_388_608 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let data = try file.read(upToCount: 8_388_609) ?? Data()
        guard data.count <= 8_388_608, data.count == info.st_size else { throw CocoaError(.fileReadCorruptFile) }
        let backup = CovePaths.dataDirectory.appendingPathComponent("preferences.recovery.\(UUID().uuidString).json")
        let output = Darwin.open(backup.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let copy = FileHandle(fileDescriptor: output, closeOnDealloc: true)
        do { try copy.write(contentsOf: data); try copy.synchronize(); try copy.close() }
        catch { try? copy.close(); try? FileManager.default.removeItem(at: backup); throw error }
        needsPreferencesBackup = false
        return backup
    }

    func showHUD(_ value: CoveHUD) {
        guard isHUDEnabled(value) else { return }
        dismissMediaPeek()
        hudDismiss?.cancel()
        hud = value
        if preferences.enableHaptics { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default) }
        hudDismiss = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.5, self?.preferences.hudDuration ?? 2)))
            guard !Task.isCancelled else { return }
            self?.hud = nil
        }
    }

    private func isHUDEnabled(_ value: CoveHUD) -> Bool {
        if value.origin == "calendar" && !preferences.enableCalendar { return false }
        switch value.kind {
        case .volume: return preferences.enableVolumeHUD
        case .brightness: return preferences.enableBrightnessHUD
        case .battery: return preferences.enableBattery
        case .bluetooth: return preferences.enableBluetooth
        case .focus: return preferences.enableFocus
        case .notification: return preferences.enableNotifications
        case .lock: return preferences.showOnLockScreen
        }
    }

    @discardableResult func completeOnboarding() -> Bool {
        preferences.completedOnboarding = true
        return savePreferences()
    }

    /// Runtime opt-outs take effect even if persistence fails. Only the setup
    /// completion marker remains at its prior value when any save step fails.
    @discardableResult func savePreferences() -> Bool {
        preferences.normalize()
        let previous = appliedPreferences
        lastError = nil
        if started {
            if preferences.enablePrivateAPIs != previous.enablePrivateAPIs {
                system.stop(); system.start(privateAPIs: preferences.enablePrivateAPIs)
            }
            if preferences.enablePrivateAPIs != previous.enablePrivateAPIs || preferences.allowAppleScript != previous.allowAppleScript || preferences.enableMedia != previous.enableMedia {
                media.stop()
                if preferences.enableMedia { media.start(privateAPIs: preferences.enablePrivateAPIs, appleScript: preferences.allowAppleScript) }
            }
            media.preferredSource = preferences.preferredMusicApp
            activities.preferredCalendarApp = preferences.preferredCalendarApp
            activities.setCalendarEnabled(preferences.enableCalendar)
            refreshSessionActivity()
            reconcileCalendarPrivacy()
            if preferences.enableCalendar { travel.start(); travel.updateEvents(activities.routingEvents) }
            else { travel.stop(); travel.updateEvents([]) }
            if preferences.enableWeather { weather.start() } else { weather.stop() }
            if preferences.showLiveWaveform { waveform.start() } else { waveform.stop() }
            hardwareKeys.volumeEnabled = preferences.enableVolumeHUD
            hardwareKeys.brightnessEnabled = preferences.enableBrightnessHUD
            hardwareKeys.start(enabled: preferences.replaceSystemHUDs && preferences.enablePrivateAPIs)
            reconcileMirroring()
            if let hud, !isHUDEnabled(hud) { hudDismiss?.cancel(); self.hud = nil }
        }
        appliedPreferences = preferences
        reconcileActivitySelection(resetToDefault: preferences.expandedLayout != previous.expandedLayout)
        reconcileCompactMedia()
        if preferences.peekOnSongChange != previous.peekOnSongChange
            || preferences.enableMedia != previous.enableMedia
            || preferences.enablePrivateAPIs != previous.enablePrivateAPIs
            || preferences.allowAppleScript != previous.allowAppleScript
            || preferences.preferredMusicApp != previous.preferredMusicApp {
            resetMediaPeek()
        } else if !mayPresentMediaPeek { dismissMediaPeek() }
        onPreferencesChange?()
        var success = true
        do {
            if CovePaths.isDevelopment {
                if preferences.launchAtLogin { success = false; lastError = "Launch at login is available in the release app." }
                preferences.launchAtLogin = false
                loginItemStatus = "Unavailable in development builds"
            } else {
                let enabled = SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
                if preferences.launchAtLogin != enabled {
                    if preferences.launchAtLogin { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                }
                reconcileLoginItem()
            }
        } catch {
            success = false
            lastError = "Launch at login could not be changed: \(error.localizedDescription)"
            reconcileLoginItem()
        }
        // Login registration can fail while JSON persistence still succeeds.
        // Never persist a completed setup after that overall failure; keep all
        // other effective choices, including privacy opt-outs, in the snapshot.
        if !success { preferences.completedOnboarding = previous.completedOnboarding }
        do {
            if needsPreferencesBackup {
                if let backup = try backupDamagedPreferences() {
                    let notice = "The original settings were preserved in \(backup.lastPathComponent)."
                    lastError = [lastError, notice].compactMap { $0 }.joined(separator: " ")
                }
            }
            try JSONEncoder().encode(preferences).write(to: CovePaths.dataDirectory.appendingPathComponent("preferences.json"), options: .atomic)
        } catch {
            success = false
            preferences.completedOnboarding = previous.completedOnboarding
            lastError = "Settings apply for this session, but could not be saved: \(error.localizedDescription)"
        }
        appliedPreferences.completedOnboarding = preferences.completedOnboarding
        return success
    }

    func reconcileLoginItem() {
        guard !CovePaths.isDevelopment else { preferences.launchAtLogin = false; loginItemStatus = "Unavailable in development builds"; return }
        switch SMAppService.mainApp.status {
        case .enabled: preferences.launchAtLogin = true; loginItemStatus = "Enabled"
        case .requiresApproval: preferences.launchAtLogin = true; loginItemStatus = "Needs approval in System Settings"
        case .notRegistered: preferences.launchAtLogin = false; loginItemStatus = "Disabled"
        case .notFound: preferences.launchAtLogin = false; loginItemStatus = "App registration is unavailable"
        @unknown default: preferences.launchAtLogin = false; loginItemStatus = "Unknown"
        }
    }

    @discardableResult func resetPreferences() -> Bool {
        let onboarded = preferences.completedOnboarding
        preferences = CovePreferences()
        preferences.completedOnboarding = onboarded
        return savePreferences()
    }
}
