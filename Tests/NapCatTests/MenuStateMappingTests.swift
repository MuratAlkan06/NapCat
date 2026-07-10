import AppKit
import Testing
@testable import NapCat

/// The stay-awake menu item renders OBSERVED `pmset -g` state only (ADR §6):
/// on/off for a definite reading, mixed when the state could not be read —
/// never a false checkmark from cached intent.
struct MenuStateMappingTests {
    @Test func observedEnabledShowsCheckmark() {
        #expect(MenuContentView.stayAwakeItemState(forObserved: true) == .on)
    }

    @Test func observedDisabledShowsNoCheckmark() {
        #expect(MenuContentView.stayAwakeItemState(forObserved: false) == .off)
    }

    @Test func unknownObservedStateShowsMixed() {
        #expect(MenuContentView.stayAwakeItemState(forObserved: nil) == .mixed)
    }
}
