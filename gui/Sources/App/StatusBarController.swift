import AppKit
import SwiftUI
import BatteryCore
import Combine

/// Owns the NSStatusItem and routes left click → popover, right click →
/// toggle Low Power Mode.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let state: AppState
    private var cancellables = Set<AnyCancellable>()
    private var eventMonitor: Any?
    /// Everything the current icon encodes, so an unchanged poll is a no-op.
    private var renderedKey: IconKey?
    /// The inputs behind `renderedKey`, replayed when something outside the
    /// observed state (the menu bar appearance) forces a repaint.
    private var lastRenderInput: RenderInput?
    private var appearanceObservation: NSKeyValueObservation?

    init(state: AppState) {
        self.state = state
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        super.init()

        popover.contentViewController = NSHostingController(rootView: PopoverView().environmentObject(state))
        popover.behavior = .transient
        popover.delegate = self

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "battery.100", accessibilityDescription: "Battery")
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Update the icon when relevant state changes.
        Publishers.CombineLatest4(state.$mode, state.$lowPowerOn, state.$status, state.$config)
            .receive(on: RunLoop.main)
            .sink { [weak self] mode, lowPower, status, config in
                self?.updateIcon(mode: mode, lowPower: lowPower, status: status, showPercentage: config.showPercentageInMenuBar)
            }
            .store(in: &cancellables)

        // The icon is drawn in explicit black/white rather than as a template
        // image, because a charging bolt has to contrast with the fill it sits
        // on. Redraw when the menu bar flips between light and dark.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            // KVO does not promise a thread, and the status item is main-actor
            // only, so hop explicitly instead of assuming isolation.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let input = self.lastRenderInput else { return }
                    self.renderedKey = nil
                    self.updateIcon(mode: input.mode, lowPower: input.lowPower, status: input.status, showPercentage: input.showPercentage)
                }
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
        let lowPower: Bool
        let darkMenuBar: Bool
        let percentage: Int      // only meaningful when showPercentage is on
        let showPercentage: Bool
    }

    private struct RenderInput {
        let mode: OperatingMode
        let lowPower: Bool
        let status: BatteryStatus?
        let showPercentage: Bool
    }

    private func updateIcon(mode: OperatingMode, lowPower: Bool, status: BatteryStatus?, showPercentage: Bool) {
        lastRenderInput = RenderInput(mode: mode, lowPower: lowPower, status: status, showPercentage: showPercentage)
        let percentage = status?.percentage
        let key = IconKey(
            calibrating: mode == .calibrating,
            level: percentage.map(StatusIcon.level(for:)) ?? -1,
            charging: Self.isCharging(mode: mode, status: status),
            lowPower: lowPower,
            darkMenuBar: Self.isDarkMenuBar,
            percentage: showPercentage ? (percentage ?? -1) : -1,
            showPercentage: showPercentage
        )
        guard key != renderedKey else { return }
        renderedKey = key

        // Calibration gets its own glyph: the pack swings between full and
        // empty, so a fill level would flicker rather than inform.
        let image: NSImage?
        if key.calibrating {
            image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Battery calibrating")
        } else if key.level >= 0 {
            image = StatusIcon.image(
                level: key.level,
                charging: key.charging,
                dark: key.darkMenuBar,
                tint: lowPower ? .systemYellow : nil
            )
        } else {
            image = NSImage(systemSymbolName: "battery.100", accessibilityDescription: "Battery")
        }
        statusItem.button?.image = image
        statusItem.button?.title = showPercentage ? (percentage.map { " \($0)%" } ?? "") : ""
    }

    private static var isDarkMenuBar: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
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
}
