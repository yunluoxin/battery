import Foundation

/// Manages per-task launchd agents:
/// ~/Library/LaunchAgents/com.battery.keeper.task.<id>.plist
public enum LaunchdManager {
    public static func label(for taskID: UUID) -> String {
        "com.battery.keeper.task.\(taskID.uuidString.lowercased())"
    }

    public static func plistURL(for taskID: UUID) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label(for: taskID)).plist")
    }

    /// Builds StartCalendarInterval entries for the task.
    public static func calendarIntervals(for task: ScheduledTask) -> [[String: Int]] {
        switch task.schedule {
        case .daily:
            return [["Hour": task.hour, "Minute": task.minute]]
        case .weekdays:
            return (2...6).map { ["Weekday": $0, "Hour": task.hour, "Minute": task.minute] }
        case .weekly:
            return task.weekdays.sorted().map { ["Weekday": $0, "Hour": task.hour, "Minute": task.minute] }
        }
    }

    /// Generates the plist XML. Extracted for testability.
    public static func plistXML(for task: ScheduledTask, helperPath: String) -> String {
        let intervals = calendarIntervals(for: task)
        let entries: String
        if intervals.count == 1, let only = intervals.first {
            entries = dictEntry(only)
        } else {
            entries = "<array>\n" + intervals.map { dictEntry($0) }.joined(separator: "\n") + "\n\t</array>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Label</key>
        \t<string>\(label(for: task.id))</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \t\t<string>\(helperPath)</string>
        \t\t<string>--task</string>
        \t\t<string>\(task.id.uuidString)</string>
        \t</array>
        \t<key>StartCalendarInterval</key>
        \t\(entries)
        \t<key>StandardOutPath</key>
        \t<string>\(StateDirectory.url.path)/helper.log</string>
        \t<key>StandardErrorPath</key>
        \t<string>\(StateDirectory.url.path)/helper.log</string>
        </dict>
        </plist>

        """
    }

    private static func dictEntry(_ dict: [String: Int]) -> String {
        let body = dict.sorted { $0.key < $1.key }
            .map { "\t\t<key>\($0.key)</key>\n\t\t<integer>\($0.value)</integer>" }
            .joined(separator: "\n")
        return "\t<dict>\n\(body)\n\t</dict>"
    }

    /// Install or replace the launch agent for a task.
    public static func install(task: ScheduledTask, helperPath: String) throws {
        let url = plistURL(for: task.id)
        try StateDirectory.ensureExists()
        try plistXML(for: task, helperPath: helperPath).write(to: url, atomically: true, encoding: .utf8)
        _ = runLaunchctl(["bootout", guiDomain + "/" + label(for: task.id)])  // ignore failure (may not be loaded)
        let result = runLaunchctl(["bootstrap", guiDomain, url.path])
        guard result.succeeded else {
            throw CLIError.commandFailed(exitCode: result.exitCode, output: "launchctl bootstrap failed: \(result.stderr)")
        }
    }

    /// Remove the launch agent for a task.
    public static func uninstall(taskID: UUID) {
        _ = runLaunchctl(["bootout", guiDomain + "/" + label(for: taskID)])
        try? FileManager.default.removeItem(at: plistURL(for: taskID))
    }

    /// Uninstall then reinstall — used when the app has moved (helper path changed).
    public static func reinstallAll(tasks: [ScheduledTask], helperPath: String) throws {
        for task in tasks where task.enabled {
            try install(task: task, helperPath: helperPath)
        }
    }

    /// Where the helper lives inside the running app. Single definition on
    /// purpose: this path is what gets baked into every launchd agent, so a
    /// second copy of the expression would eventually drift and produce agents
    /// that the self-repair below cannot match.
    public static var currentHelperPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/battery-keeper-helper")
            .path
    }

    /// The helper path baked into an installed agent, or nil when there is no
    /// plist to read. The path is absolute, so moving or re-installing the app
    /// anywhere else leaves every scheduled task pointing at a file that is no
    /// longer there.
    public static func installedHelperPath(taskID: UUID) -> String? {
        guard let data = try? Data(contentsOf: plistURL(for: taskID)),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String],
              let first = args.first
        else { return nil }
        return first
    }

    /// Whether a recorded helper path has fallen out of date. Pure, and the
    /// only place the comparison lives, so the "did the app move" decision can
    /// be tested against paths no test ever writes to disk.
    ///
    /// Compared verbatim rather than by resolving symlinks or normalising: the
    /// path launchd will exec is the literal string in the plist, so a string
    /// difference is exactly the condition worth repairing.
    public static func helperPathChanged(installed: String?, current: String) -> Bool {
        guard let installed else { return false }   // nothing installed yet
        return installed != current
    }

    /// Whether an installed agent for this task still points at the helper.
    public static func needsReinstall(taskID: UUID, currentHelperPath: String) -> Bool {
        helperPathChanged(installed: installedHelperPath(taskID: taskID), current: currentHelperPath)
    }

    /// Reinstall every enabled task whose agent points at a stale helper path.
    /// Returns the tasks that were repaired, so the caller can log or surface
    /// what moved. Silent on failure by design: a task that cannot be
    /// re-registered shows up in History rather than interrupting startup.
    @discardableResult
    public static func reinstallMovedTasks(tasks: [ScheduledTask], helperPath: String) -> [ScheduledTask] {
        var repaired: [ScheduledTask] = []
        for task in tasks where task.enabled && needsReinstall(taskID: task.id, currentHelperPath: helperPath) {
            do {
                try install(task: task, helperPath: helperPath)
                repaired.append(task)
            } catch {
                continue
            }
        }
        return repaired
    }

    private static var guiDomain: String { "gui/\(getuid())" }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) -> CLIResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let out = Pipe(); let err = Pipe()
        process.standardOutput = out; process.standardError = err
        do { try process.run() } catch {
            return CLIResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }
        process.waitUntilExit()
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CLIResult(exitCode: process.terminationStatus, stdout: o, stderr: e)
    }
}
