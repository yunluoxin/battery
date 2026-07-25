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
    case commandFailed(exitCode: Int32, output: String)
    case parseError(String)
}

/// Abstraction over the `battery` command line tool so tests can mock it.
public protocol BatteryCLI: Sendable {
    /// Run `battery status_csv` and return the parsed status.
    func status() async throws -> BatteryStatus
    /// Run an arbitrary battery command with arguments, e.g. ["maintain", "80"].
    func run(_ arguments: [String]) async throws -> CLIResult
}

extension BatteryCLI {
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
/// Process completion is observed via `terminationHandler` (event-driven,
/// no blocking waits) so it composes cleanly with Swift concurrency.
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
        guard result.succeeded else {
            throw CLIError.commandFailed(exitCode: result.exitCode, output: result.stderr + result.stdout)
        }
        var parsed = try BatteryStatusParser.parseCSV(result.stdout)
        parsed.lowPowerOn = Self.readLowPowerState()
        return parsed
    }

    /// Read Low Power Mode straight from pmset (user-space, no sudo needed).
    /// `pmset -g` merges AC+battery and can show 0 while the battery-only (-b)
    /// setting is 1; `pmset -g custom` exposes the per-source sections.
    private static func readLowPowerState() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "custom"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // Find the "Battery Power" section and read its lowpowermode value.
        guard let batteryRange = out.range(of: "Battery Power", options: .caseInsensitive) else {
            // Fall back to any lowpowermode line if sections are absent.
            return out.range(of: #"^\s*lowpowermode\s+1"#, options: .regularExpression) != nil
        }
        let section = out[batteryRange.lowerBound...]
        return section.range(of: #"^\s*lowpowermode\s+1"#, options: .regularExpression) != nil
    }

    public func run(_ arguments: [String]) async throws -> CLIResult {
        guard cliExists else { throw CLIError.cliNotFound }
        if Self.isLongRunning(arguments) {
            return try spawnDetached(arguments)
        }
        return try await runToCompletion(arguments)
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
    private func runToCompletion(_ arguments: [String]) async throws -> CLIResult {
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
        // with a hard timeout instead.
        let pid = process.processIdentifier
        let exitCode: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let deadline = Date().addingTimeInterval(60)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
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
