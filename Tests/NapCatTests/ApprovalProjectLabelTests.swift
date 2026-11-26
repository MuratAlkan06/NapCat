// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import NapCatWire
import Testing

/// The project label rule (`ApprovalProjectLabel`): normalize first (trim the
/// spaces at both ends, collapse each run of spaces inside to one), then a
/// label is 1 to 64 bytes of ASCII letters, digits, spaces and
/// `. _ - ( ) & + ,`, with at least one letter or digit. A project's label is
/// its folder's last path component, normalized, when the rule takes it,
/// otherwise empty — never shortened to fit. A frame may carry the empty
/// label or an already-normalized one the rule takes (`admitsOnTheWire`).
struct ApprovalProjectLabelTests {
    // MARK: - The rule

    /// One candidate text: whether the rule takes it once normalized
    /// (`accepts`), and whether a frame may carry it as it stands
    /// (`admitsOnTheWire`).
    struct RuleRow: Sendable, CustomTestStringConvertible {
        let note: String
        let text: String
        let accepted: Bool
        let onTheWire: Bool
        var testDescription: String { note }
    }

    static let thirtyOne: String = String(repeating: "a", count: 31)
    static let thirtyTwo: String = String(repeating: "a", count: 32)
    static let sixtyFour: String = String(repeating: "a", count: 64)
    static let sixtyFive: String = String(repeating: "a", count: 65)
    /// 64 bytes, already normalized: 32 + one space + 31.
    static let sixtyFourWithOneSpace: String = "\(thirtyTwo) \(thirtyOne)"
    /// 66 bytes that normalize to `sixtyFourWithOneSpace`.
    static let sixtyFourAfterARun: String = "\(thirtyTwo)   \(thirtyOne)"
    /// 68 bytes that normalize to `sixtyFour`.
    static let paddedSixtyFour: String = "  \(sixtyFour)  "
    /// 65 bytes, already normalized: 32 + one space + 32.
    static let sixtyFiveWithOneSpace: String = "\(thirtyTwo) \(thirtyTwo)"
    /// 68 bytes that normalize to `sixtyFive`.
    static let paddedSixtyFive: String = " \(sixtyFive)  "

    static let ruleRows: [RuleRow] = [
        // Taken as it stands: a frame may carry it.
        RuleRow(note: "a plain name", text: "NapCat", accepted: true, onTheWire: true),
        RuleRow(note: "one letter", text: "a", accepted: true, onTheWire: true),
        RuleRow(note: "one digit", text: "7", accepted: true, onTheWire: true),
        RuleRow(note: "every allowed kind", text: "My_Project-2.0 (R&D+QA, v3)", accepted: true, onTheWire: true),
        RuleRow(note: "a hidden folder", text: ".config", accepted: true, onTheWire: true),
        RuleRow(note: "a leading dash", text: "-rf", accepted: true, onTheWire: true),
        RuleRow(note: "an underscore and a letter", text: "_a", accepted: true, onTheWire: true),
        RuleRow(note: "a dotted version", text: "v1.2.3", accepted: true, onTheWire: true),
        RuleRow(note: "one space inside", text: "my project", accepted: true, onTheWire: true),
        RuleRow(note: "single spaces inside", text: "My Big Project", accepted: true, onTheWire: true),
        RuleRow(note: "parentheses", text: "NapCat (old)", accepted: true, onTheWire: true),
        RuleRow(note: "an opening parenthesis alone", text: "a(b", accepted: true, onTheWire: true),
        RuleRow(note: "a closing parenthesis alone", text: "a)b", accepted: true, onTheWire: true),
        RuleRow(note: "an ampersand", text: "R&D", accepted: true, onTheWire: true),
        RuleRow(note: "plus signs", text: "c++", accepted: true, onTheWire: true),
        RuleRow(note: "a comma", text: "Smith, Jones", accepted: true, onTheWire: true),
        RuleRow(note: "punctuation around one digit", text: "(-1,+&_.)", accepted: true, onTheWire: true),
        RuleRow(note: "exactly 64 bytes", text: sixtyFour, accepted: true, onTheWire: true),
        RuleRow(note: "exactly 64 bytes with one space", text: sixtyFourWithOneSpace, accepted: true, onTheWire: true),
        // Taken once normalized, but not as it stands: a frame must carry
        // the normalized form.
        RuleRow(note: "a leading space", text: " NapCat", accepted: true, onTheWire: false),
        RuleRow(note: "a trailing space", text: "NapCat ", accepted: true, onTheWire: false),
        RuleRow(note: "spaces at both ends", text: "  NapCat  ", accepted: true, onTheWire: false),
        RuleRow(note: "a run of two spaces inside", text: "a  b", accepted: true, onTheWire: false),
        RuleRow(note: "runs everywhere", text: "  my   big  project  ", accepted: true, onTheWire: false),
        RuleRow(note: "64 bytes once trimmed", text: paddedSixtyFour, accepted: true, onTheWire: false),
        RuleRow(note: "64 bytes once a run is collapsed", text: sixtyFourAfterARun, accepted: true, onTheWire: false),
        // The empty text: no label. A frame may carry it; the rule does not
        // take it.
        RuleRow(note: "empty", text: "", accepted: false, onTheWire: true),
        // Refused: no letter or digit.
        RuleRow(note: "one dot", text: ".", accepted: false, onTheWire: false),
        RuleRow(note: "two dots", text: "..", accepted: false, onTheWire: false),
        RuleRow(note: "three dots", text: "...", accepted: false, onTheWire: false),
        RuleRow(note: "parentheses only", text: "()", accepted: false, onTheWire: false),
        RuleRow(note: "a dash only", text: "-", accepted: false, onTheWire: false),
        RuleRow(note: "an underscore only", text: "_", accepted: false, onTheWire: false),
        RuleRow(note: "an ampersand only", text: "&", accepted: false, onTheWire: false),
        RuleRow(note: "a plus only", text: "+", accepted: false, onTheWire: false),
        RuleRow(note: "a comma only", text: ",", accepted: false, onTheWire: false),
        RuleRow(note: "punctuation and spaces", text: " ( - ) ", accepted: false, onTheWire: false),
        RuleRow(note: "a space only", text: " ", accepted: false, onTheWire: false),
        RuleRow(note: "spaces only", text: "   ", accepted: false, onTheWire: false),
        // Refused: longer than 64 bytes once normalized, never cut.
        RuleRow(note: "65 bytes", text: sixtyFive, accepted: false, onTheWire: false),
        RuleRow(note: "65 bytes with one space", text: sixtyFiveWithOneSpace, accepted: false, onTheWire: false),
        RuleRow(note: "65 bytes once trimmed", text: paddedSixtyFive, accepted: false, onTheWire: false),
        // Refused: other blanks and control bytes.
        RuleRow(note: "a tab", text: "a\tb", accepted: false, onTheWire: false),
        RuleRow(note: "a newline", text: "a\nb", accepted: false, onTheWire: false),
        RuleRow(note: "a carriage return", text: "a\rb", accepted: false, onTheWire: false),
        RuleRow(note: "a NUL byte", text: "a\u{0}b", accepted: false, onTheWire: false),
        RuleRow(note: "a DEL byte", text: "a\u{7F}b", accepted: false, onTheWire: false),
        // Refused: separators and quotes.
        RuleRow(note: "a path separator", text: "a/b", accepted: false, onTheWire: false),
        RuleRow(note: "a separator only", text: "/", accepted: false, onTheWire: false),
        RuleRow(note: "a backslash", text: "a\\b", accepted: false, onTheWire: false),
        RuleRow(note: "a double quote", text: "a\"b", accepted: false, onTheWire: false),
        RuleRow(note: "a single quote", text: "it's", accepted: false, onTheWire: false),
        RuleRow(note: "a backtick", text: "a`b", accepted: false, onTheWire: false),
        // Refused: the rest of ASCII punctuation.
        RuleRow(note: "a colon", text: "a:b", accepted: false, onTheWire: false),
        RuleRow(note: "a semicolon", text: "a;b", accepted: false, onTheWire: false),
        RuleRow(note: "a tilde", text: "~a", accepted: false, onTheWire: false),
        RuleRow(note: "an at sign", text: "me@host", accepted: false, onTheWire: false),
        RuleRow(note: "a hash", text: "#1", accepted: false, onTheWire: false),
        RuleRow(note: "a dollar sign", text: "$HOME", accepted: false, onTheWire: false),
        RuleRow(note: "a percent sign", text: "100%", accepted: false, onTheWire: false),
        RuleRow(note: "an asterisk", text: "a*", accepted: false, onTheWire: false),
        RuleRow(note: "an equals sign", text: "a=b", accepted: false, onTheWire: false),
        RuleRow(note: "a pipe", text: "a|b", accepted: false, onTheWire: false),
        RuleRow(note: "a caret", text: "a^b", accepted: false, onTheWire: false),
        RuleRow(note: "a question mark", text: "a?", accepted: false, onTheWire: false),
        RuleRow(note: "an exclamation mark", text: "a!", accepted: false, onTheWire: false),
        RuleRow(note: "angle brackets", text: "<a>", accepted: false, onTheWire: false),
        RuleRow(note: "square brackets", text: "[a]", accepted: false, onTheWire: false),
        RuleRow(note: "braces", text: "{a}", accepted: false, onTheWire: false),
        // Refused: anything not ASCII.
        RuleRow(note: "an accented letter (composed)", text: "caf\u{E9}", accepted: false, onTheWire: false),
        RuleRow(note: "an accented letter (decomposed)", text: "cafe\u{301}", accepted: false, onTheWire: false),
        RuleRow(note: "a non-Latin name", text: "\u{30D7}\u{30ED}\u{30B8}\u{30A7}\u{30AF}\u{30C8}", accepted: false, onTheWire: false),
        RuleRow(note: "an emoji", text: "cat\u{1F408}", accepted: false, onTheWire: false),
        RuleRow(note: "a no-break space", text: "a\u{A0}b", accepted: false, onTheWire: false),
        RuleRow(note: "an en space", text: "a\u{2002}b", accepted: false, onTheWire: false),
        RuleRow(note: "an ideographic space", text: "a\u{3000}b", accepted: false, onTheWire: false),
        RuleRow(note: "a zero-width space", text: "a\u{200B}b", accepted: false, onTheWire: false),
        RuleRow(note: "a soft hyphen", text: "a\u{AD}b", accepted: false, onTheWire: false),
        RuleRow(note: "a byte-order mark", text: "\u{FEFF}a", accepted: false, onTheWire: false),
        RuleRow(note: "a right-to-left mark", text: "a\u{200F}b", accepted: false, onTheWire: false),
        RuleRow(note: "a right-to-left override", text: "a\u{202E}b", accepted: false, onTheWire: false),
        RuleRow(note: "a line separator", text: "a\u{2028}b", accepted: false, onTheWire: false),
        RuleRow(note: "a curly quote", text: "it\u{2019}s", accepted: false, onTheWire: false),
        RuleRow(note: "a fullwidth letter", text: "\u{FF21}", accepted: false, onTheWire: false),
        RuleRow(note: "a fullwidth parenthesis", text: "a\u{FF08}b", accepted: false, onTheWire: false),
        RuleRow(note: "a non-ASCII digit", text: "\u{0661}", accepted: false, onTheWire: false),
        RuleRow(note: "a combining mark on a space", text: "a \u{301}b", accepted: false, onTheWire: false),
    ]

    @Test(arguments: ruleRows)
    func theRuleTable(_ row: RuleRow) {
        #expect(ApprovalProjectLabel.accepts(row.text) == row.accepted, "accepts")
        #expect(ApprovalProjectLabel.admitsOnTheWire(row.text) == row.onTheWire, "admitsOnTheWire")
    }

    /// The three entry points agree on each row with no separator: the text
    /// as a folder name has a label exactly when the rule takes it, and a
    /// frame may carry the text exactly when it is empty or is its own label.
    @Test(arguments: ruleRows.filter { !$0.text.utf8.contains(UInt8(ascii: "/")) })
    func theRuleAndTheFolderLabelAgree(_ row: RuleRow) {
        let label: String = ApprovalProjectLabel.label(forProjectRoot: row.text)
        let isOwnLabel: Bool = label == row.text
        #expect(label.isEmpty == !ApprovalProjectLabel.accepts(row.text))
        #expect(ApprovalProjectLabel.admitsOnTheWire(row.text) == (row.text.isEmpty || isOwnLabel))
        #expect(ApprovalProjectLabel.admitsOnTheWire(label), "a label the rule gives may go on the wire")
    }

    /// The rule's spaces only: the text with its spaces trimmed and each run
    /// collapsed, worked out apart from the rule (ASCII text only).
    static func spacesCollapsed(_ text: String) -> String {
        text.split(separator: " ").joined(separator: " ")
    }

    @Test func theLongestLabelIsPinned() {
        let limit: Int = ApprovalProjectLabel.maxByteCount
        let overByOne: Int = limit + 1
        #expect(limit == 64)
        #expect(Self.sixtyFour.utf8.count == limit && Self.sixtyFive.utf8.count == overByOne, "the edge rows sit on the edge")
        #expect(Self.sixtyFourWithOneSpace.utf8.count == limit && Self.sixtyFiveWithOneSpace.utf8.count == overByOne)
        // The padded rows are longer as they stand and sit on the edge once
        // normalized.
        let padded: [String] = [Self.paddedSixtyFour, Self.sixtyFourAfterARun, Self.paddedSixtyFive]
        let normalized: [Int] = padded.map { Self.spacesCollapsed($0).utf8.count }
        let expected: [Int] = [limit, limit, overByOne]
        #expect(padded.allSatisfy { $0.utf8.count > overByOne }, "vacuity: each is over the limit as it stands")
        #expect(normalized == expected)
        #expect(Self.spacesCollapsed(Self.sixtyFourAfterARun) == Self.sixtyFourWithOneSpace)
    }

    /// Every ASCII byte alone: exactly the letters and digits are taken (a
    /// punctuation mark or a space alone holds no letter or digit).
    @Test func exactlyTheLettersAndDigitsAreTakenAlone() {
        let lettersAndDigits: [UInt8] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".utf8)
        var taken: [UInt8] = []
        var admitted: [UInt8] = []
        for byte in UInt8(0)...UInt8(127) {
            let text: String = String(decoding: [byte], as: UTF8.self)
            if ApprovalProjectLabel.accepts(text) { taken.append(byte) }
            if ApprovalProjectLabel.admitsOnTheWire(text) { admitted.append(byte) }
        }
        #expect(taken.sorted() == lettersAndDigits.sorted())
        #expect(admitted == taken, "alone, a byte is admitted exactly when it is taken")
        #expect(taken.count == 62)
    }

    /// Every ASCII byte between two letters: exactly the 71 allowed ones are
    /// taken (letters, digits, the space and `. _ - ( ) & + ,`), and each is
    /// admitted as it stands (one space inside is already normalized).
    @Test func exactlyTheAllowedBytesAreTakenInsideAName() {
        let allowed: [UInt8] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 ._-()&+,".utf8)
        var taken: [UInt8] = []
        var admitted: [UInt8] = []
        for byte in UInt8(0)...UInt8(127) {
            let bytes: [UInt8] = [UInt8(ascii: "a"), byte, UInt8(ascii: "b")]
            let text: String = String(decoding: bytes, as: UTF8.self)
            if ApprovalProjectLabel.accepts(text) { taken.append(byte) }
            if ApprovalProjectLabel.admitsOnTheWire(text) { admitted.append(byte) }
        }
        #expect(taken.sorted() == allowed.sorted())
        #expect(admitted == taken)
        #expect(taken.count == 71)
    }

    /// Every scalar outside ASCII in the Basic Multilingual Plane, and a
    /// sample beyond it, between two letters: none is taken, none is
    /// admitted, and as a folder name none gives a label.
    @Test func nothingOutsideASCIIIsTaken() {
        var scalars: [Unicode.Scalar] = (0x80...0xFFFF).compactMap { Unicode.Scalar(UInt32($0)) }
        scalars.append(contentsOf: stride(from: 0x1_0000, through: 0x10_FFFF, by: 0x101).compactMap { Unicode.Scalar(UInt32($0)) })
        var passed: [UInt32] = []
        for scalar in scalars {
            let middle: String = String(Character(scalar))
            let text: String = "a\(middle)b"
            let taken: Bool = ApprovalProjectLabel.accepts(text) || ApprovalProjectLabel.admitsOnTheWire(text)
            if taken || !ApprovalProjectLabel.label(forProjectRoot: text).isEmpty { passed.append(scalar.value) }
        }
        #expect(passed.isEmpty, "taken: \(passed.prefix(8).map { String($0, radix: 16) })")
        #expect(scalars.count > 63_000, "vacuity: \(scalars.count) scalars")
    }

    // MARK: - The label of a project folder

    /// One project folder path and its label.
    struct RootRow: Sendable, CustomTestStringConvertible {
        let note: String
        let root: String
        let label: String
        var testDescription: String { note }
    }

    static let sixtyFourRoot: String = "/Users/me/\(sixtyFour)"
    static let sixtyFiveRoot: String = "/Users/me/\(sixtyFive)"
    static let paddedSixtyFourRoot: String = "/Users/me/\(paddedSixtyFour)"
    static let sixtyFourAfterARunRoot: String = "/Users/me/\(sixtyFourAfterARun)"
    static let paddedSixtyFiveRoot: String = "/Users/me/\(paddedSixtyFive)"

    static let rootRows: [RootRow] = [
        // The last component, normalized, when the rule takes it.
        RootRow(note: "a plain project", root: "/Users/me/Code/NapCat", label: "NapCat"),
        RootRow(note: "a dotted, dashed name", root: "/Users/me/Code/my-app_v2.1", label: "my-app_v2.1"),
        RootRow(note: "a hidden folder", root: "/Users/me/.dotfiles", label: ".dotfiles"),
        RootRow(note: "a trailing separator", root: "/Users/me/Code/NapCat/", label: "NapCat"),
        RootRow(note: "trailing separators", root: "/Users/me/Code/NapCat///", label: "NapCat"),
        RootRow(note: "doubled separators inside", root: "/Users//me//NapCat", label: "NapCat"),
        RootRow(note: "a relative name", root: "NapCat", label: "NapCat"),
        RootRow(note: "a folder at the root", root: "/tmp", label: "tmp"),
        RootRow(note: "only the last component counts", root: "/Users/my folder/NapCat", label: "NapCat"),
        RootRow(note: "a non-ASCII parent", root: "/Users/caf\u{E9}/NapCat", label: "NapCat"),
        RootRow(note: "a 64-byte name", root: sixtyFourRoot, label: sixtyFour),
        RootRow(note: "a space in the name", root: "/Users/me/my project", label: "my project"),
        RootRow(note: "spaces trimmed and collapsed", root: "/Users/me/  My   Big  Project ", label: "My Big Project"),
        RootRow(note: "a trailing space before a trailing separator", root: "/Users/me/NapCat /", label: "NapCat"),
        RootRow(note: "parentheses", root: "/Users/me/NapCat (old)", label: "NapCat (old)"),
        RootRow(note: "an ampersand", root: "/Users/me/R&D", label: "R&D"),
        RootRow(note: "plus signs", root: "/Users/me/c++", label: "c++"),
        RootRow(note: "a comma", root: "/Users/me/Smith, Jones", label: "Smith, Jones"),
        RootRow(note: "64 bytes once trimmed", root: paddedSixtyFourRoot, label: sixtyFour),
        RootRow(note: "64 bytes once a run is collapsed", root: sixtyFourAfterARunRoot, label: sixtyFourWithOneSpace),
        // Empty: no component, or one the rule refuses.
        RootRow(note: "the empty path", root: "", label: ""),
        RootRow(note: "the root", root: "/", label: ""),
        RootRow(note: "separators only", root: "///", label: ""),
        RootRow(note: "a dot component", root: "/Users/me/.", label: ""),
        RootRow(note: "a dot-dot component", root: "/Users/me/..", label: ""),
        RootRow(note: "parentheses only", root: "/Users/me/()", label: ""),
        RootRow(note: "a dash only", root: "/Users/me/-", label: ""),
        RootRow(note: "a space-only component", root: "/Users/me/ ", label: ""),
        RootRow(note: "a space-only component before a trailing separator", root: "/Users/me/ /", label: ""),
        RootRow(note: "a 65-byte name is never cut to 64", root: sixtyFiveRoot, label: ""),
        RootRow(note: "65 bytes once trimmed is never cut", root: paddedSixtyFiveRoot, label: ""),
        RootRow(note: "a refused name never falls back to its parent", root: "/Users/me/NapCat/caf\u{E9}", label: ""),
        RootRow(note: "a composed accent", root: "/Users/me/caf\u{E9}", label: ""),
        RootRow(note: "a decomposed accent", root: "/Users/me/cafe\u{301}", label: ""),
        RootRow(note: "a combining mark after a separator", root: "/Users/me/\u{301}NapCat", label: ""),
        RootRow(note: "an emoji", root: "/Users/me/cat\u{1F408}", label: ""),
        RootRow(note: "a right-to-left override", root: "/Users/me/a\u{202E}b", label: ""),
        RootRow(note: "a no-break space", root: "/Users/me/My\u{A0}Project", label: ""),
        RootRow(note: "a tab", root: "/Users/me/My\tProject", label: ""),
        RootRow(note: "a quote", root: "/Users/me/say \"hi\"", label: ""),
        RootRow(note: "a backslash is not a separator", root: "C:\\Users\\me\\NapCat", label: ""),
        RootRow(note: "a NUL byte", root: "/Users/me/Nap\u{0}Cat", label: ""),
        RootRow(note: "a newline", root: "/Users/me/Nap\nCat", label: ""),
    ]

    @Test(arguments: rootRows)
    func theRootTable(_ row: RootRow) {
        #expect(ApprovalProjectLabel.label(forProjectRoot: row.root) == row.label)
    }

    /// Whatever the path, the label is one a frame may carry (empty, or
    /// normalized and taken), and a non-empty label is the path's own last
    /// component, normalized, whole.
    @Test(arguments: rootRows)
    func aLabelIsEmptyOrAdmittedAndNeverCut(_ row: RootRow) {
        let label: String = ApprovalProjectLabel.label(forProjectRoot: row.root)
        #expect(ApprovalProjectLabel.admitsOnTheWire(label))
        #expect(label.isEmpty || ApprovalProjectLabel.accepts(label))
        if !label.isEmpty {
            let last: String = row.root.split(separator: "/").last.map { String($0) } ?? ""
            #expect(label == Self.spacesCollapsed(last), "the label is the path's last component, normalized, whole")
        }
    }

    @Test func theTablesAreNotVacuous() {
        let asItStands: Int = Self.ruleRows.filter { $0.accepted && $0.onTheWire }.count
        let onceNormalized: Int = Self.ruleRows.filter { $0.accepted && !$0.onTheWire }.count
        let emptyOnly: [RuleRow] = Self.ruleRows.filter { !$0.accepted && $0.onTheWire }
        let refused: Int = Self.ruleRows.filter { !$0.accepted && !$0.onTheWire }.count
        #expect(asItStands >= 15 && onceNormalized >= 5 && refused >= 50)
        #expect(emptyOnly.map(\.text) == [""], "only the empty text is admitted and not taken")
        let labelled: Int = Self.rootRows.filter { !$0.label.isEmpty }.count
        let blank: Int = Self.rootRows.filter { $0.label.isEmpty }.count
        #expect(labelled >= 15 && blank >= 15)
    }
}
