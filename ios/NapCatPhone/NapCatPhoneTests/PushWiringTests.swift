@testable import NapCatPhone
import Testing
import UserNotifications

/// How pushes and the permission row reach the user. The delegate itself
/// is never driven here: it only forwards to `AlertFeed.refresh()`, which
/// `AlertFeedTests` covers.
@Suite struct PushWiringTests {
    /// A push while the app is open still presents: banner, sound and a
    /// Notification Center entry, exactly that set (no badge).
    @Test func aForegroundPushPresentsBannerListAndSound() {
        #expect(ForegroundPresentation.options == [.banner, .list, .sound])
    }

    /// The Settings affordance resolves to the system's deep link.
    @Test func thePermissionRowOpensNotificationSettings() {
        #expect(PermissionRow.settingsURL != nil)
    }
}
