@testable import NapCatPhone
import Testing

/// How pushes and the permission row reach the user. The delegate itself
/// is never driven here: it only forwards to `AlertFeed.refresh()`, which
/// `AlertFeedTests` covers.
@Suite struct PushWiringTests {
    /// A push while the app is open updates the list in place: no banner.
    @Test func aForegroundPushShowsNoBanner() {
        #expect(ForegroundPresentation.options.isEmpty)
    }

    /// The Settings affordance resolves to the system's deep link.
    @Test func thePermissionRowOpensNotificationSettings() {
        #expect(PermissionRow.settingsURL != nil)
    }
}
