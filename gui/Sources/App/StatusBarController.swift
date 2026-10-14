import AppKit
import SwiftUI
import BatteryCore
import Combine

/// Owns the NSStatusItem and routes left click → popover, right click →
/// toggle Low Power Mode.
///
/// The item is created and removed as the "Hide status bar icon" preference
/// flips; while hidden there is no item at all, not an empty one.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    /// Nil while the icon is hidden: the item is removed from the status bar
    /// rather than left in place with an empty image, so it takes no space and
    /// leaves no gap in the bar.
    private var statusItem: NSStatusItem?
    private let popover: NSPopover
    private let state: AppState
    private var cancellables = Set<AnyCancellable>()
    private var eventMonitor: Any?
    /// Shorthand for the shared table, for the few strings this class builds
    /// outside a view's body.
    private var l10n: Localization { Localization.shared }
    /// Everything the current icon encodes, so an unchanged poll is a no-op.
    private var renderedKey: IconKey?
    /// The last icon built by the lazy drawing handler, keyed by everything
    /// that goes into it.
    private var iconCache: (style: IconStyle, image: NSImage)?
    /// The latest icon inputs, replayed onto a status item created after the
    /// app started, so a freshly restored icon paints now rather than sitting
    /// blank until the next poll.
    private var latestIconState: (mode: OperatingMode, lowPower: Bool, status: BatteryStatus?, showPercentage: Bool)?

    init(state: AppState) {
        self.state = state
        popover = NSPopover()
        super.init()

        popover.contentViewController = NSHostingController(rootView: PopoverView()
            .environmentObject(state)
            .environmentObject(Localization.shared))
        popover.behavior = .transient
        popover.delegate = self

        // Update the icon when relevant state changes.
        Publishers.CombineLatest4(state.$mode, state.$lowPowerOn, state.$status, state.$config)
            .receive(on: RunLoop.main)
            .sink { [weak self] mode, lowPower, status, config in
                guard let self else { return }
                self.latestIconState = (mode, lowPower, status, config.showPercentageInMenuBar)
                self.updateIcon(mode: mode, lowPower: lowPower, status: status, showPercentage: config.showPercentageInMenuBar)
            }
            .store(in: &cancellables)

        // Add or remove the menu bar item as the preference flips. This also
        // fires once on subscribe, which is what creates the item at launch.
        state.$config
            .map(\.hideStatusBarIcon)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] hidden in self?.setStatusItemHidden(hidden) }
            .store(in: &cancellables)
    }

    /// Create a status item wired up for left/right click routing.
    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "battery.100", accessibilityDescription: l10n.t("Battery"))
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        return item
    }

    /// Show or hide the menu bar item.
    ///
    /// The item is removed from the status bar rather than left in place with
    /// an empty image, so hiding it frees the space instead of leaving a gap.
    /// The app stays an accessory with no dock icon either way: Launchpad still
    /// lists it, and tapping it while it runs reopens the main panel — see
    /// `AppDelegate.applicationShouldHandleReopen`.
    private func setStatusItemHidden(_ hidden: Bool) {
        if hidden {
            // The popover is anchored to the button that is about to go away.
            popover.performClose(nil)
            renderedKey = nil
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
        } else if statusItem == nil {
            statusItem = makeStatusItem()
            // A new item has never been painted, so force the next update
            // through instead of waiting for state to drift.
            renderedKey = nil
            if let latest = latestIconState {
                updateIcon(mode: latest.mode, lowPower: latest.lowPower, status: latest.status, showPercentage: latest.showPercentage)
            }
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        switch event.type {
        case .rightMouseUp:
            state.toggleLowPower()
        default:
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            state.refresh()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: Icon

    /// What the menu bar currently shows. Compared against the incoming state
    /// so a poll that finds nothing new never touches the status item: every
    /// `image`/`title` assignment re-lays-out the menu bar, and the poller
    /// republishes the same values every minute. The percentage only counts
    /// when it is on screen — otherwise a 1% drift would repaint a battery
    /// glyph that has not changed.
    private struct IconKey: Equatable {
        let calibrating: Bool
        let level: Int          // 0/25/50/75/100, -1 when status is unknown
        let charging: Bool
        let pluggedIn: Bool
        let lowPower: Bool
        let percentage: Int      // only meaningful when showPercentage is on
        let showPercentage: Bool
        /// Part of the key because the accessibility description is localized:
        /// without it, switching language would leave the previous language's
        /// label on screen until the battery level happened to change.
        let language: AppLanguage
    }

    /// Everything that goes into the pixels of one icon build. `dark` is not
    /// known when the status item is configured — see `statusImage`.
    private struct IconStyle: Equatable {
        let level: Int
        let charging: Bool
        let pluggedIn: Bool
        let tinted: Bool
        let dark: Bool
    }

    private func updateIcon(mode: OperatingMode, lowPower: Bool, status: BatteryStatus?, showPercentage: Bool) {
        let percentage = status?.percentage
        let key = IconKey(
            calibrating: mode == .calibrating,
            level: percentage.map(StatusIcon.level(for:)) ?? -1,
            charging: Self.isCharging(mode: mode, status: status),
            pluggedIn: Self.isPluggedIn(mode: mode, status: status),
            lowPower: lowPower,
            percentage: showPercentage ? (percentage ?? -1) : -1,
            showPercentage: showPercentage,
            language: l10n.language
        )
        // Nothing to paint while hidden: skip the whole body so a poll cannot
        // repopulate an item the user just removed.
        guard let button = statusItem?.button else { return }
        guard key != renderedKey else { return }
        renderedKey = key

        // Calibration gets its own glyph: the pack swings between full and
        // empty, so a fill level would flicker rather than inform.
        let image: NSImage?
        if key.calibrating {
            image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: l10n.t("Battery calibrating"))
        } else if key.level >= 0 {
            image = statusImage(level: key.level, charging: key.charging, pluggedIn: key.pluggedIn, tint: lowPower ? .systemYellow : nil)
        } else {
            image = NSImage(systemSymbolName: "battery.100", accessibilityDescription: l10n.t("Battery"))
        }
        button.image = image
        button.title = showPercentage ? (percentage.map { " \($0)%" } ?? "") : ""
    }

    /// The icon is drawn in explicit black/white rather than as a template
    /// image: a charging bolt has to be punched out of the fill it crosses,
    /// and the Low Power tint is a colour AppKit would otherwise pick — so the
    /// colour has to be decided here.
    ///
    /// That makes the menu bar's appearance an input, and the menu bar follows
    /// the display it is on, not the app: with an external display driving it,
    /// `NSApp.effectiveAppearance` disagrees with how the bar actually renders
    /// and the icon comes out black on a dark bar. So the appearance is
    /// resolved here, at draw time, where AppKit has already set the context
    /// for the right display — the icon rebuilds itself on the next redraw if
    /// the appearance has changed since.
    private func statusImage(level: Int, charging: Bool, pluggedIn: Bool, tint: NSColor?) -> NSImage? {
        NSImage(size: StatusIcon.canvasSize, flipped: false) { [weak self] rect in
            MainActor.assumeIsolated {
                guard let self else { return false }
                let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let style = IconStyle(level: level, charging: charging, pluggedIn: pluggedIn, tinted: tint != nil, dark: dark)
                if self.iconCache?.style != style,
                   let built = StatusIcon.image(level: level, charging: charging, pluggedIn: pluggedIn, dark: dark, tint: tint) {
                    self.iconCache = (style, built)
                }
                self.iconCache?.image.draw(in: rect)
                return true
            }
        }
    }

    /// Whether the pack is taking charge right now. In idle and maintain mode
    /// this follows the adapter: a maintain band parks the pack at its upper
    /// limit most of the time, and a bolt there would still read as "full".
    private static func isCharging(mode: OperatingMode, status: BatteryStatus?) -> Bool {
        switch mode {
        case .chargingTo:
            return true
        case .idle, .maintaining:
            return status?.charging ?? false
        case .dischargingTo, .calibrating:
            return false
        }
    }

    /// Whether an adapter is attached, which the system icon marks with a plug
    /// on the battery rather than a bolt.
    ///
    /// It is read from pmset rather than inferred from the charging flag,
    /// because "not charging" is exactly the state this app sits in most of the
    /// time — a maintain band parks the pack at its upper limit with the
    /// adapter still plugged in — and that is the state the plug is for. The
    /// adapter reading wins over the mode even while force-discharging: macOS
    /// draws the plug there too, since only the blocking, not the adapter, is
    /// ours.
    private static func isPluggedIn(mode: OperatingMode, status: BatteryStatus?) -> Bool {
        switch mode {
        case .calibrating:
            return false   // the calibration glyph stands in for the battery
        case .idle, .maintaining, .chargingTo, .dischargingTo:
            return status?.pluggedInNotCharging ?? false
        }
    }
}
