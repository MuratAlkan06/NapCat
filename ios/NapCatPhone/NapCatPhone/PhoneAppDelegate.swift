import NapCatWire
import os
import UIKit
import UserNotifications

/// Owns the launch's `AlertFeed` and routes the system's push callbacks to
/// it. A remote notification is the alert subscription's or, since #194, the
/// prompt subscription's, which is tried first
/// (`CloudKitAlertSource.pushedPromptID`): a prompt push starts one read of
/// the prompts (with the owner's switch as last set; off, nothing is read),
/// and a tap on one opens that prompt once the inbox holds it. An alert
/// push means what it always has: fetch the record it names, then fetch
/// again (records are deduped by name, so a repeat costs nothing). The app
/// declares no background modes, so these run only while the app is open
/// or being opened from a push.
final class PhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private static let logger = Logger(subsystem: "com.muratalkan.napcat.phone", category: "push")

    let feed = AlertFeed.make(options: LaunchOptions.fromLaunchArguments(), now: Date())
    /// The forwarded permission prompts (F4, slice S3; received live since
    /// #194, while the owner's switch is on). A `-NapCatRequest` launch holds a
    /// fixture one instead.
    let inbox = RequestInbox.make(options: LaunchOptions.fromLaunchArguments(), now: Date())

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
        if CloudKitAlertSource.pushedPromptID(in: userInfo) != nil {
            await inbox.refreshPrompts()
            return .noData
        }
        guard feed.isLive else { return .noData }
        return await feed.receivePush(recordName: feed.pushedRecordName(in: userInfo)) ? .newData : .noData
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Foreground: fetch so the list updates, and still present the alert
    /// (banner, sound, Notification Center) per `ForegroundPresentation`.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let userInfo = notification.request.content.userInfo
        if let prompt = CloudKitAlertSource.pushedPromptID(in: userInfo) {
            await receivePrompt(prompt, opens: false)
        } else {
            await receivePush(named: feed.pushedRecordName(in: userInfo))
        }
        return ForegroundPresentation.options
    }

    /// The owner tapped a push: the app is opening, so fetch now; a prompt's
    /// opens that prompt.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        if let prompt = CloudKitAlertSource.pushedPromptID(in: userInfo) {
            await receivePrompt(prompt, opens: true)
        } else {
            await receivePush(named: feed.pushedRecordName(in: userInfo))
        }
    }

    /// The payload is read where it arrives; only the record name (a
    /// `String`) crosses to the main actor.
    @MainActor
    private func receivePush(named recordName: String?) async {
        await feed.receivePush(recordName: recordName)
    }

    /// A prompt push: only its prompt ID crosses to the main actor. Tapped,
    /// it is opened once held; either way the prompts are read once.
    @MainActor
    private func receivePrompt(_ id: PromptID, opens: Bool) async {
        if opens { inbox.open(id) }
        await inbox.refreshPrompts()
    }
}

/// A push that arrives while the app is open presents as it would in the
/// background: a banner, its sound and a Notification Center entry, on top
/// of the list updating in place. This is an attention app, so being on
/// screen is no reason to go quiet: a list that changes silently is easy
/// to miss (owner ruling 2026-11-22, after a finish alert reached the open
/// app and buzzed nothing). Badges are not used, so no `.badge`.
enum ForegroundPresentation {
    static let options: UNNotificationPresentationOptions = [.banner, .list, .sound]
}
