import AppKit
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
                .environmentObject(Localization.shared)
        }
        // The title comes from the table rather than a LocalizedStringKey so it
        // follows the chosen language. A scene title is fixed when the scene is
        // created, so this one updates on the next launch, not on the switch.
        Window(Text(Localization.shared.t("Schedules")), id: "schedules") {
            SchedulesView()
                .environmentObject(state)
                .environmentObject(Localization.shared)
        }
        .defaultSize(width: 560, height: 420)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBar: StatusBarController?

    /// The standalone main panel. It is built on demand rather than declared as
    /// a SwiftUI `Settings` scene because the system will not reopen a scene
    /// for an app it considers to have nothing open, which is exactly the state
    /// a hidden menu bar icon puts this app in.
    private var panelWindow: NSWindow?

    /// Show the main panel, creating the window on first use.
    ///
    /// Kept as one reusable window: reopening after a close must not stack a
    /// second copy, and the panel is the app's only entry point while the menu
    /// bar icon is hidden, so losing it would strand the preference.
    func showPanel() {
        if panelWindow == nil {
            let window = NSWindow(
                contentViewController: NSHostingController(
                    rootView: SettingsView()
                        .environmentObject(AppState.shared)
                        .environmentObject(Localization.shared)
                )
            )
            window.title = "BatteryKeeper"
            window.styleMask = [.titled, .closable, .miniaturizable]
            // Closed, not deallocated: the window is reused on the next reopen.
            window.isReleasedWhenClosed = false
            window.center()
            panelWindow = window
        }
        // An agent app is not activated by showing a window on its own, so the
        // panel would open behind whatever the user was working in.
        NSApp.activate(ignoringOtherApps: true)
        panelWindow?.makeKeyAndOrderFront(nil)
    }

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

    /// Re-opening from Launchpad while the app is already running.
    ///
    /// With the menu bar icon hidden this is the *only* way back into the app:
    /// as a launch-at-login agent it has no dock icon, and tapping its
    /// Launchpad icon with no windows open reaches AppKit's reopen path rather
    /// than a second launch. Returning `false` stops AppKit from also trying its
    /// own default handling, which for this app means nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
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
