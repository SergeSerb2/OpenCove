// SPDX-License-Identifier: MIT
import Combine
import CoreLocation
import Darwin
import Foundation

/// Open-Meteo conditions and forecasts. No location manager or network request is
/// created until the user selects a location. `start()` can reuse that consent.
@MainActor
final class WeatherController: NSObject, ObservableObject {
    @Published private(set) var state = WeatherState()
    @Published private(set) var lastError: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isRequestingLocation = false
    private(set) var requestAttempts: UInt64 = 0
    @Published private var selection: WeatherLocation?

    var hasLocation: Bool { selection != nil }
    var latitude: Double? { selection?.latitude }
    var longitude: Double? { selection?.longitude }
    var locationName: String { selection?.name ?? "" }

    private var isRunning = false
    private var requestTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var locationTimeout: Task<Void, Never>?
    private var locationManager: CLLocationManager?
    private var locationFixRequested = false
    private var requestID = UUID()
    private var persistenceError: String?
    private let refreshInterval: TimeInterval = 15 * 60

    private var locationFile: URL {
        CovePaths.dataDirectory.appendingPathComponent("weather-location.json")
    }

    override init() {
        super.init()
        // Reading a prior explicit choice does not contact Core Location or a server.
        let descriptor = Darwin.open(locationFile.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno != ENOENT { lastError = "The saved weather location could not be read. Choose a location again." }
            return
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= 65_536,
                  let data = try file.read(upToCount: 65_537), data.count <= 65_536 else { throw CocoaError(.fileReadCorruptFile) }
            let saved = try JSONDecoder().decode(WeatherLocation.self, from: data)
            guard saved.consented, Self.validCoordinates(saved.latitude, saved.longitude),
                  saved.name.count <= 120, saved.name.utf8.count <= 1_024 else {
                lastError = "The saved weather location is invalid. Choose a location again."
                return
            }
            selection = saved
            state.locationName = saved.name
        } catch {
            lastError = "The saved weather location could not be read. Choose a location again."
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        guard hasLocation else { return }
        refresh()
        scheduleRefreshes()
    }

    func stop() {
        isRunning = false
        refreshTask?.cancel()
        refreshTask = nil
        cancelRequest()
        cancelLocationRequest()
        state = WeatherState()
    }

    /// This is the only entry point that creates or requests Core Location.
    /// Location permission is never requested by `start()`, `refresh()`, or a view.
    func requestLocation() {
        guard isRunning else { lastError = "Enable weather before requesting a location."; return }
        guard !isRequestingLocation else { return }
        let usageKeys = ["NSLocationUsageDescription", "NSLocationWhenInUseUsageDescription"]
        guard usageKeys.contains(where: {
            !(Bundle.main.object(forInfoDictionaryKey: $0) as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            lastError = "Device location needs the installed app's location permission description. Enter coordinates instead."
            return
        }

        lastError = nil
        isRequestingLocation = true
        let manager = locationManager ?? CLLocationManager()
        locationManager = manager
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        locationTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, !Task.isCancelled, self.isRequestingLocation, self.locationManager === manager else { return }
            self.cancelLocationRequest()
            self.lastError = "Location took too long. Try again or enter coordinates."
        }
        continueLocationRequest(manager)
    }

    func setLocation(latitude: Double, longitude: Double, name: String) {
        guard Self.validCoordinates(latitude, longitude) else {
            lastError = "Enter a latitude from −90 to 90 and a longitude from −180 to 180."
            return
        }
        cancelLocationRequest()
        cancelRequest()
        // Bound scalars as well as characters: one grapheme can contain a very
        // large combining-mark sequence supplied through the control interface.
        let boundedName = String(String.UnicodeScalarView(name.unicodeScalars.prefix(256)))
        let cleanedName = String(boundedName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        let displayName = cleanedName.isEmpty
            ? String(format: "%.2f°, %.2f°", latitude, longitude)
            : cleanedName
        selection = WeatherLocation(latitude: latitude, longitude: longitude, name: displayName, consented: true)
        // Never show the previous location's conditions under the new name.
        state = WeatherState(locationName: displayName)
        persistenceError = nil
        do {
            try FileManager.default.createDirectory(at: CovePaths.dataDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(selection)
            let temporary = locationFile.deletingLastPathComponent().appendingPathComponent(".weather-\(UUID().uuidString).tmp")
            let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? file.close(); try? FileManager.default.removeItem(at: temporary) }
            try file.write(contentsOf: data)
            try file.synchronize()
            try file.close()
            guard Darwin.rename(temporary.path, locationFile.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            persistenceError = "Weather works for this session, but the location could not be saved: \(error.localizedDescription)"
        }
        lastError = persistenceError
        if isRunning {
            refresh()
            scheduleRefreshes()
        }
    }

    /// Removes the saved consent and stops all weather and location work.
    @discardableResult
    func clearLocation() -> Bool {
        let wasRunning = isRunning
        stop()
        selection = nil
        state = WeatherState()
        persistenceError = nil
        lastError = nil
        do {
            // unlink removes the entry itself, including a dangling link, and
            // never follows it into another location.
            if Darwin.unlink(locationFile.path) != 0, errno != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            lastError = "The saved weather location could not be removed: \(error.localizedDescription)"
        }
        // Keep the feature gate, without any work until a new explicit selection.
        if wasRunning { start() }
        return lastError == nil
    }

    func refresh() {
        guard isRunning else { lastError = "Enable weather before refreshing it."; return }
        guard let selected = selection else {
            lastError = "Choose a location to enable weather."
            return
        }
        guard !isLoading else { return }
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        // Official API: https://open-meteo.com/en/docs
        // Current conditions are model data; Unix timestamps avoid timezone ambiguity.
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(selected.latitude)),
            URLQueryItem(name: "longitude", value: String(selected.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day,apparent_temperature,relative_humidity_2m,wind_speed_10m"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,is_day,precipitation_probability"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,weather_code,precipitation_probability_max,sunrise,sunset,daylight_duration"),
            URLQueryItem(name: "temperature_unit", value: "celsius"),
            URLQueryItem(name: "wind_speed_unit", value: "kmh"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_hours", value: "24"),
            URLQueryItem(name: "forecast_days", value: "7")
        ]
        guard let url = components.url else {
            lastError = "The weather request could not be created."
            return
        }
        let id = UUID()
        requestID = id
        isLoading = true
        lastError = persistenceError
        requestTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                self?.requestAttempts &+= 1
                let result = try await CoveWeatherDownload().load(request)
                try Task.checkCancellation()
                let current = result.current
                guard current.temperature.isFinite, (-150...100).contains(current.temperature), current.time.isFinite,
                      current.time > 0, current.time <= Date().timeIntervalSince1970 + 15 * 60,
                      (0...1).contains(current.isDay) else {
                    throw CoveWeatherFailure.invalidResponse
                }
                let condition = Self.condition(for: current.code, isDay: current.isDay == 1)
                let forecast = Self.forecast(from: result)
                guard let self, self.isRunning, self.requestID == id, self.selection == selected else { return }
                self.state = WeatherState(
                    locationName: selected.name,
                    temperature: current.temperature,
                    condition: condition.name,
                    symbol: condition.symbol,
                    updatedAt: Date(timeIntervalSince1970: current.time),
                    available: true,
                    apparentTemperature: Self.valid(current.apparent, in: -200...150),
                    humidity: Self.valid(current.humidity, in: 0...100),
                    windSpeed: Self.valid(current.wind, in: 0...500),
                    timeZoneIdentifier: forecast.zone,
                    hourly: forecast.hours, daily: forecast.days, forecastNotice: forecast.notice
                )
                self.lastError = self.persistenceError
            } catch {
                guard !Task.isCancelled, let self, self.requestID == id else { return }
                if error is DecodingError {
                    self.lastError = "Open-Meteo returned weather data that could not be read. Try again later."
                } else {
                    self.lastError = error.localizedDescription
                }
                // Keep a successful same-location result visible with its original time.
            }
            guard let self, self.requestID == id else { return }
            self.isLoading = false
            self.requestTask = nil
        }
    }

    private func scheduleRefreshes() {
        guard isRunning, hasLocation, refreshTask == nil else { return }
        refreshTask = Task { [weak self, refreshInterval] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(refreshInterval)) } catch { return }
                guard let self, self.isRunning, self.hasLocation else { return }
                self.refresh()
            }
        }
    }

    private func cancelRequest() {
        requestID = UUID()
        requestTask?.cancel()
        requestTask = nil
        isLoading = false
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

    private func continueLocationRequest(_ manager: CLLocationManager) {
        guard isRequestingLocation, locationManager === manager else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            guard !locationFixRequested else { return }
            locationFixRequested = true
            manager.requestLocation()
        case .denied, .restricted:
            cancelLocationRequest()
            lastError = "Location access is off. Enable OpenCove in Privacy & Security → Location Services, or enter coordinates."
        @unknown default:
            cancelLocationRequest()
            lastError = "Device location is unavailable. Enter coordinates instead."
        }
    }

    private static func validCoordinates(_ latitude: Double, _ longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    private static func valid(_ value: Double?, in range: ClosedRange<Double>) -> Double? {
        guard let value, value.isFinite, range.contains(value) else { return nil }
        return value
    }

    private static func forecast(from response: CoveWeatherResponse)
        -> (zone: String, hours: [WeatherHour], days: [WeatherDay], notice: String?) {
        guard let identifier = response.timezone, identifier.utf8.count <= 128,
              let zone = TimeZone(identifier: identifier), let offset = response.utcOffset,
              (-64_800...64_800).contains(offset), let fixedZone = TimeZone(secondsFromGMT: offset) else {
            return ("UTC", [], [], "The forecast time zone is unavailable. Try refreshing later.")
        }
        let now = Date().timeIntervalSince1970
        var hours: [WeatherHour] = []
        if let values = response.hourly, values.time.count <= 48,
           values.temperature.count == values.time.count, values.code.count == values.time.count,
           values.isDay.count == values.time.count, values.precipitation.count == values.time.count {
            var previous = -Double.infinity
            for index in values.time.indices {
                let time = values.time[index]
                guard time.isFinite, time > previous, time >= response.current.time - 3_600,
                      time <= now + 2 * 86_400 else { continue }
                previous = time
                let daylight = values.isDay[index]
                let condition = condition(for: daylight == 0 || daylight == 1 ? values.code[index] ?? -1 : -1,
                                          isDay: daylight == 1)
                hours.append(WeatherHour(date: Date(timeIntervalSince1970: time),
                                         temperature: valid(values.temperature[index], in: -150...100),
                                         condition: condition.name, symbol: condition.symbol,
                                         precipitationProbability: valid(values.precipitation[index], in: 0...100)))
                if hours.count == 24 { break }
            }
        }
        var days: [WeatherDay] = []
        if let values = response.daily, values.time.count <= 16,
           [values.minimum.count, values.maximum.count, values.code.count, values.precipitation.count,
            values.sunrise.count, values.sunset.count].allSatisfy({ $0 == values.time.count }) {
            var providerCalendar = Calendar(identifier: .gregorian)
            providerCalendar.timeZone = fixedZone
            var localCalendar = Calendar(identifier: .gregorian)
            localCalendar.timeZone = zone
            var previous = -Double.infinity
            for index in values.time.indices {
                let time = values.time[index]
                guard time.isFinite, time > previous, time >= now - 2 * 86_400,
                      time <= now + 9 * 86_400 else { continue }
                previous = time
                // Daily boundaries use the provider's fixed request-time offset.
                // Rebuild its civil date locally so a DST change cannot label
                // tomorrow's forecast as the previous evening.
                var components = providerCalendar.dateComponents([.year, .month, .day],
                                                                 from: Date(timeIntervalSince1970: time))
                components.hour = 12
                guard let date = localCalendar.date(from: components) else { continue }
                let condition = condition(for: values.code[index] ?? -1, isDay: true)
                var low = valid(values.minimum[index], in: -150...100)
                var high = valid(values.maximum[index], in: -150...100)
                if let minimum = low, let maximum = high, minimum > maximum { low = nil; high = nil }
                func sunTime(_ raw: Double?) -> Date? {
                    guard let raw, raw.isFinite, raw > 0, abs(raw - time) < 2 * 86_400 else { return nil }
                    return Date(timeIntervalSince1970: raw)
                }
                let daylight = values.daylightDuration.flatMap { durations -> Double? in
                    guard durations.count == values.time.count else { return nil }
                    return valid(durations[index], in: 0...86_400)
                }
                var sunrise = sunTime(values.sunrise[index]), sunset = sunTime(values.sunset[index])
                // At the poles the provider can use midnight boundaries for an
                // all-day interval. Those boundaries are not sunrise/set events.
                if daylight == 0 || daylight == 86_400 {
                    sunrise = nil; sunset = nil
                } else if let rise = sunrise, let setting = sunset,
                          setting <= rise || setting.timeIntervalSince(rise) >= 86_400 {
                    sunrise = nil; sunset = nil
                }
                days.append(WeatherDay(date: date, minimum: low, maximum: high,
                                       condition: condition.name, symbol: condition.symbol,
                                       precipitationProbability: valid(values.precipitation[index], in: 0...100),
                                       sunrise: sunrise, sunset: sunset, daylightDuration: daylight))
                if days.count == 7 { break }
            }
        }
        let incomplete = hours.count < 24 || days.count < 7
            || hours.contains { $0.temperature == nil || $0.precipitationProbability == nil || $0.condition == "Unknown conditions" }
            || days.contains { $0.minimum == nil || $0.maximum == nil || $0.precipitationProbability == nil || $0.condition == "Unknown conditions" }
        return (identifier, hours, days,
                incomplete ? "Some forecast data is unavailable. Try refreshing later." : nil)
    }

    private static func condition(for code: Int, isDay: Bool) -> (name: String, symbol: String) {
        switch code {
        case 0: return ("Clear", isDay ? "sun.max.fill" : "moon.stars.fill")
        case 1: return ("Mostly clear", isDay ? "sun.max.fill" : "moon.fill")
        case 2: return ("Partly cloudy", isDay ? "cloud.sun.fill" : "cloud.moon.fill")
        case 3: return ("Overcast", "cloud.fill")
        case 45: return ("Fog", "cloud.fog.fill")
        case 48: return ("Freezing fog", "cloud.fog.fill")
        case 51: return ("Light drizzle", "cloud.drizzle.fill")
        case 53: return ("Drizzle", "cloud.drizzle.fill")
        case 55: return ("Heavy drizzle", "cloud.drizzle.fill")
        case 56, 57: return ("Freezing drizzle", "cloud.sleet.fill")
        case 61: return ("Light rain", "cloud.rain.fill")
        case 63: return ("Rain", "cloud.rain.fill")
        case 65: return ("Heavy rain", "cloud.heavyrain.fill")
        case 66, 67: return ("Freezing rain", "cloud.sleet.fill")
        case 71: return ("Light snow", "cloud.snow.fill")
        case 73: return ("Snow", "cloud.snow.fill")
        case 75: return ("Heavy snow", "cloud.snow.fill")
        case 77: return ("Snow grains", "cloud.snow.fill")
        case 80: return ("Light rain showers", "cloud.rain.fill")
        case 81: return ("Rain showers", "cloud.rain.fill")
        case 82: return ("Heavy rain showers", "cloud.heavyrain.fill")
        case 85, 86: return ("Snow showers", "cloud.snow.fill")
        case 95: return ("Thunderstorm", "cloud.bolt.rain.fill")
        case 96, 99: return ("Thunderstorm with hail", "cloud.bolt.rain.fill")
        case 97: return ("Heavy thunderstorm", "cloud.bolt.rain.fill")
        default: return ("Unknown conditions", "cloud")
        }
    }

    private struct WeatherLocation: Codable, Equatable {
        let latitude: Double
        let longitude: Double
        let name: String
        let consented: Bool
    }

}

private struct CoveWeatherResponse: Decodable, Sendable {
    let current: Current
    let timezone: String?
    let utcOffset: Int?
    let hourly: Hourly?
    let daily: Daily?

    enum CodingKeys: String, CodingKey {
        case current, timezone, hourly, daily
        case utcOffset = "utc_offset_seconds"
    }

    struct Current: Decodable, Sendable {
        let time: Double
        let temperature: Double
        let code: Int
        let isDay: Int
        let apparent: Double?
        let humidity: Double?
        let wind: Double?

        enum CodingKeys: String, CodingKey {
            case time
            case temperature = "temperature_2m"
            case code = "weather_code"
            case isDay = "is_day"
            case apparent = "apparent_temperature"
            case humidity = "relative_humidity_2m"
            case wind = "wind_speed_10m"
        }
    }

    struct Hourly: Decodable, Sendable {
        let time: [Double]
        let temperature: [Double?]
        let code: [Int?]
        let isDay: [Int?]
        let precipitation: [Double?]
        enum CodingKeys: String, CodingKey {
            case time
            case temperature = "temperature_2m"
            case code = "weather_code"
            case isDay = "is_day"
            case precipitation = "precipitation_probability"
        }
    }

    struct Daily: Decodable, Sendable {
        let time: [Double]
        let minimum: [Double?]
        let maximum: [Double?]
        let code: [Int?]
        let precipitation: [Double?]
        let sunrise: [Double?]
        let sunset: [Double?]
        let daylightDuration: [Double?]?
        enum CodingKeys: String, CodingKey {
            case time, sunrise, sunset
            case daylightDuration = "daylight_duration"
            case minimum = "temperature_2m_min"
            case maximum = "temperature_2m_max"
            case code = "weather_code"
            case precipitation = "precipitation_probability_max"
        }
    }
}

private enum CoveWeatherFailure: LocalizedError {
    case invalidResponse
    case responseTooLarge
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Open-Meteo returned an invalid weather response. Try again later."
        case .responseTooLarge: return "Open-Meteo returned more than the 64 KiB weather response limit. Try again later."
        case .http(429): return "Open-Meteo's request limit was reached. Try again in a few minutes."
        case .http(let status): return "Open-Meteo is unavailable (HTTP \(status)). Try again later."
        }
    }
}

/// Conditions and the bounded 24-hour/7-day forecast need only a small body. Limit declared bytes and
/// received body bytes to 64 KiB, including unknown-length/chunked responses and
/// bytes after URLSession's content decoding. Never use its whole-body data API.
/// URLSession still owns its network buffers; this bounds our accumulated body.
private final class CoveWeatherDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let maximumResponseBytes = 64 * 1024
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CoveWeatherResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var body = Data()
    private var acceptedResponse = false
    private var finished = false

    func load(_ request: URLRequest) async throws -> CoveWeatherResponse {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                // Cancellation can arrive before the continuation is installed.
                guard !finished else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                // No persisted URL cache, cookies, or credentials for coordinates.
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 20
                configuration.timeoutIntervalForResource = 30
                configuration.urlCache = nil
                configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil
                let queue = OperationQueue()
                queue.name = "OpenCove.weather.response"
                queue.maxConcurrentOperationCount = 1
                queue.qualityOfService = .utility
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                let task = session.dataTask(with: request)
                self.session = session
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(CoveWeatherFailure.invalidResponse))
            return
        }
        if response.expectedContentLength > Int64(Self.maximumResponseBytes) {
            completionHandler(.cancel)
            finish(.failure(CoveWeatherFailure.responseTooLarge))
            return
        }
        if let declared = http.value(forHTTPHeaderField: "Content-Length") {
            guard let bytes = UInt64(declared.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                completionHandler(.cancel)
                finish(.failure(CoveWeatherFailure.invalidResponse))
                return
            }
            guard bytes <= UInt64(Self.maximumResponseBytes) else {
                completionHandler(.cancel)
                finish(.failure(CoveWeatherFailure.responseTooLarge))
                return
            }
        }
        guard (200...299).contains(http.statusCode) else {
            // Error bodies never enter the accumulator, regardless of their size.
            completionHandler(.cancel)
            finish(.failure(CoveWeatherFailure.http(http.statusCode)))
            return
        }
        lock.lock()
        let allow = !finished
        if allow { acceptedResponse = true }
        lock.unlock()
        completionHandler(allow ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Consent names this provider; do not forward coordinates to a redirect.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished, acceptedResponse else { lock.unlock(); return }
        // Check before append. This also handles a compressed body whose decoded
        // bytes exceed its declared wire size, and a body with no Content-Length.
        guard data.count <= Self.maximumResponseBytes - body.count else {
            lock.unlock()
            finish(.failure(CoveWeatherFailure.responseTooLarge))
            return
        }
        body.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        let data = body
        let accepted = acceptedResponse
        lock.unlock()
        if let error { finish(.failure(error)); return }
        guard accepted else { finish(.failure(CoveWeatherFailure.invalidResponse)); return }
        // This serial utility delegate queue, never the main actor, decodes only
        // the bounded body. Cancellation can discard the result during decoding.
        finish(Result { try JSONDecoder().decode(CoveWeatherResponse.self, from: data) })
    }

    private func finish(_ result: Result<CoveWeatherResponse, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = continuation, session = session, task = task
        self.continuation = nil
        self.session = nil
        self.task = nil
        body = Data()
        lock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}

extension WeatherController: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.continueLocationRequest(manager) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in
            guard let self, self.isRequestingLocation, self.locationManager === manager else { return }
            guard let location = locations.last(where: {
                $0.horizontalAccuracy >= 0 && abs($0.timestamp.timeIntervalSinceNow) < 5 * 60
                    && CLLocationCoordinate2DIsValid($0.coordinate)
            }) else {
                self.cancelLocationRequest()
                self.lastError = "A recent device location was not available. Try again or enter coordinates."
                return
            }
            // One-time lookup, rounded before transmission and persistence. No geocoding call.
            let latitude = (location.coordinate.latitude * 100).rounded() / 100
            let longitude = (location.coordinate.longitude * 100).rounded() / 100
            self.setLocation(latitude: latitude, longitude: longitude, name: "Current location")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.isRequestingLocation, self.locationManager === manager else { return }
            self.cancelLocationRequest()
            self.lastError = "Device location failed: \(error.localizedDescription). You can enter coordinates instead."
        }
    }
}
