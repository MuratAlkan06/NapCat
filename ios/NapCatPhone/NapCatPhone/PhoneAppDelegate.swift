import os
import UIKit
import UserNotifications

/// Owns the launch's `AlertFeed` and routes the system's push callbacks to
/// it. Every remote notification this app can receive is the alert
/// subscription's, and each one means the same thing: fetch again (records
/// are deduped by name, so a repeat costs nothing).
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

    /// A push while the app runs (or a background wake, should the
    /// subscription ever ask for one): fetch, and say whether it found
    /// anything new.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        guard feed.isLive else { return .noData }
        return await feed.refresh() ? .newData : .noData
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Foreground: the list updates itself, no banner.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await refreshFeed()
        return ForegroundPresentation.options
    }

    /// The owner tapped an alert: the app is opening, so fetch now.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await refreshFeed()
    }

    @MainActor
    private func refreshFeed() async {
        await feed.refresh()
    }
}

/// A push that arrives while the app is open updates the list in place, so
/// no banner, no sound and no badge: the iOS default for a foreground app.
enum ForegroundPresentation {
    static let options: UNNotificationPresentationOptions = []
}
