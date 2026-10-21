import SwiftUI
import BatteryCore

struct SchedulesView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var l10n: Localization
    @State private var taskList: TaskList = TaskList()
    @State private var history: History = History()
    @State private var editingTask: ScheduledTask?
    @State private var scheduleError: String?

    private var helperPath: String { LaunchdManager.currentHelperPath }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    if taskList.tasks.isEmpty {
                        Text(l10n.t("No scheduled tasks yet."))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(taskList.tasks) { task in
                        TaskRow(task: task)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { edit(task) }
                            .contextMenu {
                                Button(l10n.t("Edit…")) { edit(task) }
                                Button(l10n.t("Run Now")) { runNow(task) }
                                Divider()
                                Button(l10n.t("Delete"), role: .destructive) { delete(task) }
                            }
                    }
                    .onDelete(perform: deleteAt)
                } header: {
                    HStack {
                        Text(l10n.t("Tasks"))
                        Spacer()
                        Button { newTask() } label: { Image(systemName: "plus") }
                    }
                }

                Section(l10n.t("History")) {
                    if history.entries.isEmpty {
                        Text(l10n.t("No runs yet."))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(history.entries.suffix(50).reversed()) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: entry.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(entry.success ? .green : .red)
                                Text(entry.taskName)
                                Spacer()
                                Text(entry.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                                    .foregroundStyle(.secondary)
                            }
                            if !entry.output.isEmpty {
                                Text(entry.output)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            if let note = entry.note {
                                Text(note)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 380)
        .sheet(item: $editingTask) { task in
            TaskEditorView(task: task) { saved in
                save(saved)
            }
        }
        .alert(l10n.t("Unable to Schedule Task"), isPresented: Binding(
            get: { scheduleError != nil },
            set: { if !$0 { scheduleError = nil } }
        )) {
            Button(l10n.t("OK")) { scheduleError = nil }
        } message: {
            Text(scheduleError ?? "")
        }
        .onAppear(perform: reload)
    }

    // MARK: Data

    private func reload() {
        taskList = JSONStore.load(TaskList.self, from: StateDirectory.tasksFile, default: TaskList())
        history = JSONStore.load(History.self, from: StateDirectory.historyFile, default: History())
    }

    private func persist() {
        try? JSONStore.save(taskList, to: StateDirectory.tasksFile)
    }

    private func newTask() {
        editingTask = ScheduledTask(
            name: l10n.t("New Task"),
            action: .maintain,
            param: "80",
            schedule: .daily,
            runAt: Calendar.current.date(byAdding: .hour, value: 1, to: Date()),
            hour: 9,
            minute: 0,
            weekdays: [2]
        )
    }

    private func edit(_ task: ScheduledTask) {
        editingTask = task
    }

    private func save(_ task: ScheduledTask) {
        guard !task.enabled || task.schedule != .once || (task.runAt.map { $0 > Date() } ?? false) else {
            scheduleError = l10n.t("Choose a future date and time.")
            return
        }
        if let index = taskList.tasks.firstIndex(where: { $0.id == task.id }) {
            taskList.tasks[index] = task
        } else {
            taskList.tasks.append(task)
        }
        persist()
        do {
            try reinstall(task)
        } catch {
            scheduleError = localizedScheduleError(error)
            if let index = taskList.tasks.firstIndex(where: { $0.id == task.id }) {
                taskList.tasks[index].enabled = false
                persist()
            }
        }
        reload()
    }

    private func delete(_ task: ScheduledTask) {
        LaunchdManager.uninstall(taskID: task.id)
        taskList.tasks.removeAll { $0.id == task.id }
        persist()
        reload()
    }

    private func deleteAt(_ offsets: IndexSet) {
        for index in offsets {
            LaunchdManager.uninstall(taskID: taskList.tasks[index].id)
        }
        taskList.tasks.remove(atOffsets: offsets)
        persist()
    }

    private func toggle(_ task: ScheduledTask, enabled: Bool) {
        guard let index = taskList.tasks.firstIndex(where: { $0.id == task.id }) else { return }
        taskList.tasks[index].enabled = enabled
        persist()
        if enabled {
            do {
                try reinstall(taskList.tasks[index])
            } catch {
                taskList.tasks[index].enabled = false
                scheduleError = localizedScheduleError(error)
                persist()
            }
        } else {
            LaunchdManager.uninstall(taskID: task.id)
        }
        reload()
    }

    private func reinstall(_ task: ScheduledTask) throws {
        guard task.enabled else {
            LaunchdManager.uninstall(taskID: task.id)
            return
        }
        try LaunchdManager.install(task: task, helperPath: helperPath)
    }

    private func localizedScheduleError(_ error: Error) -> String {
        if let cliError = error as? CLIError, case .parseError = cliError {
            return l10n.t("Choose a future date and time.")
        }
        return String(describing: error)
    }

    private func runNow(_ task: ScheduledTask) {
        let path = helperPath
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["--task", task.id.uuidString, "--force"]
            try? process.run()
            process.waitUntilExit()
            await MainActor.run { reload() }
        }
    }

    private func TaskRow(task: ScheduledTask) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.name)
                    .font(.headline)
                Text(task.localizedSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let result = task.lastResult, let lastRun = task.lastRun {
                    Text(l10n.f("Last: %@ · %@",
                                result == "ok" ? "✓" : "✗ \(result)",
                                lastRun.formatted(date: .abbreviated, time: .shortened)))
                        .font(.caption2)
                        .foregroundStyle(result == "ok" ? Color.secondary : Color.red)
                        .lineLimit(1)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { task.enabled },
                set: { toggle(task, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(!task.enabled && task.schedule == .once && (task.runAt ?? .distantPast) <= Date())
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Editor

private struct TaskEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var l10n: Localization
    @State var task: ScheduledTask
    let onSave: (ScheduledTask) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(l10n.t("Schedule Task"))
                .font(.title3)

            Form {
                TextField(l10n.t("Name"), text: $task.name)

                Picker(l10n.t("Action"), selection: Binding(
                    get: { task.action },
                    set: { action in
                        if action == .topup && task.action != .topup { task.param = "100" }
                        task.action = action
                    }
                )) {
                    ForEach(ScheduledTask.Action.allCases, id: \.self) { action in
                        Text(l10n.t(action.displayName)).tag(action)
                    }
                }

                actionParamField

                Picker(l10n.t("Repeat"), selection: Binding(
                    get: { task.schedule },
                    set: { schedule in
                        task.schedule = schedule
                        if schedule == .once && task.runAt == nil {
                            task.runAt = Calendar.current.date(byAdding: .hour, value: 1, to: Date())
                        }
                    }
                )) {
                    ForEach(ScheduledTask.ScheduleType.allCases, id: \.self) { type in
                        Text(l10n.t(type.displayName)).tag(type)
                    }
                }

                if task.schedule == .once {
                    DatePicker(l10n.t("Run once at"), selection: runAtBinding,
                               displayedComponents: [.date, .hourAndMinute])
                    if task.enabled && (task.runAt.map({ $0 <= Date() }) ?? true) {
                        Text(l10n.t("Choose a future date and time."))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                if task.schedule == .weekly {
                    WeekdayPicker(selected: $task.weekdays)
                }

                if task.schedule != .once {
                    HStack {
                        Picker(l10n.t("Hour"), selection: $task.hour) {
                            ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                        }
                        Text(":")
                        Picker(l10n.t("Minute"), selection: $task.minute) {
                            ForEach([0, 15, 30, 45], id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button(l10n.t("Cancel")) { dismiss() }
                Button(l10n.t("Save")) {
                    normalize()
                    onSave(task)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(task.name.isEmpty ||
                          (task.schedule == .weekly && task.weekdays.isEmpty) ||
                          (task.enabled && task.schedule == .once && (task.runAt.map { $0 <= Date() } ?? true)))
            }
        }
        .padding()
        .frame(width: 380)
        .onAppear {
            if task.schedule == .once && task.runAt == nil {
                task.runAt = Calendar.current.date(byAdding: .hour, value: 1, to: Date())
            }
        }
    }

    @ViewBuilder
    private var actionParamField: some View {
        switch task.action {
        case .maintain:
            Stepper(value: paramInt, in: 20...100, step: 5) {
                Text(l10n.f("Limit: %d%%", paramInt.wrappedValue))
            }
        case .discharge:
            Stepper(value: paramInt, in: 10...100, step: 5) {
                Text(l10n.f("Discharge to: %d%%", paramInt.wrappedValue))
            }
        case .topup:
            Stepper(value: paramInt, in: 20...100, step: 5) {
                Text(l10n.f("Charge to: %d%%", paramInt.wrappedValue))
            }
        case .lowpower:
            Picker(l10n.t("State"), selection: Binding(
                get: { task.param.lowercased() == "on" },
                set: { task.param = $0 ? "on" : "off" }
            )) {
                Text(l10n.t("On")).tag(true)
                Text(l10n.t("Off")).tag(false)
            }
        case .calibrate:
            EmptyView()
        }
    }

    private var paramInt: Binding<Int> {
        Binding(
            get: { Int(task.param) ?? (task.action == .topup ? 100 : 80) },
            set: { task.param = String($0) }
        )
    }

    private var runAtBinding: Binding<Date> {
        Binding(
            get: { task.runAt ?? Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date() },
            set: { task.runAt = $0 }
        )
    }

    private func normalize() {
        if task.schedule == .once, let runAt = task.runAt {
            task.runAt = Calendar.current.dateInterval(of: .minute, for: runAt)?.start ?? runAt
        }
        switch task.action {
        case .maintain:
            if Int(task.param) == nil { task.param = "80" }
        case .discharge:
            if Int(task.param) == nil { task.param = "80" }
        case .lowpower:
            if task.param.lowercased() != "on" && task.param.lowercased() != "off" { task.param = "on" }
        case .topup:
            task.param = String(min(max(Int(task.param) ?? 100, 20), 100))
        case .calibrate:
            task.param = ""
        }
        if task.schedule == .weekly && task.weekdays.isEmpty {
            task.weekdays = [2]
        }
    }
}

private struct WeekdayPicker: View {
    @EnvironmentObject var l10n: Localization
    @Binding var selected: [Int]

    // Display order: Mon..Sun, values follow launchd (1=Sun … 7=Sat). The
    // labels are BatteryCore's English abbreviations, which double as the
    // lookup keys — the table shortens them further where the language wants.
    private let days: [(label: String, value: Int)] = [
        ("Mo", 2), ("Tu", 3), ("We", 4), ("Th", 5), ("Fr", 6), ("Sa", 7), ("Su", 1),
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(days, id: \.value) { day in
                let isOn = selected.contains(day.value)
                Text(l10n.t(day.label))
                    .font(.caption)
                    .frame(width: 28, height: 24)
                    .background(isOn ? Color.accentColor : Color.secondary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(isOn ? .white : .primary)
                    .onTapGesture {
                        if isOn {
                            selected.removeAll { $0 == day.value }
                        } else {
                            selected.append(day.value)
                        }
                    }
            }
        }
    }
}

// MARK: - Localized task text

extension ScheduledTask {
    /// Localized counterpart of `BatteryCore`'s `summary`.
    ///
    /// Composed here instead of translating the finished string because the
    /// pieces are separate keys: a language is then free to drop the "·"
    /// separator English uses and to put the time first. BatteryCore keeps its
    /// English version because that module ships no string tables — the helper
    /// links it too, and has no UI to translate for.
    @MainActor
    var localizedSummary: String {
        let l10n = Localization.shared
        let time = String(format: "%02d:%02d", hour, minute)
        let what: String = switch action {
        case .maintain: l10n.f("Limit %@%", param)
        case .topup: l10n.f("Charge to %@%", param.isEmpty ? "100" : param)
        case .discharge: l10n.f("Discharge to %@%", param)
        case .calibrate: l10n.t("Calibrate")
        case .lowpower: l10n.f("Low Power %@", param.lowercased() == "on" ? l10n.t("On") : l10n.t("Off"))
        }
        // Built up front: a switch expression only allows a single expression
        // per branch, so the weekly names cannot be assembled inside one.
        let weekdayNames = weekdays.sorted()
            .map { l10n.t(ScheduledTask.weekdayShortName($0)) }
            .joined(separator: " ")
        let scheduledDate = runAt?.formatted(date: .abbreviated, time: .shortened) ?? l10n.t("Choose a date")
        let when: String = switch schedule {
        case .daily: l10n.f("Daily %@", time)
        case .weekdays: l10n.f("Weekdays %@", time)
        case .weekly: "\(weekdayNames) \(time)"
        case .once: l10n.f("Once %@", scheduledDate)
        }
        return "\(what) · \(when)"
    }
}
