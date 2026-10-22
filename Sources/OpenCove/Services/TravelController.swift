// SPDX-License-Identifier: MIT
import Combine
import CoreLocation
import CryptoKit
import Darwin
import Foundation
import MapKit

/// Routes only the events supplied by the calendar owner. No EventKit access,
/// location manager, or provider request is created by initialization.
@MainActor
final class TravelController: NSObject, ObservableObject {
    @Published private(set) var state = TravelState()
    private var hidePrivateDetails = false
    private var rawState = TravelState() {
        didSet { publishState() }
    }

    func setCalendarPrivacy(isLocked: Bool, hideSensitiveDetails: Bool) {
        hidePrivateDetails = isLocked && hideSensitiveDetails
        publishState()
    }

    private func publishState() {
        var visible = rawState
        if hidePrivateDetails {
            visible.eventTitle = visible.eventTitle.isEmpty ? "" : "Upcoming event"
            visible.destination = visible.destination.isEmpty ? "" : "Private location"
        }
        state = visible
    }
    @Published private(set) var lastError: String?
    @Published private(set) var status = "Time-to-leave alerts are off."
    @Published private(set) var isRequestingLocation = false
    @Published private(set) var isCalculating = false
    @Published private var settings = TravelSettings()

    var onHUD: ((CoveHUD) -> Void)?
    var mode: String { settings.mode.rawValue }
    var bufferMinutes: Double { settings.bufferMinutes }
    var hasOrigin: Bool { settings.origin != nil }
    var originLatitude: Double? { settings.origin?.latitude }
    var originLongitude: Double? { settings.origin?.longitude }
    var originSource: String { settings.origin?.source == "device" ? "Device location snapshot" : "Manual coordinates" }

    let dataDirectory: URL
    private var settingsFile: URL { dataDirectory.appendingPathComponent("travel-settings.json") }
    private var running = false
    private var events: [CoveEvent] = []
    private var selected: SelectedEvent?
    private var route: RouteResult?
    private var heartbeat: Timer?
    private var routeTask: Task<Void, Never>?
    private var routeTimeout: Task<Void, Never>?
    private var routeID = UUID()
    private var search: MKLocalSearch?
    private var directions: MKDirections?
    private var deadlineTask: Task<Void, Never>?
    private var deadlineID = UUID()
    private var scheduledDeadline: Date?
    private var locationManager: CLLocationManager?
    private var locationTimeout: Task<Void, Never>?
    private var locationFixRequested = false
    private var persistenceError: String?

    init(dataDirectory: URL? = nil) {
        if let dataDirectory {
            self.dataDirectory = dataDirectory.standardizedFileURL
        } else {
            self.dataDirectory = CovePaths.dataDirectory
        }
        super.init()
        loadSettings()
        rawState.enabled = settings.enabled
        status = settings.enabled ? "Waiting for the calendar and a saved origin." : "Time-to-leave alerts are off."
    }

    deinit { heartbeat?.invalidate() }

    func start() {
        guard !running else { return }
        running = true
        reconcileHeartbeat()
        // Saved enablement and a saved origin represent prior explicit consent.
        // Starting never creates a CLLocationManager or asks for location access.
        evaluate()
    }

    func stop() {
        running = false
        reconcileHeartbeat()
        clearRoute()
        cancelLocationRequest()
        events = []
        rawState = TravelState(enabled: settings.enabled)
        status = settings.enabled ? "Time-to-leave alerts are paused." : "Time-to-leave alerts are off."
    }

    func updateEvents(_ events: [CoveEvent]) {
        self.events = events
        evaluate()
    }

    func configure(enabled: Bool, mode: String, bufferMinutes: Double) {
        let requestedMode: CoveTravelMode? = mode == "driving" ? .automobile : CoveTravelMode(rawValue: mode)
        guard let requestedMode, bufferMinutes.isFinite, (0...120).contains(bufferMinutes) else {
            lastError = "Choose Driving or Walking and a buffer from 0 to 120 minutes."
            return
        }
        settings.enabled = enabled
        settings.mode = requestedMode
        settings.bufferMinutes = bufferMinutes
        reconcileHeartbeat()
        rawState.enabled = enabled
        lastError = nil
        if !enabled {
            cancelLocationRequest()
            clearRoute()
            rawState = TravelState()
            status = "Time-to-leave alerts are off."
        }
        saveSettings()
        evaluate()
    }

    /// The only entry point that creates Core Location or requests its permission.
    func requestLocation() {
        guard settings.enabled else {
            lastError = "Enable time-to-leave alerts before choosing an origin."
            return
        }
        guard !isRequestingLocation else { return }
        let usageKeys = ["NSLocationUsageDescription", "NSLocationWhenInUseUsageDescription"]
        guard usageKeys.contains(where: {
            !(Bundle.main.object(forInfoDictionaryKey: $0) as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            lastError = "This app bundle has no location permission description. Enter origin coordinates instead."
            return
        }
        lastError = persistenceError
        isRequestingLocation = true
        let manager = CLLocationManager()
        locationManager = manager
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, !Task.isCancelled, self.isRequestingLocation, self.locationManager === manager else { return }
            self.cancelLocationRequest()
            self.lastError = "Location took too long. Try again or enter origin coordinates."
        }
        continueLocationRequest(manager)
    }

    /// Saving coordinates is explicit origin consent; it does not enable alerts.
    func setOrigin(latitude: Double, longitude: Double) {
        guard settings.enabled else {
            lastError = "Enable time-to-leave alerts before choosing an origin."
            return
        }
        guard Self.validCoordinates(latitude, longitude) else {
            lastError = "Enter latitude from −90 to 90 and longitude from −180 to 180."
            return
        }
        acceptOrigin(latitude: latitude, longitude: longitude, source: "manual")
    }

    func clearOrigin() {
        cancelLocationRequest()
        clearRoute()
        settings.origin = nil
        rawState = TravelState(enabled: settings.enabled)
        lastError = nil
        saveSettings()
        evaluate()
    }

    private func acceptOrigin(latitude: Double, longitude: Double, source: String) {
        cancelLocationRequest()
        clearRoute()
        settings.origin = Origin(latitude: latitude, longitude: longitude, source: source,
                                 consented: true, selectedAt: Date())
        rawState = TravelState(enabled: settings.enabled)
        lastError = nil
        saveSettings()
        evaluate()
    }

    // MARK: Bounded route work and a separate, exact leave deadline

    private func reconcileHeartbeat() {
        guard running && settings.enabled else {
            heartbeat?.invalidate()
            heartbeat = nil
            return
        }
        guard heartbeat == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self, self.running, self.settings.enabled, self.heartbeat === timer else { return }
                self.evaluate()
            }
        }
        timer.tolerance = 2
        heartbeat = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func evaluate() {
        guard running else { return }
        guard settings.enabled else { status = "Time-to-leave alerts are off."; return }
        guard let origin = settings.origin, origin.consented else {
            clearRoute()
            rawState = TravelState(enabled: true)
            status = "Choose an origin to calculate travel time."
            return
        }
        let now = Date()
        if let attempt = settings.lastRouteAttempt, attempt.timeIntervalSince(now) > TravelState.freshnessInterval {
            settings.lastRouteAttempt = now
            saveSettings()
        }
        // Each calendar occurrence gets one deadline; all-day and started events do not.
        guard let next = events.filter({
            !$0.isAllDay && $0.start > now && $0.start <= now.addingTimeInterval(24 * 60 * 60)
                && $0.end > $0.start
        }).sorted(by: { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start })
            .compactMap({ event -> SelectedEvent? in
                guard let query = Self.destinationQuery(event.location) else { return nil }
                let key = Self.digest([event.id, String(event.start.timeIntervalSinceReferenceDate), query,
                                       String(origin.latitude), String(origin.longitude), settings.mode.rawValue])
                return SelectedEvent(event: event, query: query, key: key)
            }).first else {
            clearRoute()
            rawState = TravelState(enabled: true)
            lastError = persistenceError
            status = "No upcoming event with a physical location in the next 24 hours."
            return
        }
        if selected?.key != next.key {
            clearRoute()
            rawState = TravelState(enabled: true, eventTitle: next.event.title, destination: next.query)
            lastError = persistenceError
        }
        selected = next
        rawState.eventTitle = next.event.title

        if let route, route.key == next.key,
           (0..<TravelState.freshnessInterval).contains(now.timeIntervalSince(route.updatedAt)) {
            rawState.available = true
            rawState.destination = route.destination
            rawState.travelSeconds = route.seconds
            rawState.source = "Apple Maps"
            rawState.updatedAt = route.updatedAt
            rawState.leaveAt = next.event.start.addingTimeInterval(-route.seconds - settings.bufferMinutes * 60)
            status = "Route ready. The origin is a saved, fixed location."
            scheduleDeadline()
            emitIfDue(now: now)
            return
        }

        // A stale ETA may remain as historical data, but cannot drive an alert.
        rawState.available = false
        rawState.leaveAt = nil
        cancelDeadline()
        guard !isCalculating else { return }
        if let lastAttempt = settings.lastRouteAttempt,
           now.timeIntervalSince(lastAttempt) < TravelState.freshnessInterval {
            let retry = lastAttempt.addingTimeInterval(TravelState.freshnessInterval)
            status = "Waiting for the next route check at \(retry.formatted(date: .omitted, time: .shortened))."
            return
        }
        calculateRoute(for: next, origin: origin)
    }

    private func calculateRoute(for selected: SelectedEvent, origin: Origin) {
        // Reserve the attempt before any provider work, including failed searches.
        settings.lastRouteAttempt = Date()
        saveSettings()
        lastError = persistenceError
        isCalculating = true
        status = "Finding the event location in Apple Maps…"
        let id = UUID()
        routeID = id
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = selected.query // Never the title, notes, body, or meeting URL.
        request.resultTypes = [.address, .pointOfInterest]
        request.region = MKCoordinateRegion(center: origin.coordinate, latitudinalMeters: 100_000,
                                             longitudinalMeters: 100_000)
        let search = MKLocalSearch(request: request)
        self.search = search
        routeTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.routeID == id, self.isCalculating else { return }
            self.cancelRouteWork()
            self.lastError = "Apple Maps took too long. No leave alert will use an expired route."
            self.status = "Route unavailable. Another attempt is allowed after 15 minutes."
        }
        routeTask = Task { [weak self] in
            do {
                let response = try await search.start()
                try Task.checkCancellation()
                guard let self, self.routeID == id, self.selected?.key == selected.key else { return }
                guard let destination = response.mapItems.first(where: {
                    CLLocationCoordinate2DIsValid($0.placemark.coordinate)
                }) else { throw RouteFailure.noDestination }

                let request = MKDirections.Request()
                request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
                request.destination = destination
                request.transportType = self.settings.mode == .walking ? .walking : .automobile
                request.requestsAlternateRoutes = false
                request.arrivalDate = selected.event.start
                let directions = MKDirections(request: request)
                self.directions = directions
                self.status = "Calculating travel time with Apple Maps…"
                let result = try await directions.calculate()
                try Task.checkCancellation()
                guard self.routeID == id, self.selected?.key == selected.key else { return }
                let routeTimes: [TimeInterval] = result.routes.map { $0.expectedTravelTime }
                let validRouteTimes = routeTimes.filter { seconds in
                    seconds.isFinite && seconds > 0 && seconds <= 604_800.0
                }
                guard let eta = validRouteTimes.min() else { throw RouteFailure.noRoute }
                let address = destination.placemark.title ?? destination.name ?? selected.query
                self.route = RouteResult(key: selected.key, destination: String(address.prefix(300)),
                                         seconds: eta, updatedAt: Date())
                self.finishRouteWork(id: id)
                self.lastError = self.persistenceError
                self.evaluate()
            } catch {
                guard !Task.isCancelled, let self, self.routeID == id else { return }
                self.finishRouteWork(id: id)
                // Provider error descriptions can contain query text or URLs. Do not expose or log them.
                self.lastError = (error as? RouteFailure)?.message
                    ?? "Apple Maps could not calculate travel time. Check the event address and your connection."
                self.status = "Route unavailable. Another attempt is allowed after 15 minutes."
                self.rawState.available = false
                self.rawState.leaveAt = nil
                self.cancelDeadline()
            }
        }
    }

    private func finishRouteWork(id: UUID) {
        guard routeID == id else { return }
        routeTimeout?.cancel()
        routeTimeout = nil
        routeTask = nil
        search = nil
        directions = nil
        isCalculating = false
    }

    private func cancelRouteWork() {
        routeID = UUID()
        routeTask?.cancel()
        routeTimeout?.cancel()
        search?.cancel()
        directions?.cancel()
        routeTask = nil
        routeTimeout = nil
        search = nil
        directions = nil
        isCalculating = false
    }

    private func clearRoute() {
        cancelRouteWork()
        cancelDeadline()
        selected = nil
        route = nil
    }

    private func scheduleDeadline() {
        guard let deadline = rawState.leaveAt, deadline > Date() else { cancelDeadline(); return }
        guard scheduledDeadline != deadline else { return }
        cancelDeadline()
        let id = UUID()
        deadlineID = id
        scheduledDeadline = deadline
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) } catch { return }
            guard let self, !Task.isCancelled, self.deadlineID == id, self.scheduledDeadline == deadline else { return }
            self.scheduledDeadline = nil
            self.deadlineTask = nil
            // Rechecks consent, event changes, ETA age, and the deadline after sleep/wake.
            self.evaluate()
        }
    }

    private func cancelDeadline() {
        deadlineID = UUID()
        deadlineTask?.cancel()
        deadlineTask = nil
        scheduledDeadline = nil
    }

    private func emitIfDue(now: Date) {
        guard rawState.available, !rawState.isStale, let selected,
              let deadline = rawState.leaveAt, deadline <= now, selected.event.start > now else { return }
        let key = Self.digest([selected.event.id, String(selected.event.start.timeIntervalSinceReferenceDate)])
        guard settings.notifiedDeadlines[key] == nil else { status = "The leave alert for this event was sent."; return }
        guard let onHUD else { return }
        // Persist before calling the owner. ETA/buffer changes do not repeat this occurrence's alert.
        settings.notifiedDeadlines = settings.notifiedDeadlines.filter { $0.value > now.addingTimeInterval(-86_400) }
        if settings.notifiedDeadlines.count >= 128,
           let oldest = settings.notifiedDeadlines.min(by: { $0.value < $1.value })?.key {
            settings.notifiedDeadlines.removeValue(forKey: oldest)
        }
        settings.notifiedDeadlines[key] = selected.event.start
        saveSettings()
        status = "Time to leave."
        let minutes = Int(ceil(rawState.travelSeconds / 60))
        onHUD(CoveHUD(kind: .notification, title: "Time to leave",
                      subtitle: hidePrivateDetails ? "An upcoming event needs travel time." : "\(selected.event.title) · \(minutes) min \(settings.mode == .walking ? "walk" : "drive") + \(Int(settings.bufferMinutes)) min buffer",
                      symbol: settings.mode.symbol, origin: "calendar"))
    }

    // MARK: Explicit, one-shot origin acquisition

    private func continueLocationRequest(_ manager: CLLocationManager) {
        guard settings.enabled, isRequestingLocation, locationManager === manager else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            guard !locationFixRequested else { return }
            locationFixRequested = true
            manager.requestLocation()
        case .denied, .restricted:
            cancelLocationRequest()
            if settings.origin?.source == "device" { clearOrigin() }
            lastError = "Location access is off. Enter origin coordinates, or allow OpenCove in Location Services."
        @unknown default:
            cancelLocationRequest()
            lastError = "Device location is unavailable. Enter origin coordinates instead."
        }
    }

    private func cancelLocationRequest() {
        locationTimeout?.cancel()
        locationTimeout = nil
        locationManager?.stopUpdatingLocation()
        locationManager?.delegate = nil
        locationManager = nil
        locationFixRequested = false
        isRequestingLocation = false
    }

    // MARK: Minimal destination text; never extract or send calendar notes

    private static func destinationQuery(_ location: String) -> String? {
        guard !location.isEmpty, location.utf8.count <= 2_048 else { return nil }
        var text = location
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            if let range = Range(match.range, in: text) { text.replaceSubrange(range, with: " ") }
        }
        let online = #"(?i)\b(online|virtual|remote|zoom|teams|webex|skype|facetime|google\s+(meet|hangouts)|hangouts|slack|chime|whereby|ringcentral|gotomeeting|jitsi|meeting\s+id|passcode|password|dial[ -]?in|join|video|webinar|conference\s+call|phone|teleconference|telephone|tbd|to\s+be\s+determined)\b"#
        let linkLabels: Set<String> = ["meeting", "location", "link", "call", "conference", "details", "here",
                                       "with", "at", "via", "on", "to", "the", "open", "click"]
        let separators = CharacterSet.newlines.union(CharacterSet(charactersIn: ";|•"))
        let parts = text.components(separatedBy: separators).compactMap { part -> String? in
            let value = part.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",–—-")))
            let coordinateParts = value.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let isCoordinatePair: Bool
            if coordinateParts.count == 2, let latitude = Double(coordinateParts[0]), let longitude = Double(coordinateParts[1]) {
                isCoordinatePair = validCoordinates(latitude, longitude)
            } else { isCoordinatePair = false }
            let words = value.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
            let onlyLinkLabel = !words.isEmpty && words.allSatisfy { linkLabels.contains($0) }
            guard value.rangeOfCharacter(from: .letters) != nil || isCoordinatePair,
                  !onlyLinkLabel,
                  value.range(of: online, options: .regularExpression) == nil,
                  value.range(of: #"(?i)^(meeting|location|link|call|video)\s*[:\-]?$"#, options: .regularExpression) == nil,
                  !value.contains("://"), value.count <= 300 else { return nil }
            return value
        }
        let query = parts.prefix(3).joined(separator: ", ")
        return query.isEmpty || query.count > 300 ? nil : query
    }

    private static func validCoordinates(_ latitude: Double, _ longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    private static func digest(_ fields: [String]) -> String {
        SHA256.hash(data: Data(fields.joined(separator: "\u{1f}").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Private settings only, with a private temporary file before atomic replacement

    private func loadSettings() {
        guard FileManager.default.fileExists(atPath: settingsFile.path) else { return }
        let descriptor = Darwin.open(settingsFile.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { reportStorageFailure(); return }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_size <= 65_536, fchmod(descriptor, 0o600) == 0,
                  let data = try file.read(upToCount: 65_537), data.count <= 65_536 else { throw RouteFailure.storage }
            let value = try JSONDecoder().decode(TravelSettings.self, from: data)
            guard value.bufferMinutes.isFinite, (0...120).contains(value.bufferMinutes),
                  value.notifiedDeadlines.count <= 128,
                  value.notifiedDeadlines.allSatisfy({ $0.key.count == 64 && $0.value.timeIntervalSinceReferenceDate.isFinite }),
                  value.lastRouteAttempt?.timeIntervalSinceReferenceDate.isFinite != false else { throw RouteFailure.storage }
            if let origin = value.origin {
                guard origin.consented, Self.validCoordinates(origin.latitude, origin.longitude),
                      ["manual", "device"].contains(origin.source), origin.selectedAt.timeIntervalSinceReferenceDate.isFinite else {
                    throw RouteFailure.storage
                }
            }
            settings = value
            // A clock correction cannot postpone all future requests indefinitely.
            if let attempt = settings.lastRouteAttempt, attempt.timeIntervalSinceNow > TravelState.freshnessInterval {
                settings.lastRouteAttempt = Date()
            }
        } catch {
            settings = TravelSettings()
            reportStorageFailure()
        }
        try? file.close()
    }

    private func saveSettings() {
        let temporary = dataDirectory.appendingPathComponent(".travel-\(UUID().uuidString).tmp")
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(settings)
            let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw RouteFailure.storage }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer {
                try? file.close()
                try? FileManager.default.removeItem(at: temporary)
            }
            guard fchmod(descriptor, 0o600) == 0 else { throw RouteFailure.storage }
            try file.write(contentsOf: data)
            try file.synchronize()
            guard Darwin.rename(temporary.path, settingsFile.path) == 0 else { throw RouteFailure.storage }
            if lastError == persistenceError { lastError = nil }
            persistenceError = nil
        } catch { reportStorageFailure() }
    }

    private func reportStorageFailure() {
        persistenceError = "Travel settings could not be saved or read privately. Changes and alert deduplication may last only for this session."
        lastError = persistenceError
    }

    private struct TravelSettings: Codable {
        var enabled = false
        var mode = CoveTravelMode.automobile
        var bufferMinutes: Double = 10
        var origin: Origin?
        var lastRouteAttempt: Date?
        var notifiedDeadlines: [String: Date] = [:]
    }

    private struct Origin: Codable {
        let latitude: Double
        let longitude: Double
        let source: String
        let consented: Bool
        let selectedAt: Date
        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    }

    private struct SelectedEvent {
        let event: CoveEvent
        let query: String
        let key: String
    }

    private struct RouteResult {
        let key: String
        let destination: String
        let seconds: TimeInterval
        let updatedAt: Date
    }

    private enum RouteFailure: Error {
        case noDestination, noRoute, storage
        var message: String {
            switch self {
            case .noDestination: return "Apple Maps found no destination. Add a street address or place name to the event location."
            case .noRoute: return "Apple Maps found no route for this travel mode. Check the destination or choose another mode."
            case .storage: return "Travel settings could not be stored privately."
            }
        }
    }
}

extension TravelController: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.continueLocationRequest(manager) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in
            guard let self, self.settings.enabled, self.isRequestingLocation, self.locationManager === manager else { return }
            guard let fix = locations.last(where: {
                $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 5_000
                    && abs($0.timestamp.timeIntervalSinceNow) < 5 * 60
                    && CLLocationCoordinate2DIsValid($0.coordinate)
            }) else {
                self.cancelLocationRequest()
                self.lastError = "A recent location was not available. Try again or enter origin coordinates."
                return
            }
            self.acceptOrigin(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude, source: "device")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.isRequestingLocation, self.locationManager === manager else { return }
            let denied = (error as? CLError)?.code == .denied
            self.cancelLocationRequest()
            if denied, self.settings.origin?.source == "device" { self.clearOrigin() }
            self.lastError = denied
                ? "Location access is off. Enter origin coordinates, or allow OpenCove in Location Services."
                : "Device location failed. Try again or enter origin coordinates."
        }
    }
}
