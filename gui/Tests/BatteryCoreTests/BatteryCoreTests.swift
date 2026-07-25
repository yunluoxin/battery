import XCTest
@testable import BatteryCore

final class BatteryStatusParserTests: XCTestCase {
    func testParsesBasicCSV() throws {
        let status = try BatteryStatusParser.parseCSV("80,2:15,on,off,80\n")
        XCTAssertEqual(status.percentage, 80)
        XCTAssertEqual(status.remainingTime, "2:15")
        XCTAssertTrue(status.charging)
        XCTAssertFalse(status.discharging)
        XCTAssertEqual(status.maintain, "80")
    }

    func testParsesRangeMaintain() throws {
        let status = try BatteryStatusParser.parseCSV("75,0:30,off,off,70-80")
        XCTAssertEqual(status.maintainRange, MaintainRange(lower: 70, upper: 80))
    }

    func testParsesEmptyMaintain() throws {
        let status = try BatteryStatusParser.parseCSV("50,1:00,on,off,")
        XCTAssertNil(status.maintainRange)
    }

    func testDischargingFlag() throws {
        let status = try BatteryStatusParser.parseCSV("60,3:00,off,on,")
        XCTAssertTrue(status.discharging)
        XCTAssertFalse(status.charging)
    }

    func testRealCLIOutputFormat() throws {
        // Actual output from battery CLI v1.3.x
        let status = try BatteryStatusParser.parseCSV("70,attached;,disabled,not discharging,60-70\n")
        XCTAssertEqual(status.percentage, 70)
        XCTAssertFalse(status.charging)
        XCTAssertFalse(status.discharging)
        XCTAssertEqual(status.maintainRange, MaintainRange(lower: 60, upper: 70))
    }

    func testRealCLIEnabledFormat() throws {
        let status = try BatteryStatusParser.parseCSV("55,attached;,enabled,not discharging,")
        XCTAssertTrue(status.charging)
        XCTAssertFalse(status.discharging)
        XCTAssertNil(status.maintainRange)
    }

    func testInvalidCSVThrows() {
        XCTAssertThrowsError(try BatteryStatusParser.parseCSV("garbage"))
    }
}

final class LowPowerModeParserTests: XCTestCase {
    /// Realistic `pmset -g` output shape (multi-line).
    private func pmsetOutput(lowPower: Int) -> String {
        """
        System-wide power settings:
         SleepDisabled\t\t0
        Currently in use:
         standby              1
         Sleep On Power Button 1
         hibernatefile        /var/vm/sleepimage
         powernap             1
         lowpowermode         \(lowPower)
         hibernatemode        3
         ttyskeepawake        1

        """
    }

    func testLowPowerOn() {
        XCTAssertTrue(BatteryStatusParser.parseLowPowerMode(pmsetOutput: pmsetOutput(lowPower: 1)))
    }

    func testLowPowerOff() {
        XCTAssertFalse(BatteryStatusParser.parseLowPowerMode(pmsetOutput: pmsetOutput(lowPower: 0)))
    }

    func testLowPowerMissingKey() {
        let out = "Currently in use:\n standby              1\n sleep                1\n"
        XCTAssertFalse(BatteryStatusParser.parseLowPowerMode(pmsetOutput: out))
    }

    func testLowPowerEmptyOutput() {
        XCTAssertFalse(BatteryStatusParser.parseLowPowerMode(pmsetOutput: ""))
    }

    /// The line must be found even when it's not the first line — this is the
    /// regression the regex-based implementation had (^ didn't match mid-string).
    func testLowPowerNotFirstLine() {
        let out = "Currently in use:\n standby 1\n lowpowermode 1\n hibernatemode 3\n"
        XCTAssertTrue(BatteryStatusParser.parseLowPowerMode(pmsetOutput: out))
    }
}

final class IORegParserTests: XCTestCase {
    /// Mirrors real `ioreg -rn AppleSmartBattery`: top-level keys use
    /// `"Key" = N;` while nested BatteryData keys use `"Key"=N`.
    private let sample = """
      "BatteryData" = {"Temperature"=9999,"CycleCount"=9999,"MaxCapacity"=9999,"Voltage"=12326}
      "DesignCycleCount9C" = 1000
      "MaxCapacity" = 100
      "Temperature" = 3083
      "CycleCount" = 53

    """

    func testParsesTopLevelKeys() {
        XCTAssertEqual(BatteryStatusParser.parseIORegInt("Temperature", from: sample), 3083)
        XCTAssertEqual(BatteryStatusParser.parseIORegInt("CycleCount", from: sample), 53)
        XCTAssertEqual(BatteryStatusParser.parseIORegInt("MaxCapacity", from: sample), 100)
    }

    func testDoesNotMatchNestedKeys() {
        // Nested BatteryData values (9999) must not win over top-level ones.
        let nestedOnly = "  \"BatteryData\" = {\"Temperature\"=9999}\n"
        XCTAssertNil(BatteryStatusParser.parseIORegInt("Temperature", from: nestedOnly))
    }

    func testMissingKey() {
        XCTAssertNil(BatteryStatusParser.parseIORegInt("Nonexistent", from: sample))
    }
}

final class MaintainRangeTests: XCTestCase {
    func testSingleValue() {
        let r = MaintainRange(single: 80)
        XCTAssertEqual(r.cliValue, "80")
        XCTAssertFalse(r.isRange)
        XCTAssertEqual(r.displayValue, "80%")
    }

    func testRangeValue() {
        let r = MaintainRange(lower: 70, upper: 80)
        XCTAssertEqual(r.cliValue, "70-80")
        XCTAssertTrue(r.isRange)
        XCTAssertEqual(r.displayValue, "70% – 80%")
    }

    func testInvertedRangeNormalized() {
        let r = MaintainRange(lower: 80, upper: 70)
        XCTAssertEqual(r.cliValue, "70-80")
    }

    func testParseCLIValue() {
        XCTAssertEqual(MaintainRange(cliValue: "80"), MaintainRange(single: 80))
        XCTAssertEqual(MaintainRange(cliValue: "70-80"), MaintainRange(lower: 70, upper: 80))
        XCTAssertNil(MaintainRange(cliValue: "abc"))
        XCTAssertNil(MaintainRange(cliValue: "1-2-3"))
    }

    func testClamping() {
        let r = MaintainRange.clamped(lower: -5, upper: 250)
        XCTAssertEqual(r.cliValue, "1-100")
    }
}

final class ModeDeriverTests: XCTestCase {
    private func status(pct: Int, charging: Bool = false, discharging: Bool = false) -> BatteryStatus {
        BatteryStatus(percentage: pct, remainingTime: "", charging: charging, discharging: discharging, maintain: nil)
    }

    func testIdle() {
        var config = AppConfig()
        config.maintainEnabled = false
        XCTAssertEqual(ModeDeriver.derive(config: config, status: status(pct: 50), calibrating: false), .idle)
    }

    func testMaintaining() {
        var config = AppConfig()
        config.maintainEnabled = true
        config.maintainRange = MaintainRange(single: 80)
        XCTAssertEqual(ModeDeriver.derive(config: config, status: status(pct: 80), calibrating: false), .maintaining(MaintainRange(single: 80)))
    }

    func testChargingTakesPrecedenceOverMaintain() {
        var config = AppConfig()
        config.maintainEnabled = true
        config.chargeActive = true
        config.chargeTarget = 100
        XCTAssertEqual(ModeDeriver.derive(config: config, status: status(pct: 85), calibrating: false), .chargingTo(100))
    }

    func testCalibratingDominatesAll() {
        var config = AppConfig()
        config.chargeActive = true
        XCTAssertEqual(ModeDeriver.derive(config: config, status: status(pct: 50), calibrating: true), .calibrating)
    }

    func testChargeCycleComplete() {
        let mode = OperatingMode.chargingTo(90)
        // Completion is percentage-only; the SMC charging flag is unreliable
        // mid-cycle (the CLI toggles it while enforcing the limit).
        XCTAssertTrue(ModeDeriver.isCycleComplete(mode: mode, status: status(pct: 92, charging: false)))
        XCTAssertTrue(ModeDeriver.isCycleComplete(mode: mode, status: status(pct: 92, charging: true)))
        XCTAssertFalse(ModeDeriver.isCycleComplete(mode: mode, status: status(pct: 85, charging: true)))
    }

    func testDischargeCycleComplete() {
        let mode = OperatingMode.dischargingTo(70)
        XCTAssertTrue(ModeDeriver.isCycleComplete(mode: mode, status: status(pct: 68)))
        XCTAssertFalse(ModeDeriver.isCycleComplete(mode: mode, status: status(pct: 75, discharging: true)))
    }

    func testCycleCompleteIrrelevantForOtherModes() {
        XCTAssertFalse(ModeDeriver.isCycleComplete(mode: .idle, status: status(pct: 100)))
        XCTAssertFalse(ModeDeriver.isCycleComplete(mode: .maintaining(MaintainRange(single: 80)), status: status(pct: 80)))
    }
}

final class ScheduledTaskTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let task = ScheduledTask(
            name: "Morning topup",
            action: .topup,
            schedule: .weekly,
            hour: 9, minute: 30,
            weekdays: [2, 4]
        )
        let list = TaskList(tasks: [task])
        let data = try JSONEncoder().encode(list)
        let decoded = try JSONDecoder().decode(TaskList.self, from: data)
        XCTAssertEqual(decoded.tasks, [task])
    }

    func testSummary() {
        let daily = ScheduledTask(name: "a", action: .maintain, param: "80", schedule: .daily, hour: 9, minute: 0)
        XCTAssertEqual(daily.summary, "Limit 80% · Daily 09:00")

        let weekly = ScheduledTask(name: "b", action: .topup, schedule: .weekly, hour: 18, minute: 30, weekdays: [2, 6])
        XCTAssertTrue(weekly.summary.contains("Top Up"))
        XCTAssertTrue(weekly.summary.contains("Mo"))
        XCTAssertTrue(weekly.summary.contains("Fr"))
        XCTAssertTrue(weekly.summary.contains("18:30"))
    }
}

final class LaunchdManagerTests: XCTestCase {
    private let taskID = UUID()

    func testDailyIntervals() {
        let task = ScheduledTask(id: taskID, name: "d", action: .maintain, param: "80", schedule: .daily, hour: 9, minute: 15)
        let intervals = LaunchdManager.calendarIntervals(for: task)
        XCTAssertEqual(intervals, [["Hour": 9, "Minute": 15]])
    }

    func testWeekdaysIntervals() {
        let task = ScheduledTask(id: taskID, name: "w", action: .maintain, param: "80", schedule: .weekdays, hour: 8, minute: 0)
        let intervals = LaunchdManager.calendarIntervals(for: task)
        XCTAssertEqual(intervals.count, 5)
        XCTAssertEqual(Set(intervals.compactMap { $0["Weekday"] }), [2, 3, 4, 5, 6])
    }

    func testWeeklyIntervals() {
        let task = ScheduledTask(id: taskID, name: "wk", action: .topup, schedule: .weekly, hour: 10, minute: 30, weekdays: [2, 6])
        let intervals = LaunchdManager.calendarIntervals(for: task)
        XCTAssertEqual(intervals.count, 2)
    }

    func testPlistXMLContainsKeyElements() {
        let task = ScheduledTask(id: taskID, name: "p", action: .maintain, param: "80", schedule: .daily, hour: 9, minute: 0)
        let xml = LaunchdManager.plistXML(for: task, helperPath: "/Applications/BatteryGUI.app/Contents/MacOS/battery-gui-helper")
        XCTAssertTrue(xml.contains("com.battery.gui.task.\(taskID.uuidString.lowercased())"))
        XCTAssertTrue(xml.contains("battery-gui-helper"))
        XCTAssertTrue(xml.contains("--task"))
        XCTAssertTrue(xml.contains(taskID.uuidString))
        XCTAssertTrue(xml.contains("StartCalendarInterval"))
        XCTAssertTrue(xml.contains("<integer>9</integer>"))
    }

    func testLabelFormat() {
        XCTAssertEqual(LaunchdManager.label(for: taskID), "com.battery.gui.task.\(taskID.uuidString.lowercased())")
    }
}

final class TaskExecutorTests: XCTestCase {
    actor MockCLI: BatteryCLI {
        var calls: [[String]] = []
        var statusResult: BatteryStatus = BatteryStatus(percentage: 80, remainingTime: "", charging: false, discharging: false, maintain: nil)

        func status() async throws -> BatteryStatus { statusResult }
        func run(_ arguments: [String]) async throws -> CLIResult {
            calls.append(arguments)
            return CLIResult(exitCode: 0, stdout: "ok", stderr: "")
        }
    }

    func testMaintainAction() async {
        let cli = MockCLI()
        let task = ScheduledTask(name: "t", action: .maintain, param: "70-80", schedule: .daily, hour: 9, minute: 0)
        let (success, _, _) = await TaskExecutor.execute(task, cli: cli, currentMode: .idle)
        XCTAssertTrue(success)
        let calls = await cli.calls
        XCTAssertEqual(calls, [["maintain", "70-80"]])
    }

    func testTopupAction() async {
        let cli = MockCLI()
        let task = ScheduledTask(name: "t", action: .topup, schedule: .daily, hour: 9, minute: 0)
        _ = await TaskExecutor.execute(task, cli: cli, currentMode: .idle)
        let calls = await cli.calls
        XCTAssertEqual(calls, [["charge", "100"]])
    }

    func testLowPowerAction() async {
        let cli = MockCLI()
        let task = ScheduledTask(name: "t", action: .lowpower, param: "on", schedule: .daily, hour: 9, minute: 0)
        _ = await TaskExecutor.execute(task, cli: cli, currentMode: .idle)
        let calls = await cli.calls
        XCTAssertEqual(calls, [["low", "on"]])
    }

    func testOverrideNote() async {
        let cli = MockCLI()
        let task = ScheduledTask(name: "t", action: .maintain, param: "80", schedule: .daily, hour: 9, minute: 0)
        let (_, _, note) = await TaskExecutor.execute(task, cli: cli, currentMode: .chargingTo(90))
        XCTAssertEqual(note, "overrode: charging-to-90")
    }

    func testNoOverrideNoteWhenIdle() async {
        let cli = MockCLI()
        let task = ScheduledTask(name: "t", action: .maintain, param: "80", schedule: .daily, hour: 9, minute: 0)
        let (_, _, note) = await TaskExecutor.execute(task, cli: cli, currentMode: .idle)
        XCTAssertNil(note)
    }
}

final class CompletionHandlerTests: XCTestCase {
    actor RecordingCLI: BatteryCLI {
        var calls: [[String]] = []
        func status() async throws -> BatteryStatus {
            BatteryStatus(percentage: 80, remainingTime: "", charging: false, discharging: false, maintain: nil)
        }
        func run(_ arguments: [String]) async throws -> CLIResult {
            calls.append(arguments)
            return CLIResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    func testResumeMaintain() async {
        let cli = RecordingCLI()
        var config = AppConfig()
        config.postCompletion = .resumeMaintain
        config.maintainEnabled = true
        config.maintainRange = MaintainRange(single: 80)
        try? await CompletionHandler.handleCompletion(config: config, cli: cli)
        let calls = await cli.calls
        XCTAssertEqual(calls, [["maintain", "80"]])
    }

    func testResumeMaintainFallsBackToDefaultWhenDisabled() async {
        let cli = RecordingCLI()
        var config = AppConfig()
        config.postCompletion = .resumeMaintain
        config.maintainEnabled = false
        try? await CompletionHandler.handleCompletion(config: config, cli: cli)
        let calls = await cli.calls
        XCTAssertEqual(calls, [["maintain", "stop"], ["charging", "on"], ["adapter", "on"]])
    }

    func testRestoreDefault() async {
        let cli = RecordingCLI()
        var config = AppConfig()
        config.postCompletion = .restoreDefault
        config.maintainEnabled = true
        try? await CompletionHandler.handleCompletion(config: config, cli: cli)
        let calls = await cli.calls
        XCTAssertEqual(calls, [["maintain", "stop"], ["charging", "on"], ["adapter", "on"]])
    }
}
