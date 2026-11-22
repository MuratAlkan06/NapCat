import os
import UIKit
import UserNotifications

/// Owns the launch's `AlertFeed` and routes the system's push callbacks to
/// it. Every remote notification this app can receive is the alert
/// subscription's, and each one means the same thing: fetch the record it
/// names, then fetch again (records are deduped by name, so a repeat costs
/// nothing). The app declares no background modes, so these run only while
/// the app is open or being opened from an alert.
final class PhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private static let logger = Logger(subsystem: "com.muratalkan.napcat.phone", category: "push")

    let feed = AlertFeed.make(options: LaunchOptions.fromLaunchArguments(), now: Date())

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Fixture runs never touch the notification center.
        if feed.isLive { UNUserNotificationCenter.current().delegate = self }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Self.logger.info("registered for remote notifications")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        Self.logger.error("remote notification registration failed (code \((error as NSError).code))")
    }

    /// A push the system hands the app delegate while the app runs (per
    /// CloudKit's docs, only a push without an alert comes here; the
    /// subscription's alerts arrive through the notification-center
    /// delegate below): fetch, and say whether it found anything new.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        guard feed.isLive else { return .noData }
        return await feed.receivePush(recordName: feed.pushedRecordName(in: userInfo)) ? .newData : .noData
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Foreground: the list updates itself, no banner.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await receivePush(named: feed.pushedRecordName(in: notification.request.content.userInfo))
        return ForegroundPresentation.options
    }

    /// The owner tapped an alert: the app is opening, so fetch now.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await receivePush(named: feed.pushedRecordName(in: response.notification.request.content.userInfo))
    }

    /// The payload is read where it arrives; only the record name (a
    /// `String`) crosses to the main actor.
    @MainActor
    private func receivePush(named recordName: String?) async {
        await feed.receivePush(recordName: recordName)
    }
}

/// A push that arrives while the app is open updates the list in place, so
/// no banner, no sound and no badge: the iOS default for a foreground app.
enum ForegroundPresentation {
    static let options: UNNotificationPresentationOptions = []
}
