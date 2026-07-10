import ServiceManagement
import Testing
@testable import NapCat

/// Pure SMAppService.Status → menu-presentation mapping (P5). These tests
/// never construct LoginItemController and never touch SMAppService.mainApp —
/// registering/unregistering the real login item would mutate the user's
/// Background Items state (live checks are the Morning checklist, item 7).
struct LoginItemPresentationTests {
    @Test func enabledRendersOnWithNoCaption() {
        let mapped = MenuStateModel.launchAtLoginPresentation(for: .enabled)
        #expect(mapped.isOn)
        #expect(mapped.caption == nil)
        #expect(!mapped.showSettingsShortcut)
    }

    @Test func notRegisteredRendersOffSilently() {
        let mapped = MenuStateModel.launchAtLoginPresentation(for: .notRegistered)
        #expect(!mapped.isOn)
        #expect(mapped.caption == nil)
        #expect(!mapped.showSettingsShortcut)
    }

    @Test func requiresApprovalRendersOffWithSystemSettingsGuidance() {
        let mapped = MenuStateModel.launchAtLoginPresentation(for: .requiresApproval)
        #expect(!mapped.isOn, "pending approval is not enabled — never render a hopeful checkmark")
        #expect(mapped.caption?.contains("System Settings") == true)
        #expect(mapped.showSettingsShortcut, "the user needs a way into Login Items settings")
    }

    @Test func notFoundExplainsItselfInsteadOfFailingSilently() {
        let mapped = MenuStateModel.launchAtLoginPresentation(for: .notFound)
        #expect(!mapped.isOn)
        #expect(mapped.caption != nil)
        #expect(!mapped.showSettingsShortcut)
    }
}
