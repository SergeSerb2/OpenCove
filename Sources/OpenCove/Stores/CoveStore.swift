import AppKit
import Combine
import CoreGraphics
import Darwin
import ServiceManagement

@MainActor
final class CoveStore: ObservableObject {
    @Published private(set) var preferences: CovePreferences
    @Published private(set) var selectedTab: CoveTab = .media
    @Published var isExpanded = false {
        didSet { if isExpanded { clearBetterDisplayHUD() } }
    }
    @Published private(set) var compactMediaVisible = false
    @Published private(set) var mediaPeekVisible = false
    @Published var hud: CoveHUD?
    @Published var settingsVisible = false
    @Published var lastError: String?
    @Published var loginItemStatus = "Disabled"
    @Published var physicalNotchWidth = 0.0
    @Published var physicalNotchHeight = 0.0
    @Published private(set) var displaySelection = CoveDisplaySelection()
    @Published private var compactDismissals: [CompactDismissal] = []
    private var restoredCompactActivity: CompactCandidate?
    private var compactTarget: (candidate: CompactCandidate, token: String)?

    private struct CompactCandidate: Equatable {
        enum Identity: Equatable {
            case media(source: String, item: String)
            case metadata(source: String, title: String, artist: String, album: String)
            case timer(UUID)
            case calendar(id: String, start: Date)
        }
        let activity: CoveCompactActivity
        let identity: Identity
    }
    private struct CompactDismissal: Equatable {
        let candidate: CompactCandidate
        let token = UUID().uuidString
    }
    let media = MediaController()
    let system = SystemController()
    let activities = ActivityController()
    let weather = WeatherController()
    let waveform = AudioWaveformController()
    let travel = TravelController()
    let notificationMirror = NotificationMirror()
    let settingsSync = CoveSettingsSyncController()
    private let betterDisplayFeedback = BetterDisplayFeedbackController()
    private var betterDisplaySnapshotCurrent = false
    private var systemAwake = true
    private var screensAwake = true
    private var shuttingDown = false
    private var persistedBetterDisplayFeedback = false
    private var persistedLowPowerModeAlerts = false
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

    /// Share this decision with both SwiftUI content and native window sizing.
    /// Explicit layouts remain stable. Automatic Duo uses existing activity
    /// publications; it never starts a reader or requests calendar permission.
    var showsExpandedDuo: Bool {
        guard visibleTab == .media, preferences.enableMedia, preferences.enableCalendar else { return false }
        if preferences.expandedLayout == "duo" { return true }
        return preferences.expandedLayout == "automatic" && !system.state.isLocked
            && media.state.available && media.state.isPlaying && activities.hasVisibleCalendarActivity
    }

    private static let compactPriority: [CoveCompactActivity] = [.media, .timer, .calendar]

    private func compactActivityAvailable(_ activity: CoveCompactActivity) -> Bool {
        switch activity {
        case .media: return preferences.enableMedia && compactMediaVisible && media.state.available
        case .timer: return preferences.enableTimer && activities.timer.remaining > 0
        case .calendar: return preferences.enableCalendar && activities.eventActivity != nil
        case .clock: return false
        }
    }

    private func compactCandidate(for activity: CoveCompactActivity) -> CompactCandidate? {
        guard compactActivityAvailable(activity) else { return nil }
        switch activity {
        case .media:
            let identity: CompactCandidate.Identity
            if let item = media.state.contentItemIdentifier, !item.isEmpty, !media.state.sourceBundleIdentifier.isEmpty {
                identity = .media(source: media.state.sourceBundleIdentifier, item: item)
            } else {
                let source = media.state.sourceBundleIdentifier.isEmpty ? media.state.source : media.state.sourceBundleIdentifier
                identity = .metadata(source: source, title: media.state.title,
                                     artist: media.state.artist, album: media.state.album)
            }
            return CompactCandidate(activity: .media, identity: identity)
        case .timer:
            return CompactCandidate(activity: .timer, identity: .timer(activities.timerActivityIdentifier))
        case .calendar:
            guard let event = activities.eventActivity?.event else { return nil }
            return CompactCandidate(activity: .calendar, identity: .calendar(id: event.id, start: event.start))
        case .clock: return nil
        }
    }

    var availableCompactActivities: [CoveCompactActivity] {
        Self.compactPriority.filter(isCompactActivityVisible)
    }
    var dismissedCompactActivities: [CoveCompactActivity] {
        compactDismissals.filter { compactCandidate(for: $0.candidate.activity) == $0.candidate }.map { $0.candidate.activity }
    }
    func isCompactActivityVisible(_ activity: CoveCompactActivity) -> Bool {
        guard compactActivityAvailable(activity) else { return false }
        // The common rendering path needs no identity or temporary candidate
        // array until this category actually has a dismissal to compare.
        guard let dismissal = compactDismissals.first(where: { $0.candidate.activity == activity }) else { return true }
        return compactCandidate(for: activity) != dismissal.candidate
    }

    /// A restored activity is brought forward without changing the saved
    /// preference. Dismissals are bounded to one live instance per category.
    var compactActivity: CoveCompactActivity {
        if let restoredCompactActivity, compactCandidate(for: restoredCompactActivity.activity) == restoredCompactActivity,
           isCompactActivityVisible(restoredCompactActivity.activity) { return restoredCompactActivity.activity }
        if let preferred = CoveCompactActivity(rawValue: preferences.compactActivity), isCompactActivityVisible(preferred) { return preferred }
        return Self.compactPriority.first(where: isCompactActivityVisible) ?? .clock
    }

    private var mayEditCompactPresentation: Bool {
        started && sessionActive && !system.state.isLocked && hud == nil
    }
    private var compactDismissCandidate: CompactCandidate? {
        guard mayEditCompactPresentation, !isExpanded else { return nil }
        return compactCandidate(for: showsMediaPeek ? .media : compactActivity)
    }
    var compactDismissActivity: CoveCompactActivity? { compactDismissCandidate?.activity }
    var compactDismissTarget: String? {
        guard let candidate = compactDismissCandidate else { compactTarget = nil; return nil }
        if compactTarget?.candidate != candidate { compactTarget = (candidate, UUID().uuidString) }
        return compactTarget?.token
    }
    private var compactRestoration: CompactDismissal? {
        guard mayEditCompactPresentation else { return nil }
        return compactDismissals.last { compactCandidate(for: $0.candidate.activity) == $0.candidate }
    }
    var compactRestoreActivity: CoveCompactActivity? { compactRestoration?.candidate.activity }
    var compactRestoreTarget: String? { compactRestoration?.token }

    @discardableResult func dismissCompactActivity(target: String) -> Bool {
        guard target == compactDismissTarget, let candidate = compactDismissCandidate else { return false }
        compactTarget = nil
        restoredCompactActivity = nil
        // A peek is its own visible media presentation, not the activity below it.
        if candidate.activity == .media { dismissMediaPeek() }
        var next = compactDismissals.filter { $0.candidate.activity != candidate.activity }
        next.append(CompactDismissal(candidate: candidate))
        compactDismissals = next
        return true
    }

    @discardableResult func restoreCompactActivity(target: String) -> Bool {
        guard let restoration = compactRestoration, restoration.token == target else { return false }
        restoredCompactActivity = restoration.candidate
        compactTarget = nil
        compactDismissals.removeAll { $0.token == target }
        collapse()
        return true
    }

    private func resetCompactDismissals(for activities: Set<CoveCompactActivity>? = nil) {
        compactTarget = nil
        if let restored = restoredCompactActivity, activities.map({ $0.contains(restored.activity) }) ?? true {
            restoredCompactActivity = nil
        }
        let next = compactDismissals.filter { dismissal in
            activities.map { !$0.contains(dismissal.candidate.activity) } ?? false
        }
        if next != compactDismissals { compactDismissals = next }
    }

    func openCompactActivity() {
        // A transient HUD must not replace the prior expanded section.
        if showsMediaPeek { selectTab(.media) }
        else if hud == nil {
            switch compactActivity {
            case .media: selectTab(.media)
            case .calendar: selectTab(.calendar)
            case .timer: selectTab(.timer)
            case .clock: reconcileActivitySelection(resetToDefault: true)
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
        betterDisplaySnapshotCurrent = true
        reconcileBetterDisplayFeedback()
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
        return commitPreferences(value) ? .success(()) : .failure(.saveFailed(lastError ?? "Display settings could not be saved."))
    }
    private var hudDismiss: Task<Void, Never>?
    private var hudDeadline: ContinuousClock.Instant?
    private var appliedPreferences: CovePreferences
    private(set) var persistedLockWidgets: Set<CoveLockWidget> = []
    private var activeReaderPolicy: ReaderPolicy?
    private var restartingSystemReaders = false

    private struct ReaderPolicy: Equatable {
        var media: Bool
        var calendar: Bool
        var weather: Bool
        var bluetooth: Bool
        var focus: Bool
        var privateAPIs: Bool
        var appleScript: Bool

        init(_ preferences: CovePreferences, activeSession: Bool) {
            func extra(_ widget: CoveLockWidget) -> Bool {
                activeSession && preferences.permitsExtraLockWidgetReader(widget)
            }
            media = preferences.enableMedia || extra(.media)
            calendar = preferences.enableCalendar || extra(.calendar)
            weather = preferences.enableWeather || extra(.weather)
            bluetooth = preferences.enableBluetooth || extra(.bluetooth)
            focus = preferences.enableFocus || extra(.focus)
            privateAPIs = preferences.enablePrivateAPIs
            // An independent media reader cannot start Automation fallback.
            appleScript = preferences.enableMedia && preferences.allowAppleScript
        }
    }

    func requestsExtraLockWidgetReader(_ widget: CoveLockWidget) -> Bool {
        started && sessionActive && preferences.permitsExtraLockWidgetReader(widget)
    }

    private func reconcileReaders() {
        guard started else { return }
        let next = ReaderPolicy(preferences, activeSession: sessionActive)
        let previous = activeReaderPolicy
        activeReaderPolicy = next
        let restartMedia = previous == nil || previous?.media != next.media
            || previous?.privateAPIs != next.privateAPIs || previous?.appleScript != next.appleScript
        if restartMedia { media.stop() }
        // Establish the selected source before any startup metadata request.
        media.preferredSource = preferences.preferredMusicApp
        if restartMedia && next.media {
            media.start(privateAPIs: next.privateAPIs, appleScript: next.appleScript)
        }
        activities.preferredCalendarApp = preferences.preferredCalendarApp
        activities.setCalendarConfiguration(enabled: preferences.enableCalendar, readerEnabled: next.calendar,
                                            showDeclinedEvents: preferences.showDeclinedCalendarEvents,
                                            excludeSubscribedCalendars: preferences.excludeSubscribedCalendars)
        if previous == nil || previous?.weather != next.weather {
            if next.weather { weather.start() } else { weather.stop() }
        }
        // A system baseline can synchronously report a lock/session change.
        // Apply other readers first so a reentrant reconciliation can revoke
        // their demand without an outer call subsequently starting them again.
        if previous == nil || previous?.privateAPIs != next.privateAPIs
            || previous?.bluetooth != next.bluetooth || previous?.focus != next.focus {
            let restarting = previous == nil || previous?.privateAPIs != next.privateAPIs
            let wasRestarting = restartingSystemReaders
            if restarting {
                restartingSystemReaders = true
                reconcileLowPowerModeAlerts()
            }
            system.start(privateAPIs: next.privateAPIs, enableBluetooth: next.bluetooth, enableFocus: next.focus)
            restartingSystemReaders = wasRestarting
        }
        // Startup can reenter onLockChange. Recompute from current Store state,
        // never from the ReaderPolicy captured before system.start.
        reconcileLowPowerModeAlerts()
    }
    private var subscriptions = Set<AnyCancellable>()
    private var started = false
    private var sessionActive = false
    // Seed once from the existing startup result. Ordinary session refreshes
    // and onLockChange cannot reopen a processed session resignation.
    private var lowPowerModeSessionAdmitted = false
    private var lowPowerModeSessionRevision: UInt64 = 0
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

    var hudRemaining: Double? {
        guard hud != nil, let hudDeadline else { return nil }
        let value = mediaIdleClock.now.duration(to: hudDeadline).components
        return max(0, Double(value.seconds) + Double(value.attoseconds) / 1e18)
    }

    private var mayPresentMediaPeek: Bool {
        started && sessionActive && !system.state.isLocked && preferences.enableMedia
            && preferences.peekOnSongChange && !isExpanded && hud == nil && isCompactActivityVisible(.media)
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
            && !showsMediaPeek && compactActivity == .clock
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
        persistedLockWidgets = loaded.independentLockWidgets
        persistedBetterDisplayFeedback = loaded.enableBetterDisplayFeedback
        persistedLowPowerModeAlerts = loaded.enableLowPowerModeAlerts
        lastError = loadError
        needsPreferencesBackup = needsBackup
        settingsSync.currentPreferences = { [weak self] in self?.preferences }
        settingsSync.applySettings = { [weak self] settings in
            guard let self else { return false }
            return self.updatePreferences { settings.apply(to: &$0) }
        }
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
        system.onLowPowerModeInvalidation = { [weak self] in self?.clearLowPowerModeHUD() }
        betterDisplayFeedback.canReceive = { [weak self] in self?.mayReceiveBetterDisplayFeedback ?? false }
        betterDisplayFeedback.onInvalidation = { [weak self] in
            self?.clearBetterDisplayHUD()
            self?.objectWillChange.send()
        }
        betterDisplayFeedback.onFeedback = { [weak self] report in
            guard let self else { return }
            self.objectWillChange.send()
            self.showHUD(CoveHUD(kind: .brightness, title: "BetterDisplay brightness",
                                 subtitle: "Reported feedback · not physical readback", symbol: "sun.max.fill",
                                 value: report.fraction, origin: BetterDisplayFeedback.origin))
        }
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
            self.invalidateBetterDisplaySnapshot()
            if locked { self.collapse() }
            self.refreshSessionActivity()
            self.reconcileReaders()
            self.resetMediaPeek()
            self.reconcileCalendarPrivacy()
            self.reconcileMirroring()
            self.reconcileBetterDisplayFeedback()
            self.objectWillChange.send()
            self.onPreferencesChange?()
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.sessionDidResignActiveNotification).sink { [weak self] _ in
            self?.lowPowerModeSessionRevision &+= 1
            self?.lowPowerModeSessionAdmitted = false
            self?.sessionActive = false
            self?.reconcileLowPowerModeAlerts()
            self?.invalidateBetterDisplaySnapshot()
            self?.reconcileReaders()
            self?.collapse()
            self?.resetMediaPeek()
            self?.reconcileCalendarPrivacy()
            self?.reconcileMirroring()
            self?.reconcileBetterDisplayFeedback()
        }.store(in: &subscriptions)
        workspace.publisher(for: NSWorkspace.sessionDidBecomeActiveNotification).sink { [weak self] _ in
            guard let self else { return }
            self.lowPowerModeSessionRevision &+= 1
            let revision = self.lowPowerModeSessionRevision
            self.invalidateBetterDisplaySnapshot()
            self.refreshSessionActivity()
            self.reconcileReaders()
            self.resetMediaPeek()
            self.system.refresh()
            // Only this matching active path reopens admission after resignation,
            // and only after the existing refresh (including reentrant callbacks).
            if self.lowPowerModeSessionRevision == revision {
                self.lowPowerModeSessionAdmitted = self.sessionActive
            }
            self.reconcileLowPowerModeAlerts()
            self.reconcileCalendarPrivacy()
            self.reconcileMirroring()
            self.reconcileBetterDisplayFeedback()
        }.store(in: &subscriptions)
        // Reuse lifecycle notifications and the panel's existing display
        // snapshot. No display getter, running-app discovery or new polling.
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            workspace.publisher(for: name).sink { [weak self] _ in
                guard let self else { return }
                if name == NSWorkspace.willSleepNotification { self.systemAwake = false }
                else { self.screensAwake = false }
                self.reconcileLowPowerModeAlerts()
                self.invalidateBetterDisplaySnapshot()
            }.store(in: &subscriptions)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspace.publisher(for: name).sink { [weak self] _ in
                guard let self else { return }
                if name == NSWorkspace.didWakeNotification { self.systemAwake = true }
                else { self.screensAwake = true }
                self.reconcileLowPowerModeAlerts()
                self.invalidateBetterDisplaySnapshot()
            }.store(in: &subscriptions)
        }
        workspace.publisher(for: NSWorkspace.willPowerOffNotification).sink { [weak self] _ in
            self?.shuttingDown = true
            self?.reconcileLowPowerModeAlerts()
            self?.invalidateBetterDisplaySnapshot()
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification).sink { [weak self] _ in
            self?.invalidateBetterDisplaySnapshot()
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).sink { [weak self] _ in
            self?.reconcileLoginItem()
            self?.settingsSync.checkForChanges()
        }.store(in: &subscriptions)
        reconcileLoginItem()
        refreshSessionActivity()
        lowPowerModeSessionAdmitted = sessionActive
    }

    func start() {
        guard !started else { return }
        started = true
        shuttingDown = false
        resetMediaPeek()
        refreshSessionActivity()
        reconcileReaders()
        reconcileCalendarPrivacy()
        activities.start()
        if preferences.enableCalendar { travel.start() }
        travel.updateEvents(preferences.enableCalendar ? activities.routingEvents : [])
        waveform.setEnabled(preferences.usesLiveWaveform)
        hardwareKeys.volumeEnabled = preferences.enableVolumeHUD
        hardwareKeys.brightnessEnabled = preferences.enableBrightnessHUD
        hardwareKeys.start(enabled: preferences.replaceSystemHUDs && preferences.enablePrivateAPIs)
        reconcileMirroring()
        reconcileBetterDisplayFeedback()
        appliedPreferences = preferences
        reconcileCompactMedia()
        settingsSync.startIfEnabled(preferences)
    }

    func stop() {
        started = false
        reconcileLowPowerModeAlerts()
        invalidateBetterDisplaySnapshot()
        settingsSync.stop()
        resetCompactDismissals()
        dismissMediaPeek()
        mediaPeekInput = nil
        cancelMediaIdleDeadline()
        mediaIdleInput = nil
        mediaPausedAt = nil
        setCompactMediaVisible(false)
        hudDismiss?.cancel()
        activeReaderPolicy = nil
        media.stop(); system.stop(); activities.stop(); weather.stop()
        waveform.setEnabled(false); travel.stop(); hardwareKeys.stop()
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

    private var mayReceiveLowPowerModeAlerts: Bool {
        started && preferences.enableBattery && preferences.enableLowPowerModeAlerts
            && sessionActive && lowPowerModeSessionAdmitted && !system.state.isLocked
            && systemAwake && screensAwake && !shuttingDown && !restartingSystemReaders
    }

    private func reconcileLowPowerModeAlerts() {
        let enabled = preferences.enableBattery && preferences.enableLowPowerModeAlerts
        let admitted = mayReceiveLowPowerModeAlerts
        // Controller invalidates ownership before its invalidation callback
        // clears presentation, so reentrant work cannot use the retired token.
        system.configureLowPowerModeAlerts(enabled: enabled, admitted: admitted)
        if !admitted { clearLowPowerModeHUD() }
    }

    private func clearLowPowerModeHUD() {
        guard hud?.origin == CoveHUD.lowPowerModeOrigin else { return }
        hudDismiss?.cancel()
        hudDismiss = nil
        hudDeadline = nil
        hud = nil
    }

    var lowPowerModeAlertsStatus: String {
        guard preferences.enableBattery else { return "Enable Battery & charging separately before choosing mode alerts." }
        guard preferences.enableLowPowerModeAlerts else { return "Low Power Mode changes are off on this Mac." }
        switch system.state.lowPowerModeStatus {
        case .disabled: return "Low Power Mode monitoring is stopped."
        case .paused: return "Low Power Mode monitoring is paused in this session. Return establishes a quiet baseline."
        case .awaitingBaseline: return "Waiting for a quiet Low Power Mode baseline."
        case .reported:
            guard let reported = system.state.lowPowerModeEnabled else { return "Waiting for a quiet Low Power Mode baseline." }
            if reported { return "The public API reports Low Power Mode on." }
            return "The public API reports false: off, unknown or unsupported hardware."
        case .apiUnavailable: return "The public Low Power Mode API is unavailable."
        }
    }

    private var mayReceiveBetterDisplayFeedback: Bool {
        started && sessionActive && !system.state.isLocked && !shuttingDown
            && systemAwake && screensAwake && betterDisplaySnapshotCurrent
            && preferences.enableBetterDisplayFeedback && preferences.enableBrightnessHUD && preferences.showHUDLabels
            && !preferences.showOnAllDisplays && !preferences.selectedDisplayUUID.isEmpty
            && UUID(uuidString: preferences.selectedDisplayUUID) == UUID(uuidString: displaySelection.requestedUUID)
    }

    private func reconcileBetterDisplayFeedback() {
        betterDisplayFeedback.configure(selection: betterDisplaySnapshotCurrent ? displaySelection : nil,
                                        enabled: mayReceiveBetterDisplayFeedback)
    }

    private func invalidateBetterDisplaySnapshot() {
        betterDisplaySnapshotCurrent = false
        betterDisplayFeedback.stop()
        clearBetterDisplayHUD()
    }

    private func clearBetterDisplayHUD() {
        guard let hud, Self.isBetterDisplayHUD(hud) else { return }
        hudDismiss?.cancel()
        hudDeadline = nil
        self.hud = nil
    }

    private static func isBetterDisplayHUD(_ hud: CoveHUD) -> Bool {
        hud.origin == BetterDisplayFeedback.origin || hud.origin == BetterDisplayFeedback.previewOrigin
    }

    var betterDisplayFeedbackStatus: String {
        guard preferences.enableBetterDisplayFeedback else { return "BetterDisplay feedback is off on this Mac." }
        guard preferences.enableBrightnessHUD else { return "Enable the display brightness overlay separately." }
        guard preferences.showHUDLabels else { return "Paused: enable overlay labels to show the BetterDisplay source." }
        guard started, sessionActive, !system.state.isLocked, !shuttingDown,
              systemAwake, screensAwake else { return "BetterDisplay feedback is paused in this session." }
        guard betterDisplaySnapshotCurrent, mayReceiveBetterDisplayFeedback,
              BetterDisplayFeedback.Display.selected(in: displaySelection) != nil else {
            return "Select one unique external display in General. All, Main, Built-in and fallback selections are unavailable."
        }
        if betterDisplayFeedback.awaitingProviderLaunch { return "BetterDisplay reported termination. Waiting for a launch notification." }
        if betterDisplayFeedback.eligibleReport() != nil {
            return "Cached BetterDisplay feedback; preview rechecks the 5-second receipt limit. Physical brightness is unverified."
        }
        return "No eligible BetterDisplay feedback. The provider may be absent, dispatch may be off, or the report may have expired."
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
        defer { reconcileLowPowerModeAlerts() }
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
        let deadline = mediaIdleClock.now.advanced(by: .seconds(preferences.duration(for: value.kind)))
        hudDeadline = deadline
        if value.origin != "preview", !Self.isBetterDisplayHUD(value), preferences.enableHaptics {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        }
        hudDismiss = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.hud = nil
            self?.hudDeadline = nil
        }
    }

    /// A labelled presentation preview. Read available values only; never
    /// change hardware, request permission, or post a system notification.
    func previewHUD(_ kind: HUDKind) -> String? {
        guard started, sessionActive, !system.state.isLocked else { return "Overlays are unavailable in this session." }
        guard !isExpanded else { return "Collapse the panel before previewing an overlay." }
        var value = CoveHUD(kind: kind, title: kind.title + " preview", subtitle: "Preview", symbol: "bell.fill", origin: "preview")
        guard isHUDEnabled(value) else { return "Enable this overlay before previewing it." }
        let state = system.state
        switch kind {
        case .volume:
            value.symbol = state.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
            value.value = state.volumeAvailable ? state.volume : nil
            value.subtitle = state.volumeAvailable ? "Preview · current output" : "Preview · reading unavailable"
        case .brightness:
            value.symbol = "sun.max.fill"
            value.value = state.brightnessAvailable ? state.brightness : nil
            value.subtitle = state.brightnessAvailable ? "Preview · current display" : "Preview · reading unavailable"
        case .battery:
            value.symbol = state.isCharging ? "battery.100.bolt" : "battery.100percent"
            value.value = state.batteryAvailable && state.hasBattery ? Double(state.batteryPercent) / 100 : nil
            value.subtitle = value.value != nil ? "Preview · current charge" : "Preview · no battery reading"
        case .bluetooth:
            value.symbol = "headphones"
            value.subtitle = state.bluetoothAvailable ? "Preview · \(state.bluetoothDevices.count) connected" : "Preview · reading unavailable"
        case .focus:
            value.symbol = "moon.fill"
            value.subtitle = state.focusAvailable ? "Preview · \(state.focusEnabled ? "on" : "off")" : "Preview · reading unavailable"
        case .notification:
            value.subtitle = "Preview only · no system notification"
        case .lock:
            value.symbol = "lock.open.fill"
            value.subtitle = state.lockStateKnown ? "Preview · unlocked session" : "Preview · session reading unavailable"
        }
        showHUD(value)
        return nil
    }

    /// Explicit provider choice. This does not configure/start the receiver or
    /// refresh any state. Missing/expired reports remain a labelled nil value.
    func previewBetterDisplayFeedback() -> String? {
        guard started, sessionActive, !system.state.isLocked else { return "Overlays are unavailable in this session." }
        guard !isExpanded else { return "Collapse the panel before previewing an overlay." }
        var value = CoveHUD(kind: .brightness, title: "BetterDisplay preview",
                            subtitle: "Preview · reported feedback unavailable", symbol: "sun.max.fill",
                            origin: BetterDisplayFeedback.previewOrigin)
        guard isHUDEnabled(value) else { return betterDisplayFeedbackStatus }
        if let report = betterDisplayFeedback.eligibleReport() {
            value.value = report.fraction
            value.subtitle = "Preview · last BetterDisplay feedback · not physical readback"
        }
        showHUD(value)
        return nil
    }

    private func isHUDEnabled(_ value: CoveHUD) -> Bool {
        if value.origin == CoveHUD.lowPowerModeOrigin {
            // Final admission precedes showHUD's replacement, deadline and haptic.
            guard value.kind == .battery, mayReceiveLowPowerModeAlerts else { return false }
        }
        if Self.isBetterDisplayHUD(value) {
            guard value.kind == .brightness, mayReceiveBetterDisplayFeedback, !isExpanded,
                  BetterDisplayFeedback.Display.selected(in: displaySelection) != nil else { return false }
        }
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

    func requestWaveformAccess() {
        guard started, preferences.usesLiveWaveform else { return }
        waveform.requestAccessAndStart()
    }

    @discardableResult func completeOnboarding() -> Bool {
        updatePreferences { $0.completedOnboarding = true }
    }

    /// All ordinary UI, API, remote overlay, reset, and display edits enter here.
    /// Only the dedicated native consent actions can add reader grants, after
    /// a successful save. Generic preferences cannot enable these integrations.
    @discardableResult func updatePreferences(_ edit: (inout CovePreferences) -> Void) -> Bool {
        var candidate = preferences
        edit(&candidate)
        return commitPreferences(candidate)
    }

    @discardableResult func applyPreferences(_ candidate: CovePreferences) -> Bool {
        commitPreferences(candidate)
    }

    @discardableResult func savePreferences() -> Bool { commitPreferences(preferences) }

    /// Called only by the disclosed, affirmative native widget control. The mode
    /// and both prerequisites must already be on; this action never enables them.
    @discardableResult func setIndependentLockWidget(_ widget: CoveLockWidget, enabled: Bool) -> Bool {
        if !enabled { return updatePreferences { $0[keyPath: widget.selectionKey] = false } }
        guard !preferences.lockWidgetsFollowActivities, preferences.showOnLockScreen, preferences.enablePrivateAPIs else {
            lastError = "Choose independent widgets and enable lock-screen widgets and private integrations separately first."
            return false
        }
        guard !preferences[keyPath: widget.selectionKey] else { return true }
        var candidate = preferences
        candidate[keyPath: widget.selectionKey] = true
        return commitPreferences(candidate, granting: widget)
    }

    /// Bound only to the disclosed native BetterDisplay control. This action
    /// grants no widget, private integration, hardware-key or vendor permission.
    @discardableResult func setBetterDisplayFeedback(enabled: Bool) -> Bool {
        if !enabled { return updatePreferences { $0.enableBetterDisplayFeedback = false } }
        guard preferences.enableBrightnessHUD else {
            lastError = "Enable the display brightness overlay separately before choosing BetterDisplay feedback."
            return false
        }
        guard !preferences.enableBetterDisplayFeedback else { return true }
        var candidate = preferences
        candidate.enableBetterDisplayFeedback = true
        return commitPreferences(candidate, grantingBetterDisplayFeedback: true)
    }

    /// Only the disclosed native Settings control adds this local reader grant.
    /// It does not enable the category, a widget or any system permission.
    @discardableResult func setLowPowerModeAlerts(enabled: Bool) -> Bool {
        if !enabled { return updatePreferences { $0.enableLowPowerModeAlerts = false } }
        guard preferences.enableBattery else {
            lastError = "Enable Battery & charging separately before choosing Low Power Mode changes."
            return false
        }
        guard !preferences.enableLowPowerModeAlerts else { return true }
        var candidate = preferences
        candidate.enableLowPowerModeAlerts = true
        return commitPreferences(candidate, grantingLowPowerModeAlerts: true)
    }

    /// Revocations win over additions before publication or service changes.
    /// There is no pending grant: an unsuccessful addition is discarded here.
    private func sanitizedPreferences(_ requested: CovePreferences, granting: CoveLockWidget?,
                                      grantingBetterDisplayFeedback: Bool, grantingLowPowerModeAlerts: Bool) -> CovePreferences {
        let previous = preferences
        var candidate = requested
        candidate.normalize()
        if !candidate.enableBrightnessHUD || (!previous.enableBetterDisplayFeedback && !grantingBetterDisplayFeedback) {
            candidate.enableBetterDisplayFeedback = false
        }
        if !candidate.enableBattery || (!previous.enableLowPowerModeAlerts && !grantingLowPowerModeAlerts) {
            candidate.enableLowPowerModeAlerts = false
        }
        let clearAll = candidate.lockWidgetsFollowActivities != previous.lockWidgetsFollowActivities
            || !candidate.showOnLockScreen || !candidate.enablePrivateAPIs
            || (previous.showLockScreenPrivateContent && !candidate.showLockScreenPrivateContent)
        for widget in CoveLockWidget.allCases {
            let activityRevoked = previous[keyPath: widget.activityKey] && !candidate[keyPath: widget.activityKey]
            let unauthorizedAddition = !previous[keyPath: widget.selectionKey] && granting != widget
            if clearAll || activityRevoked || unauthorizedAddition { candidate[keyPath: widget.selectionKey] = false }
        }
        return candidate
    }

    /// Publish only sanitized, effective choices. Ordinary preferences still
    /// apply for this session if saving fails. Extra reader grants use save-first.
    private func applyEffectivePreferences(_ candidate: CovePreferences) {
        guard candidate != preferences || candidate != appliedPreferences else { return }
        let previous = appliedPreferences
        if candidate.selectedDisplayUUID != previous.selectedDisplayUUID
            || candidate.showOnAllDisplays != previous.showOnAllDisplays
            || candidate.preferBuiltInDisplay != previous.preferBuiltInDisplay {
            invalidateBetterDisplaySnapshot()
        }
        if preferences != candidate { preferences = candidate }
        reconcileLowPowerModeAlerts()
        reconcileBetterDisplayFeedback()
        if !preferences.syncSettingsWithiCloud { settingsSync.stop() }
        if started {
            refreshSessionActivity()
            reconcileReaders()
            reconcileCalendarPrivacy()
            if preferences.enableCalendar { travel.start(); travel.updateEvents(activities.routingEvents) }
            else { travel.stop(); travel.updateEvents([]) }
            if preferences.usesLiveWaveform != previous.usesLiveWaveform {
                waveform.setEnabled(preferences.usesLiveWaveform)
            }
            hardwareKeys.volumeEnabled = preferences.enableVolumeHUD
            hardwareKeys.brightnessEnabled = preferences.enableBrightnessHUD
            hardwareKeys.start(enabled: preferences.replaceSystemHUDs && preferences.enablePrivateAPIs)
            reconcileMirroring()
            reconcileBetterDisplayFeedback()
            if let hud, !isHUDEnabled(hud) { hudDismiss?.cancel(); self.hud = nil }
        }
        appliedPreferences = preferences
        if preferences.compactActivity != previous.compactActivity { resetCompactDismissals() }
        else {
            var reset = Set<CoveCompactActivity>()
            if preferences.enableMedia != previous.enableMedia { reset.insert(.media) }
            if preferences.enableTimer != previous.enableTimer { reset.insert(.timer) }
            if preferences.enableCalendar != previous.enableCalendar { reset.insert(.calendar) }
            if !reset.isEmpty { resetCompactDismissals(for: reset) }
        }
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
    }

    @discardableResult private func commitPreferences(_ requested: CovePreferences, granting: CoveLockWidget? = nil,
                                                     grantingBetterDisplayFeedback: Bool = false,
                                                     grantingLowPowerModeAlerts: Bool = false) -> Bool {
        let previous = preferences
        var candidate = sanitizedPreferences(requested, granting: granting,
                                             grantingBetterDisplayFeedback: grantingBetterDisplayFeedback,
                                             grantingLowPowerModeAlerts: grantingLowPowerModeAlerts)
        let hasNewGrant = granting.map { candidate[keyPath: $0.selectionKey] && !previous[keyPath: $0.selectionKey] } ?? false
        let hasNewBetterDisplayGrant = candidate.enableBetterDisplayFeedback && !previous.enableBetterDisplayFeedback
        let hasNewLowPowerModeGrant = candidate.enableLowPowerModeAlerts && !previous.enableLowPowerModeAlerts
        var effective = candidate
        if hasNewGrant, let granting { effective[keyPath: granting.selectionKey] = false }
        if hasNewBetterDisplayGrant { effective.enableBetterDisplayFeedback = false }
        if hasNewLowPowerModeGrant { effective.enableLowPowerModeAlerts = false }
        lastError = nil
        // Reductions reach controllers synchronously, before any fallible save.
        applyEffectivePreferences(effective)
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
        candidate.launchAtLogin = preferences.launchAtLogin
        // Registration failure can coexist with a successful JSON write. Strip
        // prospective consent before that write, not after it.
        if !success {
            candidate.completedOnboarding = previous.completedOnboarding
            if hasNewGrant, let granting { candidate[keyPath: granting.selectionKey] = false }
            if hasNewBetterDisplayGrant { candidate.enableBetterDisplayFeedback = false }
            if hasNewLowPowerModeGrant { candidate.enableLowPowerModeAlerts = false }
        }
        var preferencesPersisted = false
        do {
            if needsPreferencesBackup {
                if let backup = try backupDamagedPreferences() {
                    let notice = "The original settings were preserved in \(backup.lastPathComponent)."
                    lastError = [lastError, notice].compactMap { $0 }.joined(separator: " ")
                }
            }
            try JSONEncoder().encode(candidate).write(to: CovePaths.dataDirectory.appendingPathComponent("preferences.json"), options: .atomic)
            preferencesPersisted = true
            persistedLockWidgets = candidate.independentLockWidgets
            persistedBetterDisplayFeedback = candidate.enableBetterDisplayFeedback
            persistedLowPowerModeAlerts = candidate.enableLowPowerModeAlerts
        } catch {
            success = false
            lastError = [lastError, "Settings apply for this session, but could not be saved: \(error.localizedDescription)"].compactMap { $0 }.joined(separator: " ")
        }
        if !success {
            candidate.completedOnboarding = previous.completedOnboarding
            if hasNewGrant, let granting {
                candidate[keyPath: granting.selectionKey] = false
                lastError = [lastError, "The widget was not enabled because its consent could not be saved. Enable it again after saving succeeds."].compactMap { $0 }.joined(separator: " ")
            }
            if hasNewBetterDisplayGrant {
                candidate.enableBetterDisplayFeedback = false
                lastError = [lastError, "BetterDisplay feedback was not enabled because its consent could not be saved. Enable it again after saving succeeds."].compactMap { $0 }.joined(separator: " ")
            }
            if hasNewLowPowerModeGrant {
                candidate.enableLowPowerModeAlerts = false
                lastError = [lastError, "Low Power Mode changes were not enabled because consent could not be saved. Enable them again after saving succeeds."].compactMap { $0 }.joined(separator: " ")
            }
        }
        applyEffectivePreferences(candidate)
        if !preferencesPersisted, !persistedLockWidgets.isSubset(of: preferences.independentLockWidgets) {
            lastError = [lastError, "The revoked widgets are off for this session. Their previous saved choices could not be updated and may return after restart."].compactMap { $0 }.joined(separator: " ")
        }
        if !preferencesPersisted, persistedBetterDisplayFeedback, !preferences.enableBetterDisplayFeedback {
            lastError = [lastError, "BetterDisplay feedback is off for this session. Its previous saved choice could not be updated and may return after restart."].compactMap { $0 }.joined(separator: " ")
        }
        if !preferencesPersisted, persistedLowPowerModeAlerts, !preferences.enableLowPowerModeAlerts {
            lastError = [lastError, "Low Power Mode changes are off for this session. The previous saved choice could not be updated and may return after restart."].compactMap { $0 }.joined(separator: " ")
        }
        if started { settingsSync.preferencesDidSave(preferences, persisted: preferencesPersisted) }
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
        var candidate = CovePreferences()
        candidate.completedOnboarding = onboarded
        return commitPreferences(candidate)
    }
}
