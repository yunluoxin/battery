import Foundation

/// Maps a task action to the CLI invocation, and reports the outcome.
public enum TaskExecutor {

    /// Execute one scheduled task via the CLI. Returns (success, output, note).
    public static func execute(_ task: ScheduledTask, cli: BatteryCLI, currentMode: OperatingMode) async -> (Bool, String, String?) {
        let note: String? = switch currentMode {
        case .idle, .maintaining: nil
        case .chargingTo(let t): "overrode: charging-to-\(t)"
        case .dischargingTo(let t): "overrode: discharging-to-\(t)"
        case .calibrating: "overrode: calibrating"
        }

        let result: CLIResult
        do {
            switch task.action {
            case .maintain:
                result = try await cli.run(["maintain", task.param])
            case .topup:
                result = try await cli.charge(to: 100)
            case .discharge:
                result = try await cli.discharge(to: Int(task.param) ?? 80)
            case .calibrate:
                result = try await cli.calibrate()
            case .lowpower:
                result = try await cli.setLowPower(task.param.lowercased() == "on")
            }
        } catch {
            return (false, String(describing: error), note)
        }
        let output = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return (result.succeeded, output.isEmpty ? "exit \(result.exitCode)" : String(output.prefix(500)), note)
    }
}

/// Decides what to do when a charge/discharge cycle finishes.
public enum CompletionHandler {

    /// Called when the poll loop observes a charge/discharge reached its target.
    /// Applies the configured post-completion behavior.
    public static func handleCompletion(config: AppConfig, cli: BatteryCLI) async throws {
        switch config.postCompletion {
        case .resumeMaintain:
            if config.maintainEnabled {
                _ = try await cli.maintain(config.effectiveRange)
            } else {
                try await restoreDefault(cli: cli)
            }
        case .restoreDefault:
            try await restoreDefault(cli: cli)
        }
    }

    /// Return the Mac to stock behavior: no maintain, charging on, adapter on.
    public static func restoreDefault(cli: BatteryCLI) async throws {
        _ = try await cli.maintainStop()
        _ = try await cli.setCharging(true)
        _ = try await cli.setAdapter(true)
    }
}

/// Pure decision logic: derive the operating mode from config + observed status.
public enum ModeDeriver {

    /// Detect completion of a charge/discharge cycle.
    /// The cycle is complete when the battery reaches the target level;
    /// the SMC charging/discharging flags are unreliable mid-cycle (the CLI
    /// toggles them while enforcing), so only the percentage is authoritative.
    public static func isCycleComplete(mode: OperatingMode, status: BatteryStatus) -> Bool {
        switch mode {
        case .chargingTo(let target):
            return status.percentage >= target
        case .dischargingTo(let target):
            return status.percentage <= target
        default:
            return false
        }
    }

    /// Current mode from user intent, adjusted by what the CLI reports.
    public static func derive(config: AppConfig, status: BatteryStatus, calibrating: Bool) -> OperatingMode {
        if calibrating { return .calibrating }
        if config.chargeActive { return .chargingTo(config.chargeTarget) }
        if config.dischargeActive { return .dischargingTo(config.dischargeTarget) }
        if config.maintainEnabled { return .maintaining(config.maintainRange) }
        return .idle
    }
}
