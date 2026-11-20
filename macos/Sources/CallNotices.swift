import UserNotifications

/// "The call seems to be over" as a macOS notification: Claude Whisper's icon, a Stop Recording
/// button, and the close button, which keeps the note going. It stays on screen until answered when
/// Claude Whisper's notifications are set to Persistent (System Settings › Notifications); otherwise
/// macOS moves it to Notification Center after a few seconds.
enum CallEndNotice {
    static let category = "callEnd"
    static let stopAction = "stop"
    private static let id = "callEnd"

    /// Both notifications' buttons (macOS keeps one set of categories per app).
    static func register() {
        let stop = UNNotificationAction(identifier: stopAction, title: "Stop Recording", options: [])
        let start = UNNotificationAction(identifier: CallStartNotice.startAction, title: "Start Recording", options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: category, actions: [stop], intentIdentifiers: [],
                                   options: [.customDismissAction]),
            UNNotificationCategory(identifier: CallStartNotice.category, actions: [start], intentIdentifiers: []),
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

/// "Record this call?" when a call app has taken the microphone and Note Taker isn't recording: a
/// Start Recording button and the close button. Unlike the call-over notification it doesn't wait
/// for an answer: Claude Whisper takes it away after a few seconds, even with Persistent alerts.
enum CallStartNotice {
    static let category = "callStart"
    static let startAction = "start"
    static let id = "callStart"
    /// How long it stays on screen.
    static let shown: TimeInterval = 15

    static func show(app: String) {
        let content = UNMutableNotificationContent()
        content.title = "Record this call?"
        content.body = "\(app) is using the microphone. Start a note with Note Taker."
        content.categoryIdentifier = category
        // Silent: the call has just started and its own sounds are playing.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
                if let error { Log.write("could not show the call-start notification: \(error.localizedDescription)") }
            }
        }
    }

    static func hide() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
}
