import Foundation
@testable import NapCatPhone
import Testing
import UIKit

/// The notification permission, shared by the main screen's permission row
/// and Settings › Notifications (#92). The main screen keeps its states and
/// its words exactly.
@Suite @MainActor struct NotificationPermissionTests {
    /// Pin: the main screen's row says exactly what it said before the move,
    /// and still opens the system's page for this app.
    @Test func theMainScreensPermissionRowIsUnchanged() {
        #expect(PermissionRow.title == "Notifications are off")
        #expect(PermissionRow.detail == "Alerts still show up here, but your iPhone won't buzz.")
        #expect(PermissionRow.action == "Turn On in Settings")
        #expect(PermissionRow.actionSymbol == "arrow.up.forward.app")
        #expect(PermissionRow.settingsURL != nil)
        #expect(PermissionRow.settingsURL == URL(string: UIApplication.openNotificationSettingsURLString))
        #expect(ConnectionState.allCases.filter(\.showsPermissionRow) == [.notificationsOff])
    }

    @Test func eachStateReadsAsItsSeverity() {
        #expect(NotificationPermission.checking.line == PhoneLine(text: "Checking…", severity: .nominal))
        #expect(NotificationPermission.on.line == PhoneLine(text: "On", severity: .nominal))
        #expect(NotificationPermission.off.line == PhoneLine(text: "Off", severity: .warning))
        #expect(NotificationPermission.off.line.spoken == "Warning: Off")
        #expect(NotificationPermission(alertsAllowed: true) == .on)
        #expect(NotificationPermission(alertsAllowed: false) == .off)
    }

    /// Off says what it means and offers to turn alerts on, in the main
    /// screen's words; otherwise the affordance just opens the page.
    @Test func theAffordanceAndDetailFollowTheState() {
        #expect(NotificationPermission.off.action == PermissionRow.action)
        #expect(NotificationPermission.off.detail == PermissionRow.detail)
        for state in [NotificationPermission.checking, .on] {
            #expect(state.action == "Open Notification Settings")
            #expect(state.detail == nil)
        }
    }

    /// A live feed claims nothing before its first probe, then records each
    /// read, even without an account (the pill then says iCloud first).
    @Test func theFeedRecordsEachRead() async {
        let source = ScriptedSource(account: .available, alerts: [])
        let feed = AlertFeed(source: source, notifications: FixedNotificationGate(connection: .notificationsOff),
                             isLive: true)
        #expect(feed.notificationPermission == .checking)
        await feed.refresh()
        #expect(feed.notificationPermission == .off)
        #expect(feed.connection == .notificationsOff)

        let offline = AlertFeed(source: ScriptedSource(account: .unavailable, alerts: []),
                                notifications: FixedNotificationGate(connection: .notificationsOff), isLive: true)
        await offline.refresh()
        #expect(offline.connection == .iCloudUnavailable)
        #expect(offline.notificationPermission == .off)
    }

    /// Fixture feeds show their permission from the first frame, the same
    /// one a refresh reads, and the main screen's row only ever shows while
    /// the permission is off.
    @Test(arguments: ConnectionState.probed)
    func aFixtureFeedAgreesWithTheMainScreen(_ connection: ConnectionState) async {
        var options = LaunchOptions()
        options.connection = connection
        let feed = AlertFeed.make(options: options, now: Date(), liveCapable: false)
        let first = feed.notificationPermission
        #expect(first == (connection == .notificationsOff ? .off : .on))
        await feed.refresh()
        #expect(feed.notificationPermission == first)
        #expect(feed.connection == connection)
        if feed.connection.showsPermissionRow { #expect(feed.notificationPermission == .off) }
    }

    /// One shared way to the system's page: only the shared button names
    /// the deep link, and the main screen's row uses that button.
    @Test func theDeepLinkIsSpelledOnce() throws {
        let app = try CloudKitStructureTests.swiftFiles(under: CloudKitStructureTests.appDir)
        let holders = app.filter {
            CloudKitStructureTests.codeOnly($0.text).contains("openNotificationSettingsURLString")
        }.map(\.path)
        #expect(holders == ["\(CloudKitStructureTests.appDir)/Screen/NotificationSettingsButton.swift"])
        let row = try #require(app.first { $0.path.hasSuffix("/Screen/PermissionRow.swift") })
        #expect(CloudKitStructureTests.codeOnly(row.text).contains("NotificationSettingsButton(title: Self.action)"))
    }
}
