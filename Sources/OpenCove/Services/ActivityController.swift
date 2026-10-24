import AppKit
import Combine
import Darwin
import EventKit
import Security
import UserNotifications

struct CoveCalendarSource: Identifiable, Equatable {
    var id: String
    var title: String
    var account: String
    var colorHex: String
    var isExcluded: Bool
}

struct CoveEventActivity: Equatable {
    enum Phase { case current, startingSoon }
    var event: CoveEvent
    var phase: Phase
    /// Time until the end for a current event, or until the start otherwise.
    var remainingSeconds: Int
}

/// App-owned activities. This service does not read other applications' notifications.
@MainActor
final class ActivityController: NSObject, ObservableObject, @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    @Published var events: [CoveEvent] = []
    @Published var calendarAuthorization = "Not requested"
    @Published private(set) var calendarSources: [CoveCalendarSource] = []
    @Published private(set) var excludedCalendarIdentifiers: Set<String> = []
    @Published private(set) var selectedCalendarDate = Calendar.current.startOfDay(for: Date())
    @Published private(set) var calendarToday = Calendar.current.startOfDay(for: Date())
    @Published private(set) var isRefreshingCalendar = false
    @Published private(set) var calendarDetailsHidden = false
    @Published private(set) var nextUpcomingEvent: CoveEvent?
    @Published private(set) var eventActivity: CoveEventActivity?
    @Published private(set) var calendarPreEventLeadMinutes = 15
    @Published private(set) var calendarAlertsEnabled = true
    @Published private(set) var calendarEnabled = true
    /// The parent owns this preference and its persistence.
    var preferredCalendarApp = "calendar"
    @Published var files: [TrayFile] = []
    @Published var timer = CoveTimerState()
    // Presentation identity survives pause/resume but changes for a new timer.
    // The timer publication already delivers its changes; this adds no tick.
    private(set) var timerActivityIdentifier = UUID()
    // Clock/wake events retarget native progress even if remaining time clamps
    // to the same duration after a backwards wall-clock change.
    private(set) var timerClockRevision: UInt64 = 0
    @Published var notifications: [CoveNotification] = []
    @Published var lastError: String? {
        didSet {
            // A repeated failure is still a new failure. Clearing a visible
            // message must not erase the outcome of an operation in progress.
            if let lastError {
                failureRevision &+= 1
                latestFailureMessage = lastError
            }
        }
    }
    @Published private(set) var lastNotice: String?
    @Published private(set) var notificationAuthorization = "Not requested"
    @Published private(set) var nativeNotificationsEnabled = false
    @Published private(set) var incomingURLAuthorization = "Disabled"
    var onHUD: ((CoveHUD) -> Void)?
    // Internal route consumers receive filtered source events, independent of UI redaction.
    var onRoutingEvents: (([CoveEvent]) -> Void)?
    var routingEvents: [CoveEvent] {
        calendarEnabled && calendarSettingsValid && EKEventStore.authorizationStatus(for: .event) == .fullAccess
            ? upcomingCalendarEvents : []
    }

    var hasVisibleCalendarActivity: Bool {
        calendarEnabled && calendarSettingsValid && !calendarDetailsHidden
            && EKEventStore.authorizationStatus(for: .event) == .fullAccess && eventActivity != nil
    }

    let dataDirectory: URL
    private let eventStore = EKEventStore()
    private let calendarReader = CoveCalendarReader()
    private var calendarReadTask: Task<Void, Never>?
    private var calendarReadCancellation: CoveCalendarReadCancellation?
    private var calendarActivityTimer: Timer?
    private var calendarClockActive = false
    private var calendarClockBoundary: Date?
    private var calendarReadRevision = 0
    private var calendarSettingsLoaded = false
    private var calendarSettingsValid = true
    // The parent owns these global preferences and their persistence.
    private var showDeclinedCalendarEvents = false
    private var excludeSubscribedCalendars = false
    private var selectedDateFollowsToday = true
    private var upcomingCalendarEvents: [CoveEvent] = []
    private var monthCalendarEvents: [CoveEvent] = []
    private var rawCalendarSources: [CoveCalendarSource] = []
    private var loadedCalendarRange: DateInterval?
    private var loadedCalendarTimeZone: String?
    private var calendarClockTimeZone = TimeZone.current.identifier
    private var calendarAlertReceipts: [String: Date] = [:]
    private var lastCalendarActivityCheck: Date?
    private var started = false
    private var loaded = false
    private var damagedPersistenceFiles: Set<String> = []
    private var failureRevision: UInt64 = 0
    private var latestFailureMessage: String?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var calendarRefreshTimer: Timer?
    private var countdown: Timer?
    private var calendarAccessTask: Task<Void, Never>?
    private var authorizationTask: Task<Void, Never>?
    private var notificationTasks: [UUID: Task<Void, Never>] = [:]
    private var timerNotificationRevision = 0
    private var settings = ActivitySettings()
    private var scopedURLs: [UUID: URL] = [:]
    private var sharingPicker: NSSharingServicePicker?
    private var sharingService: NSSharingService?
    private var sharingURLs: [URL] = []

    private enum PersistenceLimits {
        static let trayCount = 1_024
        static let trayBytes = 16_777_216
        static let otherBytes = 1_048_576
        static let backupBytes = 16_777_216

        static func bytes(for name: String) -> Int {
            name == "activity-tray.json" ? trayBytes : otherBytes
        }
    }

    private struct ActivitySettings: Codable {
        var nativeNotificationsEnabled = false
        var incomingURLToken: String? = nil

        private enum CodingKeys: String, CodingKey { case nativeNotificationsEnabled, incomingURLToken }

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            nativeNotificationsEnabled = try values.decodeIfPresent(Bool.self, forKey: .nativeNotificationsEnabled) ?? false
            incomingURLToken = try values.decodeIfPresent(String.self, forKey: .incomingURLToken)
        }
    }

    private enum ActivityError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case let .message(message) = self { return message }
            return nil
        }
    }

    init(dataDirectory: URL? = nil) {
        if let dataDirectory {
            self.dataDirectory = dataDirectory.standardizedFileURL
        } else {
            self.dataDirectory = CovePaths.dataDirectory
        }
        super.init()
    }

    enum OperationResult {
        case submitted
        case failed(String)
    }

    /// Captures only failures produced by this synchronous main-actor call.
    /// Async work remains submitted; any later failure stays visible in state.
    func performSynchronousOperation(_ operation: () -> Void) -> OperationResult {
        let previousRevision = failureRevision
        operation()
        if failureRevision != previousRevision, let message = latestFailureMessage {
            return .failed(message)
        }
        return .submitted
    }

    func start() {
        guard !started else { return }
        started = true
        loadIfNeeded()
        restoreFileAccess()
        refreshCalendar()
        startCalendarActivityClock()
        refreshNotificationAuthorization()
        updateTimer()
        updateCountdown()
        scheduleTimerNotification()

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.started else { return }
                self.refreshCalendar()
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.started else { return }
                self.refreshCalendar()
                self.refreshNotificationAuthorization()
                self.timerClockRevision &+= 1
                self.updateTimer()
                self.updateCountdown()
            }
        })
        observers.append(center.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleClockChange() }
        })
        observers.append(center.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.started else { return }
                self.updateCalendarDay()
                self.refreshCalendar()
            }
        })
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleClockChange() }
        })
        let refresh = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.started else { return }
                self.refreshCalendar()
            }
        }
        refresh.tolerance = 10
        RunLoop.main.add(refresh, forMode: .common)
        calendarRefreshTimer = refresh
    }

    func stop() {
        started = false
        countdown?.invalidate()
        countdown = nil
        calendarRefreshTimer?.invalidate()
        calendarRefreshTimer = nil
        calendarActivityTimer?.invalidate()
        calendarActivityTimer = nil
        calendarReadTask?.cancel()
        calendarReadTask = nil
        calendarReadCancellation?.cancel()
        calendarReadCancellation = nil
        calendarReadRevision += 1
        isRefreshingCalendar = false
        lastCalendarActivityCheck = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
        calendarAccessTask?.cancel()
        calendarAccessTask = nil
        authorizationTask?.cancel()
        authorizationTask = nil
        notificationTasks.values.forEach { $0.cancel() }
        notificationTasks.removeAll()
        sharingPicker?.delegate = nil
        sharingPicker?.close()
        sharingPicker = nil
        sharingService?.delegate = nil
        sharingService = nil
        releaseSharingAccess()
        scopedURLs.values.forEach { $0.stopAccessingSecurityScopedResource() }
        scopedURLs.removeAll()
        clearCalendarSnapshot()
        // A running timer keeps its saved deadline and opt-in system notification across app exits.
    }

    // MARK: Calendar

    func requestCalendarAccess() {
        guard calendarEnabled else { return }
        guard calendarAccessTask == nil else { return }
        guard hasCalendarUsageDescription else {
            calendarAuthorization = "Unavailable"
            lastError = "Calendar access needs NSCalendarsFullAccessUsageDescription in the OpenCove app bundle."
            return
        }
        calendarAccessTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { self.calendarAccessTask = nil } }
            do {
                let granted = try await self.eventStore.requestFullAccessToEvents()
                guard !Task.isCancelled else { return }
                self.eventStore.reset()
                self.refreshCalendar()
                if !granted { self.lastError = "Calendar access was not granted. Enable OpenCove in System Settings → Privacy & Security → Calendars." }
            } catch {
                guard !Task.isCancelled else { return }
                self.refreshCalendar()
                self.lastError = "Calendar access failed: \(error.localizedDescription)"
            }
        }
    }

    /// Refresh both the seven-day activity feed and the selected month's 42-day grid.
    /// This never requests permission. EventKit's synchronous reads run on a serial worker.
    func refreshCalendar() {
        defer { startCalendarActivityClock() }
        loadCalendarSettingsIfNeeded()
        updateCalendarDay()
        calendarReadRevision += 1
        let revision = calendarReadRevision
        calendarReadTask?.cancel()
        calendarReadTask = nil
        calendarReadCancellation?.cancel()
        calendarReadCancellation = nil
        guard calendarEnabled else {
            calendarAuthorization = "Disabled"
            clearCalendarSnapshot()
            return
        }
        guard calendarSettingsValid else {
            calendarAuthorization = "Saved calendar settings need review"
            clearCalendarSnapshot()
            return
        }
        let authorization = EKEventStore.authorizationStatus(for: .event)
        switch authorization {
        case .fullAccess: calendarAuthorization = "Authorized"
        case .writeOnly: calendarAuthorization = "Write-only — reading unavailable"
        case .denied: calendarAuthorization = "Denied"
        case .restricted: calendarAuthorization = "Restricted"
        case .notDetermined: calendarAuthorization = hasCalendarUsageDescription ? "Not requested" : "Unavailable"
        @unknown default: calendarAuthorization = "Unavailable"
        }
        guard authorization == .fullAccess else {
            clearCalendarSnapshot()
            return
        }
        isRefreshingCalendar = true
        let calendar = Calendar.current
        let now = Date()
        let gridRange = Self.monthGridRange(containing: selectedCalendarDate, calendar: calendar)
        let upcomingEnd = calendar.date(byAdding: .day, value: 7, to: now) ?? now.addingTimeInterval(604_800)
        let cancellation = CoveCalendarReadCancellation()
        calendarReadCancellation = cancellation
        let request = CoveCalendarReader.Request(
            gridRange: gridRange,
            upcomingRange: DateInterval(start: calendar.startOfDay(for: now), end: upcomingEnd),
            excludedIdentifiers: excludedCalendarIdentifiers,
            showDeclinedEvents: showDeclinedCalendarEvents,
            excludeSubscribedCalendars: excludeSubscribedCalendars, cancellation: cancellation
        )
        calendarReadTask = Task { @MainActor [weak self] in
            // Rapid date clicks and batches of EventKit notifications need only one read.
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            let snapshot = await self.calendarReader.read(request)
            guard !Task.isCancelled, self.calendarEnabled, self.calendarReadRevision == revision else { return }
            self.calendarReadTask = nil
            self.calendarReadCancellation = nil
            self.isRefreshingCalendar = false
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                self.refreshCalendar()
                return
            }
            self.rawCalendarSources = snapshot.sources
            self.upcomingCalendarEvents = snapshot.upcomingEvents
            self.monthCalendarEvents = snapshot.gridEvents
            self.loadedCalendarRange = gridRange
            self.loadedCalendarTimeZone = calendar.timeZone.identifier
            self.publishCalendarPresentation()
            self.updateCalendarActivity()
        }
    }

    /// Select a civil day. A cache miss schedules a real, authorized EventKit read.
    func loadSelectedDate(_ date: Date) {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return }
        let calendar = Calendar.current
        selectedCalendarDate = calendar.startOfDay(for: date)
        selectedDateFollowsToday = calendar.isDateInToday(date)
        let range = Self.monthGridRange(containing: date, calendar: calendar)
        if isRefreshingCalendar || loadedCalendarRange != range || loadedCalendarTimeZone != calendar.timeZone.identifier {
            monthCalendarEvents = []
            refreshCalendar()
        }
    }

    /// All events intersecting this day, including past events and multi-day/all-day events.
    /// Call loadSelectedDate first for a date outside the loaded grid; observe this controller
    /// for the asynchronous result. A SwiftUI body can safely call this cache-only API.
    func events(on date: Date) -> [CoveEvent] {
        guard calendarEnabled, EKEventStore.authorizationStatus(for: .event) == .fullAccess,
              let day = Calendar.current.dateInterval(of: .day, for: date),
              loadedCalendarTimeZone == Calendar.current.timeZone.identifier,
              let range = loadedCalendarRange, day.start >= range.start, day.end <= range.end else { return [] }
        return monthCalendarEvents.filter { Self.overlaps($0, day) }.map(calendarPresentation)
    }

    var currentEvent: CoveEvent? {
        let now = Date()
        return events.first { !$0.isAllDay && $0.start <= now && $0.end > now }
    }

    var startingSoonEvent: CoveEvent? {
        guard let event = nextUpcomingEvent,
              event.start.timeIntervalSinceNow <= Double(calendarPreEventLeadMinutes * 60),
              calendarPreEventLeadMinutes > 0 else { return nil }
        return event
    }

    /// The parent owns the global feature preference. Other activity services keep running.
    /// The independent alert opt-in and excluded sources remain saved and unchanged.
    func setCalendarEnabled(_ enabled: Bool) {
        setCalendarConfiguration(enabled: enabled, showDeclinedEvents: showDeclinedCalendarEvents,
                                 excludeSubscribedCalendars: excludeSubscribedCalendars)
    }

    /// Apply enablement and filters together before queuing a read. A filter change
    /// clears old activity/routing data; refresh retains permission and recovery gates.
    func setCalendarConfiguration(enabled: Bool, showDeclinedEvents: Bool, excludeSubscribedCalendars: Bool) {
        let filtersChanged = showDeclinedCalendarEvents != showDeclinedEvents
            || self.excludeSubscribedCalendars != excludeSubscribedCalendars
        guard calendarEnabled != enabled || filtersChanged else { return }
        calendarEnabled = enabled
        showDeclinedCalendarEvents = showDeclinedEvents
        self.excludeSubscribedCalendars = excludeSubscribedCalendars
        lastCalendarActivityCheck = nil
        if !enabled {
            calendarAccessTask?.cancel()
            calendarAccessTask = nil
        }
        if filtersChanged { clearCalendarSnapshot() }
        // Increments the read revision and cancels prior work even when a read is gated off.
        refreshCalendar()
    }

    private func clearCalendarSnapshot() {
        isRefreshingCalendar = false
        upcomingCalendarEvents = []
        monthCalendarEvents = []
        loadedCalendarRange = nil
        loadedCalendarTimeZone = nil
        calendarSources = []
        rawCalendarSources = []
        publishCalendarPresentation()
    }

    func setCalendarExcluded(_ identifier: String, excluded: Bool) {
        loadCalendarSettingsIfNeeded()
        var identifiers = excludedCalendarIdentifiers
        if excluded { identifiers.insert(identifier) } else { identifiers.remove(identifier) }
        setExcludedCalendarIdentifiers(identifiers)
    }

    func setExcludedCalendarIdentifiers(_ identifiers: Set<String>) {
        loadCalendarSettingsIfNeeded()
        calendarSettingsValid = true
        excludedCalendarIdentifiers = Set(identifiers.filter { !$0.isEmpty })
        saveCalendarSettings()
        // Remove hidden sources immediately, before the next worker result can arrive.
        upcomingCalendarEvents.removeAll { excludedCalendarIdentifiers.contains($0.calendarIdentifier) }
        monthCalendarEvents.removeAll { excludedCalendarIdentifiers.contains($0.calendarIdentifier) }
        rawCalendarSources = rawCalendarSources.map {
            var source = $0
            source.isExcluded = excludedCalendarIdentifiers.contains(source.id)
            return source
        }
        publishCalendarPresentation()
        refreshCalendar()
    }

    /// OpenCove's independent default is 15 minutes; zero disables only pre-event alerts.
    func setCalendarPreEventLeadMinutes(_ minutes: Int) {
        loadCalendarSettingsIfNeeded()
        calendarPreEventLeadMinutes = min(1_440, max(0, minutes))
        saveCalendarSettings()
        updateCalendarActivity()
    }

    func setCalendarAlertsEnabled(_ enabled: Bool) {
        loadCalendarSettingsIfNeeded()
        calendarAlertsEnabled = enabled
        saveCalendarSettings()
        updateCalendarActivity()
    }

    /// Call from the parent's real lock-state callback. This does not infer a lock state.
    /// Published events, activity, date queries, and future HUDs all use the redacted form.
    func setCalendarPrivacy(isLocked: Bool, hideSensitiveDetails: Bool) {
        calendarDetailsHidden = isLocked && hideSensitiveDetails
        publishCalendarPresentation()
        updateCalendarActivity()
    }

    func refreshSchedule() { refreshCalendar() }

    func openEvent(_ id: String) {
        guard !calendarDetailsHidden, let event = knownCalendarEvent(id) else {
            lastError = "That event is hidden or no longer available. Refresh the calendar."
            return
        }
        openCalendar(at: event.start)
    }

    func openCalendar(at date: Date = Date()) {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        if preferredCalendarApp == "fantastical" {
            let day = formatter.string(from: date)
            // Only documented reveal-date routes; never the event-creation /parse action.
            for route in ["x-fantastical://date/\(day)", "x-fantastical3://show?date=\(day)"] {
                if openInstalledCalendarURL(route, bundleIdentifier: "com.flexibits.fantastical2.mac") { return }
            }
        } else if preferredCalendarApp == "notionCalendar" {
            // Cron is Notion Calendar's actual scheme. Date-only deep links are not
            // documented; launch its existing calendar without inventing account/UID data.
            if openInstalledCalendarURL("cron://", bundleIdentifier: "com.cron.electron") { return }
        }
        // Some OS versions register calshow, others register only ical. Check the real
        // handler instead of claiming an uninstalled scheme can navigate to a date.
        if openInstalledCalendarURL("calshow:\(date.timeIntervalSinceReferenceDate)", bundleIdentifier: "com.apple.iCal") { return }
        if openInstalledCalendarURL("ical://", bundleIdentifier: "com.apple.iCal") { return }
        lastError = "Calendar could not open. Install or enable Apple Calendar, or select an installed calendar app."
    }

    func joinMeeting(_ id: String) {
        guard !calendarDetailsHidden, let url = knownCalendarEvent(id)?.meetingURL, Self.isMeetingScheme(url) else {
            lastError = "This event has no available meeting link. Open it in Calendar to check its details."
            return
        }
        if !NSWorkspace.shared.open(url) { lastError = "The meeting link could not open. Check that its browser or meeting app is installed." }
    }

    private func openInstalledCalendarURL(_ route: String, bundleIdentifier: String) -> Bool {
        guard let url = URL(string: route),
              let app = NSWorkspace.shared.urlForApplication(toOpen: url),
              Bundle(url: app)?.bundleIdentifier == bundleIdentifier else { return false }
        return NSWorkspace.shared.open(url)
    }

    private func knownCalendarEvent(_ id: String) -> CoveEvent? {
        guard calendarEnabled, EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        return (upcomingCalendarEvents + monthCalendarEvents).first {
            $0.id == id && !excludedCalendarIdentifiers.contains($0.calendarIdentifier)
        }
    }

    private func calendarPresentation(_ value: CoveEvent) -> CoveEvent {
        guard calendarDetailsHidden else { return value }
        var event = value
        event.title = "Calendar event"
        event.location = ""
        event.calendarName = "Calendar"
        event.meetingURL = nil
        return event
    }

    private func publishCalendarPresentation() {
        defer { startCalendarActivityClock() }
        onRoutingEvents?(routingEvents)
        calendarSources = rawCalendarSources.map { source in
            guard calendarDetailsHidden else { return source }
            var value = source
            value.title = "Calendar"
            value.account = ""
            return value
        }
        let now = Date()
        events = upcomingCalendarEvents.filter { $0.end > now || ($0.end == $0.start && $0.start >= now) }
            .map(calendarPresentation)
        let upcoming = events.first { !$0.isAllDay && $0.start > now }
        if nextUpcomingEvent != upcoming { nextUpcomingEvent = upcoming }
        let current = events.first { !$0.isAllDay && $0.start <= now && $0.end > now }
        let soon = upcoming.flatMap {
            calendarPreEventLeadMinutes > 0 && $0.start.timeIntervalSince(now) <= Double(calendarPreEventLeadMinutes * 60) ? $0 : nil
        }
        let activity: CoveEventActivity?
        if let current {
            activity = CoveEventActivity(event: current, phase: .current,
                                         remainingSeconds: max(0, Int(ceil(current.end.timeIntervalSince(now)))))
        } else if let soon {
            activity = CoveEventActivity(event: soon, phase: .startingSoon,
                                         remainingSeconds: max(0, Int(ceil(soon.start.timeIntervalSince(now)))))
        } else { activity = nil }
        if eventActivity != activity { eventActivity = activity }
    }

    private func startCalendarActivityClock() {
        let now = Date()
        let relevant = upcomingCalendarEvents.filter { !$0.isAllDay && $0.end > now }
        let lead = Double(max(0, calendarPreEventLeadMinutes) * 60)
        let active = relevant.contains { $0.start <= now || $0.start.timeIntervalSince(now) <= lead }
        let boundary = active ? nil : relevant.map { $0.start.addingTimeInterval(-lead) }.min()
        guard started, calendarEnabled, calendarSettingsValid, calendarAuthorization == "Authorized",
              active || boundary != nil else {
            calendarActivityTimer?.invalidate()
            calendarActivityTimer = nil
            calendarClockBoundary = nil
            calendarClockActive = false
            return
        }
        if calendarActivityTimer?.isValid == true, calendarClockActive == active,
           active || calendarClockBoundary == boundary { return }
        calendarActivityTimer?.invalidate()
        calendarClockActive = active
        calendarClockBoundary = boundary
        // An empty/disabled/unauthorized calendar has no second ticker. A future
        // event schedules one absolute phase boundary, then ticks while visible.
        let ticker = Timer(fire: boundary ?? now.addingTimeInterval(1), interval: active ? 1 : 0, repeats: active) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.started else { return }
                guard self.calendarEnabled else { return }
                if self.updateCalendarDay() { self.refreshCalendar() }
                if EKEventStore.authorizationStatus(for: .event) != .fullAccess {
                    if !self.events.isEmpty || !self.calendarSources.isEmpty { self.refreshCalendar() }
                    return
                }
                self.updateCalendarActivity()
            }
        }
        ticker.tolerance = 0.2
        RunLoop.main.add(ticker, forMode: .common)
        calendarActivityTimer = ticker
    }

    @discardableResult
    private func updateCalendarDay() -> Bool {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date())
        guard day != calendarToday || calendarClockTimeZone != calendar.timeZone.identifier else { return false }
        calendarClockTimeZone = calendar.timeZone.identifier
        calendarToday = day
        if selectedDateFollowsToday { selectedCalendarDate = day }
        else { selectedCalendarDate = calendar.startOfDay(for: selectedCalendarDate) }
        return true
    }

    private func updateCalendarActivity() {
        defer { startCalendarActivityClock() }
        guard calendarEnabled, EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        let now = Date()
        // Publish only changed values. No one-second month-grid fetch or EventKit work.
        if events.contains(where: { $0.end <= now }) { publishCalendarPresentation() }
        let upcoming = upcomingCalendarEvents.first { !$0.isAllDay && $0.start > now }.map(calendarPresentation)
        if nextUpcomingEvent != upcoming { nextUpcomingEvent = upcoming }
        let current = upcomingCalendarEvents.first { !$0.isAllDay && $0.start <= now && $0.end > now }
        let soon = upcomingCalendarEvents.first {
            !$0.isAllDay && $0.start > now && calendarPreEventLeadMinutes > 0 &&
                $0.start.timeIntervalSince(now) <= Double(calendarPreEventLeadMinutes * 60)
        }
        let activity = (current ?? soon).map {
            CoveEventActivity(event: calendarPresentation($0), phase: current == nil ? .startingSoon : .current,
                              remainingSeconds: max(0, Int(ceil((current == nil ? $0.start : $0.end).timeIntervalSince(now)))))
        }
        if eventActivity != activity { eventActivity = activity }
        // Wait for fresh data after a store/filter/clock change, so removed or rescheduled
        // events cannot alert from the old snapshot while EventKit is reading.
        guard started, !isRefreshingCalendar else { return }
        defer { lastCalendarActivityCheck = now }
        guard calendarAlertsEnabled else { return }
        var receiptsChanged = false
        let lead = Double(calendarPreEventLeadMinutes * 60)
        let previousCheck = lastCalendarActivityCheck
        for event in upcomingCalendarEvents where !event.isAllDay && event.end > now {
            guard started, calendarEnabled, !isRefreshingCalendar else { break }
            let untilStart = event.start.timeIntervalSince(now)
            let phase: String
            let title: String
            if untilStart > 0 && lead > 0 && untilStart <= lead {
                phase = "pre"
                title = "Event starting soon"
            } else if untilStart <= 0 &&
                        (untilStart >= -60 || previousCheck.map { $0 <= event.start && now.timeIntervalSince($0) <= 120 } == true) {
                phase = "start"
                title = "Event starting"
            } else { continue }
            let receipt = "\(phase):\(event.id)"
            guard calendarAlertReceipts[receipt] == nil else { continue }
            calendarAlertReceipts[receipt] = event.end.addingTimeInterval(172_800)
            receiptsChanged = true
            // Calendar HUDs stay out of the notification history and native notifications,
            // so a later lock cannot expose a previously saved event title there.
            onHUD?(CoveHUD(kind: .notification, title: title,
                           subtitle: calendarPresentation(event).title, symbol: "calendar.badge.clock", origin: "calendar"))
        }
        let pruned = calendarAlertReceipts.filter { $0.value > now }
        if pruned.count != calendarAlertReceipts.count { calendarAlertReceipts = pruned; receiptsChanged = true }
        if receiptsChanged { save(calendarAlertReceipts, as: "calendar-alert-receipts.json") }
    }

    private struct CalendarSettings: Codable {
        var excludedCalendarIdentifiers: Set<String> = []
        var preEventLeadMinutes = 15
        var alertsEnabled = true
        var repaired = false

        private enum CodingKeys: String, CodingKey { case excludedCalendarIdentifiers, preEventLeadMinutes, alertsEnabled }

        init(excludedCalendarIdentifiers: Set<String>, preEventLeadMinutes: Int, alertsEnabled: Bool) {
            self.excludedCalendarIdentifiers = excludedCalendarIdentifiers
            self.preEventLeadMinutes = preEventLeadMinutes
            self.alertsEnabled = alertsEnabled
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            // Invalid exclusions must never silently select all of the user's calendars.
            excludedCalendarIdentifiers = values.contains(.excludedCalendarIdentifiers)
                ? try values.decode(Set<String>.self, forKey: .excludedCalendarIdentifiers) : []
            if let lead = try? values.decode(Int.self, forKey: .preEventLeadMinutes) {
                preEventLeadMinutes = min(1_440, max(0, lead))
                repaired = preEventLeadMinutes != lead
            } else if values.contains(.preEventLeadMinutes) { repaired = true }
            if let enabled = try? values.decode(Bool.self, forKey: .alertsEnabled) { alertsEnabled = enabled }
            else { alertsEnabled = false; repaired = values.contains(.alertsEnabled) || repaired }
        }
    }

    private func loadCalendarSettingsIfNeeded() {
        guard !calendarSettingsLoaded else { return }
        calendarSettingsLoaded = true
        if let value: CalendarSettings = load("calendar-settings.json") {
            excludedCalendarIdentifiers = value.excludedCalendarIdentifiers
            calendarPreEventLeadMinutes = min(1_440, max(0, value.preEventLeadMinutes))
            calendarAlertsEnabled = value.alertsEnabled
            if value.repaired {
                damagedPersistenceFiles.insert("calendar-settings.json")
                lastError = "Some saved calendar settings were invalid. Alert choices and calendar exclusions were preserved where valid."
            }
        } else if damagedPersistenceFiles.contains("calendar-settings.json") {
            // A rejected symlink can have a missing target. Only the no-follow
            // loader knows whether this is a first run or unreadable saved policy.
            calendarSettingsValid = false
            calendarAlertsEnabled = false
            lastError = "Saved calendar exclusions could not be read. Calendar reads are paused. Choose calendar sources again to replace the damaged settings."
        }
        if let value: [String: Date] = load("calendar-alert-receipts.json") {
            calendarAlertReceipts = value.filter { $0.value.timeIntervalSinceReferenceDate.isFinite && $0.value > Date() }
        }
    }

    private func saveCalendarSettings() {
        guard calendarSettingsValid else {
            lastError = "Choose calendar sources again before saving calendar settings. The damaged exclusions were left unchanged."
            return
        }
        save(CalendarSettings(excludedCalendarIdentifiers: excludedCalendarIdentifiers,
                              preEventLeadMinutes: calendarPreEventLeadMinutes,
                              alertsEnabled: calendarAlertsEnabled), as: "calendar-settings.json")
    }

    static func monthGridRange(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        let month = calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        let offset = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -offset, to: month) ?? month
        let end = calendar.date(byAdding: .day, value: 42, to: start) ?? start.addingTimeInterval(42 * 86_400)
        return DateInterval(start: start, end: end)
    }

    nonisolated fileprivate static func overlaps(_ event: CoveEvent, _ interval: DateInterval) -> Bool {
        if event.end == event.start { return event.start >= interval.start && event.start < interval.end }
        return event.start < interval.end && event.end > interval.start
    }

    private var hasCalendarUsageDescription: Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription") as? String else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated fileprivate static func meetingURL(in event: EKEvent) -> URL? {
        if let url = event.url, isMeetingScheme(url) { return url }
        let text = [event.location, event.notes].compactMap { $0 }.joined(separator: "\n")
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url).first { url in
            guard isMeetingScheme(url) else { return false }
            if !["http", "https"].contains(url.scheme?.lowercased() ?? "") { return true }
            let host = url.host?.lowercased() ?? ""
            return ["zoom.us", "zoom.com", "meet.google.com", "teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft",
                    "webex.com", "chime.aws", "gotomeet.me", "goto.com", "whereby.com", "meet.jit.si",
                    "v.ringcentral.com", "facetime.apple.com"].contains {
                host == $0 || host.hasSuffix("." + $0)
            }
        }
    }

    nonisolated private static func isMeetingScheme(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        if ["https", "http"].contains(scheme) { return !(url.host ?? "").isEmpty && url.user == nil && url.password == nil }
        return ["zoommtg", "zoomus", "msteams", "webex", "chime", "facetime", "facetime-audio"].contains(scheme)
    }

    // MARK: File tray

    func addFiles(_ urls: [URL]) {
        loadIfNeeded()
        var failures: [String] = []
        var proposed = files
        var replacedIDs = Set<UUID>()
        var proposedScopes: [UUID: URL] = [:]
        // Keep existing leases until the complete proposal is safely persisted.
        defer { proposedScopes.values.forEach { $0.stopAccessingSecurityScopedResource() } }
        for input in urls {
            let acquired = input.startAccessingSecurityScopedResource()
            var retainedScope = false
            defer { if acquired && !retainedScope { input.stopAccessingSecurityScopedResource() } }
            do {
                let url = try regularFile(input)
                if let existing = proposed.firstIndex(where: { sameFile($0.url, url) }) {
                    // Re-adding a file also repairs a missing or revoked bookmark.
                    let id = proposed[existing].id
                    let bookmark = try makeBookmark(for: input)
                    proposedScopes.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
                    if acquired { proposedScopes[id] = input; retainedScope = true }
                    proposed[existing] = TrayFile(id: id, url: url, name: url.lastPathComponent, bookmarkData: bookmark)
                    replacedIDs.insert(id)
                    continue
                }
                guard proposed.count < PersistenceLimits.trayCount else {
                    lastError = "The file tray supports at most \(PersistenceLimits.trayCount) files. No files from this import were added. Remove some tray files, then try again."
                    return
                }
                let file = TrayFile(url: url, name: url.lastPathComponent, bookmarkData: try makeBookmark(for: input))
                if acquired { proposedScopes[file.id] = input; retainedScope = true }
                proposed.append(file)
                replacedIDs.insert(file.id)
            } catch { failures.append("\(input.lastPathComponent): \(error.localizedDescription)") }
        }
        guard saveTray(proposed) else { return }
        for id in replacedIDs {
            scopedURLs.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
            if let scope = proposedScopes.removeValue(forKey: id) { scopedURLs[id] = scope }
        }
        files = proposed
        if !failures.isEmpty { lastError = failures.prefix(3).joined(separator: "\n") }
    }

    func addFile(_ url: URL) { addFiles([url]) }

    func addFile(path: String) {
        guard !path.isEmpty, (path as NSString).expandingTildeInPath.hasPrefix("/") else {
            lastError = "Use an existing file URL or an absolute file path."
            return
        }
        addFiles([URL(fileURLWithPath: (path as NSString).expandingTildeInPath)])
    }

    func removeFile(_ id: UUID) {
        loadIfNeeded()
        let proposed = files.filter { $0.id != id }
        guard saveTray(proposed) else { return }
        files = proposed
        scopedURLs.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
    }

    func clearFiles() {
        loadIfNeeded()
        guard saveTray([]) else { return }
        scopedURLs.values.forEach { $0.stopAccessingSecurityScopedResource() }
        scopedURLs.removeAll()
        files.removeAll()
    }

    func openFile(_ id: UUID) {
        guard let url = fileForAction(id) else { return }
        if !NSWorkspace.shared.open(url) { lastError = "No application could open \(url.lastPathComponent). Use Reveal in Finder to choose an application." }
    }

    func revealFile(_ id: UUID) {
        guard let url = fileForAction(id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func shareFiles() {
        guard let view = NSApp?.keyWindow?.contentView else {
            lastError = "Open an OpenCove window, then choose Share again. A visible window is needed for the share sheet."
            return
        }
        shareFiles(relativeTo: view)
    }

    func shareFiles(relativeTo view: NSView) {
        guard view.window != nil else { lastError = "The share sheet needs a view in an open window."; return }
        guard sharingPicker == nil, sharingService == nil else { lastError = "Finish the current share before starting another."; return }
        guard let urls = filesForSharing() else { return }
        retainSharingAccess(urls)
        let picker = NSSharingServicePicker(items: urls)
        picker.delegate = self
        sharingPicker = picker
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    func airDropFiles() {
        guard sharingPicker == nil, sharingService == nil else { lastError = "Finish the current share before starting another."; return }
        guard let urls = filesForSharing() else { return }
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            lastError = "AirDrop is unavailable. Enable Wi-Fi and Bluetooth, then try Share or Reveal in Finder."
            return
        }
        retainSharingAccess(urls)
        sharingService = service
        service.delegate = self
        service.perform(withItems: urls)
    }

    private func regularFile(_ input: URL) throws -> URL {
        guard input.isFileURL, input.host == nil || input.host == "" || input.host?.lowercased() == "localhost",
              input.user == nil, input.password == nil, input.port == nil, input.query == nil, input.fragment == nil,
              input.path.hasPrefix("/"), !input.path.utf8.contains(0) else {
            throw ActivityError.message("Only local file URLs are supported. Download the file first.")
        }
        let url = input.standardizedFileURL.resolvingSymlinksInPath()
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
        guard values.isRegularFile == true else { throw ActivityError.message("Choose an existing regular file, rather than a folder or device.") }
        guard values.isReadable != false, FileManager.default.isReadableFile(atPath: url.path) else {
            throw ActivityError.message("File access is unavailable. Add the file again using a file picker or Finder.")
        }
        return url
    }

    private func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = lhs.standardizedFileURL.resolvingSymlinksInPath()
        let right = rhs.standardizedFileURL.resolvingSymlinksInPath()
        if left.path == right.path { return true }
        if let a = try? left.resourceValues(forKeys: [.fileResourceIdentifierKey, .volumeIdentifierKey]),
           let b = try? right.resourceValues(forKeys: [.fileResourceIdentifierKey, .volumeIdentifierKey]),
           let aid = a.fileResourceIdentifier as? NSObject, let bid = b.fileResourceIdentifier as? NSObject,
           let av = a.volumeIdentifier as? NSObject, let bv = b.volumeIdentifier as? NSObject {
            return av.isEqual(bv) && aid.isEqual(bid)
        }
        return false
    }

    private func makeBookmark(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                        includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            // Unsandboxed development builds may lack the security-scope entitlement.
            // A regular bookmark still tracks moves, but does not grant sandbox access.
            return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
    }

    @discardableResult
    private func restoreFileAccess(only id: UUID? = nil) -> Bool {
        var proposed = files
        var replacedIDs = Set<UUID>()
        var proposedScopes: [UUID: URL] = [:]
        defer { proposedScopes.values.forEach { $0.stopAccessingSecurityScopedResource() } }
        for index in proposed.indices where id == nil || proposed[index].id == id {
            // Keep the previous lease until a replacement is acquired. Resolve on
            // actions as well as startup, so moved files work on the first click.
            let fileID = proposed[index].id
            let previousScope = scopedURLs[fileID]
            replacedIDs.insert(fileID)
            do {
                var url = previousScope ?? proposed[index].url
                var stale = false
                if let bookmark = proposed[index].bookmarkData {
                    do {
                        url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                      relativeTo: nil, bookmarkDataIsStale: &stale)
                    } catch {
                        // A regular bookmark does not contain a sandbox grant. Resolve it normally
                        // in a development build; regularFile still checks actual file access.
                        url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                      relativeTo: nil, bookmarkDataIsStale: &stale)
                    }
                }
                let acquired = url.startAccessingSecurityScopedResource()
                if acquired { proposedScopes[fileID] = url }
                let resolved = try regularFile(url)
                if stale { proposed[index].bookmarkData = try makeBookmark(for: url) }
                if proposed[index].url != resolved { proposed[index].url = resolved; proposed[index].name = resolved.lastPathComponent }
                proposed[index].isAvailable = true
                proposed[index].accessError = nil
            } catch {
                proposedScopes.removeValue(forKey: fileID)?.stopAccessingSecurityScopedResource()
                proposed[index].isAvailable = false
                proposed[index].accessError = "\(error.localizedDescription) Add this file again to restore access."
            }
        }
        // Refreshed bookmarks and paths must fit the same restart limits as imports.
        guard proposed == files || saveTray(proposed) else { return false }
        for fileID in replacedIDs {
            scopedURLs.removeValue(forKey: fileID)?.stopAccessingSecurityScopedResource()
            if let scope = proposedScopes.removeValue(forKey: fileID) { scopedURLs[fileID] = scope }
        }
        files = proposed
        return true
    }

    private func fileForAction(_ id: UUID) -> URL? {
        loadIfNeeded()
        guard restoreFileAccess(only: id) else { return nil }
        guard let file = files.first(where: { $0.id == id }) else { lastError = "This file is no longer in the tray."; return nil }
        guard file.isAvailable else { lastError = "\(file.name): \(file.accessError ?? "Add this file again to restore access.")"; return nil }
        do { return try regularFile(file.url) }
        catch {
            if let index = files.firstIndex(where: { $0.id == id }) {
                files[index].isAvailable = false
                files[index].accessError = "\(error.localizedDescription) Add this file again to restore access."
            }
            scopedURLs.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
            lastError = "\(file.name): \(error.localizedDescription)"
            return nil
        }
    }

    private func filesForSharing() -> [URL]? {
        loadIfNeeded()
        guard !files.isEmpty else { lastError = "Add at least one file to the tray before sharing."; return nil }
        var result: [URL] = []
        for id in files.map(\.id) {
            guard let url = fileForAction(id) else { return nil }
            result.append(url)
        }
        return result
    }

    private func retainSharingAccess(_ urls: [URL]) {
        // Keep separate leases so removing a tray item cannot revoke an active share.
        sharingURLs = urls.compactMap { url in
            let scope = files.first(where: { sameFile($0.url, url) }).flatMap { scopedURLs[$0.id] } ?? url
            return scope.startAccessingSecurityScopedResource() ? scope : nil
        }
    }

    private func releaseSharingAccess() {
        sharingURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        sharingURLs.removeAll()
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        guard sharingPicker === sharingServicePicker else { return }
        sharingPicker = nil
        sharingService = service
        if service == nil { releaseSharingAccess() }
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> (any NSSharingServiceDelegate)? {
        sharingPicker === sharingServicePicker ? self : nil
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        guard self.sharingService === sharingService else { return }
        self.sharingService = nil
        releaseSharingAccess()
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        guard self.sharingService === sharingService else { return }
        self.sharingService = nil
        releaseSharingAccess()
        lastError = "Sharing failed: \(error.localizedDescription)"
    }

    // MARK: Timer

    func startTimer(seconds: Double) {
        loadIfNeeded()
        guard seconds.isFinite, seconds > 0, seconds <= CoveTimerState.maximumDuration else {
            lastError = "Choose a timer duration greater than zero and no longer than one year."
            return
        }
        removeTimerNotification()
        timerActivityIdentifier = UUID()
        timer = CoveTimerState(running: true, remaining: seconds, duration: seconds,
                               endsAt: Date().addingTimeInterval(seconds), notificationIdentifier: "OpenCove.timer.\(UUID().uuidString)")
        save(timer, as: "activity-timer.json")
        updateCountdown()
        scheduleTimerNotification()
    }

    func pauseTimer() {
        loadIfNeeded()
        updateTimer()
        guard timer.running else { return }
        removeTimerNotification()
        timer.running = false
        timer.endsAt = nil
        timer.notificationIdentifier = nil
        save(timer, as: "activity-timer.json")
        updateCountdown()
    }

    func resumeTimer() {
        loadIfNeeded()
        guard !timer.running, timer.remaining.isFinite, timer.remaining > 0,
              timer.remaining <= timer.duration, timer.duration <= CoveTimerState.maximumDuration else { return }
        timer.running = true
        timer.endsAt = Date().addingTimeInterval(timer.remaining)
        timer.notificationIdentifier = "OpenCove.timer.\(UUID().uuidString)"
        save(timer, as: "activity-timer.json")
        updateCountdown()
        scheduleTimerNotification()
    }

    func cancelTimer() {
        loadIfNeeded()
        removeTimerNotification()
        timerActivityIdentifier = UUID()
        timer = CoveTimerState()
        save(timer, as: "activity-timer.json")
        updateCountdown()
    }

    private func updateCountdown() {
        countdown?.invalidate()
        countdown = nil
        guard started, timer.running, let deadline = timer.endsAt else { return }
        // One absolute completion boundary. Mounted labels and native progress
        // read this same deadline without publishing second-by-second state.
        let ticker = Timer(fire: max(Date().addingTimeInterval(0.01), deadline), interval: 0,
                           repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.started else { return }
                self.updateTimer()
                self.updateCountdown()
            }
        }
        ticker.tolerance = 0
        RunLoop.main.add(ticker, forMode: .common)
        countdown = ticker
    }

    private func updateTimer() {
        guard timer.running, timer.endsAt != nil else { return }
        timer.remaining = timer.remaining(at: Date())
        guard timer.remaining == 0 else { return }
        timer.running = false
        timer.endsAt = nil
        // Persist completion before emitting the HUD and recording it in the queue.
        save(timer, as: "activity-timer.json")
        updateCountdown()
        enqueueNotification(title: "Timer finished", body: "Your OpenCove timer has finished.", source: "Timer", symbol: "timer")
    }

    private func handleClockChange() {
        guard started else { return }
        timerClockRevision &+= 1
        updateTimer()
        updateCountdown()
        refreshCalendar()
        scheduleTimerNotification()
    }

    // MARK: Notifications (OpenCove only)

    func postNotification(title: String, body: String) {
        loadIfNeeded()
        let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
        let body = String(body.prefix(4_096))
        guard !title.isEmpty || !body.isEmpty else { lastError = "Enter a notification title or message."; return }
        let value = enqueueNotification(title: title.isEmpty ? "OpenCove" : title, body: body, source: "OpenCove")
        sendNativeNotification(value)
    }

    func removeNotification(_ id: UUID) { notifications.removeAll { $0.id == id } }
    func clearNotifications() { notifications.removeAll() }

    @discardableResult
    private func enqueueNotification(title: String, body: String, source: String, symbol: String = "bell.fill") -> CoveNotification {
        let value = CoveNotification(title: title, body: body, source: source)
        notifications.insert(value, at: 0)
        if notifications.count > 100 { notifications.removeLast(notifications.count - 100) }
        if source != "Calendar" || calendarEnabled {
            onHUD?(CoveHUD(kind: .notification, title: title, subtitle: body, symbol: symbol,
                          origin: source == "Calendar" ? "calendar" : "app"))
        }
        return value
    }

    /// Explicit opt-in. Neither start() nor postNotification() requests permission.
    func requestNotificationAccess() {
        loadIfNeeded()
        guard authorizationTask == nil else { return }
        guard let center = nativeNotificationCenter else {
            lastError = "Native notifications require a packaged OpenCove app with a bundle identifier. The in-app notification queue remains available."
            return
        }
        authorizationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { self.authorizationTask = nil } }
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard !Task.isCancelled else { return }
                self.settings.nativeNotificationsEnabled = granted
                self.nativeNotificationsEnabled = granted
                self.save(self.settings, as: "activity-settings.json")
                self.refreshNotificationAuthorization()
                if granted { self.scheduleTimerNotification() }
                else {
                    self.removeTimerNotification()
                    self.lastError = "Native notifications were not granted. Enable OpenCove in System Settings → Notifications."
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.notificationAuthorization = "Unavailable"
                self.lastError = "Notification access failed: \(error.localizedDescription)"
            }
        }
    }

    func requestNotificationAuthorization() { requestNotificationAccess() }

    func setNativeNotificationsEnabled(_ enabled: Bool) {
        loadIfNeeded()
        if enabled { requestNotificationAccess(); return }
        settings.nativeNotificationsEnabled = false
        nativeNotificationsEnabled = false
        authorizationTask?.cancel()
        authorizationTask = nil
        notificationTasks.values.forEach { $0.cancel() }
        notificationTasks.removeAll()
        removeTimerNotification()
        save(settings, as: "activity-settings.json")
    }

    private var nativeNotificationCenter: UNUserNotificationCenter? {
        // UNUserNotificationCenter.current() can abort an unpackaged SwiftPM executable.
        guard Bundle.main.bundleURL.pathExtension == "app", !(Bundle.main.bundleIdentifier ?? "").isEmpty else {
            notificationAuthorization = "Unavailable — requires an app bundle"
            return nil
        }
        return UNUserNotificationCenter.current()
    }

    private func refreshNotificationAuthorization() {
        guard let center = nativeNotificationCenter else { return }
        runNotificationTask { [weak self] in
            let value = await center.notificationSettings()
            guard !Task.isCancelled, let self else { return }
            switch value.authorizationStatus {
            case .authorized: self.notificationAuthorization = "Authorized"
            case .provisional: self.notificationAuthorization = "Provisional"
            case .denied: self.notificationAuthorization = "Denied"
            case .notDetermined: self.notificationAuthorization = "Not requested"
            @unknown default: self.notificationAuthorization = "Unavailable"
            }
        }
    }

    private func runNotificationTask(_ operation: @escaping @MainActor () async -> Void) {
        let id = UUID()
        notificationTasks[id] = Task { @MainActor [weak self] in
            await operation()
            self?.notificationTasks.removeValue(forKey: id)
        }
    }

    private func sendNativeNotification(_ notification: CoveNotification) {
        guard nativeNotificationsEnabled, let center = nativeNotificationCenter else { return }
        runNotificationTask { [weak self] in
            let settings = await center.notificationSettings()
            guard !Task.isCancelled, let self, self.nativeNotificationsEnabled,
                  [.authorized, .provisional].contains(settings.authorizationStatus) else { return }
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            content.sound = .default
            let identifier = "OpenCove.message.\(notification.id.uuidString)"
            do {
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
                if Task.isCancelled || !self.nativeNotificationsEnabled {
                    center.removePendingNotificationRequests(withIdentifiers: [identifier])
                    center.removeDeliveredNotifications(withIdentifiers: [identifier])
                }
            } catch {
                if !Task.isCancelled { self.lastError = "Native notification failed: \(error.localizedDescription)" }
            }
        }
    }

    private func scheduleTimerNotification() {
        timerNotificationRevision += 1
        let revision = timerNotificationRevision
        guard timer.running, nativeNotificationsEnabled, let deadline = timer.endsAt,
              let identifier = timer.notificationIdentifier, let center = nativeNotificationCenter else { return }
        runNotificationTask { [weak self] in
            let settings = await center.notificationSettings()
            guard !Task.isCancelled, let self, self.nativeNotificationsEnabled, self.timer.running,
                  self.timerNotificationRevision == revision, self.timer.notificationIdentifier == identifier,
                  self.timer.endsAt == deadline,
                  [.authorized, .provisional].contains(settings.authorizationStatus), deadline > Date() else { return }
            let content = UNMutableNotificationContent()
            content.title = "Timer finished"
            content.body = "Your OpenCove timer has finished."
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, deadline.timeIntervalSinceNow), repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
                // A stale generation must not remove a newer opt-in's request with
                // the same saved ID. Current consent and timer identity decide cleanup.
                // A normal stop still retains an opted-in running timer across exit.
                if !self.nativeNotificationsEnabled || self.timer.notificationIdentifier != identifier {
                    center.removePendingNotificationRequests(withIdentifiers: [identifier])
                }
            } catch {
                if !Task.isCancelled, self.timerNotificationRevision == revision {
                    self.lastError = "Timer notification failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func removeTimerNotification(removeDelivered: Bool = true) {
        timerNotificationRevision += 1
        guard let identifier = timer.notificationIdentifier, Self.isTimerNotificationIdentifier(identifier),
              let center = nativeNotificationCenter else { return }
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        if removeDelivered { center.removeDeliveredNotifications(withIdentifiers: [identifier]) }
    }

    private static func isTimerNotificationIdentifier(_ identifier: String) -> Bool {
        let prefix = "OpenCove.timer."
        return identifier.hasPrefix(prefix) && UUID(uuidString: String(identifier.dropFirst(prefix.count))) != nil
    }

    // MARK: Explicitly authorized incoming URL notifications

    /// Returns a bearer token to the caller. The parent registers and forwards app URLs.
    /// Format: opencove://notify?token=<token>&title=<title>&body=<body>
    @discardableResult
    func enableIncomingURLAPI() -> String? {
        loadIfNeeded()
        if let token = settings.incomingURLToken { return token }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            lastError = "A secure notification API token could not be created. Try again."
            return nil
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        settings.incomingURLToken = token
        guard save(settings, as: "activity-settings.json") else { settings.incomingURLToken = nil; return nil }
        incomingURLAuthorization = "Authorized"
        return token
    }

    func disableIncomingURLAPI() {
        loadIfNeeded()
        settings.incomingURLToken = nil
        incomingURLAuthorization = "Disabled"
        save(settings, as: "activity-settings.json")
    }

    @discardableResult
    func handleIncomingURL(_ url: URL) -> Bool {
        loadIfNeeded()
        let registered = (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])?
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }.map { $0.lowercased() } ?? []
        guard (["opencove", "opencove-dev"] + registered).contains(url.scheme?.lowercased() ?? ""),
              url.host?.lowercased() == "notify" else { return false }
        guard url.absoluteString.utf8.count <= 20_000, ["", "/"].contains(url.path),
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            lastError = "Invalid notification API URL."
            return false
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard ["token", "title", "body"].contains(item.name), query[item.name] == nil else {
                lastError = "The notification URL contains unknown or duplicate parameters."
                return false
            }
            query[item.name] = item.value ?? ""
        }
        guard let expected = settings.incomingURLToken, let received = query["token"], tokensMatch(expected, received) else {
            lastError = "Notification URL access is disabled or its authorization token is invalid."
            return false
        }
        let title = query["title"] ?? ""
        let body = query["body"] ?? ""
        guard title.count <= 256, body.count <= 4_096,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !body.isEmpty else {
            lastError = "Provide a title of up to 256 characters or a message of up to 4096 characters."
            return false
        }
        postNotification(title: title, body: body)
        return true
    }

    @discardableResult
    func handleURL(_ url: URL) -> Bool { handleIncomingURL(url) }

    private func tokensMatch(_ expected: String, _ received: String) -> Bool {
        let a = Array(expected.utf8), b = Array(received.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    // MARK: Separate, private activity persistence (no source file content is copied)

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let value: ActivitySettings = load("activity-settings.json") { settings = value }
        if let token = settings.incomingURLToken,
           token.utf8.count != 64 || !token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
            settings.incomingURLToken = nil
            damagedPersistenceFiles.insert("activity-settings.json")
            lastError = "The saved notification API token is invalid. Enable the API again to create a new token."
        }
        nativeNotificationsEnabled = settings.nativeNotificationsEnabled
        incomingURLAuthorization = settings.incomingURLToken == nil ? "Disabled" : "Authorized"
        if let value: [TrayFile] = load("activity-tray.json") {
            if value.count > PersistenceLimits.trayCount {
                damagedPersistenceFiles.insert("activity-tray.json")
                lastError = "The saved file tray exceeds the \(PersistenceLimits.trayCount)-file limit. The original will be preserved before replacement."
            } else {
                var ids = Set<UUID>()
                files = value.filter { $0.url.isFileURL && ids.insert($0.id).inserted }
                if files.count != value.count {
                    damagedPersistenceFiles.insert("activity-tray.json")
                    lastError = "The saved file tray contained invalid or duplicate entries. Those entries were skipped; the original will be preserved before saving."
                }
            }
        }
        if let value: CoveTimerState = load("activity-timer.json") {
            let validNotificationID = value.notificationIdentifier.map(Self.isTimerNotificationIdentifier) ?? false
            guard value.duration.isFinite, value.remaining.isFinite, value.duration >= 0,
                  value.duration <= CoveTimerState.maximumDuration, value.remaining >= 0, value.remaining <= value.duration,
                  value.endsAt?.timeIntervalSinceReferenceDate.isFinite != false,
                  !value.running || (value.duration > 0 &&
                      value.endsAt.map { $0.timeIntervalSinceNow <= value.duration + 1 } == true) else {
                if validNotificationID, let identifier = value.notificationIdentifier, let center = nativeNotificationCenter {
                    center.removePendingNotificationRequests(withIdentifiers: [identifier])
                }
                damagedPersistenceFiles.insert("activity-timer.json")
                lastError = "The saved timer is invalid. Start a new timer to replace it."
                return
            }
            timer = value
            if !timer.running { timer.endsAt = nil }
            if timer.running && !validNotificationID {
                timer.notificationIdentifier = "OpenCove.timer.\(UUID().uuidString)"
                save(timer, as: "activity-timer.json")
            } else if !validNotificationID { timer.notificationIdentifier = nil }
        }
        // A pending native request can outlive the previous process. Missing or
        // unreadable consent must reconcile that saved, app-owned ID immediately.
        // This is synchronous: no late cleanup can delete a subsequent opt-in.
        if !nativeNotificationsEnabled { removeTimerNotification(removeDelivered: false) }
    }

    private func load<T: Decodable>(_ name: String) -> T? {
        let url = dataDirectory.appendingPathComponent(name)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno != ENOENT {
                damagedPersistenceFiles.insert(name)
                lastError = "Could not read \(name). The original file was left unchanged."
            }
            return nil
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        do {
            let limit = PersistenceLimits.bytes(for: name)
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= limit,
                  let data = try file.read(upToCount: limit + 1), data.count <= limit else { throw CocoaError(.fileReadCorruptFile) }
            return try JSONDecoder().decode(T.self, from: data)
        }
        catch {
            damagedPersistenceFiles.insert(name)
            lastError = "Could not read \(name): \(error.localizedDescription). The original will be preserved before replacement."
            return nil
        }
    }

    private func saveTray(_ proposed: [TrayFile]) -> Bool {
        guard proposed.count <= PersistenceLimits.trayCount else {
            lastError = "The file tray supports at most \(PersistenceLimits.trayCount) files. The previous tray was kept."
            return false
        }
        return save(proposed, as: "activity-tray.json")
    }

    @discardableResult
    private func save<T: Encodable>(_ value: T, as name: String) -> Bool {
        do {
            let data = try JSONEncoder().encode(value)
            guard data.count <= PersistenceLimits.bytes(for: name) else {
                if name == "activity-tray.json" {
                    throw ActivityError.message("The file tray exceeds its 16 MiB saved-data limit, including bookmarks. The previous tray was kept. Remove some tray files, then try again.")
                }
                throw ActivityError.message("The saved data exceeds the restart read limit. The previous file was kept.")
            }
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let url = dataDirectory.appendingPathComponent(name)
            if damagedPersistenceFiles.contains(name) {
                let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                if descriptor >= 0 {
                    let original = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                    defer { try? original.close() }
                    var info = stat()
                    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= PersistenceLimits.backupBytes else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    let originalData = try original.read(upToCount: PersistenceLimits.backupBytes + 1) ?? Data()
                    guard originalData.count <= PersistenceLimits.backupBytes, originalData.count == info.st_size else { throw CocoaError(.fileReadCorruptFile) }
                    let backup = dataDirectory.appendingPathComponent("\(name).recovery.\(UUID().uuidString)")
                    try writePrivateData(originalData, to: backup)
                    lastNotice = "The original \(name) was preserved as \(backup.lastPathComponent)."
                } else if errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                damagedPersistenceFiles.remove(name)
            }
            try writePrivateData(data, to: url)
            return true
        } catch {
            lastError = "Could not save \(name): \(error.localizedDescription)"
            return false
        }
    }

    private func writePrivateData(_ data: Data, to url: URL) throws {
        let temporary = dataDirectory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

/// No EventKit object leaves this worker. The main-actor store is used only for permission.
private final class CoveCalendarReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private final class CoveCalendarReader: @unchecked Sendable {
    struct Request {
        let gridRange: DateInterval
        let upcomingRange: DateInterval
        let excludedIdentifiers: Set<String>
        let showDeclinedEvents: Bool
        let excludeSubscribedCalendars: Bool
        let cancellation: CoveCalendarReadCancellation
    }

    struct Snapshot {
        var sources: [CoveCalendarSource] = []
        var gridEvents: [CoveEvent] = []
        var upcomingEvents: [CoveEvent] = []
    }

    private let queue = DispatchQueue(label: "org.opencove.calendar-reader", qos: .utility)
    // Access only on queue, including initialization and reset.
    private var store: EKEventStore?

    func read(_ request: Request) async -> Snapshot {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.readOnQueue(request)) }
        }
    }

    private func readOnQueue(_ request: Request) -> Snapshot {
        guard !request.cancellation.isCancelled,
              EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return Snapshot() }
        if store == nil { store = EKEventStore() }
        guard let store else { return Snapshot() }
        store.reset()
        let calendars = store.calendars(for: .event)
        let sources = calendars.map {
            CoveCalendarSource(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title,
                               colorHex: Self.colorHex($0.cgColor),
                               isExcluded: request.excludedIdentifiers.contains($0.calendarIdentifier))
        }.sorted {
            if $0.account != $1.account { return $0.account.localizedStandardCompare($1.account) == .orderedAscending }
            if $0.title != $1.title { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return $0.id < $1.id
        }
        let included = calendars.filter {
            !request.excludedIdentifiers.contains($0.calendarIdentifier)
                // isSubscribed also covers CalDAV subscriptions, whose type is .calDAV.
                && (!request.excludeSubscribedCalendars || !$0.isSubscribed)
        }
        // EventKit treats nil as all calendars; do not use nil/empty as an exclusion filter.
        guard !included.isEmpty else { return Snapshot(sources: sources) }
        let ranges: [DateInterval]
        if request.gridRange.intersects(request.upcomingRange) {
            ranges = [DateInterval(start: min(request.gridRange.start, request.upcomingRange.start),
                                   end: max(request.gridRange.end, request.upcomingRange.end))]
        } else { ranges = [request.gridRange, request.upcomingRange] }
        var seen = Set<String>()
        var values: [CoveEvent] = []
        for range in ranges {
            guard !request.cancellation.isCancelled,
                  EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return Snapshot() }
            let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: included)
            for event in store.events(matching: predicate) {
                guard !request.cancellation.isCancelled else { return Snapshot() }
                guard event.status != .canceled, let start = event.startDate, let end = event.endDate,
                      start.timeIntervalSinceReferenceDate.isFinite, end.timeIntervalSinceReferenceDate.isFinite,
                      end >= start, let source = event.calendar,
                      request.showDeclinedEvents
                        || !(event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false) else { continue }
                // Include source and occurrence start: recurring instances remain separate,
                // while overlapping queries cannot duplicate them. A moved start gets a new ID.
                let id = "\(source.calendarIdentifier):\(event.eventIdentifier ?? event.calendarItemIdentifier):\(start.timeIntervalSinceReferenceDate)"
                guard seen.insert(id).inserted else { continue }
                values.append(CoveEvent(id: id, title: event.title ?? "Untitled event", start: start, end: end,
                                        calendarName: source.title, colorHex: Self.colorHex(source.cgColor),
                                        location: event.location ?? event.structuredLocation?.title ?? "",
                                        meetingURL: ActivityController.meetingURL(in: event),
                                        timeZoneIdentifier: (event.timeZone ?? .current).identifier,
                                        isAllDay: event.isAllDay, calendarIdentifier: source.calendarIdentifier))
            }
        }
        values.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            let titleOrder = $0.title.localizedStandardCompare($1.title)
            return titleOrder == .orderedSame ? $0.id < $1.id : titleOrder == .orderedAscending
        }
        return Snapshot(sources: sources,
                        gridEvents: values.filter { ActivityController.overlaps($0, request.gridRange) },
                        upcomingEvents: values.filter { ActivityController.overlaps($0, request.upcomingRange) })
    }

    private static func colorHex(_ cgColor: CGColor?) -> String {
        guard let cgColor, let color = NSColor(cgColor: cgColor)?.usingColorSpace(.deviceRGB) else { return "#808080" }
        return String(format: "#%02X%02X%02X", Int((color.redComponent * 255).rounded()),
                      Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
    }
}
