import SwiftUI
import BatteryCore

struct SchedulesView: View {
    @EnvironmentObject var state: AppState
    @State private var taskList: TaskList = TaskList()
    @State private var history: History = History()
    @State private var editingTask: ScheduledTask?

    private var helperPath: String { LaunchdManager.currentHelperPath }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    if taskList.tasks.isEmpty {
                        Text("No scheduled tasks yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(taskList.tasks) { task in
                        TaskRow(task: task)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { edit(task) }
                            .contextMenu {
                                Button("Edit…") { edit(task) }
                                Button("Run Now") { runNow(task) }
                                Divider()
                                Button("Delete", role: .destructive) { delete(task) }
                            }
                    }
                    .onDelete(perform: deleteAt)
                } header: {
                    HStack {
                        Text("Tasks")
                        Spacer()
                        Button { newTask() } label: { Image(systemName: "plus") }
                    }
                }

                Section("History") {
                    if history.entries.isEmpty {
                        Text("No runs yet.")
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
            name: "New Task",
            action: .maintain,
            param: "80",
            schedule: .daily,
            hour: 9,
            minute: 0,
            weekdays: [2]
        )
    }

    private func edit(_ task: ScheduledTask) {
        editingTask = task
    }

    private func save(_ task: ScheduledTask) {
        if let index = taskList.tasks.firstIndex(where: { $0.id == task.id }) {
            taskList.tasks[index] = task
        } else {
            taskList.tasks.append(task)
        }
        persist()
        reinstall(task)
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
            reinstall(taskList.tasks[index])
        } else {
            LaunchdManager.uninstall(taskID: task.id)
        }
        reload()
    }

    private func reinstall(_ task: ScheduledTask) {
        guard task.enabled else {
            LaunchdManager.uninstall(taskID: task.id)
            return
        }
        try? LaunchdManager.install(task: task, helperPath: helperPath)
    }

    private func runNow(_ task: ScheduledTask) {
        let path = helperPath
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["--task", task.id.uuidString]
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
                Text(task.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let result = task.lastResult, let lastRun = task.lastRun {
                    Text("Last: \(result == "ok" ? "✓" : "✗ \(result)") · \(lastRun.formatted(date: .abbreviated, time: .shortened))")
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
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Editor

private struct TaskEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var task: ScheduledTask
    let onSave: (ScheduledTask) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Schedule Task")
                .font(.title3)

            Form {
                TextField("Name", text: $task.name)

                Picker("Action", selection: $task.action) {
                    ForEach(ScheduledTask.Action.allCases, id: \.self) { action in
                        Text(action.displayName).tag(action)
                    }
                }

                actionParamField

                Picker("Repeat", selection: $task.schedule) {
                    ForEach(ScheduledTask.ScheduleType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }

                if task.schedule == .weekly {
                    WeekdayPicker(selected: $task.weekdays)
                }

                HStack {
                    Picker("Hour", selection: $task.hour) {
                        ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                    }
                    Text(":")
                    Picker("Minute", selection: $task.minute) {
                        ForEach([0, 15, 30, 45], id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    normalize()
                    onSave(task)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(task.name.isEmpty || (task.schedule == .weekly && task.weekdays.isEmpty))
            }
        }
        .padding()
        .frame(width: 380)
    }

    @ViewBuilder
    private var actionParamField: some View {
        switch task.action {
        case .maintain:
            Stepper(value: paramInt, in: 20...100, step: 5) {
                Text("Limit: \(paramInt.wrappedValue)%")
            }
        case .discharge:
            Stepper(value: paramInt, in: 10...100, step: 5) {
                Text("Discharge to: \(paramInt.wrappedValue)%")
            }
        case .lowpower:
            Picker("State", selection: Binding(
                get: { task.param.lowercased() == "on" },
                set: { task.param = $0 ? "on" : "off" }
            )) {
                Text("On").tag(true)
                Text("Off").tag(false)
            }
        case .topup, .calibrate:
            EmptyView()
        }
    }

    private var paramInt: Binding<Int> {
        Binding(
            get: { Int(task.param) ?? 80 },
            set: { task.param = String($0) }
        )
    }

    private func normalize() {
        switch task.action {
        case .maintain:
            if Int(task.param) == nil { task.param = "80" }
        case .discharge:
            if Int(task.param) == nil { task.param = "80" }
        case .lowpower:
            if task.param.lowercased() != "on" && task.param.lowercased() != "off" { task.param = "on" }
        case .topup, .calibrate:
            task.param = ""
        }
        if task.schedule == .weekly && task.weekdays.isEmpty {
            task.weekdays = [2]
        }
    }
}

private struct WeekdayPicker: View {
    @Binding var selected: [Int]

    // Display order: Mon..Sun, values follow launchd (1=Sun … 7=Sat)
    private let days: [(label: String, value: Int)] = [
        ("Mo", 2), ("Tu", 3), ("We", 4), ("Th", 5), ("Fr", 6), ("Sa", 7), ("Su", 1),
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(days, id: \.value) { day in
                let isOn = selected.contains(day.value)
                Text(day.label)
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
