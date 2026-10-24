import Foundation
import BatteryCore
import ServiceManagement
import Combine

/// What asked for a refresh. The answer decides how much the refresh may cost.
enum RefreshCue {
    /// The app itself: a user action, the popover opening, the five-minute
    /// safety net. These already know why they are refreshing, so each one
    /// reads the CLI in full, and none is subject to the event floor.
    case explicit
    /// A PowerEventMonitor event. Carries the reading IOKit handed over for
    /// free when the event came from IOKit itself; nil for the other sources,
    /// which announce changes IOKit's battery fields cannot see (a wake, a
    /// Low Power Mode flip) and therefore always read the CLI in full.
    case event(PowerSnapshot?)
}

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
    private var eventMonitor: PowerEventMonitor?
    /// Grace timestamp: a freshly started charge/discharge cycle is not
    /// evaluated for completion until this passes. Prevents the race where the
    /// first poll after toggling still sees the pre-cycle percentage.
    private var cycleStartedAt: Date?
    /// The reading as the last successful full CLI read saw it. An event whose
    /// IOKit snapshot still matches this changed nothing the CLI reports, so
    /// its refresh stops at the display patch below instead of running the
    /// CLI. Cleared when a read fails, so the next event retries the CLI
    /// rather than comparing against a baseline that predates the failure.
    private var lastFullSnapshot: PowerSnapshot?
    /// Whether the auto low-power rule may still fire. Cleared by a firing and
    /// restored only once the level has climbed clear of the threshold, so one
    /// drop below the threshold produces one `smc low on` rather than one per
    /// poll. Deliberately not persisted: a relaunch starts armed, which is what
    /// you want — a pack still below the threshold at launch should get the mode.
    private var autoLowPowerArmed: Bool = true

    init(cli: BatteryCLI = ProcessBatteryCLI()) {
        self.cli = cli
        self.config = JSONStore.load(AppConfig.self, from: StateDirectory.configFile, default: AppConfig())
        self.cliAvailable = (cli as? ProcessBatteryCLI)?.cliExists ?? true
        // Seed the low-power state immediately so the menu bar badge and the
        // toggle are correct before the first full status poll completes.
        self.lowPowerOn = ProcessBatteryCLI.readLowPowerState()
        // Here rather than in start(): this runs before any window exists, so
        // the very first frame is drawn in the user's language instead of
        // flashing English and then switching.
        Localization.shared.load(from: config)
    }

    /// The low-power state shown in the UI: always the real system state.
    var effectiveLowPower: Bool {
        lowPowerOn
    }

    var chargingControlAvailable: Bool {
        status?.chargingControlAvailable != false
    }

    // MARK: Lifecycle

    func start() {
        repairAfterMove()
        refresh()
        // Events, not a timer, are what drives the refreshes: the battery
        // level moves on its own schedule, and a fixed interval either lags
        // behind it or keeps re-reading a level that has not moved. Each
        // event carries the reading IOKit hands over for free, so a refresh
        // can tell a level change from an estimate tick before paying for a
        // CLI run — see refreshAsync.
        let monitor = PowerEventMonitor { [weak self] snapshot in
            self?.refresh(.event(snapshot))
        }
        monitor.start()
        eventMonitor = monitor
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // Safety net, not the primary trigger. Some state changes
                // announce themselves through no notification at all: a
                // `battery maintain` typed in a terminal, a calibration
                // killed from another shell, the CLI uninstalled underneath
                // the app. Events cover everything the battery itself does,
                // so this only has to be slow enough to be free in the common
                // case while still catching up on the rest.
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { break }
                self?.refresh()
            }
        }
    }

    /// Re-point anything that stored the app's absolute path after the app was
    /// moved or re-installed elsewhere.
    ///
    /// Both mechanisms below record where the app *was*, and neither follows it:
    /// launchd agents name the helper by absolute path, and SMAppService stores
    /// the registered bundle location. Moving the app therefore breaks both
    /// silently — scheduled tasks stop firing and the login item launches
    /// nothing. Repairing at startup beats asking the user to go toggle
    /// switches, since moving an app is a thing people do casually.
    private func repairAfterMove() {
        let tasks = JSONStore.load(TaskList.self, from: StateDirectory.tasksFile, default: TaskList())
        let repaired = LaunchdManager.reinstallMovedTasks(tasks: tasks.tasks, helperPath: LaunchdManager.currentHelperPath)
        if !repaired.isEmpty {
            print("[BatteryKeeper] re-registered \(repaired.count) scheduled task(s) after the app moved")
        }

        // Only ever re-register when the user asked to launch at login in the
        // first place: a stale registration is not evidence the feature is
        // wanted, and re-registering unconditionally would turn on a behaviour
        // the user may have switched off. The toggle is the record of intent.
        guard config.launchAtLogin else { return }
        let registered = SMAppService.mainApp.status
        if registered == .notFound || registered == .notRegistered {
            do {
                try SMAppService.mainApp.register()
                print("[BatteryKeeper] re-registered launch at login after the app moved")
            } catch {
                print("[BatteryKeeper] could not re-register launch at login: \(error)")
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        eventMonitor?.stop()
    }

    // MARK: Polling

    func refresh(_ cue: RefreshCue = .explicit) {
        Task {
            await refreshAsync(cue)
        }
    }

    private func refreshAsync(_ cue: RefreshCue = .explicit) async {
        if let processCLI = cli as? ProcessBatteryCLI {
            cliAvailable = processCLI.cliExists
        }
        guard cliAvailable else { return }

        // Events first patch the display from the free IOKit reading, so
        // nothing the user sees waits on the floor below: a percentage that
        // moved, an adapter that arrived, a bolt that became real — all land
        // with the event, however recently the CLI last ran. What the patch
        // cannot see (maintain state, Low Power Mode, the charging backend)
        // keeps its value from the last full read and is re-read next.
        //
        // A reading that matches the last full read then stops here entirely:
        // most often the event is macOS re-publishing its time-remaining
        // estimate, which it does about once a minute, and the whole refresh
        // reduces to that patch. Cycle detection and the auto rule stay on
        // full reads: they act on CLI-owned state, and a level that has not
        // moved can neither complete a cycle nor cross the rule's threshold.
        if case .event(let snapshot) = cue, let snapshot {
            applyDisplayOnlyUpdate(from: snapshot)
            if let baseline = lastFullSnapshot, snapshot == baseline {
                return
            }
        }

        do {
            let newStatus = try await cli.status()
            status = newStatus
            // The baseline the next event's snapshot is compared against:
            // what the world looked like the last time the CLI actually
            // answered.
            lastFullSnapshot = PowerSnapshot(status: newStatus)
            calibrating = CalibrationTracker.detectRunningCalibration() != nil

            // Always mirror the real system low-power state; pmset is the
            // single source of truth.
            lowPowerOn = newStatus.lowPowerOn

            await applyAutoLowPowerRule(newStatus)

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
                    try await CompletionHandler.handleCompletion(config: config, cli: cli,
                                                                 chargingControlAvailable: newStatus.chargingControlAvailable)
                }
            }
            mode = ModeDeriver.derive(config: config, status: newStatus, calibrating: calibrating)
        } catch CLIError.cliNotFound {
            cliAvailable = false
        } catch {
            // The read failed, so the baseline no longer describes the last
            // thing the CLI confirmed. Clearing it makes the next event
            // retry the CLI rather than skip against a stale reading.
            lastFullSnapshot = nil
            show(error)
        }
    }

    /// Carry an event's IOKit reading to the UI without a CLI run.
    ///
    /// These four fields are exactly what IOKit can see, and they only move
    /// when IOKit says so — otherwise the snapshot would have differed from
    /// the baseline and the caller would be running the CLI instead. What the
    /// patch cannot see (maintain state, Low Power Mode, the charging
    /// backend) keeps its value from the last full read until the next one.
    /// Republishes only when something actually moved, so estimate ticks that
    /// repeat the same numbers cost no SwiftUI invalidation at all.
    private func applyDisplayOnlyUpdate(from snapshot: PowerSnapshot) {
        guard var refreshed = status else { return }
        var changed = false
        if refreshed.percentage != snapshot.percentage {
            refreshed.percentage = snapshot.percentage
            changed = true
        }
        // `isChargingNow` semantics: charge only moves into a pack that has
        // an adapter, which is the same test the live-state column applies,
        // so the field maps onto `charging` one to one in every state.
        if refreshed.charging != snapshot.isCharging {
            refreshed.charging = snapshot.isCharging
            changed = true
        }
        if refreshed.adapterAttached != snapshot.adapterAttached {
            refreshed.adapterAttached = snapshot.adapterAttached
            changed = true
        }
        if let time = snapshot.updatedRemainingTime(for: refreshed), refreshed.remainingTime != time {
            refreshed.remainingTime = time
            changed = true
        }
        guard changed else { return }
        status = refreshed
    }

    /// The cycle currently under way, if any. Charge and discharge share one
    /// CLI switcher, so at most one of them is ever active.
    var activeCycleKind: BatteryCycle? {
        if config.chargeActive { return .charge }
        if config.dischargeActive { return .discharge }
        return nil
    }

    /// The level the popover's single target slider shows and edits: the level
    /// of the running cycle, or the charge level while nothing is running.
    var cycleTarget: Int {
        config.target(for: activeCycleKind ?? .charge)
    }

    private var activeCycle: OperatingMode? {
        switch activeCycleKind {
        case .charge: chargingControlAvailable ? .chargingTo(config.chargeTarget) : nil
        case .discharge: .dischargingTo(config.dischargeTarget)
        case nil: nil
        }
    }

    // MARK: Config persistence

    func saveConfig() {
        try? JSONStore.save(config, to: StateDirectory.configFile)
    }

    // MARK: Actions

    /// Switch UI language and persist it. The change is applied in place:
    /// `Localization` is in the SwiftUI environment, so open windows redraw
    /// instead of waiting for a relaunch.
    func setLanguage(_ language: AppLanguage) {
        config.language = language
        saveConfig()
        Localization.shared.setLanguage(language)
    }

    func setMaintain(enabled: Bool) {
        guard !enabled || chargingControlAvailable else { return }
        Task {
            do {
                if enabled {
                    _ = try await cli.maintain(config.effectiveRange)
                } else {
                    _ = try await cli.maintainStop()
                }
                config.maintainEnabled = enabled
                saveConfig()
                errorMessage = nil
                await refreshAsync()
            } catch {
                if enabled {
                    config.maintainEnabled = false
                    saveConfig()
                }
                await refreshAsync()
                show(error)
            }
        }
    }

    func setMaintainRange(_ range: MaintainRange) {
        config.maintainRange = range
        saveConfig()
        guard config.maintainEnabled && chargingControlAvailable else { return }
        Task {
            do {
                _ = try await cli.maintain(config.effectiveRange)
                errorMessage = nil
                await refreshAsync()
            } catch {
                config.maintainEnabled = false
                saveConfig()
                await refreshAsync()
                show(error)
            }
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
        setMaintainRange(config.maintainRange)
    }

    /// Toggle the shared charge/discharge switchers. They are mutually exclusive.
    func setCharge(active: Bool) {
        guard !active || chargingControlAvailable else { return }
        config.chargeActive = active
        if active {
            config.dischargeActive = false
            // Switching this toggle on *is* the intent "top the battery up", so
            // the target snaps to the charge level instead of keeping whatever
            // level the discharge cycle left behind.
            config.setTarget(BatteryCycle.charge.defaultTarget, for: .charge)
            cycleStartedAt = Date()
        } else {
            cycleStartedAt = nil
        }
        let level = config.chargeTarget
        saveConfig()
        Task {
            do {
                if active {
                    try await cli.requireChargingControl()
                    // Keep this foreground stop for older CLI versions and to
                    // report stop failures before detaching the charge cycle.
                    // Newer CLI versions also sweep workers when charging starts.
                    _ = try await cli.maintainStop()
                    _ = try await cli.charge(to: level)
                } else {
                    // Manual cancel: restore according to post-completion policy.
                    try await CompletionHandler.handleCompletion(config: config, cli: cli,
                                                                 chargingControlAvailable: status?.chargingControlAvailable)
                }
                errorMessage = nil
                await refreshAsync()
            } catch {
                config.chargeActive = false
                cycleStartedAt = nil
                saveConfig()
                await refreshAsync()
                show(error)
            }
        }
    }

    func setDischarge(active: Bool) {
        config.dischargeActive = active
        if active {
            config.chargeActive = false
            // See setCharge: the toggle carries the intent, so discharge takes
            // its own level rather than the charge cycle's 100%.
            config.setTarget(BatteryCycle.discharge.defaultTarget, for: .discharge)
            cycleStartedAt = Date()
        } else {
            cycleStartedAt = nil
        }
        let level = config.dischargeTarget
        saveConfig()
        Task {
            do {
                if active {
                    // See setCharge: stop maintenance before detaching the cycle.
                    _ = try await cli.maintainStop()
                    _ = try await cli.discharge(to: level)
                } else {
                    try await CompletionHandler.handleCompletion(config: config, cli: cli,
                                                                 chargingControlAvailable: status?.chargingControlAvailable)
                }
                errorMessage = nil
                await refreshAsync()
            } catch {
                config.dischargeActive = false
                cycleStartedAt = nil
                saveConfig()
                await refreshAsync()
                show(error)
            }
        }
    }

    /// Update the level the popover's single target slider edits.
    ///
    /// It belongs to the running cycle; with no cycle running there is no owner,
    /// so both cycles take the value — whichever toggle is switched on next
    /// snaps to its own default anyway.
    func setTarget(_ value: Int) {
        switch activeCycleKind {
        case .charge:
            config.setTarget(value, for: .charge)
        case .discharge:
            config.setTarget(value, for: .discharge)
        case nil:
            config.setTarget(value, for: .charge)
            config.setTarget(value, for: .discharge)
        }
        saveConfig()
    }

    /// The auto rule's single action: switch Low Power Mode on, once per drop.
    ///
    /// Runs off the poll that read the level rather than off a poll of its own,
    /// so it costs nothing extra. The armed flag is cleared *before* the command
    /// goes out, which is what makes firing once per drop hold however many
    /// refreshes arrive afterwards — the one this sits inside, or the one the
    /// notification it provokes — all find the rule disarmed.
    private func applyAutoLowPowerRule(_ status: BatteryStatus) async {
        if AutoLowPowerRule.shouldRearm(percentage: status.percentage, threshold: config.autoLowPowerThreshold) {
            autoLowPowerArmed = true
        }
        guard AutoLowPowerRule.shouldEnable(enabled: config.autoLowPower,
                                            armed: autoLowPowerArmed,
                                            lowPowerOn: status.lowPowerOn,
                                            percentage: status.percentage,
                                            threshold: config.autoLowPowerThreshold)
        else { return }

        autoLowPowerArmed = false
        do {
            _ = try await cli.setLowPower(true)
            // Mirror the change rather than read it back. The status this poll
            // is holding predates the command, so without this the toggle sits
            // showing off while the mode is on, until some unrelated event
            // refreshes it. Re-reading would mean a second CLI run nested
            // inside the refresh that is deciding this — and the rule is
            // already disarmed, so the nested pass could not act on anything
            // anyway. The next event-driven refresh confirms it from pmset
            // like any other state.
            lowPowerOn = true
        } catch {
            // The command failed, so the mode is still off. Re-arm rather than
            // leave the rule disarmed until the level recovers — the failure
            // may well have been transient.
            autoLowPowerArmed = true
            show(error)
        }
    }

    /// The rule's switch. Turning it on re-reads the level straight away,
    /// otherwise a user watching a battery already below the threshold would
    /// wait up to a minute for the toggle to appear to do anything.
    func setAutoLowPower(_ enabled: Bool) {
        config.autoLowPower = enabled
        if enabled { autoLowPowerArmed = true }
        saveConfig()
        guard enabled else { return }
        refresh()
    }

    func setAutoLowPowerThreshold(_ value: Int) {
        config.autoLowPowerThreshold = AutoLowPowerRule.clamp(value)
        // Re-arm so a newly chosen level applies now, even when it is above a
        // threshold that has already fired: the user has just restated the
        // rule, and the next poll is up to a minute away.
        autoLowPowerArmed = true
        saveConfig()
        guard config.autoLowPower else { return }
        refresh()
    }

    func toggleLowPower() {
        setLowPower(!effectiveLowPower)
    }

    func setLowPower(_ on: Bool) {
        // Optimistic update; the refresh below replaces it with whatever the
        // system actually did.
        lowPowerOn = on
        Task {
            do {
                _ = try await cli.setLowPower(on)
                // Re-read on success too, and not only to confirm the flag:
                // Low Power Mode changes what the pack is allowed to do, and
                // the time-remaining estimate moves with it. Only the system
                // recomputes that, and only something asking pmset again
                // finds out. Every other action here re-reads after changing
                // something; this one did not, which left the popover's
                // countdown and Settings' status row showing the reading from
                // before the toggle until an unrelated event or the
                // safety-net poll came round — up to five minutes.
                //
                // Whether the number visibly changes is still the system's
                // call: it recomputes the estimate on its own schedule, not on
                // this call.
                errorMessage = nil
                await refreshAsync()
            } catch {
                await refreshAsync()    // revert to actual system state
                show(error)
            }
        }
    }

    func setScheduledTaskNotifications(_ enabled: Bool) {
        guard enabled else {
            config.scheduledTaskNotifications = false
            saveConfig()
            return
        }
        Task {
            do {
                config.scheduledTaskNotifications = try await ScheduledTaskNotifications.requestAuthorization()
                saveConfig()
            } catch {
                config.scheduledTaskNotifications = false
                saveConfig()
                show(error)
            }
        }
    }

    func startCalibration() {
        guard chargingControlAvailable else { return }
        Task {
            do {
                try await CalibrationTracker.start(cli: cli)
                calibrating = true
                errorMessage = nil
            } catch {
                await refreshAsync()
                show(error)
            }
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
                try await CompletionHandler.restoreDefault(cli: cli,
                                                           chargingControlAvailable: status?.chargingControlAvailable)
                errorMessage = nil
                await refreshAsync()
            } catch { show(error) }
        }
    }

    // MARK: Menu bar icon

    /// Hide or restore the menu bar item. StatusBarController watches
    /// `config.hideStatusBarIcon` and adds or removes the item, so persisting
    /// the flag is the whole action — it also survives a restart, which is what
    /// keeps a hidden icon hidden across launches.
    func setHideStatusBarIcon(_ hidden: Bool) {
        config.hideStatusBarIcon = hidden
        saveConfig()
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
            mode = .idle
            return
        }
        if let status {
            mode = ModeDeriver.derive(config: config, status: status, calibrating: calibrating)
        }
        if case CLIError.chargingControlUnavailable = error {
            errorMessage = Localization.shared.t("Charging control unavailable")
            return
        }
        errorMessage = String(describing: error)
    }
}
