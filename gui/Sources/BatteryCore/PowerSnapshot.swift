import Foundation

/// What the power supply is doing, as IOKit reports it in-process.
///
/// The refresh cycle's fast path is built on this: an IOKit notification
/// carries a snapshot for free, and comparing it against the one derived from
/// the last `battery status_csv` read decides whether that read has to run
/// again. Three fields are the comparison; `remainingMinutes` rides along for
/// display only — the time-remaining estimate is the one thing macOS
/// recomputes on its own every minute, which is exactly the tick this
/// comparison exists to absorb.
public struct PowerSnapshot: Equatable, Sendable {
    public let percentage: Int
    /// Whether the pack is taking charge right now — `BatteryStatus`'s
    /// `isChargingNow`, not the charging *permission* flag the CSV's third
    /// column carries.
    public let isCharging: Bool
    public let adapterAttached: Bool
    /// The time-remaining estimate in minutes, or nil when macOS has none:
    /// `kIOPSTimeRemainingUnknown` while it recalculates, or a status line
    /// that carried prose instead of a clock.
    public let remainingMinutes: Int?

    public init(percentage: Int, isCharging: Bool, adapterAttached: Bool, remainingMinutes: Int?) {
        self.percentage = percentage
        self.isCharging = isCharging
        self.adapterAttached = adapterAttached
        self.remainingMinutes = remainingMinutes
    }

    /// The snapshot as the last full CLI read saw the world, so an IOKit
    /// snapshot can be compared against it field for field. Both sides read
    /// the same source — `pmset`'s battery line is IOKit's power-source
    /// description through a shell — so equal readings here really are equal.
    public init(status: BatteryStatus) {
        self.init(
            percentage: status.percentage,
            isCharging: status.isChargingNow,
            adapterAttached: status.adapterAttached,
            remainingMinutes: status.timeRemaining.flatMap(Self.minutes(inClock:)))
    }

    /// Equality over the reading alone. `remainingMinutes` is deliberately
    /// excluded: it is the field that changes when nothing else did, and
    /// counting it would turn every estimate refresh into a full CLI read —
    /// the cost this type exists to avoid. The estimate reaches the UI
    /// through `updatedRemainingTime(for:)` instead.
    public static func == (lhs: PowerSnapshot, rhs: PowerSnapshot) -> Bool {
        lhs.percentage == rhs.percentage
            && lhs.isCharging == rhs.isCharging
            && lhs.adapterAttached == rhs.adapterAttached
    }

    /// The countdown to keep showing after this snapshot, or nil when the
    /// display is to be left alone.
    ///
    /// Only a countdown the CLI itself started is continued: an estimate that
    /// turns up while the status line holds pmset prose ("attached;") would
    /// put a clock where the UI shows the adapter state instead, so a nil
    /// `timeRemaining` patches nothing and the next full read decides. A nil
    /// estimate here — macOS between recalculations — likewise keeps the
    /// previous figure rather than blanking it.
    public func updatedRemainingTime(for status: BatteryStatus) -> String? {
        guard let minutes = remainingMinutes, status.timeRemaining != nil else { return nil }
        let padded = minutes % 60 < 10 ? "0\(minutes % 60)" : "\(minutes % 60)"
        return "\(minutes / 60):\(padded)"
    }

    /// Minutes from the CLI's clock ("H:MM", or "H:MM:SS" for the longer
    /// estimates). `timeRemaining` has already vetted the shape, so the
    /// subscripts hold numbers or nothing at all. Seconds are truncated: the
    /// value feeds a display the next full read replaces, and the comparison
    /// ignores it entirely.
    private static func minutes(inClock time: String) -> Int? {
        let parts = time.split(separator: ":", omittingEmptySubsequences: false)
        guard let hours = Int(parts[0]), let minutes = Int(parts[1]) else { return nil }
        return hours * 60 + minutes
    }
}
