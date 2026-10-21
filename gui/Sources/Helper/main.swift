import Foundation
import BatteryCore

/// battery-keeper-helper --task <uuid>
/// Invoked by launchd at scheduled times. Executes the task's action via the
/// battery CLI, appends to history.json, and updates the task's lastRun/lastResult.
/// Runs headless and exits.

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("helper: \(message)\n".utf8))
    exit(code)
}

// Parse --task <uuid>
var taskID: UUID?
var forceRun = false
var argIterator = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argIterator.next() {
    if arg == "--task", let value = argIterator.next() {
        taskID = UUID(uuidString: value)
    } else if arg == "--force" {
        forceRun = true
    }
}
guard let taskID else { fail("usage: battery-keeper-helper --task <uuid>", code: 2) }

// Advisory lock serializes task bookkeeping; long battery cycles release it.
try? StateDirectory.ensureExists()
let lockFD = open(StateDirectory.helperLockFile.path, O_CREAT | O_RDWR, 0o644)
guard lockFD >= 0 else { fail("cannot open lock file") }
if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    // Another helper holds the lock. Wait briefly for it to finish rather
    // than silently dropping the task — launchd-triggered tasks should run.
    var acquired = false
    for _ in 0..<20 {
        usleep(500_000)
        if flock(lockFD, LOCK_EX | LOCK_NB) == 0 { acquired = true; break }
    }
    if !acquired { fail("another helper is still running", code: 1) }
}
defer { flock(lockFD, LOCK_UN); close(lockFD) }

// Load task.
var taskList = JSONStore.load(TaskList.self, from: StateDirectory.tasksFile, default: TaskList())
guard let index = taskList.tasks.firstIndex(where: { $0.id == taskID }) else {
    fail("task \(taskID) not found in tasks.json")
}
let task = taskList.tasks[index]
guard task.enabled || forceRun else { exit(0) }

if task.schedule == .once && !forceRun {
    guard let runAt = task.runAt else { fail("one-time task has no date") }
    // launchd has calendar month/day fields but no year. It can therefore
    // start this agent at an earlier annual match (or on RunAtLoad); leave the
    // task armed until its selected date is actually due.
    guard runAt <= Date() else { exit(0) }
}

// A one-time task is consumed when it starts, even if the battery command
// later fails. This prevents launchd from replaying it on the same calendar
// date after a restart or next year.
if task.schedule == .once && task.enabled {
    taskList.tasks[index].enabled = false
    try? JSONStore.save(taskList, to: StateDirectory.tasksFile)
}

let cli = ProcessBatteryCLI()
let config = JSONStore.load(AppConfig.self, from: StateDirectory.configFile, default: AppConfig())

var outcome: (Bool, String, String?) = (false, "not executed", nil)
var statusForMode: BatteryStatus?

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
}

log("starting task \(task.id)")
do {
    // Current mode, for override notes in history.
    log("fetching status…")
    statusForMode = try await cli.status()
    log("status fetched: \(statusForMode?.percentage ?? -1)%")

    // Long battery operations wait for their target so that history and
    // notifications reflect completion. Release the bookkeeping lock while
    // the CLI runs; other scheduled tasks may still start during a long cycle.
    let longRunning = task.action == .topup || task.action == .discharge || task.action == .calibrate
    if longRunning { flock(lockFD, LOCK_UN) }
    let calibrating = CalibrationTracker.detectRunningCalibration() != nil
    let mode = statusForMode.map { ModeDeriver.derive(config: config, status: $0, calibrating: calibrating) } ?? .idle
    log("executing action \(task.action.rawValue) param=\(task.param)")
    outcome = await TaskExecutor.execute(task, cli: cli, currentMode: mode)
    if longRunning { flock(lockFD, LOCK_EX) }
    log("action finished success=\(outcome.0) output=\(outcome.1.prefix(80))")
} catch {
    outcome = (false, String(describing: error), nil)
    log("error: \(outcome.1)")
}
log("writing history")

// Record history.
var history = JSONStore.load(History.self, from: StateDirectory.historyFile, default: History())
history.append(HistoryEntry(
    taskID: task.id,
    taskName: task.name,
    success: outcome.0,
    output: outcome.1,
    note: outcome.2
))
try? JSONStore.save(history, to: StateDirectory.historyFile)

// Update task bookkeeping from disk again because another task may have run
// while this helper released the lock for a long battery cycle.
var latestTaskList = JSONStore.load(TaskList.self, from: StateDirectory.tasksFile, default: TaskList())
if let latestIndex = latestTaskList.tasks.firstIndex(where: { $0.id == taskID }) {
    latestTaskList.tasks[latestIndex].lastRun = Date()
    latestTaskList.tasks[latestIndex].lastResult = outcome.0 ? "ok" : outcome.1
    if task.schedule == .once {
        latestTaskList.tasks[latestIndex].enabled = false
    }
    try? JSONStore.save(latestTaskList, to: StateDirectory.tasksFile)
}

let latestConfig = JSONStore.load(AppConfig.self, from: StateDirectory.configFile, default: AppConfig())
if latestConfig.scheduledTaskNotifications {
    do {
        try await ScheduledTaskNotifications.deliver(
            taskName: task.name,
            success: outcome.0,
            output: outcome.1
        )
    } catch {
        log("could not send notification: \(error)")
    }
}

if task.schedule == .once {
    LaunchdManager.uninstall(taskID: task.id)
}

exit(outcome.0 ? 0 : 1)
