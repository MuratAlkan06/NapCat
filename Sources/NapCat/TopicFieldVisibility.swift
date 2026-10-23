import AppKit

/// Show/hide state of the topic field in the "ntfy settings…" editor (issue
/// #10). The topic IS the password to the alert feed, so the editor opens with
/// it masked and reveals it only while the user ticks "Show" to proofread it.
///
/// Why TWO overlaid fields rather than one: NSSecureTextField is its own class
/// (its cell and its field editor do the bullet echo), and AppKit offers no
/// supported way to switch a field between secure and plain at runtime. The
/// editor therefore stacks an NSSecureTextField and a plain NSTextField in the
/// same frame and shows exactly one of them; each toggle hands the visible
/// field's text to the other unchanged and blanks the one it hid. This type is
/// the pure half — which field is visible, what the checkbox shows, and whose
/// text counts — MenuContentView only maps it onto the views.
///
/// Byte-identity matters: Save returns the VISIBLE field's text untouched, and
/// `LidGuardController.setTopic` keeps the feature primed when the value is
/// unchanged, so opening the editor and saving the prefilled topic must never
/// disarm anything.
///
/// The topic passes through `visibleText` but is never logged: this file holds
/// no log call at all, and the no-topic-in-logs lint scans it.
enum TopicFieldVisibility {
    case masked
    case revealed

    /// Every editor opens masked — the topic is never on screen until asked for.
    static let initial: TopicFieldVisibility = .masked

    var isRevealed: Bool { self == .revealed }
    var secureFieldHidden: Bool { isRevealed }
    var plainFieldHidden: Bool { !isRevealed }
    var checkboxState: NSControl.StateValue { isRevealed ? .on : .off }

    func toggled() -> TopicFieldVisibility { isRevealed ? .masked : .revealed }

    /// The text that counts — what a toggle hands to the other field and what
    /// Save returns: the visible field's own text, byte for byte. The hidden
    /// field is never read (MenuContentView also keeps it blank).
    func visibleText(secure: String, plain: String) -> String { isRevealed ? plain : secure }

    // Accessibility: both fields speak as "Topic" (VoiceOver announces the
    // secure one as a secure field and does not read its text out). The
    // checkbox keeps its short visible title but names WHAT it shows.
    static let fieldAccessibilityLabel = "Topic"
    static let checkboxTitle = "Show"
    static let checkboxAccessibilityLabel = "Show topic"
}
