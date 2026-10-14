import FactoryKit
import Foundation
import UserNotifications

/// What happens when a local notification arrives, and what happens when it's tapped.
@MainActor
final class PushRouting: NSObject, UNUserNotificationCenterDelegate {
    /// Installed once, at launch, from `AppDelegate`.
/// Held statically because `UNUserNotificationCenter.delegate` is `weak`.
    static let shared = PushRouting()

/// Must be set before launch finishes: a notification that launched the app is delivered
/// during launch, and a later delegate never hears about that tap.
    static func install() {
        UNUserNotificationCenter.current().delegate = shared
    }

    /// A notification arrived while the app is in the foreground: show it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let info = notification.request.content.userInfo
        completionHandler(info["shortcut_request_id"] is String ? [.banner, .list] : [.banner, .sound, .list])
    }

    /// The user tapped a notification. An unrecognised one opens nothing rather than guessing.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        Task { @MainActor in
            defer { completionHandler() }
            if let rawID = info["shortcut_request_id"] as? String, let id = UUID(uuidString: rawID) {
                Container.shared.shortcutActions().openFromNotification(requestID: id)
            } else {
                RealtimeLog.log("push: tapped a notification with no route")
            }
        }
    }
}
