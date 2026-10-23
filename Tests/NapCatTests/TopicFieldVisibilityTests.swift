// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// Issue #10: the "ntfy settings…" editor masks the topic (the feed's
/// password) and reveals it only while "Show" is ticked. The pure show/hide
/// state is tested here; the AppKit modal cannot be driven headlessly, so its
/// USE of that state is locked lint-style at the end (same approach as the M1
/// validation lock in ScaffoldTests). No test reads UserDefaults, and every
/// string below is a made-up sample, never a real topic.
struct TopicFieldVisibilityTests {
    static let allStates: [TopicFieldVisibility] = [.masked, .revealed]

    @Test func theEditorOpensMasked() {
        let state = TopicFieldVisibility.initial
        #expect(state == .masked)
        #expect(!state.isRevealed)
        #expect(!state.secureFieldHidden, "the masked field is the one on screen")
        #expect(state.plainFieldHidden, "the plain twin must start hidden")
        #expect(state.checkboxState == .off)
    }

    @Test func toggledFlipsEveryProperty() {
        for state in Self.allStates {
            let next = state.toggled()
            #expect(next != state)
            #expect(next.isRevealed != state.isRevealed)
            #expect(next.secureFieldHidden != state.secureFieldHidden)
            #expect(next.plainFieldHidden != state.plainFieldHidden)
            #expect(next.checkboxState != state.checkboxState)
        }
        let revealed = TopicFieldVisibility.initial.toggled()
        #expect(revealed == .revealed)
        #expect(revealed.secureFieldHidden && !revealed.plainFieldHidden)
        #expect(revealed.checkboxState == .on)
    }

    @Test func togglingTwiceReturnsToTheStartingState() {
        #expect(TopicFieldVisibility.initial.toggled().toggled() == .initial)
        for state in Self.allStates {
            #expect(state.toggled().toggled() == state)
        }
    }

    /// The two overlaid fields share one frame, so exactly one may be visible,
    /// and the checkbox is ticked exactly when the plain one is.
    @Test func exactlyOneFieldIsVisibleAndTheCheckboxTracksIt() {
        for state in Self.allStates {
            #expect(state.secureFieldHidden != state.plainFieldHidden)
            #expect((state.checkboxState == .on) == !state.plainFieldHidden)
        }
    }

    @Test func onlyTheVisibleFieldsTextCounts() {
        #expect(TopicFieldVisibility.masked.visibleText(secure: "from-secure", plain: "stale-copy") == "from-secure")
        #expect(TopicFieldVisibility.revealed.visibleText(secure: "stale-copy", plain: "from-plain") == "from-plain")
    }

    /// The editor's hand-off, modelled on two plain strings exactly as the
    /// AppKit glue drives it: only the masked field is prefilled; a toggle
    /// reads the visible field's text, flips, writes it into the field that
    /// just became visible and blanks the one it hid. Edits made in either
    /// state survive every toggle, and Save returns the text BYTE for byte —
    /// Swift's `==` is canonical-equivalence, so the bytes are compared (a
    /// precomposed "é" must not come back decomposed). An untouched prefill
    /// coming back unchanged is what keeps `setTopic` from disarming a primed
    /// feed.
    @Test func theTextSurvivesEveryToggleByteForByte() {
        struct Fields {
            var secure: String
            var plain = ""
            var visibility = TopicFieldVisibility.initial
            init(prefill: String) {
                secure = prefill
            }
            var saved: String { visibility.visibleText(secure: secure, plain: plain) }
            var hidden: String { visibility.isRevealed ? secure : plain }
            mutating func typeText(_ text: String) {
                if visibility.isRevealed { plain += text } else { secure += text }
            }
            mutating func toggle() {
                let text = saved
                visibility = visibility.toggled()
                if visibility.isRevealed { plain = text } else { secure = text }
                if visibility.isRevealed { secure = "" } else { plain = "" }
            }
        }

        let prefill = "sample-topic-\u{E9}"            // precomposed é
        var untouched = Fields(prefill: prefill)
        #expect(untouched.hidden.isEmpty, "the plain twin must open empty")
        for _ in 0..<4 {
            untouched.toggle()
            #expect(untouched.hidden.isEmpty, "a hidden field must never keep a copy of the topic")
        }
        #expect(Array(untouched.saved.utf8) == Array(prefill.utf8), "show/hide alone must never alter the value")

        var edited = Fields(prefill: prefill)
        edited.typeText("-a")                          // typed while masked
        edited.toggle()                                // reveal
        #expect(edited.plain == prefill + "-a")
        edited.typeText("b")                           // typed while revealed
        edited.toggle()                                // hide again
        #expect(edited.visibility == .masked)
        #expect(Array(edited.saved.utf8) == Array((prefill + "-ab").utf8))
        edited.toggle()
        #expect(Array(edited.saved.utf8) == Array((prefill + "-ab").utf8), "Save while revealed returns the same bytes")

        var cleared = Fields(prefill: prefill)
        cleared.plain = prefill                        // a stale twin copy, as if blanking were skipped
        cleared.secure = ""                            // user cleared the masked field
        cleared.toggle()
        #expect(cleared.saved.isEmpty, "a stale prefill in the hidden twin must not resurrect a cleared topic")
    }

    @Test func accessibilityAndTitleStrings() {
        #expect(TopicFieldVisibility.fieldAccessibilityLabel == "Topic")
        #expect(TopicFieldVisibility.checkboxTitle == "Show")
        #expect(TopicFieldVisibility.checkboxAccessibilityLabel == "Show topic")
    }

    /// USE lock: the editor's topic row is an NSSecureTextField that opens
    /// masked and focused, the state comes from the pure type, and Save hands
    /// back the visible field's text — not a field prefilled on the side.
    /// Security-review follow-ups are locked too: the secure field is not
    /// offered saved logins / generated passwords (M1), only it is prefilled,
    /// and a toggle blanks the field it hid only after hiding it (L1).
    @Test func theSettingsEditorUsesTheMaskedTopicRow() throws {
        let menu = LidGuardStructureTests.codeOnly(try String(
            contentsOf: LidGuardStructureTests.sourcesDir().appendingPathComponent("MenuContentView.swift"),
            encoding: .utf8
        ))
        try #require(menu.contains("final class MenuContentView"))
        for token in [
            "MaskedTopicRow(topic: entry.topic,",
            "alert.window.initialFirstResponder = topicRow.secureField",
            "LidAlertSettingsEntry(topic: topicRow.topic,",
            "secureField = NSSecureTextField(frame: fieldFrame)",
            "private var visibility = TopicFieldVisibility.initial",
            "visibility.visibleText(secure: secureField.stringValue, plain: plainField.stringValue)",
            "visibility = visibility.toggled()",
            "secureField.contentType = .newPassword",
            "secureField.isAutomaticTextCompletionEnabled = false",
            "plainField.isAutomaticTextCompletionEnabled = false",
            "secureField.stringValue = topic",
            "let hidden: NSTextField = visibility.isRevealed ? secureField : plainField",
            "hidden.stringValue = \"\"",
        ] {
            #expect(menu.contains(token), "'\(token)' not found in MenuContentView.swift — the masked topic row was rewired")
        }
        #expect(!menu.contains("= entry.topic"), "the topic must reach the editor only through MaskedTopicRow")
        #expect(menu.components(separatedBy: "stringValue = topic").count - 1 == 1,
                "only the secure field may be prefilled with the topic")

        // The blank comes AFTER `apply()` hid the field, inside the toggle.
        let toggle = try #require(menu.range(of: "func toggleVisibility("))
        let body = menu[toggle.upperBound...]
        let hide = try #require(body.range(of: "apply()"))
        let blank = try #require(body.range(of: "hidden.stringValue = \"\""))
        #expect(hide.upperBound <= blank.lowerBound, "the hidden field must be blanked only after it is hidden")
    }
}
