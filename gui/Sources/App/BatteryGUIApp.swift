import SwiftUI
import BatteryCore

@main
struct BatteryGUIApp: App {
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
        // Agent app: no dock icon.
        NSApp.setActivationPolicy(.accessory)
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

    private func isAppleSilicon() -> Bool {
        var size = 0
        sysctlbyname("hw.optional.arm64", nil, &size, nil, 0)
        var value: Int32 = 0
        sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return value == 1
    }
}
