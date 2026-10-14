import Foundation
import UIKit
import UserNotifications

/// Whether this phone may show a notification. The system prompt shows once per install: a later
/// `requestAuthorization` returns the stored answer silently. Not `final` for the preview subclass.
@MainActor
class PushNotifications: ObservableObject {
    /// What iOS currently believes; `.notDetermined` until the first read answers.
    @Published var status: UNAuthorizationStatus = .notDetermined

    /// True while the system prompt is up, so a second tap can't stack a second ask.
    @Published var isRequesting = false

    /// Whether an alert sent right now would appear.
    var isEnabled: Bool { status == .authorized || status == .provisional || status == .ephemeral }

    /// Whether asking would show the system prompt; false once the user has answered either way.
    var canAsk: Bool { status == .notDetermined }

    /// Read the current authorisation. Call on every appearance: the user can change it in iOS Settings.
    func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        status = settings.authorizationStatus
    }

    /// Show the system prompt, returning the resulting status for a caller mid-flow.
    @discardableResult
    func request() async -> UNAuthorizationStatus {
        guard !isRequesting else { return status }
        isRequesting = true
        defer { isRequesting = false }

        do {
            // `.badge` is asked now: asking later would need a prompt that can no longer be shown.
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            // A refusal is `granted == false`, not a throw; the settings read below is the authority.
            print("[push] authorization request failed: \(error.localizedDescription)")
        }
        await refresh()
        return status
    }

    /// Open this app's page in iOS Settings, the only way back from a denial.
    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
