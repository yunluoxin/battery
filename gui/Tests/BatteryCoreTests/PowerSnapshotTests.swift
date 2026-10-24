import XCTest
@testable import BatteryCore

final class PowerSnapshotTests: XCTestCase {
    // MARK: Building from a CLI status

    func testSnapshotFromStatusMirrorsTheReading() {
        let status = try! BatteryStatusParser.parseCSV("55,1:30,off,on,,1,1,charging,native")
        let snapshot = PowerSnapshot(status: status)
        XCTAssertEqual(snapshot.percentage, 55)
        // Charging and on AC — the one state the bolt is allowed to claim.
        XCTAssertTrue(snapshot.isCharging)
        XCTAssertTrue(snapshot.adapterAttached)
        XCTAssertEqual(snapshot.remainingMinutes, 90)
    }

    /// The bolt question is "is charge moving", never "is charging allowed".
    /// The permission flag reads enabled on every healthy machine; the live
    /// state is what decides.
    func testPermissionFlagAloneNeverCountsAsCharging() {
        let status = try! BatteryStatusParser.parseCSV("55,attached;,on,not discharging,")
        let snapshot = PowerSnapshot(status: status)
        XCTAssertFalse(snapshot.isCharging)
        // No live column and prose in the estimate slot: the snapshot must
        // carry no estimate either.
        XCTAssertNil(snapshot.remainingMinutes)
    }

    /// A pack blocked on AC — the state this app parks in — reads the same
    /// through the CLI and through IOKit: on AC, not charging. This is the
    /// pair of readings the fast path has to call equal.
    func testParkedOnACMatchesAnIOKitStyleReading() {
        let status = try! BatteryStatusParser.parseCSV("70,attached;,disabled,not discharging,60-70,1,0,not charging")
        let snapshot = PowerSnapshot(status: status)
        let fromIOKit = PowerSnapshot(percentage: 70, isCharging: false, adapterAttached: true, remainingMinutes: nil)
        XCTAssertEqual(snapshot, fromIOKit)
    }

    // MARK: Equality

    /// The estimate is the field that moves when nothing else does — macOS
    /// republishes it about once a minute. Equality has to ignore it, or
    /// every estimate tick would cost a full CLI read, which is the exact
    /// cost this type exists to avoid.
    func testEqualityIgnoresTheEstimate() {
        let a = PowerSnapshot(percentage: 40, isCharging: false, adapterAttached: false, remainingMinutes: 259)
        let b = PowerSnapshot(percentage: 40, isCharging: false, adapterAttached: false, remainingMinutes: 241)
        let noEstimate = PowerSnapshot(percentage: 40, isCharging: false, adapterAttached: false, remainingMinutes: nil)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, noEstimate)
    }

    func testEqualityCatchesReadingChanges() {
        let base = PowerSnapshot(percentage: 40, isCharging: false, adapterAttached: false, remainingMinutes: 259)
        XCTAssertNotEqual(base, PowerSnapshot(percentage: 39, isCharging: false, adapterAttached: false, remainingMinutes: 259))
        XCTAssertNotEqual(base, PowerSnapshot(percentage: 40, isCharging: true, adapterAttached: false, remainingMinutes: 259))
        XCTAssertNotEqual(base, PowerSnapshot(percentage: 40, isCharging: false, adapterAttached: true, remainingMinutes: 259))
    }

    // MARK: Clock parsing

    func testParsesHoursAndMinutes() {
        let status = try! BatteryStatusParser.parseCSV("37,4:19,enabled,not discharging,60-70,0,1,discharging")
        XCTAssertEqual(PowerSnapshot(status: status).remainingMinutes, 259)
    }

    /// The longer estimates carry seconds; they are truncated, since the
    /// value only feeds a display the next full read replaces.
    func testTruncatesSeconds() {
        let status = try! BatteryStatusParser.parseCSV("20,1:02:30,off,on,")
        XCTAssertEqual(PowerSnapshot(status: status).remainingMinutes, 62)
    }

    // MARK: Display patch

    func testUpdatedRemainingTimeFormatsAsClock() {
        let status = try! BatteryStatusParser.parseCSV("37,4:19,enabled,not discharging,60-70,0,1,discharging")
        let snapshot = PowerSnapshot(percentage: 37, isCharging: false, adapterAttached: false, remainingMinutes: 0)
        XCTAssertEqual(snapshot.updatedRemainingTime(for: status), "0:00")
    }

    func testSixtyFiveMinutesReadsAsOneOhFive() {
        let status = try! BatteryStatusParser.parseCSV("37,1:05,enabled,not discharging,,0,1,discharging")
        let snapshot = PowerSnapshot(percentage: 37, isCharging: false, adapterAttached: false, remainingMinutes: 65)
        XCTAssertEqual(snapshot.updatedRemainingTime(for: status), "1:05")
    }

    func testTenHoursKeepsTheSameShape() {
        let status = try! BatteryStatusParser.parseCSV("90,10:00,off,off,,0,1,not charging")
        let snapshot = PowerSnapshot(percentage: 90, isCharging: false, adapterAttached: true, remainingMinutes: 600)
        XCTAssertEqual(snapshot.updatedRemainingTime(for: status), "10:00")
    }

    /// Only a countdown the CLI itself started is continued. An estimate
    /// arriving while the status line holds pmset prose must not put a clock
    /// where the UI shows the adapter state.
    func testDoesNotStartACountdownFromProse() {
        let status = try! BatteryStatusParser.parseCSV("70,attached;,disabled,not discharging,60-70,1,0,not charging")
        let snapshot = PowerSnapshot(percentage: 70, isCharging: false, adapterAttached: true, remainingMinutes: 120)
        XCTAssertNil(snapshot.updatedRemainingTime(for: status))
    }

    /// macOS between recalculations reports no estimate; the previous figure
    /// stays on screen rather than being blanked.
    func testNilEstimateLeavesTheDisplayAlone() {
        let status = try! BatteryStatusParser.parseCSV("37,4:19,enabled,not discharging,,0,0,discharging")
        let snapshot = PowerSnapshot(percentage: 37, isCharging: false, adapterAttached: false, remainingMinutes: nil)
        XCTAssertNil(snapshot.updatedRemainingTime(for: status))
    }

    /// The round trip the refresh loop actually performs: a CLI clock becomes
    /// the baseline's estimate, an IOKit snapshot of the same world becomes a
    /// clock again, and the two must agree — the display patch compares them
    /// to decide whether republishing is worth anything.
    func testRoundTripPreservesTheClock() {
        let status = try! BatteryStatusParser.parseCSV("37,4:19,enabled,not discharging,,0,0,discharging")
        let baseline = PowerSnapshot(status: status)
        let sameWorld = PowerSnapshot(percentage: 37, isCharging: false, adapterAttached: false, remainingMinutes: 259)
        XCTAssertEqual(sameWorld.updatedRemainingTime(for: status), status.remainingTime)
        XCTAssertEqual(baseline, sameWorld)
    }
}
