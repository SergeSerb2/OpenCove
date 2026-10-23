import Foundation

struct CoveEvent: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var calendarName: String
    var colorHex: String
    var location: String
    var meetingURL: URL?
    var timeZoneIdentifier: String = TimeZone.current.identifier
    var isAllDay: Bool = false
    var calendarIdentifier: String = ""

    var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? .current }
}

struct TrayFile: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var url: URL
    var name: String
    var bookmarkData: Data? = nil
    var isAvailable: Bool = true
    var accessError: String? = nil

    private enum CodingKeys: String, CodingKey {
        case id, url, name, bookmarkData, isAvailable, accessError
    }

    init(id: UUID = UUID(), url: URL, name: String, bookmarkData: Data? = nil,
         isAvailable: Bool = true, accessError: String? = nil) {
        self.id = id
        self.url = url
        self.name = name
        self.bookmarkData = bookmarkData
        self.isAvailable = isAvailable
        self.accessError = accessError
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        url = try values.decode(URL.self, forKey: .url)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? url.lastPathComponent
        bookmarkData = try values.decodeIfPresent(Data.self, forKey: .bookmarkData)
        isAvailable = try values.decodeIfPresent(Bool.self, forKey: .isAvailable) ?? true
        accessError = try values.decodeIfPresent(String.self, forKey: .accessError)
    }
}

struct CoveTimerState: Codable, Equatable {
    static let maximumDuration: TimeInterval = 31_536_000
    var running: Bool = false
    var remaining: Double = 0
    var duration: Double = 0
    var endsAt: Date? = nil
    // A distinct identifier prevents a late notification request from reviving a cancelled timer.
    var notificationIdentifier: String? = nil

    /// The deadline stays authoritative while running. Reading it does not
    /// publish a new service state or require a mounted countdown view.
    func remaining(at date: Date) -> Double {
        let value = running ? endsAt?.timeIntervalSince(date) ?? remaining : remaining
        guard value.isFinite, duration.isFinite else { return 0 }
        return min(max(0, duration), max(0, value))
    }

    func snapshot(at date: Date = Date()) -> Self {
        var value = self
        value.remaining = remaining(at: date)
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case running, remaining, duration, endsAt, notificationIdentifier
    }

    init(running: Bool = false, remaining: Double = 0, duration: Double = 0,
         endsAt: Date? = nil, notificationIdentifier: String? = nil) {
        self.running = running
        self.remaining = remaining
        self.duration = duration
        self.endsAt = endsAt
        self.notificationIdentifier = notificationIdentifier
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        running = try values.decodeIfPresent(Bool.self, forKey: .running) ?? false
        remaining = try values.decodeIfPresent(Double.self, forKey: .remaining) ?? 0
        duration = try values.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        endsAt = try values.decodeIfPresent(Date.self, forKey: .endsAt)
        notificationIdentifier = try values.decodeIfPresent(String.self, forKey: .notificationIdentifier)
    }
}

struct CoveNotification: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var body: String
    var date: Date = Date()
    var source: String = "OpenCove"
}
