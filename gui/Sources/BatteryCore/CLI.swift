import Foundation

/// Result of a single battery CLI invocation.
public struct CLIResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { exitCode == 0 }
}

/// Errors surfaced to the UI layer.
public enum CLIError: Error, Equatable, Sendable {
    case cliNotFound
    case chargingControlUnavailable
    case commandFailed(exitCode: Int32, output: String)
    case parseError(String)
}

/// Abstraction over the `battery` command line tool so tests can mock it.
public protocol BatteryCLI: Sendable {
    /// Run `battery status_csv` and return the parsed status.
    func status() async throws -> BatteryStatus
    /// Run an arbitrary battery command with arguments, e.g. ["maintain", "80"].
    func run(_ arguments: [String]) async throws -> CLIResult
    /// Run a scheduled action to completion, including charge/discharge tasks
    /// that the interactive GUI normally launches in the background.
    func runScheduledAction(_ arguments: [String]) async throws -> CLIResult
}

extension BatteryCLI {
    public func requireChargingControl() async throws {
        guard try await status().chargingControlAvailable != false else {
            throw CLIError.chargingControlUnavailable
        }
    }

    public func runScheduledAction(_ arguments: [String]) async throws -> CLIResult {
        try await run(arguments)
    }

    @discardableResult
    public func maintain(_ range: MaintainRange) async throws -> CLIResult {
        try await run(["maintain", range.cliValue])
    }

    @discardableResult
    public func maintainStop() async throws -> CLIResult {
        try await run(["maintain", "stop"])
    }

    @discardableResult
    public func charge(to level: Int) async throws -> CLIResult {
        try await run(["charge", String(level)])
    }

    @discardableResult
    public func discharge(to level: Int) async throws -> CLIResult {
        try await run(["discharge", String(level)])
    }

    @discardableResult
    public func setLowPower(_ on: Bool) async throws -> CLIResult {
        try await run(["low", on ? "on" : "off"])
    }

    @discardableResult
    public func setCharging(_ on: Bool) async throws -> CLIResult {
        try await run(["charging", on ? "on" : "off"])
    }

    @discardableResult
    public func setAdapter(_ on: Bool) async throws -> CLIResult {
        try await run(["adapter", on ? "on" : "off"])
    }

    @discardableResult
    public func calibrate() async throws -> CLIResult {
        try await run(["calibrate"])
    }
}

/// Concrete implementation that shells out to /usr/local/bin/battery.
///
/// Short process completion is polled off the main actor so it composes cleanly
/// with Swift concurrency; scheduled battery cycles use the same runner without
/// a timeout so their recorded result reflects the final target outcome.
///
/// Some subcommands (charge, discharge, calibrate) run in the foreground
/// until the target percentage is reached, which can take hours. They are
/// launched detached instead: `run()` returns once the process is spawned,
/// and the caller tracks progress via `status()` polling.
public final class ProcessBatteryCLI: BatteryCLI, @unchecked Sendable {
    public static let defaultBinaryPath = "/usr/local/bin/battery"

    private let binaryPath: String

    public init(binaryPath: String = ProcessBatteryCLI.defaultBinaryPath) {
        self.binaryPath = binaryPath
    }

    public var cliExists: Bool {
        FileManager.default.isExecutableFile(atPath: binaryPath)
    }

    /// Subcommands that block until a percentage is reached.
    private static let longRunningSubcommands: Set<String> = ["charge", "discharge", "calibrate"]

    public static func isLongRunning(_ arguments: [String]) -> Bool {
        guard let first = arguments.first else { return false }
        return longRunningSubcommands.contains(first)
    }

    public func status() async throws -> BatteryStatus {
        let result = try await run(["status_csv"])
        var parsed = try BatteryStatusParser.parseCSV(result.stdout)
        // A CLI older than v1.3.7 left out the live-state column, and behind
        // it the adapter and low-power columns an older one still dropped.
        // pmset fills the gaps, which is what these two reads are for: the
        // battery line carries both the live state and the adapter in one go,
        // and Low Power Mode appears in no other output.
        //
        // Without this the live state would default to "not charging" for
        // every user still on an older CLI, so the bolt would be gone but so
        // would the plug, and a genuinely charging pack would read as idle.
        if parsed.liveStateColumnMissing {
            let batt = Self.pmset(["-g", "batt"])
            let live = BatteryStatusParser.parseLivePowerState(pmsetBattOutput: batt)
            parsed.charging = live == .charging
            parsed.discharging = live == .discharging
            parsed.adapterAttached = BatteryStatusParser.parseAdapterAttached(pmsetOutput: batt)
        }
        if parsed.powerColumnsMissing {
            parsed.lowPowerOn = Self.readLowPowerState()
        }
        return parsed
    }

    /// Read Low Power Mode straight from pmset (user-space, no sudo needed).
    /// The CLI sets it with `-a` (all power sources), so the merged `pmset -g`
    /// view is authoritative. Used as the fallback for a CLI predating
    /// v1.3.6, and on launch before the first full battery status is available.
    public static func readLowPowerState() -> Bool {
        BatteryStatusParser.parseLowPowerMode(pmsetOutput: pmset(["-g"]))
    }

    /// Run pmset and return stdout, or "" when it cannot be run. Both pmset
    /// reads are user-space and cheap, and only a CLI too old to report the
    /// power state itself reaches them at all. A failure is simply "unknown",
    /// which callers treat as "not on AC, not charging".
    private static func pmset(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    public func run(_ arguments: [String]) async throws -> CLIResult {
        guard cliExists else { throw CLIError.cliNotFound }
        if Self.isLongRunning(arguments) {
            if arguments.first == "charge" || arguments.first == "calibrate" {
                try await requireChargingControl()
            }
            return try spawnDetached(arguments)
        }
        let result = try await runToCompletion(arguments)
        guard result.succeeded else {
            throw CLIError.commandFailed(exitCode: result.exitCode, output: result.stderr + result.stdout)
        }
        return result
    }

    public func runScheduledAction(_ arguments: [String]) async throws -> CLIResult {
        guard cliExists else { throw CLIError.cliNotFound }
        guard Self.isLongRunning(arguments) else {
            return try await run(arguments)
        }
        if arguments.first == "charge" || arguments.first == "calibrate" {
            try await requireChargingControl()
        }
        return try await runToCompletion(arguments, timeout: nil)
    }

    /// Fire and forget: the CLI keeps running in the background and enforces
    /// the target itself. Output goes to the GUI log so it stays inspectable.
    private func spawnDetached(_ arguments: [String]) throws -> CLIResult {
        try? StateDirectory.ensureExists()
        let logURL = StateDirectory.url.appendingPathComponent("gui-cli.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments
        if let logHandle = try? FileHandle(forWritingTo: logURL) {
            logHandle.seekToEndOfFile()
            process.standardOutput = logHandle
            process.standardError = logHandle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        try process.run()
        return CLIResult(exitCode: 0, stdout: "started (detached): \(arguments.joined(separator: " "))", stderr: "")
    }

    /// Run a short-lived subcommand and capture its output.
    ///
    /// Output goes to a temp file, NOT a pipe: `battery maintain` spawns a
    /// background daemon (maintain_synchronous) that inherits the write end
    /// of a pipe and keeps it open forever, so pipe-based capture never sees
    /// EOF and hangs. File-based capture is immune — the daemon closes and
    /// reopens its own descriptors after forking.
    private func runToCompletion(_ arguments: [String], timeout: TimeInterval? = 60) async throws -> CLIResult {
        try? StateDirectory.ensureExists()
        let outURL = StateDirectory.url.appendingPathComponent("cli-out-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments
        let outHandle = try FileHandle(forWritingTo: outURL)
        process.standardOutput = outHandle
        process.standardError = outHandle
        try process.run()

        // Poll for completion on a background thread. Process.terminationHandler
        // proved unreliable in this helper's context (handlers occasionally never
        // fire when the child spawns daemon grandchildren), so we poll isRunning
        // with a timeout instead. Scheduled charge/discharge/calibration calls
        // opt out because their duration depends on the battery and target.
        let pid = process.processIdentifier
        let exitCode: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let deadline = timeout.map { Date().addingTimeInterval($0) }
                let pollInterval = timeout == nil ? 1.0 : 0.1
                while process.isRunning && (deadline == nil || Date() < deadline!) {
                    Thread.sleep(forTimeInterval: pollInterval)
                }
                if process.isRunning {
                    process.terminate()
                    Thread.sleep(forTimeInterval: 0.5)
                    if process.isRunning { kill(pid, SIGKILL) }
                }
                continuation.resume(returning: process.terminationStatus)
            }
        }
        try? outHandle.close()
        let out = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        return CLIResult(exitCode: exitCode, stdout: out, stderr: "")
    }
}
