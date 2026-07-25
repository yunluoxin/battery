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
        Publishers.CombineLatest3(state.$mode, state.$lowPowerOn, state.$status)
            .receive(on: RunLoop.main)
            .sink { [weak self] mode, lowPower, status in
                self?.updateIcon(mode: mode, lowPower: lowPower, status: status)
            }
            .store(in: &cancellables)
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

    private func updateIcon(mode: OperatingMode, lowPower: Bool, status: BatteryStatus?) {
        let symbol: String = switch mode {
        case .idle:
            status.map { "battery.\(Self.batteryLevel($0.percentage))" } ?? "battery.100"
        case .maintaining:
            "battery.100.bolt"
        case .chargingTo:
            "battery.100.bolt"
        case .dischargingTo:
            "battery.75"
        case .calibrating:
            "arrow.triangle.2.circlepath"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Battery")
        if lowPower, let base = image {
            // Badge low power mode with a small leaf.
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemGreen])
            statusItem.button?.image = base.withSymbolConfiguration(config) ?? base
        } else {
            statusItem.button?.image = image
        }
        if let pct = status?.percentage {
            statusItem.button?.title = " \(pct)%"
        }
    }

    private static func batteryLevel(_ pct: Int) -> Int {
        switch pct {
        case 0..<13: return 0
        case 13..<38: return 25
        case 38..<63: return 50
        case 63..<88: return 75
        default: return 100
        }
    }
}
