import XCTest
@testable import BatteryCore

@MainActor
final class ControlAvailabilityTests: XCTestCase {
    func testSupportedBackendsKeepLiveChargingSeparate() throws {
        for backend in ["legacy", "tahoe", "native"] {
            let status = try BatteryStatusParser.parseCSV("90,attached;,unknown,off,60-70,1,0,charging,\(backend)")
            XCTAssertEqual(status.chargingControlAvailable, true, backend)
            XCTAssertTrue(status.charging)
            XCTAssertEqual(status.maintainRange, MaintainRange(lower: 60, upper: 70))
        }
    }

    func testUnavailableBackendsStillReportRealCharging() throws {
        for backend in ["unsupported", "unavailable"] {
            let status = try BatteryStatusParser.parseCSV("90,attached;,enabled,off,60-70,1,0,charging,\(backend)")
            XCTAssertEqual(status.chargingControlAvailable, false, backend)
            XCTAssertTrue(status.charging)
            XCTAssertTrue(status.adapterAttached)
        }
    }

    func testOlderUnknownChargingControlIsUnavailable() throws {
        for csv in ["90,attached;,unknown,off,60-70", "90,attached;,unknown,off,60-70,1,0,charging"] {
            let status = try BatteryStatusParser.parseCSV(csv)
            XCTAssertEqual(status.chargingControlAvailable, false)
        }
    }

    func testOlderSupportedFormatsRemainUnspecified() throws {
        for control in ["on", "off", "enabled", "disabled"] {
            let status = try BatteryStatusParser.parseCSV("70,attached;,\(control),off,60-70")
            XCTAssertNil(status.chargingControlAvailable)
        }
    }

    func testUnrecognizedBackendDoesNotClaimSupport() throws {
        let status = try BatteryStatusParser.parseCSV("70,attached;,enabled,off,60-70,1,0,idle,future")
        XCTAssertNil(status.chargingControlAvailable)
    }

    func testUnavailableControlDoesNotClaimChargingModesOrChangeSavedRange() {
        var config = AppConfig()
        config.maintainEnabled = true
        config.sailingEnabled = true
        config.maintainRange = MaintainRange(lower: 60, upper: 70)
        let status = makeStatus(available: false)

        XCTAssertEqual(ModeDeriver.derive(config: config, status: status, calibrating: false), .idle)
        config.chargeActive = true
        XCTAssertEqual(ModeDeriver.derive(config: config, status: status, calibrating: false), .idle)
        XCTAssertEqual(ModeDeriver.derive(config: config, status: status, calibrating: true), .idle)
        XCTAssertEqual(config.effectiveRange, MaintainRange(lower: 60, upper: 70))
        XCTAssertTrue(config.maintainEnabled)
    }

    func testSupportedAndUnspecifiedControlPreserveMaintainMode() {
        var config = AppConfig()
        config.maintainEnabled = true
        config.maintainRange = MaintainRange(lower: 60, upper: 70)

        for available: Bool? in [true, nil] {
            XCTAssertEqual(
                ModeDeriver.derive(config: config, status: makeStatus(available: available), calibrating: false),
                .maintaining(config.maintainRange)
            )
        }
    }

    func testManualDischargeRemainsActiveWithoutChargingControl() {
        var config = AppConfig()
        config.maintainEnabled = true
        config.dischargeActive = true
        config.dischargeTarget = 40

        let mode = ModeDeriver.derive(config: config, status: makeStatus(available: false), calibrating: false)

        XCTAssertEqual(mode, .dischargingTo(40))
        XCTAssertTrue(ModeDeriver.isCycleComplete(mode: mode, status: makeStatus(available: false)))
    }

    func testManualDischargeCompletionRestoresAdapterWithoutChargingCommands() async throws {
        for policy in [PostCompletionBehavior.resumeMaintain, .restoreDefault] {
            let cli = RecordingCLI()
            var config = AppConfig()
            config.maintainEnabled = true
            config.postCompletion = policy

            try await CompletionHandler.handleCompletion(config: config, cli: cli, chargingControlAvailable: false)

            let calls = await cli.calls
            XCTAssertEqual(calls, [["adapter", "on"]])
        }
    }

    func testRestoreDefaultsStopsMaintenanceAndRestoresAdapterWhenUnavailable() async throws {
        let cli = RecordingCLI()

        try await CompletionHandler.restoreDefault(cli: cli, chargingControlAvailable: false)

        let calls = await cli.calls
        XCTAssertEqual(calls, [["maintain", "stop"], ["adapter", "on"]])
    }

    private func makeStatus(available: Bool?) -> BatteryStatus {
        BatteryStatus(percentage: 40, remainingTime: "", charging: false, discharging: true,
                      maintain: "60-70", chargingControlAvailable: available)
    }

    private actor RecordingCLI: BatteryCLI {
        var calls: [[String]] = []

        func status() async throws -> BatteryStatus {
            BatteryStatus(percentage: 40, remainingTime: "", charging: false, discharging: true, maintain: nil)
        }

        func run(_ arguments: [String]) async throws -> CLIResult {
            calls.append(arguments)
            return CLIResult(exitCode: 0, stdout: "", stderr: "")
        }
    }
}
