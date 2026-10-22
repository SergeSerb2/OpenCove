import AppKit
import Combine
import CoreGraphics
import Darwin
import ServiceManagement

@MainActor
final class CoveStore: ObservableObject {
    @Published var preferences: CovePreferences
    @Published var selectedTab: CoveTab = .media
    @Published var isExpanded = false
    @Published var hud: CoveHUD?
    @Published var settingsVisible = false
    @Published var lastError: String?
    @Published var loginItemStatus = "Disabled"
    @Published var physicalNotchWidth = 0.0
    @Published var physicalNotchHeight = 0.0
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
    private var hudDismiss: Task<Void, Never>?
    private var appliedPreferences: CovePreferences
    private var subscriptions = Set<AnyCancellable>()
    private var started = false
    private var sessionActive = false
    private var needsPreferencesBackup = false

    private var mayMirror: Bool {
        started && sessionActive && preferences.mirrorSystemNotifications && preferences.enableNotifications
            && preferences.enablePrivateAPIs && system.state.lockStateKnown && !system.state.isLocked
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
        media.onHUD = { [weak self] in self?.showHUD($0) }
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
            self.reconcileCalendarPrivacy()
            self.reconcileMirroring()
            self.objectWillChange.send()
            self.onPreferencesChange?()
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.sessionDidResignActiveNotification).sink { [weak self] _ in
            self?.sessionActive = false
            self?.collapse()
            self?.reconcileCalendarPrivacy()
            self?.reconcileMirroring()
        }.store(in: &subscriptions)
        workspace.publisher(for: NSWorkspace.sessionDidBecomeActiveNotification).sink { [weak self] _ in
            self?.refreshSessionActivity()
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
    }

    func stop() {
        started = false
        hudDismiss?.cancel()
        media.stop(); system.stop(); activities.stop(); weather.stop()
        waveform.stop(); travel.stop(); hardwareKeys.stop()
        reconcileMirroring()
        hud = nil
    }

    func expand() { isExpanded = true }
    func collapse() { isExpanded = false }
    func toggleExpanded() { isExpanded.toggle() }
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
