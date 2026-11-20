import Foundation
import os
import UserNotifications

/// The app's quiet notification: «Автоочистка освободила N ГБ» after an auto-clean run (updates only get the menu bar
/// dot). No sound, no paths. Permission
/// is asked once, when auto-clean is first turned on (never in the UI-test sandbox, which shows nothing); the app lives
/// in the menu bar only with auto-clean on.
final class AutoCleanNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.ovvi.MacWashing", category: "autoclean")
    static let shared = AutoCleanNotifier()

    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    /// Asks for permission to show alerts (only the first time does macOS show the question).
    func requestPermission() {
        center.delegate = self
        center.requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                Self.log.error("notification permission: \(error.localizedDescription, privacy: .public)")
            } else {
                Self.log.info("notification permission \(granted ? "granted" : "declined", privacy: .public)")
            }
        }
    }

    func post(freed: String) {
        center.delegate = self
        let content = UNMutableNotificationContent()
        content.title = "MacWashing"
        content.body = String(localized: "Автоочистка освободила \(freed)")
        content.sound = nil
        let request = UNNotificationRequest(identifier: "autoclean." + UUID().uuidString, content: content, trigger: nil)
        center.add(request) { error in
            if let error { Self.log.error("notification not posted: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// Shown as a banner even while MacWashing is the active app.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
