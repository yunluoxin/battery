import SwiftUI
import BatteryCore

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var l10n: Localization
    @State private var selection: SettingsTab = .general

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsView()
                .tabItem { Label(l10n.t("General"), systemImage: "gear") }
                .tag(SettingsTab.general)
            BatterySettingsView()
                .tabItem { Label(l10n.t("Battery"), systemImage: "battery.100") }
                .tag(SettingsTab.battery)
            AppearanceSettingsView()
                .tabItem { Label(l10n.t("Appearance"), systemImage: "paintbrush") }
                .tag(SettingsTab.appearance)
            AboutSettingsView()
                .tabItem { Label(l10n.t("About"), systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        // Fixed content size: the Settings scene sizes its window around this,
        // so it is what gives the panel its dimensions on both entry paths.
        .frame(width: 440, height: 300)
        // Re-injected for the tab's contents. This view is only ever the root
        // of the Settings scene now — AppDelegate.showPanel() opens that scene
        // rather than hosting a window of its own — so the scene is the one
        // call site, and it passes both in.
        .environmentObject(state)
        .environmentObject(l10n)
    }
}

private enum SettingsTab: Hashable {
    case general, battery, appearance, about
}

private struct GeneralSettingsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var l10n: Localization

    var body: some View {
        Form {
            Toggle(l10n.t("Launch at login"), isOn: Binding(
                get: { state.config.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }
            ))

            Toggle(l10n.t("Hide status bar icon"), isOn: Binding(
                get: { state.config.hideStatusBarIcon },
                set: { state.setHideStatusBarIcon($0) }
            ))

            Toggle(l10n.t("Show battery percentage in menu bar"), isOn: Binding(
                get: { state.config.showPercentageInMenuBar },
                set: {
                    state.config.showPercentageInMenuBar = $0
                    state.saveConfig()
                }
            ))

            Picker(l10n.t("After Charge/Discharge completes:"), selection: Binding(
                get: { state.config.postCompletion },
                set: {
                    state.config.postCompletion = $0
                    state.saveConfig()
                }
            )) {
                ForEach(PostCompletionBehavior.allCases, id: \.self) { behavior in
                    // BatteryCore's displayName is the English text, which is
                    // also the lookup key.
                    Text(l10n.t(behavior.displayName)).tag(behavior)
                }
            }

            Toggle(l10n.t("Auto Low Power Mode"), isOn: Binding(
                get: { state.config.autoLowPower },
                set: { state.setAutoLowPower($0) }
            ))

            Toggle(l10n.t("Scheduled task notifications"), isOn: Binding(
                get: { state.config.scheduledTaskNotifications },
                set: { state.setScheduledTaskNotifications($0) }
            ))

            // The level the rule fires at. Hidden rather than greyed out while
            // the rule is off: with nothing for the number to modify, a
            // disabled stepper is just a row to read past.
            if state.config.autoLowPower {
                Stepper(value: Binding(
                    get: { state.config.autoLowPowerThreshold },
                    set: { state.setAutoLowPowerThreshold($0) }
                ), in: AutoLowPowerRule.thresholdRange, step: 5) {
                    HStack {
                        Text(l10n.t("When the battery is below:"))
                        Spacer()
                        Text("\(state.config.autoLowPowerThreshold)%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal)
    }
}

private struct BatterySettingsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var l10n: Localization
    /// Nil until the ioreg read finishes; the view shows a placeholder instead.
    @State private var batteryInfo: String?

    var body: some View {
        Form {
            LabeledContent(l10n.t("Status")) {
                Text(statusSummary)
            }
            LabeledContent(l10n.t("Hardware info")) {
                Text(batteryInfo ?? l10n.t("Loading…"))
                    .font(.callout.monospaced())
                    .multilineTextAlignment(.trailing)
            }
            Button(l10n.t("Restore system default charging")) {
                state.restoreDefaults()
            }
            .disabled(!state.cliAvailable)
        }
        .formStyle(.grouped)
        .padding()
        .onAppear(perform: loadBatteryInfo)
    }

    /// Percentage plus whatever else is worth saying about it: the countdown
    /// while the pack is running, or the adapter state when it is not. The CLI
    /// puts pmset's own wording in that slot on AC (`attached;`), which is why
    /// this goes through `timeRemaining` rather than `remainingTime`. The
    /// countdown is labelled rather than bare, for the same reason as the
    /// popover: "71%, 4:11" leaves the reader to guess what 4:11 measures.
    private var statusSummary: String {
        guard let status = state.status else { return l10n.t("Unknown") }
        if let time = status.timeRemaining {
            return "\(status.percentage)%, \(l10n.f("%@ remaining", time))"
        }
        guard status.adapterAttached else { return "\(status.percentage)%" }
        return "\(status.percentage)%, \(l10n.t("Power adapter connected"))"
    }

    private func loadBatteryInfo() {
        // Snapshot the labels before leaving the main actor: the parse runs in
        // a detached task, and the user may switch language while it is in
        // flight, in which case only the labels captured here would be stale.
        let tempLabel = l10n.t("Temp")
        let cyclesLabel = l10n.t("Cycles")
        let healthLabel = l10n.t("Health")
        let unavailable = l10n.t("Unavailable")
        Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
            process.arguments = ["-rn", "AppleSmartBattery"]
            let pipe = Pipe()
            process.standardOutput = pipe
            guard let _ = try? process.run() else { return }
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let temp = BatteryStatusParser.parseIORegInt("Temperature", from: output).map { String(format: "%.1f°C", Double($0) / 100.0) }
            let cycles = BatteryStatusParser.parseIORegInt("CycleCount", from: output).map(String.init)
            let health = BatteryStatusParser.parseHealthPercent(from: output)
            let parts = [
                temp.map { "\(tempLabel) \($0)" },
                cycles.map { "\(cyclesLabel) \($0)" },
                health.map { "\(healthLabel) \($0)%" },
            ].compactMap { $0 }
            let summary = parts.isEmpty ? unavailable : parts.joined(separator: " · ")
            await MainActor.run {
                batteryInfo = summary
            }
        }
    }
}

/// How the app looks: currently only the language. Appearance preferences that
/// need a choice of their own (light / dark / system) land here too, which is
/// why this is a tab rather than another row on General.
private struct AppearanceSettingsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var l10n: Localization

    var body: some View {
        Form {
            Picker(l10n.t("Language"), selection: Binding(
                get: { state.config.language },
                set: { state.setLanguage($0) }
            )) {
                ForEach(AppLanguage.allCases, id: \.self) { language in
                    Text(language.displayName).tag(language)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct AboutSettingsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var l10n: Localization
    @State private var cliVersion: String = "…"

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text("BatteryKeeper")
                .font(.title2)
            Text(l10n.t("A menu bar charge limiter wrapping the battery CLI."))
                .font(.callout)
                .foregroundStyle(.secondary)
            // Each row is one self-contained centered line — the CLI version
            // and the app version each sit on their own centre, not split
            // into a label column and a value column.
            VStack(spacing: 4) {
                Text(l10n.f("CLI %@", cliVersionText))
                    .foregroundStyle(state.cliAvailable ? Color.primary : Color.red)
                Text(l10n.f("App v%@", AppVersion.current))
            }
        }
        .padding()
        .onAppear(perform: loadCLIVersion)
    }

    /// What the CLI line reads: the reported version, or the same
    /// "not installed" wording the panel used before, in the CLI's own red.
    private var cliVersionText: String {
        guard state.cliAvailable else { return l10n.t("not installed") }
        return cliVersion
    }

    private func loadCLIVersion() {
        Task {
            let installed = l10n.t("installed")
            if let result = try? await state.cli.run(["--version"]), result.succeeded {
                let v = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run { cliVersion = v.isEmpty ? installed : v }
            } else {
                await MainActor.run { cliVersion = installed }
            }
        }
    }
}
