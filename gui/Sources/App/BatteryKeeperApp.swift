import SwiftUI
import BatteryCore

@main
struct BatteryKeeperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        // The menu bar UI is managed imperatively by StatusBarController
        // (needed to distinguish left/right clicks), so no MenuBarExtra here.
        Settings {
            SettingsView()
                .environmentObject(state)
        }
        Window("Schedules", id: "schedules") {
            SchedulesView()
                .environmentObject(state)
        }
        .defaultSize(width: 560, height: 420)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Agent app: no dock icon, and closing windows must not quit the app.
        NSApp.setActivationPolicy(.accessory)
        // Close any window the Settings/Window scenes restored on launch so
        // the app starts as a bare menu bar item. The status item's window is
        // never in NSApp.windows at this point, so this is safe here (unlike
        // the async variant, which ran after it was added and disabled it).
        NSApp.windows.forEach { window in
            if window.isVisible { window.close() }
        }
        guard isAppleSilicon() else {
            let alert = NSAlert()
            alert.messageText = "Unsupported Mac"
            alert.informativeText = "This app requires an Apple Silicon Mac. The battery charge limiter does not work on Intel Macs."
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        statusBar = StatusBarController(state: AppState.shared)
        AppState.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.stop()
    }

    /// The menu bar app is long-running: closing the Settings or Schedules
    /// window must never quit it; only the explicit Quit action does.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func isAppleSilicon() -> Bool {
        var size = 0
        sysctlbyname("hw.optional.arm64", nil, &size, nil, 0)
        var value: Int32 = 0
        sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return value == 1
    }
}
