import SwiftUI

/// How the request screen draws a prompt's input: every character as it
/// came, with each whitespace character drawn as a mark, as an editor's
/// "show invisibles" does. A line the screen wraps then never hides whether
/// a space stood at the break, and a wrap the screen made never reads as a
/// line break the input holds: every line break in the input ends its line
/// with the return mark, so a line end without one is the screen's own wrap.
///
/// The marks are decoration. They are drawn in a color of their own (the
/// screen passes the secondary ink; the input is in the ink), they are
/// decided by what the input holds and never by how a glyph looks (a mark
/// glyph typed into the input is drawn as input), and the input itself is
/// never trimmed, collapsed or changed: `source(of:)` gives back every
/// Unicode scalar of it, in order, and a wrap adds no glyph to it (no
/// hyphen: `language`). VoiceOver reads the input itself, not the drawing.
/// Why these marks: `VisibleWhitespaceTests`.
enum VisibleWhitespace {
    /// A run of the drawing: what is shown, the input it stands for, and
    /// whether it is a mark (decoration) or the input drawn as it is.
    struct Segment: Equatable, Sendable {
        let shown: String
        let source: String
        let isMark: Bool

        /// A line break's mark: the line ends after it.
        var endsLine: Bool { isMark && shown.hasSuffix("\n") }
    }

    /// A space (U+0020): the open box, Unicode's own graphic for a space.
    static let spaceMark = "\u{2423}"
    /// A tab.
    static let tabMark = "\u{2192}"
    /// Any other horizontal whitespace (a no-break or an em space, …): not a
    /// plain space, so not drawn as one. A solid square: it must be seen at
    /// a glance, and a shade pattern thins the mark ink to almost nothing.
    static let otherSpaceMark = "\u{25A0}"
    /// A line break (LF, CR, CR LF, or a Unicode line or paragraph
    /// separator), drawn before the break itself.
    static let lineBreakMark = "\u{23CE}"
    /// Drawn after each horizontal mark, a zero-width break opportunity, so
    /// the drawing still wraps where the input's spaces would.
    static let wrapPoint = "\u{200B}"

    /// Every glyph a mark can draw (the wrap point and the break are not
    /// glyphs).
    static let markGlyphs = [spaceMark, tabMark, otherSpaceMark, lineBreakMark]

    /// The mark for one horizontal whitespace scalar; nil for anything else.
    static func mark(for scalar: Unicode.Scalar) -> String? {
        guard scalar.properties.isWhitespace else { return nil }
        switch scalar {
        case " ": return spaceMark
        case "\t": return tabMark
        default: return otherSpaceMark
        }
    }

    /// The drawing of `input`, run by run. Line breaks are whole characters
    /// (a CR LF is one), so each gets one mark; every other whitespace
    /// scalar gets its own.
    static func segments(_ input: String) -> [Segment] {
        var segments: [Segment] = []
        var pending = String.UnicodeScalarView()
        func flush() {
            guard !pending.isEmpty else { return }
            let text = String(pending)
            segments.append(Segment(shown: text, source: text, isMark: false))
            pending = String.UnicodeScalarView()
        }
        for character in input {
            if character.isNewline {
                flush()
                segments.append(Segment(shown: lineBreakMark + "\n", source: String(character), isMark: true))
                continue
            }
            for scalar in character.unicodeScalars {
                guard let mark = mark(for: scalar) else {
                    pending.append(scalar)
                    continue
                }
                flush()
                segments.append(Segment(shown: mark + wrapPoint, source: String(scalar), isMark: true))
            }
        }
        flush()
        return segments
    }

    /// The input a drawing stands for.
    static func source(of segments: [Segment]) -> String {
        segments.map(\.source).joined()
    }

    // MARK: Chunks

    /// A chunk ends at the next mark once it holds this many scalars, or
    /// wherever it reaches twice as many.
    static let chunkSize = 1024
    /// A chunk ends at a line break once it holds this many.
    static let chunkLineBreaks = 64

    /// The drawing in chunks, each drawn as its own text and stacked: one
    /// text holding a whole 32 KB input is taller, at the larger text
    /// sizes, than the system will draw (it comes out blank). A chunk's end
    /// is a line end; after a return mark it is the input's line break,
    /// anywhere else it is a wrap the screen made, like any other line end
    /// without the mark. A run of input longer than a chunk is split
    /// between characters, never inside one.
    static func chunks(_ input: String) -> [[Segment]] {
        var chunks: [[Segment]] = []
        var chunk: [Segment] = []
        var scalars = 0
        var breaks = 0
        for segment in segments(input) {
            for piece in pieces(of: segment) {
                chunk.append(piece)
                scalars += piece.shown.unicodeScalars.count
                if piece.endsLine { breaks += 1 }
                let full = scalars >= chunkSize || breaks >= chunkLineBreaks
                if scalars >= 2 * chunkSize || (full && piece.isMark) {
                    chunks.append(chunk)
                    chunk = []
                    scalars = 0
                    breaks = 0
                }
            }
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks
    }

    /// An input run longer than a chunk, cut between characters.
    private static func pieces(of segment: Segment) -> [Segment] {
        guard !segment.isMark, segment.source.unicodeScalars.count > chunkSize else { return [segment] }
        var pieces: [Segment] = []
        var piece = ""
        var scalars = 0
        for character in segment.source {
            piece.append(character)
            scalars += character.unicodeScalars.count
            if scalars >= chunkSize {
                pieces.append(Segment(shown: piece, source: piece, isMark: false))
                piece = ""
                scalars = 0
            }
        }
        if !piece.isEmpty { pieces.append(Segment(shown: piece, source: piece, isMark: false)) }
        return pieces
    }

    /// The drawing's language: none, ISO 639's "no linguistic content".
    /// The system hyphenates text in a text style (the input's body font)
    /// by its language and draws the hyphen in the text's own ink, so
    /// "content" broken as "con-" / "tent" shows a hyphen the input does not
    /// hold. No language has no hyphenation. Lines still wrap after a mark,
    /// or between two characters of a run too long for its line, and that
    /// wrap draws nothing. (`Text` ignores a paragraph style's hyphenation
    /// factor; the language is what it honors.)
    static let language = "zxx"

    /// One chunk as text, set in no language (`language`): the input's runs
    /// carry no color of their own (they take the view's ink), the marks
    /// carry `mark`. A chunk that ends on a line break draws its mark but
    /// not the break: the next chunk starts its own line.
    static func attributed(_ chunk: [Segment], mark: Color) -> AttributedString {
        var drawing = AttributedString()
        for (index, segment) in chunk.enumerated() {
            let shown = index == chunk.count - 1 && segment.endsLine ? String(segment.shown.dropLast()) : segment.shown
            var run = AttributedString(shown)
            if segment.isMark { run.swiftUI.foregroundColor = mark }
            drawing.append(run)
        }
        drawing.languageIdentifier = language
        return drawing
    }
}
