import Foundation

public struct NativeQuietHours: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let startMinute: Int
    public let endMinute: Int
    public let timezone: String
    public let days: [Int]

    public init(enabled: Bool, startMinute: Int, endMinute: Int, timezone: String, days: [Int]) throws {
        guard (0..<1440).contains(startMinute), (0..<1440).contains(endMinute),
              startMinute != endMinute, TimeZone(identifier: timezone) != nil,
              !days.isEmpty, days.allSatisfy({ (1...7).contains($0) }),
              Set(days).count == days.count else {
            throw HorizonError.message("Choose different quiet-hour times, a valid time zone and at least one weekday.")
        }
        self.enabled = enabled
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.timezone = timezone
        self.days = days.sorted()
    }

    public func isQuiet(at date: Date) throws -> Bool {
        guard date.timeIntervalSince1970.isFinite, let zone = TimeZone(identifier: timezone) else {
            throw HorizonError.message("Quiet hours cannot be evaluated for this date or time zone.")
        }
        guard enabled else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        guard let hour = parts.hour, let minute = parts.minute, let weekday = parts.weekday else {
            throw HorizonError.message("Quiet hours could not resolve the local calendar.")
        }
        let now = hour * 60 + minute
        let isoDay = ((weekday + 5) % 7) + 1
        if startMinute < endMinute {
            return days.contains(isoDay) && now >= startMinute && now < endMinute
        }
        if now >= startMinute { return days.contains(isoDay) }
        if now < endMinute { return days.contains(isoDay == 1 ? 7 : isoDay - 1) }
        return false
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, timezone, days
        case startMinute = "start_minute"
        case endMinute = "end_minute"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(enabled: values.decode(Bool.self, forKey: .enabled),
            startMinute: values.decode(Int.self, forKey: .startMinute),
            endMinute: values.decode(Int.self, forKey: .endMinute),
            timezone: values.decode(String.self, forKey: .timezone),
            days: values.decode([Int].self, forKey: .days))
    }
}

public struct NativeDevicePreferences: Codable, Equatable, Sendable {
    public let revision: Int
    public let cameraSnoozeUntil: [String: Double]
    public var quietHours: NativeQuietHours?
    public var healthAlerts: Bool

    public init(revision: Int, cameraSnoozeUntil: [String: Double],
                quietHours: NativeQuietHours?, healthAlerts: Bool) throws {
        guard revision >= 0, cameraSnoozeUntil.allSatisfy({
            NativeNotificationRoute.isValidIdentifier($0.key) && $0.value.isFinite && $0.value >= 0
        }) else { throw HorizonError.message("The server returned invalid notification preferences.") }
        self.revision = revision
        self.cameraSnoozeUntil = cameraSnoozeUntil
        self.quietHours = quietHours
        self.healthAlerts = healthAlerts
    }

    private enum CodingKeys: String, CodingKey {
        case revision
        case cameraSnoozeUntil = "camera_snooze_until"
        case quietHours = "quiet_hours"
        case healthAlerts = "health_alerts"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(revision: values.decode(Int.self, forKey: .revision),
            cameraSnoozeUntil: values.decode([String: Double].self, forKey: .cameraSnoozeUntil),
            quietHours: values.decodeIfPresent(NativeQuietHours.self, forKey: .quietHours),
            healthAlerts: values.decode(Bool.self, forKey: .healthAlerts))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(revision, forKey: .revision)
        try values.encode(cameraSnoozeUntil, forKey: .cameraSnoozeUntil)
        try values.encode(quietHours, forKey: .quietHours)
        try values.encode(healthAlerts, forKey: .healthAlerts)
    }
}

public struct NativeCameraSnoozeBody: Encodable, Sendable {
    public let cameraID: String
    public let seconds: Int
    private enum CodingKeys: String, CodingKey { case cameraID = "camera_id"; case seconds }

    public init(cameraID: String, seconds: Int) throws {
        guard NativeNotificationRoute.isValidIdentifier(cameraID), [0, 900, 3600].contains(seconds) else {
            throw HorizonError.message("Choose an available camera and a supported snooze duration.")
        }
        self.cameraID = cameraID
        self.seconds = seconds
    }
}

public struct NativeHealthIssue: Decodable, Identifiable, Sendable {
    public enum Severity: String, Decodable, Sendable { case critical, warning, info }
    public let id: String
    public let kind: String
    public let camera: String?
    public let severity: Severity
    public let title: String
    public let detail: String
    public let firstSeen: Double
    enum CodingKeys: String, CodingKey {
        case id, kind, camera, severity, title, detail
        case firstSeen = "first_seen"
    }
}

public struct NativeHealthSnapshot: Decodable, Sendable {
    public let sampledAt: Double
    public let checksComplete: Bool
    public let issues: [NativeHealthIssue]
    enum CodingKeys: String, CodingKey {
        case sampledAt = "sampled_at"
        case checksComplete = "checks_complete"
        case issues
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sampledAt = try values.decode(Double.self, forKey: .sampledAt)
        checksComplete = try values.decode(Bool.self, forKey: .checksComplete)
        issues = try values.decode([NativeHealthIssue].self, forKey: .issues)
        guard sampledAt.isFinite, sampledAt > 0, Set(issues.map(\.id)).count == issues.count, issues.allSatisfy({
            NativeNotificationRoute.isValidIdentifier($0.id) && !$0.title.isEmpty
                && $0.firstSeen.isFinite && $0.firstSeen >= 0
                && $0.camera.map(NativeNotificationRoute.isValidIdentifier) != false
        }) else {
            throw DecodingError.dataCorruptedError(forKey: .issues, in: values,
                debugDescription: "Health data has invalid identifiers, timestamps or labels.")
        }
    }
}
