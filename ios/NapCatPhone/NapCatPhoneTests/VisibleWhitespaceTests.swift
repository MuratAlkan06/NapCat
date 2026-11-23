import CoreText
import Foundation
@testable import NapCatPhone
import SwiftUI
import Testing
import UIKit

/// The request screen's input drawing (F4 S3, design review): a wrapped
/// line must never hide whether a space stood at the break, and a wrap the
/// screen made must never read as a line break the input holds.
///
/// Why marks, and why these:
///
/// - Every whitespace character is drawn as a mark, as an editor's "show
///   invisibles" does, so a blank at a line end cannot exist: `…/build`
///   and `…/ build` differ by a visible mark wherever the line breaks.
///   Every line break in the input is drawn as the return mark before the
///   break, so a line that ends without one is the screen's own wrap. Both
///   hold at every Dynamic Type size: they are decided by the text, not by
///   the layout.
/// - The space mark is the open box U+2423, Unicode's own graphic for a
///   space, NOT the middle dot U+00B7 editors often use. The Mac's gate
///   refuses U+00B7 in paths because it passes for a space; drawing spaces
///   as U+00B7 would make a real U+00B7 in a text field pass for a space
///   here. The open box looks like nothing an input plausibly holds.
/// - The marks are decoration by style as well as by shape: drawn in the
///   secondary ink while the input is in the ink, and every one is a glyph
///   of the monospaced system font, so it takes one cell like the input
///   around it. A mark glyph typed INTO the input is drawn as input, in
///   the ink: what is marked is decided by the input's characters, never
///   by how a glyph looks.
/// - Any other space (a no-break space, an em space, …) is a solid square
///   U+25A0: an exotic space in an Edit or Write must be seen. The light
///   shade U+2591 it replaced is a sparse dot pattern that thinned the mark
///   ink to about 1.3:1 on a light card.
/// - The input itself is never changed: the drawing gives back every
///   Unicode scalar of it, in order (compared as UTF-8 bytes, since
///   `String ==` would call a decomposed "é" equal to a precomposed one).
///   VoiceOver reads the input itself, from the card's label.
@Suite struct VisibleWhitespaceTests {
    typealias Segment = VisibleWhitespace.Segment

    /// The review's ambiguous pairs: each pair drew pixel-identically.
    static let reviewPairs: [(String, String)] = [
        (#"{"command":"echo 01234567890 && rm -rf ./tmp/aaaaaaaaaaaaaa/build"}"#,
         #"{"command":"echo 01234567890 && rm -rf ./tmp/aaaaaaaaaaaaaa/ build"}"#),
        (#"{"command":"swift test -- --mode"}"#, #"{"command":"swift test -- -- mode"}"#),
    ]

    static let corpus: [String] = [
        "", " ", "  ", "\n", "\r\n", "\r", "\t",
        FixtureRequests.inputPreview,
        // Pretty-printed JSON: the only place a strict preview holds raw
        // line breaks and tabs.
        "{\n\t\"command\": \"ls\",\r\n  \"timeout\": 5\r}\n",
        "  leading and trailing  ",
        // A JSON escape stays two visible characters.
        #"{"content":"line 1\nline 2\ttabbed"}"#,
        // Other spaces and separators: no-break, en, ideographic, narrow
        // no-break, line and paragraph separators, next line.
        "a\u{00A0}b\u{2002}c\u{3000}d\u{202F}e\u{2028}f\u{2029}g\u{0085}h\u{000B}i\u{000C}j",
        // Mark glyphs (and the shade the other-space mark once was) and the
        // space look-alike typed into the input.
        "\u{2423}\u{2192}\u{25A0}\u{2591}\u{23CE}\u{00B7}\u{200B}",
        // A combining mark after a space, decomposed vs precomposed, emoji.
        "a \u{0301}b", "e\u{0301} é", "👩‍👩‍👧 🇹🇷 x",
    ] + reviewPairs.flatMap { [$0.0, $0.1] }

    /// Up to the wire's 32 KB: a long heredoc of a prompt.
    static let longInput: String = {
        var body = #"{"command": "cat <<EOF > notes.txt"#
        var line = 0
        while body.utf8.count < 32 * 1024 - 64 {
            body += #"\nline \#(line) of a long heredoc body that keeps going"#
            line += 1
        }
        return body + #"\nEOF"}"#
    }()

    /// 32 KB inputs at the extremes: no whitespace at all (one run longer
    /// than any chunk), and almost nothing but line breaks.
    static let longInputs: [String] = [
        longInput,
        #"{"content":""# + String(repeating: "a\u{0301}", count: 10 * 1024) + #""}"#,
        "{" + String(repeating: "\r\n", count: 16 * 1024 - 32) + #""command":"ls"}"#,
    ]

    static func shown(_ input: String) -> String {
        VisibleWhitespace.segments(input).map(\.shown).joined()
    }

    /// What the screen draws: each chunk's text, stacked; a chunk that ends
    /// on a return mark ends a line of the input, any other chunk end is
    /// the screen's own break. Read back as one string, with "\n" where a
    /// chunk ends on a line break.
    static func stacked(_ input: String, mark: Color = .gray) -> String {
        VisibleWhitespace.chunks(input).map { chunk in
            String(VisibleWhitespace.attributed(chunk, mark: mark).characters) + (chunk.last?.endsLine == true ? "\n" : "")
        }.joined()
    }

    // MARK: The input is never changed

    @Test(arguments: corpus + longInputs)
    func theDrawingGivesBackTheInputByteForByte(_ input: String) {
        let segments = VisibleWhitespace.segments(input)
        let back = VisibleWhitespace.source(of: segments)
        #expect(Array(back.utf8) == Array(input.utf8), "\(input.debugDescription.prefix(200)) came back changed")
        // Its input runs are drawn exactly as they are.
        for segment in segments where !segment.isMark {
            #expect(segment.shown.utf8.elementsEqual(segment.source.utf8))
            #expect(!segment.source.isEmpty)
        }
        // Chunked, it is still the whole input, in order...
        let chunks = VisibleWhitespace.chunks(input)
        #expect(Array(VisibleWhitespace.source(of: chunks.flatMap { $0 }).utf8) == Array(input.utf8))
        // ...and the stacked texts the screen draws are exactly these runs.
        #expect(Array(Self.stacked(input).unicodeScalars) == Array(Self.shown(input).unicodeScalars))
    }

    /// No chunk's text is taller than the system will draw: each holds at
    /// most three chunk sizes of scalars and the line-break cap, and none
    /// ends on a bare line break (which would draw an empty line the input
    /// does not hold). Every line break ends its line: inside a chunk as a
    /// break after its mark, at a chunk's end as the chunk's end.
    @Test(arguments: corpus + longInputs)
    func everyChunkStaysDrawable(_ input: String) {
        for chunk in VisibleWhitespace.chunks(input) {
            #expect(!chunk.isEmpty)
            #expect(chunk.map(\.shown.unicodeScalars.count).reduce(0, +) <= 3 * VisibleWhitespace.chunkSize)
            #expect(chunk.filter(\.endsLine).count <= VisibleWhitespace.chunkLineBreaks)
            let text = String(VisibleWhitespace.attributed(chunk, mark: .gray).characters)
            #expect(!text.hasSuffix("\n"), "a chunk ends on a bare line break")
        }
        if input.utf8.count > 16 * 1024 {
            #expect(VisibleWhitespace.chunks(input).count > 4, "a long input is drawn in several texts")
        }
    }

    // MARK: No blank and no unmarked break

    /// Nothing in the drawing renders as a blank or a break unless a mark
    /// is drawn there: the only whitespace left is the break right after a
    /// return mark.
    @Test(arguments: corpus)
    func noWhitespaceIsDrawnBare(_ input: String) {
        let shown = Self.shown(input).replacingOccurrences(of: VisibleWhitespace.lineBreakMark + "\n", with: "")
        let bare = shown.unicodeScalars.filter(\.properties.isWhitespace)
        #expect(bare.isEmpty, "\(input.debugDescription): bare \(bare.map { String(format: "U+%04X", $0.value) })")
    }

    /// Each line break of the input is one return mark and one break, so a
    /// line the screen ends without the mark is its own wrap.
    @Test(arguments: corpus)
    func everyLineBreakEndsWithItsMark(_ input: String) {
        let shown = Self.shown(input)
        // Counted in place: filtered into a new string, a lone CR and the
        // LF after it would merge into one CR LF.
        let breaks = input.reduce(0) { $0 + ($1.isNewline ? 1 : 0) }
        #expect(shown.components(separatedBy: "\n").count - 1 == breaks)
        #expect(shown.components(separatedBy: VisibleWhitespace.lineBreakMark + "\n").count - 1 == breaks)
    }

    /// The review's pairs now draw differently, by a space mark where the
    /// space was.
    @Test func theReviewPairsDrawDifferently() {
        for (without, with) in Self.reviewPairs {
            #expect(Self.shown(without) != Self.shown(with))
            #expect(Self.shown(with).components(separatedBy: VisibleWhitespace.spaceMark).count
                    == Self.shown(without).components(separatedBy: VisibleWhitespace.spaceMark).count + 1)
        }
        #expect(Self.shown(Self.reviewPairs[0].1).hasSuffix("/\u{2423}\u{200B}build\"}"))
        #expect(Self.shown(Self.reviewPairs[0].0).hasSuffix("/build\"}"))
    }

    // MARK: Each mark, and only for whitespace

    @Test func eachMarkStandsForItsWhitespace() {
        let wrap = VisibleWhitespace.wrapPoint
        #expect(VisibleWhitespace.segments("a b\tc\u{00A0}d\r\ne\nf\u{2028}g") == [
            Segment(shown: "a", source: "a", isMark: false),
            Segment(shown: "\u{2423}" + wrap, source: " ", isMark: true),
            Segment(shown: "b", source: "b", isMark: false),
            Segment(shown: "\u{2192}" + wrap, source: "\t", isMark: true),
            Segment(shown: "c", source: "c", isMark: false),
            Segment(shown: "\u{25A0}" + wrap, source: "\u{00A0}", isMark: true),
            Segment(shown: "d", source: "d", isMark: false),
            Segment(shown: "\u{23CE}\n", source: "\r\n", isMark: true),
            Segment(shown: "e", source: "e", isMark: false),
            Segment(shown: "\u{23CE}\n", source: "\n", isMark: true),
            Segment(shown: "f", source: "f", isMark: false),
            Segment(shown: "\u{23CE}\n", source: "\u{2028}", isMark: true),
            Segment(shown: "g", source: "g", isMark: false),
        ])
        // Two spaces are two marks, never one.
        #expect(VisibleWhitespace.segments("  ").filter(\.isMark).count == 2)
    }

    /// A mark glyph or the space look-alike typed into the input is input,
    /// not a mark.
    @Test func marksComeFromTheInputNeverFromHowItLooks() {
        let typed = VisibleWhitespace.markGlyphs.joined() + "\u{00B7}"
        #expect(VisibleWhitespace.segments(typed) == [Segment(shown: typed, source: typed, isMark: false)])
    }

    // MARK: The marks are decoration

    /// Marks carry the mark color and the input carries none (it takes the
    /// view's ink): colored runs are exactly the marks.
    @Test(arguments: corpus)
    func onlyTheMarksCarryTheMarkColor(_ input: String) {
        let mark = Color.orange
        for chunk in VisibleWhitespace.chunks(input) {
            let drawing = VisibleWhitespace.attributed(chunk, mark: mark)
            var marks = "", plain = ""
            for run in drawing.runs {
                let text = String(drawing[run.range].characters)
                if let color = run[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] {
                    #expect(color == mark)
                    marks += text
                } else {
                    plain += text
                }
            }
            let drawnMarks = chunk.filter(\.isMark).map(\.shown).joined()
            let expectedMarks = chunk.last?.endsLine == true ? String(drawnMarks.dropLast()) : drawnMarks
            #expect(Array(marks.unicodeScalars) == Array(expectedMarks.unicodeScalars), "\(input.debugDescription)")
            #expect(Array(plain.unicodeScalars) == Array(chunk.filter { !$0.isMark }.map(\.shown).joined().unicodeScalars),
                    "\(input.debugDescription)")
        }
    }

    /// Every mark glyph is in the monospaced system font the input is drawn
    /// in (no fallback font), so it takes one cell like the input around it.
    @Test(arguments: VisibleWhitespace.markGlyphs)
    func eachMarkIsAGlyphOfTheInputsFont(_ glyph: String) {
        let font = UIFont.monospacedSystemFont(ofSize: 17, weight: .regular) as CTFont
        let units = Array(glyph.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        #expect(CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count), "\(glyph) falls back to another font")
        #expect(glyph.unicodeScalars.allSatisfy { !$0.properties.isWhitespace })
    }

    /// How a glyph of the input's font (the monospaced system font at
    /// `size` pt) inks its own bounding box, drawn by Core Text at 3 px a
    /// point: the share of the box it covers, the box's height, and the
    /// font's x-height.
    static func ink(_ glyph: String, size: CGFloat = 17) -> (coverage: Double, height: CGFloat, xHeight: CGFloat) {
        let scale: CGFloat = 3
        let font = UIFont.monospacedSystemFont(ofSize: size * scale, weight: .regular) as CTFont
        let units = Array(glyph.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        guard units.count == 1, CTFontGetGlyphsForCharacters(font, units, &glyphs, 1) else { return (0, 0, 0) }
        let box = CTFontGetBoundingRectsForGlyphs(font, .horizontal, glyphs, nil, 1)
        let width = Int(ceil(box.maxX - min(box.minX, 0))) + 4
        let height = Int(ceil(box.maxY - min(box.minY, 0))) + 4
        guard box.width > 0, box.height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return (0, 0, 0) }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 1, alpha: 1)
        var origin = CGPoint(x: 2 - min(box.minX, 0), y: 2 - min(box.minY, 0))
        CTFontDrawGlyphs(font, glyphs, &origin, 1, context)
        let inked = (0..<width * height).reduce(0.0) { $0 + Double(data[$1]) / 255 }
        return (inked / Double(box.width * box.height), box.height / scale, CTFontGetXHeight(font) / scale)
    }

    /// The other-space mark carries a warning (an exotic space in an Edit or
    /// Write must be seen), so it is solid: it covers its box, it is at least
    /// as tall as the font's x-height, and, averaged over its box as the eye
    /// reads a small glyph, it keeps the mark ink's text contrast (4.5:1,
    /// AA) on the card in every palette, light and dark. Not vacuous: the
    /// light shade it replaced falls below even a graphic's 3:1.
    @Test(arguments: PaletteID.allCases, PaletteLint.schemes)
    func theOtherSpaceMarkIsSolidAndSeen(_ palette: PaletteID, _ scheme: ColorScheme) {
        let theme = ThemeID.fallback.theme(palette: palette)
        let card = PaletteLint.SRGB(theme.surface, scheme)
        let markInk = PaletteLint.SRGB(theme.inkSecondary, scheme)
        func seen(_ glyph: String) -> Double {
            PaletteLint.contrast(markInk.over(card, alpha: min(Self.ink(glyph).coverage, 1)), card)
        }
        let mark = Self.ink(VisibleWhitespace.otherSpaceMark)
        #expect(mark.coverage >= 0.9, "\(mark.coverage)")
        #expect(mark.height >= mark.xHeight, "\(mark.height) < \(mark.xHeight)")
        #expect(seen(VisibleWhitespace.otherSpaceMark) >= PaletteLint.textMinimum,
                "\(PaletteLint.ratio(seen(VisibleWhitespace.otherSpaceMark)))")
        #expect(Self.ink("\u{2591}").coverage < 0.9)
        if scheme == .light {
            #expect(seen("\u{2591}") < PaletteLint.borderMinimum, "\(PaletteLint.ratio(seen("\u{2591}")))")
        }
    }

    /// The space mark is not the middle dot: a dot would let a real U+00B7
    /// in the input pass for a space.
    @Test func theSpaceMarkIsNotASpaceLookAlike() {
        #expect(VisibleWhitespace.spaceMark == "\u{2423}")
        #expect(!VisibleWhitespace.markGlyphs.contains("\u{00B7}"))
        #expect(Set(VisibleWhitespace.markGlyphs).count == VisibleWhitespace.markGlyphs.count)
    }
}
