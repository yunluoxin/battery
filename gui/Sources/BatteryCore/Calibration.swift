import Foundation

/// Tracks a running `battery calibrate` process across app launches.
/// The calibrate command writes its own pidfile in ~/.battery, but we keep
/// our own state so the UI can show progress after an app restart.
public struct CalibrationState: Codable, Sendable {
    public var pid: Int32
    public var startedAt: Date

    public init(pid: Int32, startedAt: Date = Date()) {
        self.pid = pid
        self.startedAt = startedAt
    }
}

public enum CalibrationTracker {

    public static func load() -> CalibrationState? {
        let state = JSONStore.load(CalibrationState.self, from: StateDirectory.calibrateStateFile, default: CalibrationState(pid: -1, startedAt: .distantPast))
        return state.pid > 0 ? state : nil
    }

    public static func save(_ state: CalibrationState) throws {
        try JSONStore.save(state, to: StateDirectory.calibrateStateFile)
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: StateDirectory.calibrateStateFile)
    }

    /// Is the recorded calibration process still alive?
    public static func isRunning(_ state: CalibrationState) -> Bool {
        kill(state.pid, 0) == 0
    }

    /// The CLI keeps its own pidfile at ~/.battery/calibrate.pid
    public static var cliPIDFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".battery/calibrate.pid")
    }

    /// Best-effort detection combining our state file and the CLI's pidfile.
    public static func detectRunningCalibration() -> CalibrationState? {
        if let ours = load(), isRunning(ours) { return ours }
        if let data = try? Data(contentsOf: cliPIDFile),
           let pid = Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 0, kill(pid, 0) == 0 {
            return CalibrationState(pid: pid)
        }
        return nil
    }

    /// Launch `battery calibrate` detached (it runs for hours), record state.
    public static func start(cli: BatteryCLI) async throws {
        // `battery calibrate` is a long-running foreground script; run detached.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessBatteryCLI.defaultBinaryPath)
        process.arguments = ["calibrate"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try save(CalibrationState(pid: process.processIdentifier))
    }

    public static func stop() {
        if let state = detectRunningCalibration() {
            kill(state.pid, SIGTERM)
        }
        clear()
    }
}
