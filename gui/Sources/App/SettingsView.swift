import SwiftUI
import BatteryCore

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }
            BatterySettingsView()
                .tabItem { Label("Battery", systemImage: "battery.100") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 440, height: 300)
        .environmentObject(state)
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: Binding(
                get: { state.config.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }
            ))

            Toggle("Show battery percentage in menu bar", isOn: Binding(
                get: { state.config.showPercentageInMenuBar },
                set: {
                    state.config.showPercentageInMenuBar = $0
                    state.saveConfig()
                }
            ))

            Picker("After Charge/Discharge completes:", selection: Binding(
                get: { state.config.postCompletion },
                set: {
                    state.config.postCompletion = $0
                    state.saveConfig()
                }
            )) {
                ForEach(PostCompletionBehavior.allCases, id: \.self) { behavior in
                    Text(behavior.displayName).tag(behavior)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct BatterySettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var batteryInfo: String = "Loading…"

    var body: some View {
        Form {
            LabeledContent("Status") {
                Text(state.status.map { "\($0.percentage)%, \($0.remainingTime)" } ?? "Unknown")
            }
            LabeledContent("Hardware info") {
                Text(batteryInfo)
                    .font(.callout.monospaced())
                    .multilineTextAlignment(.trailing)
            }
            Button("Restore system default charging") {
                state.restoreDefaults()
            }
            .disabled(!state.cliAvailable)
        }
        .formStyle(.grouped)
        .padding()
        .onAppear(perform: loadBatteryInfo)
    }

    private func loadBatteryInfo() {
        Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
            process.arguments = ["-rn", "AppleSmartBattery"]
            let pipe = Pipe()
            process.standardOutput = pipe
            guard let _ = try? process.run() else { return }
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let temp = Self.extract(#""Temperature" = (\d+)"#, from: output).flatMap(Int.init).map { String(format: "%.1f°C", Double($0) / 100.0) }
            let cycles = Self.extract(#""CycleCount" = (\d+)"#, from: output)
            let maxCap = Self.extract(#""MaxCapacity" = (\d+)"#, from: output)
            let parts = [
                temp.map { "Temp \($0)" },
                cycles.map { "Cycles \($0)" },
                maxCap.map { "MaxCapacity \($0)%" },
            ].compactMap { $0 }
            await MainActor.run {
                batteryInfo = parts.isEmpty ? "Unavailable" : parts.joined(separator: " · ")
            }
        }
    }

    nonisolated private static func extract(_ pattern: String, from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

private struct AboutSettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var cliVersion: String = "…"

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "battery.100.bolt")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("Battery GUI")
                .font(.title2)
            Text("A menu bar charge limiter wrapping the battery CLI.")
                .font(.callout)
                .foregroundStyle(.secondary)
            LabeledContent("CLI") {
                Text(state.cliAvailable ? cliVersion : "not installed")
                    .foregroundStyle(state.cliAvailable ? Color.primary : Color.red)
            }
            .padding(.horizontal, 40)
        }
        .padding()
        .onAppear(perform: loadCLIVersion)
    }

    private func loadCLIVersion() {
        Task {
            if let result = try? await state.cli.run(["--version"]), result.succeeded {
                let v = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run { cliVersion = v.isEmpty ? "installed" : v }
            } else {
                await MainActor.run { cliVersion = "installed" }
            }
        }
    }
}
