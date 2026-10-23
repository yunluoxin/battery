import SwiftUI
import BatteryCore

struct PopoverView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var l10n: Localization
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    @State private var sliderLower: Double = 80
    @State private var sliderUpper: Double = 80

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
                Label(l10n.t("battery CLI not found"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.headline)
                Text(l10n.t("Install with:"))
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
        if state.cliAvailable && !state.chargingControlAvailable {
            VStack(alignment: .leading, spacing: 6) {
                Label(l10n.t("Charging control unavailable"), systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                Text(l10n.t("Charging control is unavailable on this system. Your saved limits are not being applied."))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.orange)
            .padding(8)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
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
            guard let s = state.status else { return l10n.t("Unknown") }
            return s.charging ? l10n.t("Charging") : (s.discharging ? l10n.t("On Battery") : l10n.t("Not Charging"))
        case .maintaining(let range):
            return l10n.f("Maintaining at %@", range.displayValue)
        case .chargingTo(let target):
            return l10n.f("Charging to %d%%", target)
        case .dischargingTo(let target):
            return l10n.f("Discharging to %d%%", target)
        case .calibrating:
            return l10n.t("Calibrating…")
        }
    }

    /// The headline already says whether the pack is charging, on battery or
    /// idle, so this only fills in the detail: how long the pack has left when
    /// there is a countdown, otherwise that the adapter is what it is plugged
    /// into. A bare "8:43" says nothing on its own — the word is what tells the
    /// user it is time and not, say, a charge count.
    private var statusSubline: String {
        guard let s = state.status else { return "" }
        // `timeRemaining`, not `remainingTime`: on AC the raw field holds
        // pmset's word "attached;" rather than a duration.
        if let time = s.timeRemaining { return l10n.f("%@ remaining", time) }
        return l10n.t("Power adapter")
    }

    // MARK: Maintain

    private var maintainSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(l10n.t("Maintain"))
                    .font(.headline)
                Spacer()
                Text(maintainLabel)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Toggle("", isOn: Binding(
                    get: { state.config.maintainEnabled && state.chargingControlAvailable },
                    set: { state.setMaintain(enabled: $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!state.cliAvailable || !state.chargingControlAvailable || state.mode == .calibrating)
            }

            RangeSlider(
                lower: $sliderLower,
                upper: $sliderUpper,
                lowerEnabled: state.config.sailingEnabled
            )
            .disabled(!state.cliAvailable || state.mode == .calibrating)
            .onChange(of: sliderLower) { _, _ in applyRange() }
            .onChange(of: sliderUpper) { _, _ in applyRange() }

            Toggle(l10n.t("Sailing Mode"), isOn: Binding(
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
                Text(l10n.t("Target"))
                    .font(.headline)
                Spacer()
                Text("\(state.cycleTarget)%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            // Bound to the store rather than a local @State: switching a cycle
            // on moves the target (charge → 100%, discharge → 40%) and the
            // slider has to follow without waiting for the popover to reopen.
            StyledSlider(value: Binding(
                get: { Double(state.cycleTarget) },
                set: { state.setTarget(Int($0)) }
            ))
                .disabled(!state.cliAvailable || state.mode == .calibrating)

            Toggle(l10n.t("Charge (Top Up)"), isOn: Binding(
                get: { state.config.chargeActive && state.chargingControlAvailable },
                set: { state.setCharge(active: $0) }
            ))
            .toggleStyle(.switch)
            .disabled(!state.cliAvailable || !state.chargingControlAvailable || state.mode == .calibrating)

            Toggle(l10n.t("Discharge"), isOn: Binding(
                get: { state.config.dischargeActive },
                set: { state.setDischarge(active: $0) }
            ))
            .toggleStyle(.switch)
            .disabled(!state.cliAvailable || state.mode == .calibrating)

            Toggle(l10n.t("Low Power Mode"), isOn: Binding(
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
                Text(l10n.t("Calibration"))
                    .font(.headline)
                Text(!state.chargingControlAvailable ? l10n.t("Unavailable") : (state.calibrating ? l10n.t("In progress…") : l10n.t("Idle")))
                    .font(.caption)
                    .foregroundStyle(state.calibrating ? .orange : .secondary)
            }
            Spacer()
            if state.calibrating {
                Button(l10n.t("Stop")) { state.stopCalibration() }
            } else {
                Button(l10n.t("Start")) { state.startCalibration() }
                    .disabled(!state.cliAvailable || !state.chargingControlAvailable)
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
                Label(l10n.t("Schedules…"), systemImage: "clock")
            }
            .buttonStyle(.borderless)

            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label(l10n.t("Settings…"), systemImage: "gear")
            }
            .buttonStyle(.borderless)

            Spacer()

            Button(l10n.t("Quit")) {
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
    }
}
