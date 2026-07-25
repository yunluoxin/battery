import SwiftUI
import BatteryCore

struct PopoverView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    @State private var sliderLower: Double = 80
    @State private var sliderUpper: Double = 80
    @State private var target: Double = 90

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cliBanner
            statusSection
            Divider().padding(.vertical, 8)
            maintainSection
            Divider().padding(.vertical, 8)
            cycleSection
            Divider().padding(.vertical, 8)
            calibrationSection
            Divider().padding(.vertical, 8)
            footerSection
        }
        .padding()
        .frame(width: 300)
        .onAppear {
            syncSlidersFromConfig()
        }
    }

    // MARK: CLI banner

    @ViewBuilder
    private var cliBanner: some View {
        if !state.cliAvailable {
            VStack(alignment: .leading, spacing: 6) {
                Label("battery CLI not found", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.headline)
                Text("Install with:")
                    .font(.caption)
                HStack {
                    Text("curl -s https://raw.githubusercontent.com/actuallymentor/battery/main/setup.sh | bash")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("curl -s https://raw.githubusercontent.com/actuallymentor/battery/main/setup.sh | bash", forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(8)
            .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 8)
        }
        if let error = state.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .padding(.bottom, 4)
        }
    }

    // MARK: Status

    private var statusSection: some View {
        HStack(alignment: .center) {
            Text(state.status.map { "\($0.percentage)%" } ?? "--")
                .font(.system(size: 36, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(statusHeadline)
                    .font(.headline)
                Text(statusSubline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var statusHeadline: String {
        switch state.mode {
        case .idle:
            guard let s = state.status else { return "Unknown" }
            return s.charging ? "Charging" : (s.discharging ? "On Battery" : "Not Charging")
        case .maintaining(let range):
            return "Maintaining at \(range.displayValue)"
        case .chargingTo(let target):
            return "Charging to \(target)%"
        case .dischargingTo(let target):
            return "Discharging to \(target)%"
        case .calibrating:
            return "Calibrating…"
        }
    }

    private var statusSubline: String {
        guard let s = state.status else { return "" }
        let time = s.remainingTime.isEmpty ? "" : " · \(s.remainingTime)"
        return "Power adapter\(time)"
    }

    // MARK: Maintain

    private var maintainSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Maintain")
                    .font(.headline)
                Spacer()
                Text(maintainLabel)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Toggle("", isOn: Binding(
                    get: { state.config.maintainEnabled },
                    set: { state.setMaintain(enabled: $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!state.cliAvailable || state.mode == .calibrating)
            }

            RangeSlider(
                lower: $sliderLower,
                upper: $sliderUpper,
                lowerEnabled: state.config.sailingEnabled
            )
            .disabled(!state.cliAvailable || state.mode == .calibrating)
            .onChange(of: sliderLower) { _, _ in applyRange() }
            .onChange(of: sliderUpper) { _, _ in applyRange() }

            Toggle("Sailing Mode", isOn: Binding(
                get: { state.config.sailingEnabled },
                set: { newValue in
                    state.setSailing(enabled: newValue)
                    // Enabling sailing restores the stored band to the thumbs;
                    // disabling it pins the (hidden) lower thumb to the upper
                    // so the next enable starts from a sensible band.
                    if newValue {
                        sliderLower = Double(state.config.maintainRange.lower)
                    } else {
                        sliderLower = sliderUpper
                    }
                }
            ))
            .toggleStyle(.switch)
            .disabled(!state.cliAvailable || state.mode == .calibrating)
        }
    }

    private var maintainLabel: String {
        state.config.sailingEnabled
            ? "\(Int(sliderLower))% – \(Int(sliderUpper))%"
            : "\(Int(sliderUpper))%"
    }

    private func applyRange() {
        // Persist the full band the user has set. When sailing is off the
        // lower thumb is hidden, but keep the stored lower value so toggling
        // sailing back on restores the previous band instead of collapsing
        // to a single point.
        let newLower = state.config.sailingEnabled ? Int(sliderLower) : state.config.maintainRange.lower
        let range = MaintainRange.clamped(lower: newLower, upper: Int(sliderUpper))
        if range != state.config.maintainRange {
            state.setMaintainRange(range)
        }
    }

    // MARK: Charge / Discharge

    private var cycleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Target")
                    .font(.headline)
                Spacer()
                Text("\(Int(target))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            StyledSlider(value: $target)
                .disabled(!state.cliAvailable || state.mode == .calibrating)
                .onChange(of: target) { _, _ in state.setTarget(Int(target)) }

            Toggle("Charge (Top Up)", isOn: Binding(
                get: { state.config.chargeActive },
                set: { state.setCharge(active: $0) }
            ))
            .toggleStyle(.switch)
            .disabled(!state.cliAvailable || state.mode == .calibrating)

            Toggle("Discharge", isOn: Binding(
                get: { state.config.dischargeActive },
                set: { state.setDischarge(active: $0) }
            ))
            .toggleStyle(.switch)
            .disabled(!state.cliAvailable || state.mode == .calibrating)

            Toggle("Low Power Mode", isOn: Binding(
                get: { state.effectiveLowPower },
                set: { state.setLowPower($0) }
            ))
            .toggleStyle(.switch)
            .disabled(!state.cliAvailable)
        }
    }

    // MARK: Calibration

    private var calibrationSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Calibration")
                    .font(.headline)
                Text(state.calibrating ? "In progress…" : "Idle")
                    .font(.caption)
                    .foregroundStyle(state.calibrating ? .orange : .secondary)
            }
            Spacer()
            if state.calibrating {
                Button("Stop") { state.stopCalibration() }
            } else {
                Button("Start") { state.startCalibration() }
                    .disabled(!state.cliAvailable)
            }
        }
    }

    // MARK: Footer

    private var footerSection: some View {
        HStack {
            Button {
                openWindow(id: "schedules")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Schedules…", systemImage: "clock")
            }
            .buttonStyle(.borderless)

            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Settings…", systemImage: "gear")
            }
            .buttonStyle(.borderless)

            Spacer()

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
        .font(.callout)
    }

    // MARK: Helpers

    private func syncSlidersFromConfig() {
        let range = state.config.maintainRange
        sliderLower = Double(range.lower)
        sliderUpper = Double(range.upper)
        target = Double(max(state.config.chargeTarget, state.config.dischargeTarget))
    }
}
