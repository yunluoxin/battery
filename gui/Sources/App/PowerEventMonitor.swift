import AppKit
import Foundation
import BatteryCore
import IOKit.ps

/// Watches for the moments the battery reading changes on its own, so the app
/// can refresh when something happened instead of on a fixed timer.
///
/// Three sources, all events macOS already maintains:
/// - IOKit's power-source notification fires when the reported percentage or
///   time remaining changes, and when the adapter is attached or pulled. This
///   is what keeps the menu bar live while a pack charges or drains, and it
///   stays silent while the pack sits parked at its maintain limit — the state
///   this app spends most of its time in, and the reason the old timer spent
///   most of a day asking a question whose answer never changed. The callback
///   attaches a `PowerSnapshot` read from IOKit in-process, which lets the
///   app tell an estimate-only change (nothing to do but move a countdown)
///   from a reading change worth a CLI run — see `AppState.refreshAsync`.
/// - `NSWorkspace.didWakeNotification`: a sleeping Mac runs no timers, so
///   after a lid-open the reading was up to a poll interval stale.
/// - `NSProcessInfoPowerStateDidChangeNotification`: Low Power Mode was
///   switched in System Settings. IOKit's battery fields do not carry that
///   bit, so these events arrive without a snapshot and always get a full
///   read. The state itself is still read from pmset as before — the
///   notification only says it is worth re-reading now.
///
/// Events arrive in bursts (IOKit can report a percentage and a time change
/// together) and every refresh costs a dozen subprocesses, so events landing
/// within `minimumRefreshInterval` of the previous refresh fold into a single
/// refresh — at the *end* of the interval rather than on the first arrival,
/// so what gets read is the burst's last state and not its first. The
/// interval is also the floor it names: no event-driven refresh runs sooner
/// than that after the last one, so a system given to reporting power-state
/// flaps every few seconds still costs one CLI run per interval, not one per
/// flap.
@MainActor
final class PowerEventMonitor {
    /// Length of the folding window and the floor between event-driven
    /// refreshes. Comfortably longer than the gap between two notifications
    /// describing the same change — those land a second or two apart — and
    /// still far shorter than the minute the old poll needed to notice
    /// anything at all.
    private static let minimumRefreshInterval: TimeInterval = 30

    /// `nonisolated(unsafe)` because `deinit` is nonisolated and still has to
    /// unschedule the source. Every other access is on the main actor, and
    /// `CFRunLoopRemoveSource` only reads the reference, so the pointer is
    /// never handed across an isolation boundary.
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    /// Each token paired with the center it was registered on, since a token
    /// only unregisters from the center that vends it.
    private var notificationObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    /// When the last refresh ran, or nil before the first one. Left nil until
    /// then so the first event after launch always refreshes, even if the
    /// launch-time read failed.
    ///
    /// Only events count towards this, not the explicit refreshes the app
    /// makes on its own when the user changes something. Those are already the
    /// answer to whatever prompted them, and letting them swallow an unrelated
    /// event would only delay it.
    private var lastRefresh: Date?
    /// The refresh waiting out the current window, replaced rather than
    /// stacked so a long burst still costs one set of subprocesses.
    private var pendingRefresh: Task<Void, Never>?
    private let onChange: @MainActor (PowerSnapshot?) -> Void

    init(onChange: @escaping @MainActor (PowerSnapshot?) -> Void) {
        self.onChange = onChange
    }

    /// The run loop source holds a raw pointer back to this object, so it must
    /// be unscheduled as part of tearing the monitor down rather than left to
    /// outlive it. The notification tokens unregister themselves when the
    /// last reference to them goes away.
    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, CFRunLoopMode.commonModes)
        }
    }

    func start() {
        guard runLoopSource == nil else { return }
        schedulePowerSourceNotifications()
        observe(NSWorkspace.didWakeNotification, on: NSWorkspace.shared.notificationCenter)
        observe(NSNotification.Name.NSProcessInfoPowerStateDidChange, on: .default)
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, CFRunLoopMode.commonModes)
            self.runLoopSource = nil
        }
        pendingRefresh?.cancel()
        pendingRefresh = nil
        for observer in notificationObservers {
            observer.center.removeObserver(observer.token)
        }
        notificationObservers = []
    }

    // MARK: IOKit

    /// Subscribe to IOKit's power-source notification.
    ///
    /// The callback is a C function pointer, so it cannot capture: the monitor
    /// travels as the opaque context and is recovered on the far side. The
    /// source is scheduled on the main run loop, which is what makes the hop
    /// in the callback's `assumeIsolated` sound — the same reasoning the menu
    /// bar icon's drawing handler relies on. The snapshot is read here, on
    /// the same thread the callback lands on, while the reading IOKit is
    /// notifying about is at its freshest.
    private func schedulePowerSourceNotifications() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerEventMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.receivedNotification(PowerSourceReader.read()) }
        }, context)?.takeRetainedValue() else { return }

        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
    }

    // MARK: NotificationCenter

    /// The other two sources announce changes no battery reading describes —
    /// a wake, a Low Power Mode flip — so they travel without a snapshot and
    /// the app reads the CLI in full.
    private func observe(_ name: Notification.Name, on center: NotificationCenter) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.receivedNotification(nil) }
        }
        notificationObservers.append((center, observer))
    }

    // MARK: Debounce

    private func receivedNotification(_ snapshot: PowerSnapshot?) {
        let now = Date()
        guard let lastRefresh, now.timeIntervalSince(lastRefresh) < Self.minimumRefreshInterval else {
            refresh(snapshot)
            return
        }
        // Inside the interval, so read the state at its end rather than
        // dropping the event.
        //
        // Dropping it is what a plain debounce does, and it is wrong here,
        // because IOKit reports a change and its consequence as separate
        // notifications a second or two apart. Plugging an adapter in fires
        // one for the adapter and another for the charge starting that
        // follows it; refreshing on the first and ignoring the second left the
        // app reading a world where the pack was plugged in and not filling,
        // which for the menu bar's bolt means wrong until the safety-net poll
        // came round minutes later. The trailing end doubles as the floor:
        // the fold lands no earlier than a full interval after the refresh
        // this event would otherwise have interrupted.
        let delay = Self.minimumRefreshInterval - now.timeIntervalSince(lastRefresh)
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.refresh(snapshot)
        }
    }

    private func refresh(_ snapshot: PowerSnapshot?) {
        lastRefresh = Date()
        onChange(snapshot)
    }
}
