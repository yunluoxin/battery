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
        // The word, not a duration — see timeRemaining.
        XCTAssertNil(status.timeRemaining)
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

final class AdapterParserTests: XCTestCase {
    /// Real `pmset -g batt` output on AC: the pack is full (or held by a
    /// maintain band) and taking no charge, which is the plug-not-bolt case.
    private let onAC = """
    Now drawing from 'AC Power'
     -InternalBattery-0 (id=7209059)\t71%; AC attached; not charging present: true

    """

    func testAdapterAttached() {
        XCTAssertTrue(BatteryStatusParser.parseAdapterAttached(pmsetOutput: onAC))
    }

    func testOnBatteryPower() {
        let out = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=7209059)\t71%; discharging; 4:11 remaining present: true\n"
        XCTAssertFalse(BatteryStatusParser.parseAdapterAttached(pmsetOutput: out))
    }

    /// The header line alone is enough — older pmset builds do not append
    /// "AC attached" to the battery line.
    func testHeaderOnlyCounts() {
        XCTAssertTrue(BatteryStatusParser.parseAdapterAttached(pmsetOutput: "Now drawing from 'AC Power'\n"))
    }

    /// Unknown stays unknown: no adapter is claimed when pmset says nothing,
    /// so a failed read can never invent a plug on a battery-powered Mac.
    func testEmptyOutput() {
        XCTAssertFalse(BatteryStatusParser.parseAdapterAttached(pmsetOutput: ""))
    }

    /// The menu bar draws the plug from this combination, not from either flag
    /// alone: a full pack on AC and a pack merely sitting idle both report
    /// charging=false, discharging=false.
    func testPluggedInNotCharging() throws {
        var status = try BatteryStatusParser.parseCSV("100,0:00,disabled,not discharging,")
        XCTAssertFalse(status.pluggedInNotCharging)   // adapter unknown
        status.adapterAttached = true
        XCTAssertTrue(status.pluggedInNotCharging)
        status.charging = true
        XCTAssertFalse(status.pluggedInNotCharging)
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

final class EffectiveRangeTests: XCTestCase {
    func testSailingOnUsesFullBand() {
        var config = AppConfig()
        config.sailingEnabled = true
        config.maintainRange = MaintainRange(lower: 70, upper: 80)
        XCTAssertEqual(config.effectiveRange, MaintainRange(lower: 70, upper: 80))
    }

    func testSailingOffCollapsesToUpper() {
        var config = AppConfig()
        config.sailingEnabled = false
        config.maintainRange = MaintainRange(lower: 70, upper: 80)
        XCTAssertEqual(config.effectiveRange, MaintainRange(single: 80))
    }

    /// Regression: the stored band must survive sailing off→on. Previously
    /// disabling sailing overwrote maintainRange with a single value, so
    /// re-enabling (or restarting) showed 70%–70%.
    func testStoredBandSurvivesSailingToggle() {
        var config = AppConfig()
        config.sailingEnabled = true
        config.maintainRange = MaintainRange(lower: 70, upper: 80)

        config.sailingEnabled = false
        // effectiveRange collapses for the CLI…
        XCTAssertEqual(config.effectiveRange, MaintainRange(single: 80))
        // …but the stored band is untouched.
        XCTAssertEqual(config.maintainRange, MaintainRange(lower: 70, upper: 80))

        config.sailingEnabled = true
        XCTAssertEqual(config.effectiveRange, MaintainRange(lower: 70, upper: 80))
    }
}

final class AppConfigDecodingTests: XCTestCase {
    /// Regression: a config.json written before a preference existed is missing
    /// that key. The synthesised decoder throws on a missing key, which made
    /// `JSONStore.load` fall back to defaults and silently reset every other
    /// preference the user had set.
    func testMissingKeysFallBackWithoutLosingStoredValues() throws {
        let json = """
        { "maintainEnabled": true, "maintainRange": { "lower": 60, "upper": 70 }, "sailingEnabled": true }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertTrue(config.maintainEnabled)
        XCTAssertTrue(config.sailingEnabled)
        XCTAssertEqual(config.maintainRange, MaintainRange(lower: 60, upper: 70))
        // Absent keys take the declared default.
        XCTAssertEqual(config.chargeTarget, 100)
        XCTAssertEqual(config.postCompletion, .resumeMaintain)
        XCTAssertTrue(config.showPercentageInMenuBar)
        XCTAssertFalse(config.hideStatusBarIcon)
        XCTAssertEqual(config.language, .system)
        XCTAssertFalse(config.autoLowPower)
        XCTAssertEqual(config.autoLowPowerThreshold, AutoLowPowerRule.defaultThreshold)
    }

    /// A hand-edited or newer-build config can name a level outside the range
    /// the Settings stepper offers, which would leave the row unreadable.
    func testOutOfRangeAutoLowPowerThresholdIsClamped() throws {
        let json = """
        { "autoLowPower": true, "autoLowPowerThreshold": 95 }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertTrue(config.autoLowPower)
        XCTAssertEqual(config.autoLowPowerThreshold, AutoLowPowerRule.thresholdRange.upperBound)
    }

    func testRoundTripKeepsEveryPreference() throws {
        var original = AppConfig()
        original.maintainEnabled = true
        original.maintainRange = MaintainRange(lower: 60, upper: 70)
        original.sailingEnabled = true
        original.chargeTarget = 95
        original.dischargeTarget = 40
        original.launchAtLogin = true
        original.showPercentageInMenuBar = false
        original.hideStatusBarIcon = true
        original.postCompletion = .restoreDefault
        original.language = .zh
        original.autoLowPower = true
        original.autoLowPowerThreshold = 25

        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: data), original)
    }

    /// Each cycle owns its level: topping up runs to 100, discharging stops
    /// well below it, and switching one cycle's level leaves the other alone.
    func testCycleTargetsAreIndependent() {
        var config = AppConfig()
        XCTAssertEqual(config.target(for: .charge), 100)
        XCTAssertEqual(config.target(for: .discharge), 40)

        config.setTarget(60, for: .discharge)
        XCTAssertEqual(config.target(for: .discharge), 60)
        XCTAssertEqual(config.target(for: .charge), 100)

        // Snapping back is what switching the toggle on does.
        config.setTarget(BatteryCycle.charge.defaultTarget, for: .charge)
        config.setTarget(BatteryCycle.discharge.defaultTarget, for: .discharge)
        XCTAssertEqual(config.chargeTarget, 100)
        XCTAssertEqual(config.dischargeTarget, 40)
    }
}

final class AutoLowPowerRuleTests: XCTestCase {
    private func shouldFire(enabled: Bool = true,
                            armed: Bool = true,
                            lowPowerOn: Bool = false,
                            percentage: Int,
                            threshold: Int = AutoLowPowerRule.defaultThreshold) -> Bool {
        AutoLowPowerRule.shouldEnable(enabled: enabled,
                                      armed: armed,
                                      lowPowerOn: lowPowerOn,
                                      percentage: percentage,
                                      threshold: threshold)
    }

    func testFiresAtAndBelowThreshold() {
        XCTAssertTrue(shouldFire(percentage: 20))
        XCTAssertTrue(shouldFire(percentage: 15))
        XCTAssertFalse(shouldFire(percentage: 21))
    }

    /// The rule is deliberately independent of the power source, so a pack on
    /// AC below the threshold still fires.
    func testFiresOnACToo() {
        XCTAssertTrue(shouldFire(percentage: 10))
    }

    func testDisabledRuleNeverFires() {
        XCTAssertFalse(shouldFire(enabled: false, percentage: 5))
    }

    /// Level-triggered behaviour would re-issue the command on every poll.
    func testDisarmedAfterFiring() {
        XCTAssertFalse(shouldFire(armed: false, percentage: 5))
    }

    /// macOS may have switched it on by itself (or the user did); the rule has
    /// no work to do, so it must not count that as a firing and disarm.
    func testAlreadyOnIsNotAFiring() {
        XCTAssertFalse(shouldFire(lowPowerOn: true, percentage: 5))
    }

    /// Re-arming needs the hysteresis band, otherwise a level bouncing either
    /// side of the threshold would fire on consecutive polls.
    func testRearmRequiresClearingTheHysteresisBand() {
        let threshold = AutoLowPowerRule.defaultThreshold
        XCTAssertFalse(AutoLowPowerRule.shouldRearm(percentage: threshold + 1, threshold: threshold))
        XCTAssertFalse(AutoLowPowerRule.shouldRearm(percentage: threshold + AutoLowPowerRule.hysteresis - 1,
                                                    threshold: threshold))
        XCTAssertTrue(AutoLowPowerRule.shouldRearm(percentage: threshold + AutoLowPowerRule.hysteresis,
                                                   threshold: threshold))
        XCTAssertTrue(AutoLowPowerRule.shouldRearm(percentage: 100, threshold: threshold))
    }

    func testClampPullsLevelsIntoTheOfferedRange() {
        XCTAssertEqual(AutoLowPowerRule.clamp(0), AutoLowPowerRule.thresholdRange.lowerBound)
        XCTAssertEqual(AutoLowPowerRule.clamp(-5), AutoLowPowerRule.thresholdRange.lowerBound)
        XCTAssertEqual(AutoLowPowerRule.clamp(1000), AutoLowPowerRule.thresholdRange.upperBound)
        XCTAssertEqual(AutoLowPowerRule.clamp(30), 30)
    }

    /// The whole sequence, which is what the AppState loop actually runs:
    /// fire, stay quiet while it keeps discharging, then re-arm on the way back
    /// up and fire again if it falls a second time.
    func testDropRearmDropFiresTwice() {
        var armed = true
        let threshold = AutoLowPowerRule.defaultThreshold

        func poll(_ percentage: Int, lowPowerOn: Bool) -> Bool {
            if AutoLowPowerRule.shouldRearm(percentage: percentage, threshold: threshold) { armed = true }
            let fires = AutoLowPowerRule.shouldEnable(enabled: true,
                                                     armed: armed,
                                                     lowPowerOn: lowPowerOn,
                                                     percentage: percentage,
                                                     threshold: threshold)
            if fires { armed = false }
            return fires
        }

        XCTAssertTrue(poll(19, lowPowerOn: false))          // crossed the line
        XCTAssertFalse(poll(18, lowPowerOn: true))          // already on, no re-fire
        XCTAssertFalse(poll(15, lowPowerOn: true))          // still down there
        XCTAssertFalse(poll(22, lowPowerOn: true))          // inside the band
        XCTAssertFalse(poll(25, lowPowerOn: true))          // re-armed, but above the line
        XCTAssertTrue(poll(18, lowPowerOn: false))          // second drop fires again
    }
}

final class AppLanguageTests: XCTestCase {
    /// A config written by a newer build — or hand-edited — can name a language
    /// this one does not ship. It must degrade to .system instead of failing
    /// the whole decode and resetting every other preference with it.
    func testUnknownLanguageFallsBackToSystem() throws {
        let json = #"{ "maintainEnabled": true, "language": "kl" }"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.language, .system)
        XCTAssertTrue(config.maintainEnabled)
    }

    func testExplicitLanguagesSurviveARoundTrip() throws {
        for language in [AppLanguage.en, .zh, .system] {
            var config = AppConfig()
            config.language = language
            let data = try JSONEncoder().encode(config)
            XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: data).language, language)
        }
    }

    /// `.system` is resolved, never stored: it has to keep following the Mac's
    /// own language list, including when that list is not English.
    func testSystemResolvesAgainstThePreferredLanguageList() {
        XCTAssertEqual(AppLanguage.resolved(.system, languages: ["zh-Hans-CN", "en-US"]), .zh)
        XCTAssertEqual(AppLanguage.resolved(.system, languages: ["en-GB"]), .en)
        // Nothing we ship: English rather than an untranslatable language.
        XCTAssertEqual(AppLanguage.resolved(.system, languages: ["fr-FR", "de-DE"]), .en)
    }

    /// Only Simplified Chinese ships, so a Traditional Chinese system uses it
    /// rather than falling back to English the way Bundle's own matching would.
    func testEveryChineseScriptResolvesToTheShippedTable() {
        for code in ["zh-Hans", "zh-Hant", "zh-HK", "zh-TW", "zh"] {
            XCTAssertEqual(AppLanguage.resolved(.system, languages: [code]), .zh,
                           "\(code) must not fall back to English")
        }
    }

    /// An explicit choice ignores the system list entirely — that is the whole
    /// point of pinning a language.
    func testExplicitChoiceIgnoresTheSystemList() {
        XCTAssertEqual(AppLanguage.resolved(.en, languages: ["zh-Hans"]), .en)
        XCTAssertEqual(AppLanguage.resolved(.zh, languages: ["en-US"]), .zh)
    }

    func testLprojNamesMatchTheBundledTables() {
        XCTAssertEqual(AppLanguage.en.lproj, "en")
        XCTAssertEqual(AppLanguage.zh.lproj, "zh-Hans")
        XCTAssertNil(AppLanguage.system.lproj, "system resolves before it asks for a table")
    }
}

/// `battery status_csv` derives its remaining_time column from `awk '{print
/// $5}'` over the pmset line, so the column only holds a duration while the
/// pack is running. On AC it holds a scrap of pmset's prose instead, and that
/// is the word that used to surface in the UI verbatim.
final class TimeRemainingTests: XCTestCase {
    private func status(_ remainingTime: String) -> BatteryStatus {
        BatteryStatus(percentage: 71, remainingTime: remainingTime, charging: false,
                      discharging: false, maintain: nil)
    }

    func testAcceptsClockDurations() {
        XCTAssertEqual(status("4:11").timeRemaining, "4:11")
        XCTAssertEqual(status("0:52").timeRemaining, "0:52")
        XCTAssertEqual(status("0:00").timeRemaining, "0:00")
        XCTAssertEqual(status("1:02:03").timeRemaining, "1:02:03")
    }

    /// The actual line on AC: field 5 of "71%; AC attached; not charging".
    func testRejectsTheACProse() {
        XCTAssertNil(status("attached;").timeRemaining)
    }

    /// Any other word awk lands on for the same column.
    func testRejectsOtherWords() {
        for word in ["not", "charging", "discharging;", "calculating", "AC", "-"] {
            XCTAssertNil(status(word).timeRemaining, "\(word) is not a duration")
        }
    }

    func testRejectsEmptyAndMalformed() {
        XCTAssertNil(status("").timeRemaining)
        XCTAssertNil(status("   ").timeRemaining)
        XCTAssertNil(status(":").timeRemaining)
        XCTAssertNil(status("4:").timeRemaining)
        XCTAssertNil(status(":11").timeRemaining)
        XCTAssertNil(status("4::11").timeRemaining)
        XCTAssertNil(status("4:1a").timeRemaining)
        XCTAssertNil(status("4:11:22:33").timeRemaining)
    }

    /// Surrounding whitespace is how the value arrives from the CSV column.
    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(status(" 4:11 ").timeRemaining, "4:11")
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
        let xml = LaunchdManager.plistXML(for: task, helperPath: "/Applications/BatteryKeeper.app/Contents/MacOS/battery-keeper-helper")
        XCTAssertTrue(xml.contains("com.battery.keeper.task.\(taskID.uuidString.lowercased())"))
        XCTAssertTrue(xml.contains("battery-keeper-helper"))
        XCTAssertTrue(xml.contains("--task"))
        XCTAssertTrue(xml.contains(taskID.uuidString))
        XCTAssertTrue(xml.contains("StartCalendarInterval"))
        XCTAssertTrue(xml.contains("<integer>9</integer>"))
    }

    func testLabelFormat() {
        XCTAssertEqual(LaunchdManager.label(for: taskID), "com.battery.keeper.task.\(taskID.uuidString.lowercased())")
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

/// The app bakes its own absolute path into every launchd agent, so moving or
/// re-installing it elsewhere leaves scheduled tasks pointing at a helper that
/// no longer exists. These cover the detection half of the self-repair that
/// runs at launch.
final class LaunchdHelperPathTests: XCTestCase {

    // MARK: Staleness comparison

    func testUnchangedPathNeedsNoReinstall() {
        XCTAssertFalse(LaunchdManager.helperPathChanged(
            installed: "/Applications/BatteryKeeper.app/Contents/MacOS/battery-keeper-helper",
            current: "/Applications/BatteryKeeper.app/Contents/MacOS/battery-keeper-helper"))
    }

    func testMovedAppNeedsReinstall() {
        XCTAssertTrue(LaunchdManager.helperPathChanged(
            installed: "/Users/east/Applications/BatteryKeeper.app/Contents/MacOS/battery-keeper-helper",
            current: "/Applications/BatteryKeeper.app/Contents/MacOS/battery-keeper-helper"))
    }

    func testMissingPlistNeedsNoReinstall() {
        // Nothing installed means nothing to repair — a first run must not
        // bootstrap agents for tasks the user never enabled a schedule on.
        XCTAssertFalse(LaunchdManager.helperPathChanged(installed: nil, current: "/Applications/x/helper"))
    }

    func testTrailingSlashDifferenceCountsAsMoved() {
        // launchd execs the literal string, so a slash difference is a real
        // difference rather than a cosmetic one.
        XCTAssertTrue(LaunchdManager.helperPathChanged(installed: "/Applications/app/helper/", current: "/Applications/app/helper"))
    }

    func testPathWithSpacesSurvivesComparison() {
        XCTAssertTrue(LaunchdManager.helperPathChanged(
            installed: "/Applications/My Apps/BatteryKeeper.app/Contents/MacOS/battery-keeper-helper",
            current: "/Applications/BatteryKeeper.app/Contents/MacOS/battery-keeper-helper"))
    }

    // MARK: Writer/reader round trip

    func testGeneratedXMLReadsBackTheHelperPath() throws {
        // Guards the assumption the whole self-heal rests on: the plist this
        // file writes is parseable, and ProgramArguments[0] really is the path.
        let task = ScheduledTask(name: "T", action: .maintain, param: "80",
                                 schedule: .daily, hour: 9, minute: 0, weekdays: [])
        let helper = "/Applications/BatteryKeeper.app/Contents/MacOS/battery-keeper-helper"
        let xml = LaunchdManager.plistXML(for: task, helperPath: helper)

        let data = Data(xml.utf8)
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        let args = try XCTUnwrap(plist["ProgramArguments"] as? [String])
        XCTAssertEqual(args.first, helper)
    }

    func testHelperPathIsNotConfusedBySiblingArguments() throws {
        // The reader takes ProgramArguments[0]; --task and the id follow it, so
        // a reader that grabbed the wrong element would compare against "on".
        let task = ScheduledTask(name: "T", action: .maintain, param: "80",
                                 schedule: .daily, hour: 9, minute: 0, weekdays: [])
        let helper = "/opt/battery/Contents/MacOS/battery-keeper-helper"
        let data = Data(LaunchdManager.plistXML(for: task, helperPath: helper).utf8)
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        let args = try XCTUnwrap(plist["ProgramArguments"] as? [String])
        XCTAssertEqual(args.count, 3)
        XCTAssertEqual(args, [helper, "--task", task.id.uuidString])
    }
}
