import UserNotifications

/// "The call seems to be over" as a macOS notification: Claude Whisper's icon, a Stop Recording
/// button, and the close button, which keeps the note going. It stays on screen until answered when
/// Claude Whisper's notifications are set to Persistent (System Settings › Notifications); otherwise
/// macOS moves it to Notification Center after a few seconds.
enum CallEndNotice {
    static let category = "callEnd"
    static let stopAction = "stop"
    private static let id = "callEnd"

    static func register() {
        let stop = UNNotificationAction(identifier: stopAction, title: "Stop Recording", options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: category, actions: [stop], intentIdentifiers: [],
                                   options: [.customDismissAction])
        ])
    }

    /// macOS asks only the first time; later calls just log the answer.
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            Log.write("notifications \(granted ? "allowed" : "not allowed")\(error.map { ": \($0.localizedDescription)" } ?? "")")
        }
    }

    static func show(reason: String) {
        let content = UNMutableNotificationContent()
        content.title = "The call seems to be over"
        content.body = reason.prefix(1).uppercased() + reason.dropFirst() + ". Stop the note?"
        content.categoryIdentifier = category
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error { Log.write("could not show the call-over notification: \(error.localizedDescription)") }
        }
    }

    static func hide() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }
}
