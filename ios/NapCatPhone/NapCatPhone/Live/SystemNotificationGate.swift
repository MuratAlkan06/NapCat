import UIKit
import UserNotifications

/// The live `NotificationGate`: the system notification center. Only a live
/// feed builds one, so fixture runs never show the permission prompt.
///
/// The alert a push shows is rendered by the SYSTEM from the subscription's
/// notification info (title "NapCat", the record's body as the text), so the
/// app schedules no notification of its own; that would buzz twice.
struct SystemNotificationGate: NotificationGate {
    /// What the app may present. Badges are not used.
    nonisolated static let requestedOptions: UNAuthorizationOptions = [.alert, .sound]

    func prepare() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: Self.requestedOptions)
        // CloudKit delivers subscription pushes to this app's registration;
        // the token itself is never needed (CloudKit associates it).
        UIApplication.shared.registerForRemoteNotifications()
    }

    func alertsAllowed() async -> Bool {
        Self.allowsAlerts(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
    }

    /// Only full authorization lets an alert buzz. Undecided (before the
    /// prompt is answered), denied and provisional (quiet, Notification
    /// Center only) all read as "Notifications off".
    nonisolated static func allowsAlerts(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .ephemeral: return true
        case .denied, .notDetermined, .provisional: return false
        @unknown default: return false
        }
    }
}
