import Foundation

/// When the app should switch Low Power Mode on by itself: the charge level has
/// reached or dropped below the configured threshold.
///
/// Deliberately blind to the power source — the rule fires on AC as well as on
/// battery, so a pack sitting at 15% on a charger still gets the system's
/// power-saving behaviour.
///
/// The rule is edge-triggered, not level-triggered. `AppState` owns the armed
/// flag and hands it in: once the rule has fired it stays disarmed and further
/// polls do nothing however low the level goes, so a single discharge produces
/// a single `smc low on`. `shouldRearm` puts the flag back only after the level
/// has climbed clear of the threshold by `hysteresis`, which is what stops a
/// level hovering around the threshold from firing over and over.
///
/// Only switching *on* is automatic. Nothing here turns Low Power Mode back off
/// — the popover's manual toggle does that, and a mode the user can see and
/// change is easier to reason about than one that flips on its own.
public enum AutoLowPowerRule {
    /// How far above the threshold the level must recover before the rule is
    /// allowed to fire again. Without it, a battery oscillating either side of
    /// the threshold would re-arm and re-fire on consecutive polls.
    public static let hysteresis = 5

    /// Bounds offered by the Settings stepper. Under 10% the rule would fire on
    /// a pack that is merely tired; over 50% it would fire on a healthy one.
    public static let thresholdRange = 10...50
    public static let defaultThreshold = 20

    /// Pull a level into the offered range, for stored values and stepper input.
    public static func clamp(_ threshold: Int) -> Int {
        min(max(threshold, thresholdRange.lowerBound), thresholdRange.upperBound)
    }

    /// Whether this poll should switch Low Power Mode on.
    ///
    /// - Parameters:
    ///   - armed: false while a previous firing is still outstanding.
    ///   - lowPowerOn: the real system state, already mirrored by `AppState`.
    ///     Already-on is not a firing — the command would be a no-op the CLI
    ///     still has to make.
    public static func shouldEnable(enabled: Bool,
                                    armed: Bool,
                                    lowPowerOn: Bool,
                                    percentage: Int,
                                    threshold: Int) -> Bool {
        guard enabled, armed, !lowPowerOn else { return false }
        return percentage <= threshold
    }

    /// Whether the rule may fire again after a firing.
    public static func shouldRearm(percentage: Int, threshold: Int) -> Bool {
        percentage >= clamp(threshold) + hysteresis
    }
}
