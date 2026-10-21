import AppKit
import SwiftUI
import BatteryCore
import UserNotifications

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

/// Fires the SwiftUI `openSettings` action on behalf of `AppDelegate`.
///
/// The `Settings` scene's window can only be opened from inside SwiftUI: the
/// AppKit selectors do not reach it (`showSettingsWindow:` reports success but
/// opens nothing) and AppKit will not reopen a scene for an app it believes has
/// nothing open. So this view is hosted in an off-screen window purely to get
/// the environment action, and it throws that window away immediately after.
private struct SettingsOpener: View {
    @Environment(\.openSettings) private var openSettings
    /// Runs right after the open is dispatched, once the panel exists.
    let onOpened: () -> Void
    @State private var fired = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                // An off-screen hosting view can still see `onAppear` more than
                // once; opening twice in a row is harmless but not free, and the
                // guard keeps it to one call.
                guard !fired else { return }
                fired = true
                openSettings()
                // After the open, not before it: an agent app is not activated by
                // opening a window, so activating any earlier leaves the panel
                // behind whatever the user was working in. See `showPanel`.
                onOpened()
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var statusBar: StatusBarController?

    /// The off-screen host for `SettingsOpener`, held only until the open
    /// action has been dispatched. It is never shown, so the panel it opens is
    /// the `Settings` scene's own window — titled after the current tab and
    /// wearing the same toolbar chrome as the one `openSettings()` gives from
    /// the menu bar popover.
    private var settingsOpenerWindow: NSWindow?

    /// Open the settings panel, the app's only entry point while the menu bar
    /// icon is hidden.
    ///
    /// Opening goes through `SettingsOpener` rather than a hand-built window of
    /// our own: hosting `SettingsView` in a plain `NSWindow` gives an untitled
    /// bar with the tabs crammed into a toolbar, which is not the settings UI
    /// anywhere else in this app. The scene's window is reused by AppKit, so
    /// reopening after a close re-focuses it instead of stacking a second copy.
    ///
    /// Activation is deliberately sequenced *after* the open: `openSettings()`
    /// only reaches the scene from the hosting view's `onAppear`, so nothing is on
    /// screen yet while this method runs. Activating at that point has no window
    /// to front, and the panel then comes up behind whatever the user was working
    /// in with its traffic lights greyed out — hence the closure above.
    func showPanel() {
        if settingsOpenerWindow == nil {
            // No style mask and never ordered front: this window exists only to
            // host the view that fires `openSettings()`.
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsOpener {
                // An agent app is not activated by opening a window, so this is
                // what brings the panel to the front at all.
                NSApp.activate(ignoringOtherApps: true)
            }))
            window.styleMask = []
            window.orderOut(nil)
            settingsOpenerWindow = window
        }
        // Releasing the opener on the next turn is what lets the next open host a
        // fresh `SettingsOpener`; a spent one has already fired and would not
        // fire again.
        DispatchQueue.main.async { self.settingsOpenerWindow = nil }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Agent app: no dock icon, and closing windows must not quit the app.
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
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
    /// own default handling, which for this app means nothing: it does not
    /// reopen a scene for an app it believes has nothing open, which is the
    /// whole reason `showPanel` has to do it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }

    /// The menu bar app is long-running: closing the Settings or Schedules
    /// window must never quit it; only the explicit Quit action does.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    private func isAppleSilicon() -> Bool {
        var size = 0
        sysctlbyname("hw.optional.arm64", nil, &size, nil, 0)
        var value: Int32 = 0
        sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return value == 1
    }
}
