import Foundation

/// Parsed from `battery status_csv`:
/// percentage,remaining_time,charging_status,discharging_status,maintain
public struct BatteryStatus: Equatable, Sendable {
    public var percentage: Int
    public var remainingTime: String
    public var charging: Bool          // smc charging status: "on"/"off"/...
    public var discharging: Bool       // actively discharging (adapter blocked)
    public var maintain: String?       // raw maintain value, e.g. "80", "70-80", "" when off
    public var lowPowerOn: Bool        // macOS Low Power Mode (via pmset)

    public init(percentage: Int, remainingTime: String, charging: Bool, discharging: Bool, maintain: String?, lowPowerOn: Bool = false) {
        self.percentage = percentage
        self.remainingTime = remainingTime
        self.charging = charging
        self.discharging = discharging
        self.maintain = maintain
        self.lowPowerOn = lowPowerOn
    }

    public var maintainRange: MaintainRange? {
        guard let maintain, !maintain.isEmpty, maintain != "off" else { return nil }
        return MaintainRange(cliValue: maintain)
    }
}

public enum BatteryStatusParser {
    /// Parses the single CSV line emitted by `battery status_csv`.
    public static func parseCSV(_ raw: String) throws -> BatteryStatus {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 4, let percentage = Int(fields[0]) else {
            throw CLIError.parseError("unexpected status_csv output: \(line)")
        }
        let chargingRaw = fields[2].lowercased()
        let dischargingRaw = fields[3].lowercased()
        let maintain = fields.count > 4 ? fields[4] : nil
        // Real CLI output uses "enabled"/"disabled" and "discharging"/"not discharging".
        return BatteryStatus(
            percentage: percentage,
            remainingTime: fields[1],
            charging: ["on", "yes", "true", "1", "enabled", "charging"].contains(chargingRaw),
            discharging: ["on", "yes", "true", "1", "enabled", "discharging"].contains(dischargingRaw),
            maintain: (maintain?.isEmpty == false) ? maintain : nil
        )
    }

    /// Parse the Low Power Mode state from full `pmset -g` output.
    /// Line-by-line parsing: regex anchors (^/$) do not reliably match
    /// mid-string lines in `String.range(of:options:.regularExpression)`,
    /// which made an earlier regex-based implementation always return false.
    public static func parseLowPowerMode(pmsetOutput: String) -> Bool {
        for line in pmsetOutput.components(separatedBy: "\n") where line.contains("lowpowermode") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.last == "1" { return true }
        }
        return false
    }

    /// Extract the integer value of a top-level `"Key" = N;` property from
    /// `ioreg -rn AppleSmartBattery` output. Nested occurrences (e.g. inside
    /// "BatteryData" = {...}) use `"Key"=N` without spaces around `=`, so
    /// requiring `" = ` avoids matching them.
    public static func parseIORegInt(_ key: String, from output: String) -> Int? {
        let needle = "\"\(key)\" = "
        for line in output.components(separatedBy: "\n") {
            guard let range = line.range(of: needle) else { continue }
            let value = line[range.upperBound...]
                .prefix(while: { $0.isNumber })
            if let int = Int(value) { return int }
        }
        return nil
    }
}

/// Charge limit, optionally a sailing range.
public struct MaintainRange: Equatable, Codable, Sendable {
    public var lower: Int
    public var upper: Int

    public init(lower: Int, upper: Int) {
        self.lower = min(lower, upper)
        self.upper = max(lower, upper)
    }

    public init(single: Int) {
        self.init(lower: single, upper: single)
    }

    public var isRange: Bool { lower != upper }

    /// "80" or "70-80"
    public var cliValue: String { isRange ? "\(lower)-\(upper)" : "\(upper)" }

    public var displayValue: String { isRange ? "\(lower)% – \(upper)%" : "\(upper)%" }

    public init?(cliValue: String) {
        let parts = cliValue.components(separatedBy: "-")
        switch parts.count {
        case 1:
            guard let v = Int(parts[0]) else { return nil }
            self.init(single: v)
        case 2:
            guard let lo = Int(parts[0]), let hi = Int(parts[1]) else { return nil }
            self.init(lower: lo, upper: hi)
        default:
            return nil
        }
    }

    public static func clamped(lower: Int, upper: Int) -> MaintainRange {
        MaintainRange(lower: max(1, min(100, lower)), upper: max(1, min(100, upper)))
    }
}

/// What the GUI believes is the active operating mode.
/// Derived from user intent (config) + observed CLI status.
public enum OperatingMode: Equatable, Sendable {
    case idle
    case maintaining(MaintainRange)
    case chargingTo(Int)
    case dischargingTo(Int)
    case calibrating
}

/// Behavior after a charge/discharge cycle completes.
public enum PostCompletionBehavior: String, Codable, CaseIterable, Sendable {
    case resumeMaintain
    case restoreDefault

    public var displayName: String {
        switch self {
        case .resumeMaintain: "Resume Maintain mode"
        case .restoreDefault: "Restore system default"
        }
    }
}

/// User preferences persisted in ~/.battery-keeper/config.json
public struct AppConfig: Codable, Sendable {
    public var maintainEnabled: Bool = false
    public var maintainRange: MaintainRange = .init(single: 80)
    public var sailingEnabled: Bool = false
    public var chargeTarget: Int = 100
    public var dischargeTarget: Int = 80
    public var chargeActive: Bool = false
    public var dischargeActive: Bool = false
    public var postCompletion: PostCompletionBehavior = .resumeMaintain
    public var launchAtLogin: Bool = false
    /// Show the battery percentage next to the menu bar icon.
    public var showPercentageInMenuBar: Bool = false

    public init() {}
}

/// App-level state directory. Keeps GUI state separate from the CLI's ~/.battery.
public enum StateDirectory {
    public static let url: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let current = home.appendingPathComponent(".battery-keeper")
        let legacy = home.appendingPathComponent(".battery-gui")
        // Migrate state from the pre-rename directory once.
        if !FileManager.default.fileExists(atPath: current.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: current)
        }
        return current
    }()

    public static var tasksFile: URL { url.appendingPathComponent("tasks.json") }
    public static var historyFile: URL { url.appendingPathComponent("history.json") }
    public static var configFile: URL { url.appendingPathComponent("config.json") }
    public static var calibrateStateFile: URL { url.appendingPathComponent("calibrate.state") }
    public static var helperLockFile: URL { url.appendingPathComponent("helper.lock") }

    public static func ensureExists() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

/// Generic JSON file store used by app and helper.
public enum JSONStore {
    public static func load<T: Decodable>(_ type: T.Type, from url: URL, default defaultValue: T) -> T {
        guard let data = try? Data(contentsOf: url) else { return defaultValue }
        return (try? JSONDecoder().decode(T.self, from: data)) ?? defaultValue
    }

    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try StateDirectory.ensureExists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
}
