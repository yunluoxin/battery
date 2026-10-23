import Foundation

/// Parsed from `battery status_csv`:
/// percentage,remaining_time,charging_status,discharging_status,maintain,
/// adapter_attached,low_power_enabled,live_power_state,charging_control_backend
public struct BatteryStatus: Equatable, Sendable {
    public var percentage: Int
    public var remainingTime: String
    /// Whether the pack is taking charge right now.
    ///
    /// This is deliberately *not* the CSV's third column, which comes from
    /// `CH0B`/`CHTE` — the flag `CHARGING_ON`/`CHARGING_OFF` write. That one
    /// answers "is charging allowed", so it reads "enabled" on any healthy
    /// machine, charging or not, and a menu bar that trusted it drew a bolt
    /// on a laptop running unplugged. What counts is the live-state column
    /// added in CLI v1.3.7; `ProcessBatteryCLI` re-derives it from pmset when
    /// the installed CLI is older than that.
    public var charging: Bool
    /// Whether the pack is actively losing charge right now — on its own
    /// power, which is a different thing from being blocked from charging
    /// with the adapter still plugged in.
    public var discharging: Bool
    public var maintain: String?       // raw maintain value, e.g. "80", "70-80", "" when off
    public var lowPowerOn: Bool        // macOS Low Power Mode
    /// Whether a power adapter is attached, regardless of whether the pack is
    /// taking charge. The two are independent: a full pack, or one parked at
    /// the top of a maintain band, sits on AC without charging — and that is
    /// exactly the state the system battery icon marks with a plug.
    public var adapterAttached: Bool
    /// Nil means the CLI did not report a recognized charging-control backend.
    public var chargingControlAvailable: Bool?

    public init(percentage: Int, remainingTime: String, charging: Bool, discharging: Bool, maintain: String?, lowPowerOn: Bool = false, adapterAttached: Bool = false, chargingControlAvailable: Bool? = nil) {
        self.percentage = percentage
        self.remainingTime = remainingTime
        self.charging = charging
        self.discharging = discharging
        self.maintain = maintain
        self.lowPowerOn = lowPowerOn
        self.adapterAttached = adapterAttached
        self.chargingControlAvailable = chargingControlAvailable
    }

    /// Whether the CLI that produced this status predates v1.3.6 and left the
    /// adapter and low-power columns out.
    ///
    /// Their absence is not an answer of "no": the caller has to read pmset
    /// itself. Carried on the status so the fallback can be decided from the
    /// parsed line rather than by inspecting the raw output a second time.
    public var powerColumnsMissing: Bool = false

    /// Whether the CLI that produced this status predates v1.3.7 and left the
    /// live-state column out, which leaves `charging` and `discharging`
    /// undecided rather than answered.
    public var liveStateColumnMissing: Bool = false

    /// On AC but not charging: the state the system icon draws with a plug.
    public var pluggedInNotCharging: Bool { adapterAttached && !charging }

    /// Whether charge is moving into the pack right now, which is the one
    /// thing the menu bar's bolt is allowed to claim.
    ///
    /// The adapter is part of the question, not just the flag: nothing charges
    /// without one. That includes a charge cycle switched on with nothing
    /// plugged in — the request stands and the CLI waits for an adapter to
    /// turn up, but no current is flowing, so a bolt there would be claiming
    /// something that is not happening.
    public var isChargingNow: Bool { adapterAttached && charging }

    public var maintainRange: MaintainRange? {
        guard let maintain, !maintain.isEmpty, maintain != "off" else { return nil }
        return MaintainRange(cliValue: maintain)
    }

    /// The countdown, or nil when the CLI reported no duration.
    ///
    /// `battery status_csv` fills that column with `awk '{print $5}'` over the
    /// `pmset -g batt` line, which only lines up with a duration while the pack
    /// is running:
    ///
    ///     71%; discharging; 4:11 remaining present: true   → "4:11"
    ///     71%; AC attached; not charging present: true     → "attached;"
    ///
    /// So on AC the field holds a scrap of pmset's own prose. That word is not
    /// a duration and must not reach the UI as one — callers show the adapter
    /// state instead.
    public var timeRemaining: String? {
        let trimmed = remainingTime.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // H:MM, or H:MM:SS for the longer estimates. Anything containing a
        // non-digit is prose, not a clock.
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else { return nil }
        return trimmed
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
        let maintain = fields.count > 4 ? fields[4] : nil
        // Columns 6 and 7 arrived in CLI v1.3.6. Their absence means an older
        // binary is installed, not that the answer is "no": the caller falls
        // back to reading pmset itself when they are missing.
        let adapterAttached = fields.count > 5 ? fields[5] == "1" : false
        let lowPowerOn = fields.count > 6 ? fields[6] == "1" : false
        // Column 8 arrived in v1.3.7 and supersedes columns 3 and 4 for the
        // live state: it carries pmset's own state word, where the other two
        // carry the charging permission flags.
        let liveState = fields.count > 7 ? fields[7].lowercased() : ""
        let chargingControlAvailable: Bool?
        if fields.count > 8 {
            chargingControlAvailable = switch fields[8].lowercased() {
            case "legacy", "tahoe", "native": true
            case "unsupported", "unavailable": false
            default: nil
            }
        } else {
            chargingControlAvailable = fields[2].lowercased() == "unknown" ? false : nil
        }
        // Columns 3 and 4 say whether charging and discharging are *allowed*.
        // With no live column to go on, both flags stay off rather than
        // falling back to them: an unknown state has to read as "not
        // charging", and defaulting the other way is what put a permanent
        // bolt on the menu bar. `ProcessBatteryCLI` fills both in from pmset
        // for a CLI older than v1.3.7.
        var status = BatteryStatus(
            percentage: percentage,
            remainingTime: fields[1],
            charging: liveState == LivePowerState.charging.rawValue,
            discharging: liveState == LivePowerState.discharging.rawValue,
            maintain: (maintain?.isEmpty == false) ? maintain : nil,
            lowPowerOn: lowPowerOn,
            adapterAttached: adapterAttached,
            chargingControlAvailable: chargingControlAvailable
        )
        status.powerColumnsMissing = fields.count <= 6
        status.liveStateColumnMissing = liveState.isEmpty
        return status
    }

    /// What the pack is doing right now, as opposed to whether it is allowed
    /// to. The cases a substring match gets wrong are both here: the pack
    /// blocked on AC reports "not charging", which contains "charging", and a
    /// full pack on AC reports "charged", which is neither.
    public enum LivePowerState: String, Sendable {
        case charging
        case discharging
        /// On AC and not filling, or full, or blocked. Everything that is not
        /// one of the two states above.
        case idle
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

    /// Whether an adapter is attached, from `pmset -g batt` output. macOS
    /// appends "; AC attached" to the battery line when it is on AC, and names
    /// the source in the header line ("Now drawing from 'AC Power'").
    public static func parseAdapterAttached(pmsetOutput: String) -> Bool {
        pmsetOutput.contains("AC attached") || pmsetOutput.contains("AC Power")
    }

    /// Read the live power state out of `pmset -g batt`, matching the CLI's
    /// own helper so the two agree word for word.
    public static func parseLivePowerState(pmsetBattOutput: String) -> LivePowerState {
        for line in pmsetBattOutput.components(separatedBy: "\n") where line.contains("InternalBattery") {
            var previous = ""
            for token in line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == ";" }) {
                let word = token.lowercased()
                // `previous` rather than a plain word match, so "not
                // charging" stays the idle case it is.
                if previous != "not", let state = LivePowerState(rawValue: word), state != .idle {
                    return state
                }
                previous = word
            }
        }
        return .idle
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

    /// Battery health: how much charge the pack can still hold, as a
    /// percentage of the capacity it was built with.
    ///
    /// `AppleRawMaxCapacity` is what the pack holds now and `DesignCapacity`
    /// is what it held when new, both in mAh. `MaxCapacity` is NOT the
    /// figure for this: it reads 100 on a pack at any charge level above the
    /// maintain band, because it is scaled to the current charge, not to the
    /// design capacity. A pack is only past its design capacity when macOS
    /// recalibrates it, so a value slightly over 100 is real and shown as is.
    public static func parseHealthPercent(from output: String) -> Int? {
        guard let maxCap = parseIORegInt("AppleRawMaxCapacity", from: output),
              let designCap = parseIORegInt("DesignCapacity", from: output),
              designCap > 0
        else { return nil }
        return Int((Double(maxCap) / Double(designCap) * 100).rounded())
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

/// The two charge/discharge cycles the GUI drives through one switcher and one
/// target slider.
///
/// They are mutually exclusive, but each keeps its own level: switching a
/// toggle on means "do this cycle", not "run the level the other cycle was
/// left on".
public enum BatteryCycle: String, CaseIterable, Sendable {
    case charge
    case discharge

    /// Level the cycle runs to when its toggle is switched on. Topping up means
    /// a full battery; discharging is only worth starting from below full, so
    /// its target stops well short of 100.
    public var defaultTarget: Int {
        switch self {
        case .charge: 100
        case .discharge: 40
        }
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
public struct AppConfig: Codable, Equatable, Sendable {
    public var maintainEnabled: Bool = false
    public var maintainRange: MaintainRange = .init(single: 80)
    public var sailingEnabled: Bool = false
    public var chargeTarget: Int = BatteryCycle.charge.defaultTarget
    public var dischargeTarget: Int = BatteryCycle.discharge.defaultTarget
    public var chargeActive: Bool = false
    public var dischargeActive: Bool = false
    public var postCompletion: PostCompletionBehavior = .resumeMaintain
    /// Scheduled task results are opt-in because macOS asks for notification permission.
    public var scheduledTaskNotifications: Bool = false
    public var launchAtLogin: Bool = false
    /// Show the battery percentage next to the menu bar icon.
    public var showPercentageInMenuBar: Bool = true
    /// Remove the menu bar item entirely instead of drawing it with an empty
    /// icon. Default false, i.e. the icon is shown (current behaviour).
    public var hideStatusBarIcon: Bool = false
    /// UI language. `.system` is the default so a fresh install follows the
    /// Mac's own language list without the user visiting Settings first.
    public var language: AppLanguage = .system
    /// Switch Low Power Mode on by itself once the charge level reaches
    /// `autoLowPowerThreshold`. Off by default: macOS may already do this on
    /// some hardware, so the rule is opt-in.
    public var autoLowPower: Bool = false
    /// Charge level that fires the rule, as a percentage.
    public var autoLowPowerThreshold: Int = AutoLowPowerRule.defaultThreshold

    public init() {}

    /// Tolerant decoding: a config written by an older build is missing newer
    /// keys, and the synthesised decoder throws on a missing key, which would
    /// silently reset *every* preference back to the defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decode(T.self, forKey: key)) ?? fallback
        }
        maintainEnabled = get(.maintainEnabled, false)
        maintainRange = get(.maintainRange, .init(single: 80))
        sailingEnabled = get(.sailingEnabled, false)
        chargeTarget = get(.chargeTarget, BatteryCycle.charge.defaultTarget)
        dischargeTarget = get(.dischargeTarget, BatteryCycle.discharge.defaultTarget)
        chargeActive = get(.chargeActive, false)
        dischargeActive = get(.dischargeActive, false)
        postCompletion = get(.postCompletion, .resumeMaintain)
        scheduledTaskNotifications = get(.scheduledTaskNotifications, false)
        launchAtLogin = get(.launchAtLogin, false)
        showPercentageInMenuBar = get(.showPercentageInMenuBar, true)
        hideStatusBarIcon = get(.hideStatusBarIcon, false)
        // An unknown raw value (a language this build does not ship, written by
        // a newer one) decodes to nil and lands on .system rather than
        // throwing away the rest of the config with it.
        language = get(.language, .system)
        autoLowPower = get(.autoLowPower, false)
        // Clamped on the way in: a hand-edited config could otherwise park the
        // stepper outside the range it offers and leave the row unreadable.
        autoLowPowerThreshold = AutoLowPowerRule.clamp(get(.autoLowPowerThreshold, AutoLowPowerRule.defaultThreshold))
    }

    /// The range sent to the CLI: the full sailing band when sailing is on,
    /// otherwise just the upper limit.
    public var effectiveRange: MaintainRange {
        sailingEnabled ? maintainRange : MaintainRange(single: maintainRange.upper)
    }

    /// The level stored for one cycle.
    public func target(for cycle: BatteryCycle) -> Int {
        switch cycle {
        case .charge: chargeTarget
        case .discharge: dischargeTarget
        }
    }

    /// Store a level for one cycle, leaving the other cycle's level alone.
    public mutating func setTarget(_ value: Int, for cycle: BatteryCycle) {
        switch cycle {
        case .charge: chargeTarget = value
        case .discharge: dischargeTarget = value
        }
    }
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
