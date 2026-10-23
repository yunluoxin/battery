import XCTest
@testable import BatteryCore

@MainActor
final class CLIFailureTests: XCTestCase {
    func testMaintainFailureThrowsWithExitCodeAndOutput() async throws {
        let cli = try makeCLI("""
        printf '%s\n' 'starting maintain'
        printf '%s\n' 'SMC charging control unavailable' >&2
        exit 23
        """)

        do {
            _ = try await cli.maintain(MaintainRange(lower: 60, upper: 70))
            XCTFail("A failed maintain command must not report success")
        } catch let error as CLIError {
            XCTAssertEqual(error, .commandFailed(
                exitCode: 23,
                output: "starting maintain\nSMC charging control unavailable\n"
            ))
        }
    }

    func testSuccessfulMaintainPreservesOutput() async throws {
        let cli = try makeCLI("printf '%s\\n' \"$*\"")

        let result = try await cli.maintain(MaintainRange(lower: 60, upper: 70))

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout, "maintain 60-70\n")
    }

    func testScheduledCycleReturnsFinalFailureResult() async throws {
        for status in ["50,attached;,enabled,off,,1,0,charging,native", "50,attached;,enabled,off,,1,0,charging"] {
            let cli = try makeCLI("""
            if [ "$1" = status_csv ]; then
                printf '%s\n' '\(status)'
                exit 0
            fi
            printf '%s\n' 'charge failed'
            exit 9
            """)

            let result = try await cli.runScheduledAction(["charge", "80"])

            XCTAssertEqual(result.exitCode, 9)
            XCTAssertEqual(result.stdout, "charge failed\n")
        }
    }

    func testUnavailableControlRejectsChargingCyclesBeforeLaunch() async throws {
        let cli = try makeCLI("""
        if [ "$1" = status_csv ]; then
            printf '%s\n' '90,attached;,unknown,off,60-70,1,0,charging,unavailable'
            exit 0
        fi
        exit 99
        """)

        for arguments in [["charge", "100"], ["calibrate"]] {
            for scheduled in [false, true] {
                do {
                    _ = try await scheduled ? cli.runScheduledAction(arguments) : cli.run(arguments)
                    XCTFail("Unsupported charging must be rejected before starting a cycle")
                } catch let error as CLIError {
                    XCTAssertEqual(error, .chargingControlUnavailable)
                }
            }
        }
    }

    func testManualDischargeDoesNotRequireChargingControl() async throws {
        let cli = try makeCLI("""
        if [ "$1" = status_csv ]; then
            printf '%s\n' '90,attached;,unknown,off,60-70,1,0,charging,unavailable'
            exit 0
        fi
        printf '%s\n' 'discharge completed'
        """)

        let result = try await cli.runScheduledAction(["discharge", "40"])

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout, "discharge completed\n")
    }

    func testScheduledMaintainRecordsCommandFailure() async throws {
        let cli = try makeCLI("""
        printf '%s\n' 'SMC charging control unavailable' >&2
        exit 23
        """)
        let task = ScheduledTask(
            name: "Maintain", action: .maintain, param: "60-70",
            schedule: .daily, hour: 9, minute: 0
        )

        let (success, output, note) = await TaskExecutor.execute(
            task, cli: cli, currentMode: .chargingTo(90)
        )

        XCTAssertFalse(success)
        XCTAssertTrue(output.contains("SMC charging control unavailable"))
        XCTAssertEqual(note, "overrode: charging-to-90")
    }

    private func makeCLI(_ script: String) throws -> ProcessBatteryCLI {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryKeeper-CLIFailureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("battery")
        try ("#!/bin/sh\n" + script + "\n").write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return ProcessBatteryCLI(binaryPath: binary.path)
    }
}
