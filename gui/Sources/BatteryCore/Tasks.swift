import Foundation

/// A scheduled task stored in ~/.battery-gui/tasks.json
public struct ScheduledTask: Codable, Equatable, Identifiable, Sendable {
    public enum Action: String, Codable, CaseIterable, Sendable {
        case maintain        // set charge limit (param = "80" or "70-80")
        case topup           // charge to 100 once
        case discharge       // discharge to param %
        case calibrate       // start calibration cycle
        case lowpower        // toggle low power mode (param = "on"/"off")

        public var displayName: String {
            switch self {
            case .maintain: "Set Charge Limit"
            case .topup: "Top Up to 100%"
            case .discharge: "Discharge To…"
            case .calibrate: "Start Calibration"
            case .lowpower: "Low Power Mode"
            }
        }
    }

    public enum ScheduleType: String, Codable, CaseIterable, Sendable {
        case daily
        case weekdays        // Mon-Fri
        case weekly          // specific weekdays, see weekdays array

        public var displayName: String {
            switch self {
            case .daily: "Daily"
            case .weekdays: "Weekdays"
            case .weekly: "Weekly"
            }
        }
    }

    public var id: UUID
    public var name: String
    public var action: Action
    /// Action parameter: percentage ("80"), range ("70-80"), or "on"/"off" for lowpower.
    public var param: String
    public var schedule: ScheduleType
    public var hour: Int
    public var minute: Int
    /// For .weekly: weekdays 1=Sun … 7=Sat (launchd convention). Multiple allowed.
    public var weekdays: [Int]
    public var enabled: Bool
    public var lastRun: Date?
    public var lastResult: String?    // "ok" or error summary

    public init(
        id: UUID = UUID(),
        name: String,
        action: Action,
        param: String = "",
        schedule: ScheduleType,
        hour: Int,
        minute: Int,
        weekdays: [Int] = [],
        enabled: Bool = true,
        lastRun: Date? = nil,
        lastResult: String? = nil
    ) {
        self.id = id
        self.name = name
        self.action = action
        self.param = param
        self.schedule = schedule
        self.hour = hour
        self.minute = minute
        self.weekdays = weekdays
        self.enabled = enabled
        self.lastRun = lastRun
        self.lastResult = lastResult
    }

    /// One-line summary shown in the task list.
    public var summary: String {
        let time = String(format: "%02d:%02d", hour, minute)
        let when: String
        switch schedule {
        case .daily:
            when = "Daily \(time)"
        case .weekdays:
            when = "Weekdays \(time)"
        case .weekly:
            let names = weekdays.sorted().map { Self.weekdayShortName($0) }.joined(separator: " ")
            when = "\(names) \(time)"
        }
        let what: String = switch action {
        case .maintain: "Limit \(param)%"
        case .topup: "Top Up"
        case .discharge: "Discharge to \(param)%"
        case .calibrate: "Calibrate"
        case .lowpower: "Low Power \(param)"
        }
        return "\(what) · \(when)"
    }

    public static func weekdayShortName(_ day: Int) -> String {
        ["?", "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"][min(max(day, 0), 7)]
    }
}

public struct TaskList: Codable, Sendable {
    public var tasks: [ScheduledTask] = []
    public init(tasks: [ScheduledTask] = []) {
        self.tasks = tasks
    }
}

/// One entry per task execution, appended by the helper.
public struct HistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var taskID: UUID
    public var taskName: String
    public var date: Date
    public var success: Bool
    public var output: String        // trimmed CLI output
    public var note: String?         // e.g. "overrode: charging-to-90"

    public init(id: UUID = UUID(), taskID: UUID, taskName: String, date: Date = Date(), success: Bool, output: String, note: String? = nil) {
        self.id = id
        self.taskID = taskID
        self.taskName = taskName
        self.date = date
        self.success = success
        self.output = output
        self.note = note
    }
}

public struct History: Codable, Sendable {
    public var entries: [HistoryEntry] = []
    public init() {}

    /// Keep history bounded.
    public static let maxEntries = 500

    public mutating func append(_ entry: HistoryEntry) {
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }
}
