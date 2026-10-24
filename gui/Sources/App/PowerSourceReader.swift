import Foundation
import BatteryCore
import IOKit.ps

/// Reads the power-source state IOKit already maintains, in-process.
///
/// Everything here is a dictionary lookup against IOKit's own cache — no
/// subprocess, no SMC, nothing the visudo entry covers. The GUI's contract of
/// reaching the outside world only through the `battery` CLI stays intact:
/// this reads what macOS publishes to every process, and it exists so a
/// refresh can ask "did anything the CLI knows about actually change?" before
/// paying for the CLI's dozen subprocesses.
enum PowerSourceReader {
    /// The internal battery's current reading, or nil when IOKit reports no
    /// internal battery, or answers with anything less than a full
    /// description. nil makes the caller fall back to a full read, never to
    /// a guess.
    static func read() -> PowerSnapshot? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let percentage = description[kIOPSCurrentCapacityKey] as? Int
            else { continue }
            // The source state names where the machine's power comes from, so
            // an adapter on the port reads as AC even while charging is
            // blocked — the same reading the CLI's adapter column carries,
            // and the reason a force-discharge still draws the plug.
            return PowerSnapshot(
                percentage: percentage,
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                adapterAttached: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                remainingMinutes: Self.estimateMinutes())
        }
        return nil
    }

    /// The system's time-remaining estimate in whole minutes, or nil when
    /// there is none to show: kIOPSTimeRemainingUnknown (-1) while macOS is
    /// between recalculations, kIOPSTimeRemainingUnlimited (-2) on AC —
    /// where the CLI's column holds pmset prose and the UI shows the adapter
    /// state instead of a clock. nil keeps the previous estimate on screen
    /// rather than turning it into "no estimate".
    ///
    /// The function answers in seconds — a CFTimeInterval — whatever its
    /// header docs claim about minutes. Cross-checked against the CLI: a
    /// reading of 9180 lines up with `pmset -g batt`'s "2:33" only as
    /// seconds. Truncating to minutes is the same rounding pmset applies,
    /// so the patched clock and the CLI's own agree.
    private static func estimateMinutes() -> Int? {
        let estimate = IOPSGetTimeRemainingEstimate()
        guard estimate >= 0 else { return nil }
        return Int(estimate / 60)
    }
}
