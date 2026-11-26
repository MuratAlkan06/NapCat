// NapCatWire — F4 remote approvals: the project label a forwarded prompt
// carries (the prompt record's `projectLabel` field). Design:
// design/remote-approvals.md.
//
// PURE — no imports, no I/O: the caller reads the project folder's path and
// hands it in. The label is that path's last component, normalized (spaces
// trimmed from both ends, each run of spaces inside made one space), when
// the normalized text is 1 to `maxByteCount` bytes of ASCII letters,
// digits, spaces and `. _ - ( ) & + ,`, holding at least one letter or
// digit. Anything else gives the empty label. A label is never truncated,
// so a folder name the rule refuses shows nothing.
//
// Why so narrow: the label is untrusted text, and the phone shows it on the
// request card. The alphabet leaves out quotes, the backslash and every
// invisible or direction character (nothing outside ASCII gets in), so a
// label cannot pose as another field or reorder what is shown around it;
// collapsing spaces keeps it from padding text out of view.

/// The project label rule, the one spelling of it for every app.
public enum ApprovalProjectLabel {
    /// The longest label, in bytes after normalizing (one byte per
    /// character: the rule is ASCII only).
    public static let maxByteCount: Int = 64

    /// The byte that separates a path's components.
    private static let separator: UInt8 = UInt8(ascii: "/")

    /// The one space byte the rule allows, and the only byte normalizing
    /// touches (a tab, a no-break space or any other blank is refused).
    private static let space: UInt8 = UInt8(ascii: " ")

    /// Whether the rule takes `text` once normalized: 1 to `maxByteCount`
    /// bytes, each an ASCII letter, digit, space or one of `. _ - ( ) & + ,`,
    /// with at least one letter or digit (so `.`, `..`, `()`, `-` and a
    /// space alone are refused, as is the empty text). It normalizes first,
    /// so it takes `" a  b "`, whose label is `"a b"`: it does not say the
    /// text is a label as it stands. To check a received frame's label, use
    /// `admitsOnTheWire`, never this.
    public static func accepts(_ text: String) -> Bool {
        isAccepted(normalized(Array(text.utf8)))
    }

    /// Whether a frame may carry `label` as its project label: the empty
    /// label (no label), or text already normalized that the rule takes —
    /// exactly what `label(forProjectRoot:)` can give. `"a  b"` and `" a"`
    /// are not admitted: a sender must normalize, and a receiver never
    /// repairs. Every later slice that checks a frame's label uses this,
    /// not `accepts`.
    public static func admitsOnTheWire(_ label: String) -> Bool {
        let bytes: [UInt8] = Array(label.utf8)
        return bytes.isEmpty || (normalized(bytes) == bytes && isAccepted(bytes))
    }

    /// The label for the project folder at `projectRoot`: its last path
    /// component, normalized, when the rule takes it, otherwise empty.
    /// Trailing separators are ignored (`a/b/` ends in `b`), so a root of
    /// only separators, like the empty path, has no label. Only the last
    /// component counts: a refused one never falls back to its parent.
    public static func label(forProjectRoot projectRoot: String) -> String {
        var bytes: [UInt8] = Array(projectRoot.utf8)
        while bytes.last == separator { bytes.removeLast() }
        let start: Int = bytes.lastIndex(of: separator).map { $0 + 1 } ?? 0
        let component: [UInt8] = normalized(Array(bytes[start...]))
        guard isAccepted(component) else { return "" }
        return String(decoding: component, as: UTF8.self)
    }

    /// `bytes` with the spaces at both ends dropped and each run of spaces
    /// inside made one space. Every other byte is kept as it is. (No byte of
    /// a multi-byte UTF-8 sequence is a space, so this never splits one.)
    private static func normalized(_ bytes: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var spaceOwed: Bool = false
        for byte in bytes {
            if byte == space {
                spaceOwed = !result.isEmpty
                continue
            }
            if spaceOwed { result.append(space) }
            spaceOwed = false
            result.append(byte)
        }
        return result
    }

    /// The rule on normalized bytes. Requiring a letter or digit also
    /// refuses the empty text.
    private static func isAccepted(_ bytes: [UInt8]) -> Bool {
        bytes.count <= maxByteCount && bytes.allSatisfy(isLabelByte) && bytes.contains(where: isLetterOrDigit)
    }

    private static func isLetterOrDigit(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"):
            return true
        default:
            return false
        }
    }

    private static func isLabelByte(_ byte: UInt8) -> Bool {
        if isLetterOrDigit(byte) { return true }
        switch byte {
        case UInt8(ascii: " "), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-"),
             UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "&"), UInt8(ascii: "+"), UInt8(ascii: ","):
            return true
        default:
            return false
        }
    }
}
