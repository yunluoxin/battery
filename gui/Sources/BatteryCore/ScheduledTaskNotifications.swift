import Foundation
import UserNotifications

public enum ScheduledTaskNotifications {
    public static func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    public static func deliver(taskName: String, success: Bool, output: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = taskName
        content.body = "\(success ? "✓" : "✗") \(output)"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try await UNUserNotificationCenter.current().add(request)
    }
}
