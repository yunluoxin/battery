import Foundation
import BatteryCore
import ServiceManagement
import Combine

/// Central observable store for the app: config, live battery status, mode.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // MARK: Published UI state

    @Published var status: BatteryStatus?
    @Published var config: AppConfig
    @Published var mode: OperatingMode = .idle
    @Published var calibrating: Bool = false
    @Published var cliAvailable: Bool = false
    @Published var errorMessage: String?
    @Published var lowPowerOn: Bool = false

    let cli: BatteryCLI
    private var pollTask: Task<Void, Never>?
    /// Grace timestamp: a freshly started charge/discharge cycle is not
    /// evaluated for completion until this passes. Prevents the race where the
    /// first poll after toggling still sees the pre-cycle percentage.
    private var cycleStartedAt: Date?

    init(cli: BatteryCLI = ProcessBatteryCLI()) {
        self.cli = cli
        self.config = JSONStore.load(AppConfig.self, from: StateDirectory.configFile, default: AppConfig())
        self.cliAvailable = (cli as? ProcessBatteryCLI)?.cliExists ?? true
        // Seed the low-power state immediately so the menu bar badge and the
        // toggle are correct before the first full status poll completes.
        self.lowPowerOn = ProcessBatteryCLI.readLowPowerState()
    }

    /// The low-power state shown in the UI: always the real system state.
    var effectiveLowPower: Bool {
        lowPowerOn
    }

    // MARK: Lifecycle

    func start() {
        refresh()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                self?.refresh()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
    }

    // MARK: Polling

    func refresh() {
        Task {
            await refreshAsync()
        }
    }

    private func refreshAsync() async {
        if let processCLI = cli as? ProcessBatteryCLI {
            cliAvailable = processCLI.cliExists
        }
        guard cliAvailable else { return }

        do {
            let newStatus = try await cli.status()
            status = newStatus
            calibrating = CalibrationTracker.detectRunningCalibration() != nil

            // Always mirror the real system low-power state; pmset is the
            // single source of truth.
            lowPowerOn = newStatus.lowPowerOn

            // Detect completion of an active charge/discharge cycle. A grace
            // period after starting avoids the race where the first poll still
            // sees the pre-cycle percentage and instantly "completes".
            if let cycle = activeCycle, ModeDeriver.isCycleComplete(mode: cycle, status: newStatus) {
                let started = cycleStartedAt ?? .distantPast
                if Date().timeIntervalSince(started) >= 5 {
                    config.chargeActive = false
                    config.dischargeActive = false
                    cycleStartedAt = nil
                    saveConfig()
                    try await CompletionHandler.handleCompletion(config: config, cli: cli)
                }
            }
            mode = ModeDeriver.derive(config: config, status: newStatus, calibrating: calibrating)
            errorMessage = nil
        } catch CLIError.cliNotFound {
            cliAvailable = false
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private var activeCycle: OperatingMode? {
        if config.chargeActive { return .chargingTo(config.chargeTarget) }
        if config.dischargeActive { return .dischargingTo(config.dischargeTarget) }
        return nil
    }

    // MARK: Config persistence

    func saveConfig() {
        try? JSONStore.save(config, to: StateDirectory.configFile)
    }

    // MARK: Actions

    func setMaintain(enabled: Bool) {
        config.maintainEnabled = enabled
        saveConfig()
        Task {
            do {
                if enabled {
                    _ = try await cli.maintain(config.effectiveRange)
                } else {
                    _ = try await cli.maintainStop()
                }
                await refreshAsync()
            } catch { show(error) }
        }
    }

    func setMaintainRange(_ range: MaintainRange) {
        config.maintainRange = range
        saveConfig()
        guard config.maintainEnabled else { return }
        Task {
            do {
                _ = try await cli.maintain(config.effectiveRange)
                await refreshAsync()
            } catch { show(error) }
        }
    }

    func setSailing(enabled: Bool) {
        config.sailingEnabled = enabled
        // Never mutate maintainRange here: the stored range is the user's
        // sailing band and must survive toggling sailing off and on again.
        // Non-sailing mode simply uses the range's upper value (see
        // config.effectiveRange).
        saveConfig()
        guard config.maintainEnabled else { return }
        setMaintainRange(config.effectiveRange)
    }

    /// Toggle the shared charge/discharge switchers. They are mutually exclusive.
    func setCharge(active: Bool) {
        config.chargeActive = active
        if active {
            config.dischargeActive = false
            cycleStartedAt = Date()
        } else {
            cycleStartedAt = nil
        }
        saveConfig()
        Task {
            do {
                if active {
                    // `battery charge` runs maintain-stop internally, but only
                    // kills the daemon named in the pidfile; an orphaned daemon
                    // (stale/empty pidfile) survives and keeps forcing charging
                    // off, defeating the cycle. Sweep all maintain daemons first.
                    _ = try await cli.maintainStop()
                    _ = try await cli.charge(to: config.chargeTarget)
                } else {
                    // Manual cancel: restore according to post-completion policy.
                    try await CompletionHandler.handleCompletion(config: config, cli: cli)
                }
                await refreshAsync()
            } catch { show(error) }
        }
    }

    func setDischarge(active: Bool) {
        config.dischargeActive = active
        if active {
            config.chargeActive = false
            cycleStartedAt = Date()
        } else {
            cycleStartedAt = nil
        }
        saveConfig()
        Task {
            do {
                if active {
                    // See setCharge: sweep orphaned maintain daemons first.
                    _ = try await cli.maintainStop()
                    _ = try await cli.discharge(to: config.dischargeTarget)
                } else {
                    try await CompletionHandler.handleCompletion(config: config, cli: cli)
                }
                await refreshAsync()
            } catch { show(error) }
        }
    }

    func setTarget(_ value: Int) {
        config.chargeTarget = value
        config.dischargeTarget = value
        saveConfig()
    }

    func toggleLowPower() {
        setLowPower(!effectiveLowPower)
    }

    func setLowPower(_ on: Bool) {
        // Optimistic update; the next refresh re-reads the real system state.
        lowPowerOn = on
        Task {
            do {
                _ = try await cli.setLowPower(on)
            } catch {
                await refreshAsync()    // revert to actual system state
                show(error)
            }
        }
    }

    func startCalibration() {
        Task {
            do {
                try await CalibrationTracker.start(cli: cli)
                calibrating = true
            } catch { show(error) }
        }
    }

    func stopCalibration() {
        CalibrationTracker.stop()
        calibrating = false
        refresh()
    }

    func restoreDefaults() {
        Task {
            do {
                config.chargeActive = false
                config.dischargeActive = false
                config.maintainEnabled = false
                cycleStartedAt = nil
                saveConfig()
                try await CompletionHandler.restoreDefault(cli: cli)
                await refreshAsync()
            } catch { show(error) }
        }
    }

    // MARK: Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        config.launchAtLogin = enabled
        saveConfig()
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            show(error)
        }
    }

    private func show(_ error: Error) {
        if case CLIError.cliNotFound = error {
            cliAvailable = false
            return
        }
        errorMessage = String(describing: error)
    }
}
