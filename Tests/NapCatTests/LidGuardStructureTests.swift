// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// Structural isolation for Track B slice B2 (mirrors
/// ClaudeDetectionStructureTests and the DebugPowerSimulator lint): network I/O
/// and the IOKit power registration each live in exactly ONE file; the whole
/// subsystem is absent from the debug-simulator object graph; the sender API
/// cannot carry free text; the ntfy topic (which IS the password) can never
/// reach a log line; and the feature adds no privileged surface.
///
/// Since B4 the subsystem also asserts what is GONE: no osascript, no
/// AppleEvents, no bundled AppleScript, no Automation (TCC) surface at all.
struct LidGuardStructureTests {
    // MARK: Helpers

    static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)      // Tests/NapCatTests/<this file>
            .deletingLastPathComponent()     // Tests/NapCatTests
            .deletingLastPathComponent()     // Tests
            .deletingLastPathComponent()     // repo root
    }

    static func sourcesDir() -> URL { repoRoot().appendingPathComponent("Sources/NapCat") }

    /// Strips `//` line comments so the scan matches executable code only —
    /// doc comments legitimately NAME these symbols to document the boundary.
    /// AMENDED (#155): a `//` opens a comment only in code (`lexemes`), so a
    /// URL in a string literal no longer cuts its line and hides what
    /// follows it. Block comments and string literals stay in.
    static func codeOnly(_ text: String) -> String {
        guard text.contains("//") else { return text }      // a comment opens only at a `//`
        let scalars = Array(text.unicodeScalars)
        let kinds = lexemes(scalars)
        var code = String.UnicodeScalarView()
        for index in scalars.indices where kinds[index] != .lineComment { code.append(scalars[index]) }
        return String(code)
    }

    /// Removes WHOLE-LINE `//` comments only (a line whose first non-blank
    /// characters open a `//` comment). Unlike `codeOnly`, it keeps trailing
    /// comments — they can only over-match — so the checks added after
    /// security review 2 (#146) scan this form. AMENDED (#155): read through
    /// `lexemes`, so a line of a multi-line string or a block comment that
    /// starts with `//` is not a comment and stays in (an interpolation on
    /// it is code), and a CR or CRLF line end ends a line.
    static func wholeLineCommentsRemoved(_ text: String) -> String {
        guard text.contains("//") else { return text }      // a comment opens only at a `//`
        let scalars = Array(text.unicodeScalars)
        let kinds = lexemes(scalars)
        var kept = String.UnicodeScalarView()
        var start = 0
        while start < scalars.count {
            var first = start
            while first < scalars.count, scalars[first] == " " || scalars[first] == "\t" { first += 1 }
            var end = first
            while end < scalars.count, !isLineEnd(scalars[end]) { end += 1 }
            if first == end || kinds[first] != .lineComment { kept.append(contentsOf: scalars[start..<end]) }
            if end < scalars.count { kept.append(scalars[end]) }
            start = end + 1
        }
        return String(kept)
    }

    /// The copy the constructor bans scan IN ADDITION to the raw text (#153,
    /// security delta B1/B2): every backtick removed, and each block comment
    /// replaced by one space, so `` extension `T` `` and `extension /* … */ T`
    /// both read `extension T`. Read through `lexemes`, so a `/*` inside a
    /// string literal cannot swallow the code after it.
    static func cleaned(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        let kinds = lexemes(scalars)
        var copy = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            if kinds[index] == .blockComment {
                while index < scalars.count, kinds[index] == .blockComment { index += 1 }
                copy.append(" ")
                continue
            }
            if scalars[index] != "`" { copy.append(scalars[index]) }
            index += 1
        }
        return String(copy)
    }

    /// What every constructor ban reads (#153): the text as given, the same
    /// text with its backticks removed and nothing else (no lexer involved,
    /// so nothing the lexer misreads can hide a backticked name), and
    /// `cleaned`. A ban must hold in all three — the cleaned copies are
    /// read IN ADDITION to the raw text, never instead of it. "In every scan
    /// copy" holds for what the copies show: the text given is most often
    /// `codeOnly`'s or `wholeLineCommentsRemoved`'s, and `cleaned` reads
    /// through `lexemes`, so a lock holds it for the lines the stripper
    /// reads as the compiler does. The raw-text locks keep out the lines
    /// known to be read apart (`noSourceHoldsASlashTheStripperCouldReadApart`,
    /// `noSourceDeclaresAnOperator`); a line outside the shapes they model
    /// is not covered.
    static func constructorScanCopies(_ text: String) -> [String] {
        guard mayClean(text) else { return [text] }          // its own cleaned copy
        return [text, text.replacingOccurrences(of: "`", with: ""), cleaned(text)]
    }

    /// `constructorScanCopies` of a whole source set: the set as given, then
    /// its two cleaned copies, file for file.
    static func constructorScanCopies(_ sources: [(name: String, text: String)]) -> [[(name: String, text: String)]] {
        guard sources.contains(where: { mayClean($0.text) }) else { return [sources] }
        return [sources, sources.map { ($0.name, $0.text.replacingOccurrences(of: "`", with: "")) },
                sources.map { ($0.name, cleaned($0.text)) }]
    }

    /// Whether cleaning can change `text` at all: with no backtick and no
    /// `/*` (a block comment opens only there), every copy is the text.
    static func mayClean(_ text: String) -> Bool { text.contains("`") || text.contains("/*") }

    // MARK: Lexing (issue #155: a `//` inside a string literal is not a comment)

    /// What a character of Swift source is, as far as the strippers care.
    enum Lexeme: Equatable { case code, lineComment, blockComment, literal }

    static func isLineEnd(_ scalar: Unicode.Scalar) -> Bool { scalar == "\n" || scalar == "\r" }

    /// One `Lexeme` per scalar of `scalars`: `//` and `/*` open a comment
    /// only in code, never inside a string or regex literal, and nothing in
    /// a comment opens a literal. Modelled: nested block comments; string
    /// literals, single- and multi-line, raw with any number of `#`, with
    /// escapes and `\( … )` interpolations (code again, which may hold
    /// literals of their own); `#/…/#` regex literals, and a bare `/…/` one
    /// where an expression can start (`bareRegexOpens`). A single-line
    /// literal ends with its line even when unterminated.
    ///
    /// A misreading is not harmless. Against the old line cut it is bounded
    /// in `codeOnly` and `wholeLineCommentsRemoved` only: each still keeps
    /// all the old forms kept (the Mac's `theStrippersNeverHideWhatTheLineCutShowed`).
    /// But the locks read these forms to see what the old cut hid, and
    /// `cleaned` has no old form at all. A literal opened or missed in the
    /// wrong place swaps string and code from there on (to the end of its
    /// line, or from a misread `"""` to the next one), so a token behind a
    /// URL, a `//`-led interpolation line or a block-comment-split name can
    /// vanish from every form a lock reads (security spot-check H9, a bare
    /// regex after `switch`). The opener shapes modelled here are pinned by
    /// the stripper tables and by canaries in the locks that read them; but
    /// this models a context-sensitive lexer and is not the compiler's own,
    /// so a line it does not model can still be read apart from the
    /// compiler. The Mac's raw-text locks, over the four targets and the
    /// phone app with no lexer, ban the shapes known to be read apart:
    /// `noSourceHoldsASlashTheStripperCouldReadApart` (its slash sites) and
    /// `noSourceDeclaresAnOperator` (custom operators). A shape outside
    /// both is not covered.
    static func lexemes(_ scalars: [Unicode.Scalar]) -> [Lexeme] {
        enum Mode {
            case code(parens: Int)                       // parens > 0: inside an interpolation
            case string(hashes: Int, multiline: Bool)
            case regex(hashes: Int)                      // hashes == 0: a bare `/…/`
            case blockComment(depth: Int)
        }
        let count = scalars.count
        func starts(_ prefix: String, at index: Int) -> Bool {
            var cursor = index
            for scalar in prefix.unicodeScalars {
                guard cursor < count, scalars[cursor] == scalar else { return false }
                cursor += 1
            }
            return true
        }
        func hashes(at index: Int) -> Int {
            var cursor = index
            while cursor < count, scalars[cursor] == "#" { cursor += 1 }
            return cursor - index
        }
        var kinds = [Lexeme](repeating: .code, count: count)
        func mark(_ range: Range<Int>, _ kind: Lexeme) {
            for index in range where index < count { kinds[index] = kind }
        }
        var stack: [Mode] = [.code(parens: 0)]
        /// A single-line literal ended by its line: unwind to the enclosing
        /// multi-line string, or to top-level code.
        func endLine() {
            while stack.count > 1 {
                if case .string(_, true) = stack[stack.count - 1] { return }
                stack.removeLast()
            }
        }
        var index = 0
        while index < count, let mode = stack.last {
            let scalar = scalars[index]
            let next: Unicode.Scalar? = index + 1 < count ? scalars[index + 1] : nil
            switch mode {
            case .code(let parens):
                if scalar == "/", next == "/" {
                    while index < count, !isLineEnd(scalars[index]) {
                        kinds[index] = .lineComment
                        index += 1
                    }
                    continue
                }
                if scalar == "/", next == "*" {
                    mark(index..<index + 2, .blockComment)
                    stack.append(.blockComment(depth: 1))
                    index += 2
                    continue
                }
                if scalar == "\"" || scalar == "#" {
                    let pounds = hashes(at: index)
                    if index + pounds < count, scalars[index + pounds] == "\"" {
                        let quotes = starts("\"\"\"", at: index + pounds) ? 3 : 1
                        mark(index..<index + pounds + quotes, .literal)
                        stack.append(.string(hashes: pounds, multiline: quotes == 3))
                        index += pounds + quotes
                        continue
                    }
                    if pounds > 0, index + pounds < count, scalars[index + pounds] == "/" {
                        mark(index..<index + pounds + 1, .literal)
                        stack.append(.regex(hashes: pounds))
                        index += pounds + 1
                        continue
                    }
                }
                if scalar == "/", bareRegexOpens(scalars, at: index) {
                    kinds[index] = .literal
                    stack.append(.regex(hashes: 0))
                    index += 1
                    continue
                }
                if parens > 0, scalar == "(" {
                    stack[stack.count - 1] = .code(parens: parens + 1)
                } else if parens > 0, scalar == ")" {
                    if parens == 1 {
                        kinds[index] = .literal                  // the interpolation's own `)`
                        stack.removeLast()
                        index += 1
                        continue
                    }
                    stack[stack.count - 1] = .code(parens: parens - 1)
                }
                index += 1
            case .blockComment(let depth):
                if scalar == "/", next == "*" {
                    mark(index..<index + 2, .blockComment)
                    stack[stack.count - 1] = .blockComment(depth: depth + 1)
                    index += 2
                } else if scalar == "*", next == "/" {
                    mark(index..<index + 2, .blockComment)
                    if depth == 1 { stack.removeLast() } else { stack[stack.count - 1] = .blockComment(depth: depth - 1) }
                    index += 2
                } else {
                    kinds[index] = .blockComment
                    index += 1
                }
            case .string(let pounds, let multiline):
                if !multiline, isLineEnd(scalar) {
                    endLine()                                    // re-read the line end as code
                    continue
                }
                kinds[index] = .literal
                if scalar == "\\", hashes(at: index + 1) >= pounds {
                    let escaped = index + 1 + pounds
                    mark(index..<escaped, .literal)
                    if escaped < count, scalars[escaped] == "(" {
                        kinds[escaped] = .literal
                        stack.append(.code(parens: 1))
                        index = escaped + 1
                    } else if escaped < count, multiline || !isLineEnd(scalars[escaped]) {
                        kinds[escaped] = .literal
                        index = escaped + 1
                    } else {
                        index = escaped
                    }
                    continue
                }
                let quotes = multiline ? 3 : 1
                if scalar == "\"", !multiline || starts("\"\"\"", at: index), hashes(at: index + quotes) >= pounds {
                    mark(index..<index + quotes + pounds, .literal)
                    stack.removeLast()
                    index += quotes + pounds
                    continue
                }
                index += 1
            case .regex(let pounds):
                if pounds == 0, isLineEnd(scalar) {
                    endLine()
                    continue
                }
                kinds[index] = .literal
                if scalar == "\\", let next, !isLineEnd(next) {
                    kinds[index + 1] = .literal
                    index += 2
                    continue
                }
                if scalar == "/", hashes(at: index + 1) >= pounds {
                    mark(index..<index + 1 + pounds, .literal)
                    stack.removeLast()
                    index += 1 + pounds
                    continue
                }
                index += 1
            }
        }
        return kinds
    }

    /// Whether the token ending at `index` is an operator, read by the
    /// compiler's own scalar classes (its lexer's operator-start and
    /// operator-continuation sets), not by Unicode's letters: Swift lets
    /// some scalars Unicode calls alphabetic into an operator. A scalar
    /// that continues an operator and an identifier alike takes its class
    /// from the first scalar before its run that does not.
    static func endsAnOperator(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        var head = index
        while head > 0, continuesEither(scalars[head]) { head -= 1 }
        return startsAnOperator(scalars[head]) && !continuesEither(scalars[head])
    }

    /// The scalars an operator can start with (the grammar's operator-head
    /// set, as the compiler's lexer reads it).
    static func startsAnOperator(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x21, 0x25, 0x26, 0x2A, 0x2B, 0x2D, 0x2E, 0x2F, 0x3C, 0x3D, 0x3E, 0x3F, 0x5E, 0x7C, 0x7E: return true
        case 0xA1...0xA7, 0xA9, 0xAB, 0xAC, 0xAE, 0xB0, 0xB1, 0xB6, 0xBB, 0xBF, 0xD7, 0xF7: return true
        case 0x2016...0x2017, 0x2020...0x2027, 0x2030...0x203E, 0x2041...0x2053, 0x2055...0x205E: return true
        case 0x2190...0x23FF, 0x2500...0x2775, 0x2794...0x2BFF, 0x2E00...0x2E7F, 0x3001...0x3003, 0x3008...0x3030: return true
        default: return false
        }
    }

    /// The scalars that continue an operator and an identifier alike: the
    /// combining marks and variation selectors of the grammar's
    /// operator-character set, and the run of the compiler's operator range
    /// that is also an identifier's.
    static func continuesEither(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x300...0x36F, 0x1DC0...0x1DFF, 0x20D0...0x20FF, 0x3021...0x302F: return true
        case 0xFE00...0xFE0F, 0xFE20...0xFE2F, 0xE0100...0xE01EF: return true
        default: return false
        }
    }

    /// Whether the `/` at `index` (not `//` or `/*`) opens a bare regex
    /// literal: an expression can start there (nothing before it on its
    /// line; a space or tab right before it, since with none after it Swift
    /// 6 never reads that `/` as a division (security spot-check H9); or an
    /// operator, an opening bracket, a separator or a keyword that precedes
    /// an expression, `switch/"/` included; an operator ending in a
    /// non-ASCII scalar by `endsAnOperator`), no space follows it, and an
    /// unescaped `/` closes it on the same line. A division (`a / b`, `n/2`,
    /// `f()/2`) is never one. Two more of the compiler's rules: a `/=` is a
    /// compound assignment only with a space after it (`n /= 2`; `/=a/`
    /// opens a regex), and a candidate holding a `)` that closes no `(` of
    /// its own (escapes skipped, a character class's brackets ignored) is no
    /// regex, so its `/` is an operator (`f(/)`, `reduce(3, /)`, `g(/2)`).
    static func bareRegexOpens(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        let next = index + 1
        guard next < scalars.count, !scalars[next].properties.isWhitespace else { return false }
        if scalars[next] == "=", next + 1 == scalars.count || scalars[next + 1].properties.isWhitespace { return false }
        var before = index - 1
        while before >= 0, scalars[before] == " " || scalars[before] == "\t" { before -= 1 }
        var opens = before < 0 || before < index - 1 || isLineEnd(scalars[before])
            || "([{,:;=!&|?^~<>+-*%".unicodeScalars.contains(scalars[before])
            || (!scalars[before].isASCII && endsAnOperator(scalars, at: before))
        if !opens, scalars[before].properties.isAlphabetic {
            var wordStart = before
            while wordStart > 0, scalars[wordStart - 1].properties.isAlphabetic { wordStart -= 1 }
            let word = String(String.UnicodeScalarView(scalars[wordStart...before]))
            let identifierChar = wordStart > 0 && (scalars[wordStart - 1] == "_" || scalars[wordStart - 1].properties.numericType != nil)
            opens = !identifierChar && ["return", "in", "throw", "try", "await", "case", "where", "if", "guard", "while",
                                        "else", "is", "as", "repeat", "some", "any", "switch"].contains(word)
        }
        guard opens else { return false }
        var cursor = next
        var groups = 0
        var classes = 0
        while cursor < scalars.count, !isLineEnd(scalars[cursor]) {
            let scalar = scalars[cursor]
            if scalar == "\\" {
                cursor += 2
                continue
            }
            if scalar == "/" { return true }
            if scalar == "[" {
                classes += 1
            } else if scalar == "]", classes > 0 {
                classes -= 1
            } else if scalar == "(", classes == 0 {
                groups += 1
            } else if scalar == ")", classes == 0 {
                if groups == 0 { return false }                  // closes no `(` of its own: an operator
                groups -= 1
            }
            cursor += 1
        }
        return false
    }

    // MARK: The strippers themselves (#155)

    /// What the strippers keep, case by case: a `//` in a string, raw string,
    /// interpolation, block comment or regex literal opens no comment; a real
    /// trailing or doc comment still goes; CR and CRLF end a line.
    static let codeOnlyCases: [(name: String, text: String, code: String)] = [
        ("a URL, then a token", "let u = \"https://x\"; let c = URLSession.shared // note",
         "let u = \"https://x\"; let c = URLSession.shared "),
        ("an escaped quote", "let a = \"\\\"//\"; tokenA // c", "let a = \"\\\"//\"; tokenA "),
        ("an escaped backslash ends the string", "let a = \"\\\\\"; tokenB // c", "let a = \"\\\\\"; tokenB "),
        ("a string inside an interpolation", "let a = \"\\(f(\"(\", \"//\"))\"; tokenC // c",
         "let a = \"\\(f(\"(\", \"//\"))\"; tokenC "),
        ("a raw string", "let r = #\"//\"#; tokenD // c", "let r = #\"//\"#; tokenD "),
        ("a quote inside a raw string", "let r = #\"a\"//\"#; tokenE // c", "let r = #\"a\"//\"#; tokenE "),
        ("a raw interpolation", "let r = #\"\\#(\"//\")\"#; tokenF // c", "let r = #\"\\#(\"//\")\"#; tokenF "),
        ("a multi-line string", "let m = \"\"\"\n// not a comment\nx // y\n\"\"\"\ntokenG // z",
         "let m = \"\"\"\n// not a comment\nx // y\n\"\"\"\ntokenG "),
        ("a block comment holding a URL", "/* see http://x */ tokenH // c", "/* see http://x */ tokenH "),
        ("a nested block comment", "/* a /* b */ // in */ tokenI // c", "/* a /* b */ // in */ tokenI "),
        ("a block-comment opener in a string", "let s = \"/*\"; tokenJ // c", "let s = \"/*\"; tokenJ "),
        ("an extended regex literal", "let r = #/https://x/#; tokenK // c", "let r = #/https://x/#; tokenK "),
        ("a bare regex holding a quote", "let r = /\"/; tokenL // c", "let r = /\"/; tokenL "),
        ("a bare regex with escaped slashes", "let r = /a\\/\\/b/; tokenM // c", "let r = /a\\/\\/b/; tokenM "),
        ("a division is no regex", "let q = a / b // half\nlet h = n/2 // c\nlet f = g()/2 // c",
         "let q = a / b \nlet h = n/2 \nlet f = g()/2 "),
        // Security spot-check H9: a bare regex after `switch` (unlisted until
        // then) read as a division, so its quote opened a phantom string.
        ("H9a: a bare regex after switch holding a quote", "switch /\"/ { default: let u = \"https://x\"; tokenT } // c",
         "switch /\"/ { default: let u = \"https://x\"; tokenT } "),
        ("a bare regex right after switch", "switch/\"/ { default: let u = \"https://x\"; tokenU } // c",
         "switch/\"/ { default: let u = \"https://x\"; tokenU } "),
        ("H9, multi-line: a bare regex holding \"\"\" before a multi-line string",
         "switch /\"\"\"/ { default: break }\nlet s = \"\"\"\n// \\(tokenV)\n\"\"\"\nswitch /\"\"\"/ { default: break } // c",
         "switch /\"\"\"/ { default: break }\nlet s = \"\"\"\n// \\(tokenV)\n\"\"\"\nswitch /\"\"\"/ { default: break } "),
        // A keyword that is also a name divides when a `/` touches it (the
        // Swift 6 compiler reads `copy/2` as the parameter `copy`, halved).
        ("a name spelled like a contextual keyword divides", "let h = copy/2; let s = \"a/b // x\"; tokenW // c",
         "let h = copy/2; let s = \"a/b // x\"; tokenW "),
        // A `/` the compiler reads as an operator: a candidate holding a `)`
        // that closes no `(` of its own is no regex, so a `/` in the string
        // after it closes nothing.
        ("an operator reference is no regex", "let a = [6].reduce(3, /); let b = \"a/\"; let c = \"//\"; tokenAA // c",
         "let a = [6].reduce(3, /); let b = \"a/\"; let c = \"//\"; tokenAA "),
        ("an unspaced operator reference", "let a = f(/); let b = \"a/\"; let c = \"//\"; tokenAB // c",
         "let a = f(/); let b = \"a/\"; let c = \"//\"; tokenAB "),
        ("a prefix operator's argument", "let a = g(/2); let b = \"a/\"; let c = \"//\"; tokenAC // c",
         "let a = g(/2); let b = \"a/\"; let c = \"//\"; tokenAC "),
        ("a group, an escaped and a bracketed parenthesis stay in a regex", "let r = /(a)\\)[)]\"/; let c = \"//\"; tokenAD // c",
         "let r = /(a)\\)[)]\"/; let c = \"//\"; tokenAD "),
        // A `/=` with no space after it opens a regex as any `/` does; with
        // one it is a compound assignment.
        ("a bare regex opening with =", "let r = /=a\"/; let c = \"//\"; tokenAE // c", "let r = /=a\"/; let c = \"//\"; tokenAE "),
        ("a compound assignment is no regex", "n /= 2; let b = \"a/\"; let c = \"//\"; tokenAF // c",
         "n /= 2; let b = \"a/\"; let c = \"//\"; tokenAF "),
        ("a division by a parenthesized divisor", "let h = (n)/(2); let q = n / (2); let b = \"a/\"; let c = \"//\"; tokenAG // c",
         "let h = (n)/(2); let q = n / (2); let b = \"a/\"; let c = \"//\"; tokenAG "),
        // An operator is read by the compiler's scalar classes, not by
        // Unicode's letters: after one ending in a scalar Unicode calls
        // alphabetic, or in a combining mark, a `/` opens a regex as after
        // any operator. After an identifier's non-ASCII letter or mark it
        // divides.
        ("a bare regex after an operator ending in an alphabetic scalar", "let r = \u{2E2F}/a\"/; let c = \"//\"; tokenAI // c",
         "let r = \u{2E2F}/a\"/; let c = \"//\"; tokenAI "),
        ("a bare regex after an operator ending in a combining mark", "let r = +\u{345}/a\"/; let c = \"//\"; tokenAJ // c",
         "let r = +\u{345}/a\"/; let c = \"//\"; tokenAJ "),
        ("a bare regex after a non-ASCII operator", "let r = \u{AC}/a\"/; let c = \"//\"; tokenAK // c",
         "let r = \u{AC}/a\"/; let c = \"//\"; tokenAK "),
        ("a non-ASCII identifier divides", "let h = caf\u{E9}/2 + caf\u{E9} / 2; let b = \"a/\"; let c = \"//\"; tokenAL // c",
         "let h = caf\u{E9}/2 + caf\u{E9} / 2; let b = \"a/\"; let c = \"//\"; tokenAL "),
        ("an identifier ending in a combining mark divides", "let h = cafe\u{301}/2 + e\u{345}/2; let b = \"a/\"; let c = \"//\"; tokenAM // c",
         "let h = cafe\u{301}/2 + e\u{345}/2; let b = \"a/\"; let c = \"//\"; tokenAM "),
        ("CRLF line ends", "// c\r\nlet x = tokenN // c\r\nlet y = 1", "\r\nlet x = tokenN \r\nlet y = 1"),
        ("a CR line end", "x // c\ry", "x \ry"),
        ("an unterminated string ends with its line", "let s = \"abc\nlet t = 1 // c", "let s = \"abc\nlet t = 1 "),
        ("a doc comment", "/// doc tokenO\nlet x = 1", "\nlet x = 1"),
    ]

    static let wholeLineCases: [(name: String, text: String, uncut: String)] = [
        ("a whole-line comment goes, a trailing one stays", "// c\n  /// d\nlet x = 1 // t", "\n\nlet x = 1 // t"),
        ("a multi-line string line opening with //", "let m = \"\"\"\n// \\(tokenP)\n\"\"\"", "let m = \"\"\"\n// \\(tokenP)\n\"\"\""),
        ("a block comment line opening with //", "/*\n// tokenQ\n*/", "/*\n// tokenQ\n*/"),
        ("CRLF line ends", "// c\r\nlet x = tokenR\r\n", "\r\nlet x = tokenR\r\n"),
        ("a URL", "let u = \"https://x\"; tokenS", "let u = \"https://x\"; tokenS"),
        // H9, multi-line (the R-H9-X1b plant): the line is a string's, its
        // interpolation code.
        ("H9: a multi-line string after a bare regex holding \"\"\"",
         "switch /\"\"\"/ { default: break }\nlet s = \"\"\"\n// \\(tokenX)\n\"\"\"\nswitch /\"\"\"/ { default: break }",
         "switch /\"\"\"/ { default: break }\nlet s = \"\"\"\n// \\(tokenX)\n\"\"\"\nswitch /\"\"\"/ { default: break }"),
        ("a multi-line string after an operator reference",
         "let a = [6].reduce(3, /); let b = \"/\"; let s = \"\"\"\n// \\(tokenAH)\n\"\"\"",
         "let a = [6].reduce(3, /); let b = \"/\"; let s = \"\"\"\n// \\(tokenAH)\n\"\"\""),
        ("a multi-line string after a bare regex behind an operator ending in an alphabetic scalar",
         "let a = \u{2E2F}/a\"/; let b = \"/\"; let s = \"\"\"\n// \\(tokenAN)\n\"\"\"",
         "let a = \u{2E2F}/a\"/; let b = \"/\"; let s = \"\"\"\n// \\(tokenAN)\n\"\"\""),
    ]

    /// The words a space before a `/` covers (H9): with a space or tab right
    /// before it and none after, a `/` opens a regex whatever word precedes
    /// it — `switch` and the contextual keywords that can start an
    /// expression alike.
    static let spacedRegexWords = ["switch", "yield", "then", "unsafe", "consume", "copy", "discard", "each"]

    @Test func theStrippersReadLiteralsAndComments() {
        for (name, text, code) in Self.codeOnlyCases {
            #expect(Self.codeOnly(text) == code, "codeOnly, \(name): \(Self.codeOnly(text).debugDescription)")
        }
        for (name, text, uncut) in Self.wholeLineCases {
            #expect(Self.wholeLineCommentsRemoved(text) == uncut,
                    "wholeLineCommentsRemoved, \(name): \(Self.wholeLineCommentsRemoved(text).debugDescription)")
        }
        for word in Self.spacedRegexWords {
            let text = "\(word) /\"/; let u = \"https://x\"; tokenY // c"
            #expect(Self.codeOnly(text) == "\(word) /\"/; let u = \"https://x\"; tokenY ",
                    "codeOnly, a bare regex after '\(word) ': \(Self.codeOnly(text).debugDescription)")
        }
    }

    /// The cleaned copy (#153): backticks out, each block comment (nested,
    /// multi-line) one space; a `/*` in a string, a line comment or after a
    /// bare regex holding a quote opens none.
    @Test func theCleanedCopyDropsBackticksAndBlockComments() {
        let cases: [(name: String, text: String, cleaned: String)] = [
            ("B1: a backticked name", "extension `ApprovalDecision` {}", "extension ApprovalDecision {}"),
            ("B2: a block comment between the words", "extension /* b2 */ ApprovalDecision {}", "extension   ApprovalDecision {}"),
            ("a nested block comment", "a /* x /* y */ z */ b", "a   b"),
            ("a multi-line block comment", "a /*\n x\n*/ b", "a   b"),
            ("a block-comment opener in a string", "let s = \"/*\"; T /* c */ x; let e = \"*/\"",
             "let s = \"/*\"; T   x; let e = \"*/\""),
            ("a block-comment opener in a line comment", "x // see /*\ny */ z", "x // see /*\ny */ z"),
            ("a bare regex holding a quote", "let r = /\"/; extension /* x */ T {}", "let r = /\"/; extension   T {}"),
            // Security spot-check H9b (the R-H9-B2 plant), then its multi-line form.
            ("H9b: a bare regex after switch before a commented extension",
             "switch /\"/ { default: break }; extension /* x */ T {}", "switch /\"/ { default: break }; extension   T {}"),
            ("H9: a bare regex holding \"\"\" before a commented extension",
             "switch /\"\"\"/ { default: break }\nlet s = \"\"\"\n\"\"\"\nextension /* x */ T {}",
             "switch /\"\"\"/ { default: break }\nlet s = \"\"\"\n\"\"\"\nextension   T {}"),
            ("an operator reference before a commented extension", "let a = f(/); let b = \"a/\"; extension /* x */ T {}",
             "let a = f(/); let b = \"a/\"; extension   T {}"),
        ]
        for (name, text, cleaned) in cases {
            #expect(Self.cleaned(text) == cleaned, "cleaned, \(name): \(Self.cleaned(text).debugDescription)")
            #expect(Self.constructorScanCopies(text).contains(cleaned), "\(name): the cleaned copy is scanned")
            #expect(Self.constructorScanCopies(text).first == text, "\(name): the raw text is scanned first, always")
        }
        #expect(Self.constructorScanCopies("let a = b // c") == ["let a = b // c"], "a text cleaning cannot change is its own copy")
    }

    /// The strippers before #155: each line cut at its first `//`, and each
    /// line whose first non-blank characters are `//` blanked.
    static func lineCut(_ line: Substring) -> Substring { line.range(of: "//").map { line[..<$0.lowerBound] } ?? line }
    static func lineBlanked(_ line: Substring) -> Bool { line.drop { $0 == " " || $0 == "\t" }.hasPrefix("//") }

    /// No lock got weaker (#155): over every Swift source a lock reads (the
    /// four Mac targets, the phone app and both test directories), the new
    /// strippers keep everything the old line cut kept — line for line, the
    /// old line is a prefix of the new one — and blank no line the old one
    /// kept. They differ only where a `//` sat inside a literal.
    @Test func theStrippersNeverHideWhatTheLineCutShowed() throws {
        let root = Self.repoRoot()
        let directories = ApprovalChannelStructureTests.directories
            + ["Tests/NapCatTests", "ios/NapCatPhone/NapCatPhone", "ios/NapCatPhone/NapCatPhoneTests"]
        var files = 0
        var widened = 0
        for directory in directories {
            let base = root.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                let old = text.split(separator: "\n", omittingEmptySubsequences: false)
                let code = Self.codeOnly(text).split(separator: "\n", omittingEmptySubsequences: false)
                let uncut = Self.wholeLineCommentsRemoved(text).split(separator: "\n", omittingEmptySubsequences: false)
                files += 1
                guard code.count == old.count, uncut.count == old.count else {
                    Issue.record("\(url.lastPathComponent): the strippers changed the line count")
                    continue
                }
                for (number, line) in old.enumerated() {
                    #expect(code[number].hasPrefix(Self.lineCut(line)),
                            "\(url.lastPathComponent):\(number + 1): codeOnly hides what the line cut kept")
                    #expect(Self.lineBlanked(line) || uncut[number] == line,
                            "\(url.lastPathComponent):\(number + 1): wholeLineCommentsRemoved blanks a line the old form kept")
                    if code[number] != Self.lineCut(line) { widened += 1 }
                }
            }
        }
        #expect(files > 150, "vacuity: only \(files) files read")
        #expect(widened > 0, "vacuity: a URL line, at least, must now be read whole")
    }

    /// The phone's structure tests carry their own copy of the lexer (the two
    /// test targets share no code): the copies stay byte-identical, so the
    /// strippers read Swift the same way on both devices.
    @Test func thePhonesLexerIsTheMacsTwin() throws {
        func lexer(_ path: String) throws -> String? {
            let text = try String(contentsOf: Self.repoRoot().appendingPathComponent(path), encoding: .utf8)
            guard let start = text.range(of: "    /// What a character of Swift source is"),
                  let tail = text.range(of: "static func bareRegexOpens(", range: start.upperBound..<text.endIndex),
                  let end = text.range(of: "\n        return false\n    }\n", range: tail.upperBound..<text.endIndex) else { return nil }
            return String(text[start.lowerBound..<end.upperBound])
        }
        let mac = try #require(try lexer("Tests/NapCatTests/LidGuardStructureTests.swift"))
        let phone = try #require(try lexer("ios/NapCatPhone/NapCatPhoneTests/CloudKitStructureTests.swift"))
        #expect(mac.contains("static func lexemes(") && mac.count > 4000, "vacuity: the whole lexer is compared")
        #expect(mac == phone, "the phone's lexer drifted from the Mac's — keep the twins alike")
        // … and the strippers and the cleaned copy built on it (#153).
        func member(_ head: String, in path: String) throws -> String? {
            let text = try String(contentsOf: Self.repoRoot().appendingPathComponent(path), encoding: .utf8)
            guard let start = text.range(of: head), let end = text.range(of: "\n    }\n", range: start.upperBound..<text.endIndex)
            else { return nil }
            return String(text[start.lowerBound..<end.upperBound])
        }
        for head in ["    static func codeOnly(_ text: String) -> String {", "    static func wholeLineCommentsRemoved(_ text: String) -> String {",
                     "    static func cleaned(_ text: String) -> String {", "    static func constructorScanCopies(_ text: String) -> [String] {"] {
            let macMember = try member(head, in: "Tests/NapCatTests/LidGuardStructureTests.swift")
            let phoneMember = try member(head, in: "ios/NapCatPhone/NapCatPhoneTests/CloudKitStructureTests.swift")
            #expect(macMember != nil && macMember == phoneMember, "'\(head)' drifted between the Mac and the phone")
        }
        let mayClean = "    static func mayClean(_ text: String) -> Bool { text.contains(\"`\") || text.contains(\"/*\") }\n"
        for path in ["Tests/NapCatTests/LidGuardStructureTests.swift", "ios/NapCatPhone/NapCatPhoneTests/CloudKitStructureTests.swift"] {
            let text = try String(contentsOf: Self.repoRoot().appendingPathComponent(path), encoding: .utf8)
            #expect(text.contains(mayClean), "mayClean drifted in \(path)")
        }
    }

    // MARK: The raw-text precondition (no lexer)

    /// What the raw-text precondition reads: every Swift file under the four
    /// Mac targets and the phone app.
    static let rawScanDirectories: [String] = ApprovalChannelStructureTests.directories + ["ios/NapCatPhone/NapCatPhone"]

    /// The words that, touching a `/`, can start an expression: a superset
    /// of `bareRegexOpens`'s list and of `spacedRegexWords`.
    static let regexLeadWords: Set<String> = [
        "return", "in", "throw", "try", "await", "case", "where", "if", "guard", "while", "else", "is", "as", "repeat", "some",
        "any", "switch", "yield", "then", "unsafe", "consume", "copy", "discard", "each", "do", "catch", "for", "let", "var",
        "default", "defer", "inout", "borrowing", "consuming", "throws", "rethrows", "async", "borrow",
    ]

    /// Whether `scalar` can end an operand before a `/`, for the raw-text
    /// rule: an ASCII letter, digit or underscore, and nothing else. Swift
    /// lets some scalars Unicode calls alphabetic into an operator, so any
    /// other scalar counts as one an expression may follow. Conservative by
    /// design: a non-ASCII identifier touching a `/` counts too.
    static func isOperandScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (scalar == "_" || scalar.properties.isAlphabetic || scalar.properties.numericType != nil)
    }

    /// Whether the `/` at `index` of `line` (one line's scalars) may open a
    /// bare regex literal, to the compiler or to `lexemes`, whose reading
    /// moves a string or comment boundary — decided from the raw text alone.
    /// A `/` counts unless a space, a tab, a `/` or a `*` follows it, or what
    /// touches it ends an operand (an ASCII word, `isOperandScalar`, other
    /// than a `regexLeadWords` word; a closing bracket, a quote, a backtick,
    /// a `#`) or it is the second `/` of a `//`. It is a site when the next
    /// `/` on its line closes a span holding a quote, a `#`, a backslash or a
    /// parenthesis, or is followed by `/` or `*`: read as a regex, that span
    /// is a literal, read as code it is not, and either reading can then open
    /// a string or a comment the other does not.
    static func regexShapeSite(_ line: [Unicode.Scalar], at index: Int) -> Bool {
        guard line[index] == "/", index + 1 < line.count, !" \t/*".unicodeScalars.contains(line[index + 1]) else { return false }
        if index > 0 {
            let before: Unicode.Scalar = line[index - 1]
            if isOperandScalar(before) {
                var start = index - 1
                while start > 0, line[start - 1].isASCII, line[start - 1].properties.isAlphabetic { start -= 1 }
                let word = String(String.UnicodeScalarView(line[start..<index]))
                guard regexLeadWords.contains(word), start == 0 || !isOperandScalar(line[start - 1]) else { return false }
            } else if ")]}\"`#".unicodeScalars.contains(before) || (before == "/" && (index < 2 || line[index - 2] != "*")) {
                return false
            }
        }
        guard let close = line[(index + 1)...].firstIndex(of: "/") else { return false }
        let significant: [Unicode.Scalar] = ["\"", "#", "\\", "(", ")"]
        if line[(index + 1)..<close].contains(where: { significant.contains($0) }) { return true }
        return close + 1 < line.count && (line[close + 1] == "/" || line[close + 1] == "*")
    }

    /// Each line of `text` holding a `regexShapeSite`, trimmed.
    static func regexShapeLines(in text: String) -> [String] {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
        return lines.filter { line in
            let scalars: [Unicode.Scalar] = Array(line.unicodeScalars)
            return scalars.indices.contains { regexShapeSite(scalars, at: $0) }
        }.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// `regexShapeLines` of each RAW source, as failures.
    static func regexShapeFailures(_ sources: [(name: String, text: String)]) -> [String] {
        sources.flatMap { source in
            regexShapeLines(in: source.text).map {
                "\(source.name): '\($0)' — a `/` the stripper can read apart from the compiler; spell the line otherwise"
            }
        }
    }

    /// Every Swift file under `rawScanDirectories`, RAW, by its repository path.
    static func rawScanSources() throws -> [(name: String, text: String)] {
        var sources: [(name: String, text: String)] = []
        for directory in rawScanDirectories {
            let base = repoRoot().appendingPathComponent(directory).resolvingSymlinksInPath()
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let components: [String] = url.resolvingSymlinksInPath().pathComponents
                let name: String = components.starts(with: base.pathComponents)
                    ? ([directory] + components.dropFirst(base.pathComponents.count)).joined(separator: "/") : url.path
                sources.append((name, try String(contentsOf: url, encoding: .utf8)))
            }
        }
        return sources.sorted { $0.name < $1.name }
    }

    /// A precondition the strippers' readings rest on, read from the RAW
    /// text with no lexer: the four Mac targets and the phone app hold no
    /// `regexShapeSite` (none today). `lexemes` mimics a context-sensitive
    /// lexer, and a line it reads apart from the compiler can hide a token
    /// from every form a lock reads. This bans the slash shapes known to be
    /// read apart, whatever the stripper does with them; a shape it does
    /// not model is not covered (`noSourceDeclaresAnOperator` bans custom
    /// operators beside it). The rule reads comments and string literals
    /// too: it over-matches by design (a `/=` or a division followed on its
    /// line by a quoted `/` is a site, as is a `/` touching a non-ASCII
    /// identifier before such a span; split such a line).
    @Test func noSourceHoldsASlashTheStripperCouldReadApart() throws {
        let sources: [(name: String, text: String)] = try Self.rawScanSources()
        #expect(Self.regexShapeFailures(sources).isEmpty, "\(Self.regexShapeFailures(sources))")
        #expect(sources.count > 120, "vacuity: only \(sources.count) files read")
        for directory in Self.rawScanDirectories {
            #expect(sources.contains { $0.name.hasPrefix(directory + "/") }, "vacuity: \(directory) is read")
        }
        // The plants below, each flagged on exactly its planted lines.
        let plants: [(name: String, text: String, lines: Int)] = [
            ("lookups behind an operator slash", Self.lookupsBehindAnOperator, 4),
            ("lookups in an interpolation line", Self.lookupsInAnInterpolationLine, 1),
            ("a factory's class shadowed behind an operator slash", Self.shadowBehindAnOperator, 3),
            ("lookups behind a regex opening with =", Self.lookupsBehindAnEqualsRegex, 4),
            ("the record path's member", Self.recordPathMember, 1),
            ("lookups behind a custom operator ending in an alphabetic scalar", Self.lookupsBehindACustomOperator(Self.alphabeticOperator), 4),
            ("lookups behind a custom operator ending in a combining mark", Self.lookupsBehindACustomOperator(Self.markedOperator), 4),
            ("lookups behind a custom operator declared behind one", Self.lookupsBehindAHiddenCustomOperator, 5),
            ("the record path's member behind a custom operator", Self.recordPathMemberBehindACustomOperator, 1),
        ]
        for (name, text, lines) in plants {
            let flagged: [String] = Self.regexShapeLines(in: text)
            #expect(flagged.count == lines, "canary '\(name)': \(flagged.count) lines flagged, want \(lines)")
            #expect(flagged.allSatisfy { $0.contains("reduce(3, /)") || $0.contains("/=a\"/") || $0.contains("/a\"/;") },
                    "canary '\(name)': \(flagged)")
        }
        // More lines the ban holds out, whatever the stripper makes of them.
        let shapes: [String] = [
            "let r = /= a\"/; let v = \"//\"; _ = zzHidden()",
            "let q = 8 /- \"a/\"; let v = \"//\"; _ = zzHidden()",
            "let r = /* c *//a\"/; let v = \"//\"; _ = zzHidden()",
            "let r =\u{A0}/a\"/; let v = \"//\"; _ = zzHidden()",
            "let q = zzF(/a,\" /\"); let v = \"//\"; _ = zzHidden()",
            "let q = zzId(/a/* \" */); let v = \"//\"; _ = zzHidden()",
            "let q = zzOp(/); let u = \"/\"; let v = \"//\"; _ = zzHidden()",
            "let q = zzId(/2); let u = \"/\"; let v = \"//\"; _ = zzHidden()",
            "switch/a\\/b/ { default: break }",
            "let r = \u{2E2F}/a\"/; let v = \"//\"; _ = zzHidden()",
            "let r = +\u{345}/a\"/; let v = \"//\"; _ = zzHidden()",
            "let r = \u{AC}/a\"/; let v = \"//\"; _ = zzHidden()",
            "let r = \u{2E2F}return/a\"/; let v = \"//\"; _ = zzHidden()",
            // By design: only an ASCII word ends an operand here.
            "let h = caf\u{E9}/2; let v = \"a/\"; _ = zzHidden()",
        ]
        for line in shapes {
            #expect(Self.regexShapeLines(in: line).count == 1, "canary '\(line)' was NOT caught")
        }
        // … in any of the five directories.
        let seam: String = "Sources/NapCatSeam/SeamSocket.swift"
        let settings: String = "ios/NapCatPhone/NapCatPhone/Settings/SettingsScreen.swift"
        for path in [seam, settings] {
            #expect(sources.contains { $0.name == path }, "vacuity: \(path) is read")
            let planted = sources.map { $0.name == path ? ($0.name, $0.text + Self.lookupsBehindAnOperator) : $0 }
            #expect(Self.regexShapeFailures(planted).count == 4, "canary 'lookups behind an operator slash, in \(path)' was NOT caught")
            let custom = sources.map { $0.name == path ? ($0.name, $0.text + Self.lookupsBehindAHiddenCustomOperator) : $0 }
            #expect(Self.regexShapeFailures(custom).count == 5,
                    "canary 'lookups behind a custom operator declared behind one, in \(path)' was NOT caught")
        }
        // Over-match controls: divisions, a compound assignment, paths and
        // URLs in strings and comments, and today's shapes beside them.
        let near: [String] = [
            "let q = a / b; let h = n/2; let f = g()/2; let p = (a)/(b); let s = \"a/b\"",
            "n /= 2",
            "let path = \"/usr/bin:/bin:/usr/sbin:/sbin\"",
            "let u = \"https://\\(host):\\(port)/x\" // see a/b, (c)/(d)",
            "/// never touches ~/.claude/settings.json (`GET /repos/…/releases/latest`), art/idle/ (see a/b)",
            "let p = \"a/b\" + \"/c\"; let w = [8].map { $0 / 2 }; let r = #/a\"/#",
            "// /usr/local/napcat/smc does not exist until setup; POST <server>/<topic>",
            "let s = \"a/b\"; let h = caf\u{E9} / 2 + caf\u{E9}/2 + \u{3C0}/2",
            "let q = a + b - c * d % e; let t = !f && g || h ?? i; let w = x == y ? -z : ~z",
        ]
        for line in near {
            #expect(Self.regexShapeLines(in: line).isEmpty, "over-match: '\(line)' was flagged")
        }
    }

    /// The standard library's operators: a type may implement one
    /// (`static func < (…)`), and no source declares another.
    static let standardOperators: Set<String> = [
        "==", "!=", "<", "<=", ">", ">=", "~=", "===", "!==", "+", "-", "*", "/", "%", "+=", "-=", "*=", "/=", "%=",
        "&", "|", "^", "~", "!", "<<", ">>", "&=", "|=", "^=", "<<=", ">>=", "&&", "||", "??", "...", "..<",
        "&+", "&-", "&*", "&<<", "&>>", "&+=", "&-=", "&*=", "&<<=", "&>>=",
    ]

    /// Each line of `text` that declares an operator or implements one the
    /// standard library does not declare, trimmed — from the RAW text, with
    /// no lexer. Every operator declaration spells the word `operator`
    /// (only its fixity, whitespace and comments may precede it), so the
    /// word is banned outright, comments and string literals included; an
    /// implementation is a `func` named by anything but an ASCII identifier
    /// or a `standardOperators` spelling.
    static func operatorDeclarationLines(in text: String) -> [String] {
        let whole: NSRange = NSRange(text.startIndex..., in: text)
        guard let word = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9_])operator(?![A-Za-z0-9_])"),
              let named = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9_])func\\s*([^\\sA-Za-z_`(][^\\s(]*)")
        else { return ["<bad pattern>"] }
        var sites: [Int] = word.matches(in: text, range: whole).map { $0.range.location }
        for match in named.matches(in: text, range: whole) {
            guard let name = Range(match.range(at: 1), in: text), !standardOperators.contains(String(text[name])) else { continue }
            sites.append(match.range.location)
        }
        let lines: NSString = text as NSString
        var seen: Set<Int> = []
        var found: [String] = []
        for site in sites.sorted() {
            let line: NSRange = lines.lineRange(for: NSRange(location: site, length: 0))
            if seen.insert(line.location).inserted {
                found.append(lines.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return found
    }

    /// No source declares a custom operator, read from the RAW text with no
    /// lexer: the four Mac targets and the phone app hold no
    /// `operatorDeclarationLines` (none today). A custom operator can end in
    /// a scalar Unicode calls alphabetic, and the strippers have read a
    /// bare regex behind one as a division; with no custom operator, every
    /// operator a source can use is one the standard library or an SDK
    /// declares. Over-matches by design: the word `operator` is banned in
    /// comments and strings too.
    @Test func noSourceDeclaresAnOperator() throws {
        let sources: [(name: String, text: String)] = try Self.rawScanSources()
        let failures: [String] = sources.flatMap { source in
            Self.operatorDeclarationLines(in: source.text).map { "\(source.name): '\($0)' — a custom operator; the sources declare none" }
        }
        #expect(failures.isEmpty, "\(failures)")
        #expect(sources.count > 120, "vacuity: only \(sources.count) files read")
        let implementations: Int = sources.filter { $0.text.contains("static func < (") }.count
        #expect(implementations > 0, "vacuity: a standard operator's implementation is read and allowed")
        // The plants, each flagged on exactly its operator's two lines.
        let recordTail: String = Self.recordPathTail + Self.customOperatorTail
        let plants: [(name: String, text: String)] = [
            ("lookups behind a custom operator ending in an alphabetic scalar", Self.lookupsBehindACustomOperator(Self.alphabeticOperator)),
            ("lookups behind a custom operator ending in a combining mark", Self.lookupsBehindACustomOperator(Self.markedOperator)),
            ("lookups behind a custom operator declared behind one", Self.lookupsBehindAHiddenCustomOperator),
            ("the record path's custom operator", recordTail),
        ]
        for (name, text) in plants {
            let flagged: [String] = Self.operatorDeclarationLines(in: text)
            #expect(flagged.count == 2, "canary '\(name)': \(flagged)")
        }
        // More spellings the ban holds out.
        let shapes: [String] = [
            "infix operator <~> : AdditionPrecedence",
            "postfix operator \u{2E2F}",
            "prefix /* c */ operator \u{2E2F}",
            "prefix // c\noperator \u{2E2F}",
            "let s = \"prefix operator \u{2E2F}\"",
            "static func <~> (l: S, r: S) -> S { l }",
            "prefix func /* c */ \u{2E2F} (x: Int) -> Int { x }",
            "prefix func\n\u{2E2F} (x: Int) -> Int { x }",
            "struct S { static prefix func +\u{345}(x: S) -> S { x } }",
        ]
        for text in shapes {
            #expect(Self.operatorDeclarationLines(in: text).count == 1, "canary '\(text)' was NOT caught")
        }
        // … in any of the five directories.
        for path in ["Sources/NapCatSeam/SeamSocket.swift", "ios/NapCatPhone/NapCatPhone/Settings/SettingsScreen.swift"] {
            #expect(sources.contains { $0.name == path }, "vacuity: \(path) is read")
            let planted: [(name: String, text: String)] = sources.map { $0.name == path ? ($0.name, $0.text + Self.customOperatorTail) : $0 }
            #expect(planted.flatMap { Self.operatorDeclarationLines(in: $0.text) }.count == 2, "canary 'a custom operator, in \(path)' was NOT caught")
        }
        // Over-match controls: the standard operators, implemented and used,
        // and words that hold or sit beside the banned ones.
        let near: [String] = [
            "static func < (lhs: V, rhs: V) -> Bool { lhs.rawValue < rhs.rawValue }",
            "nonisolated static func == (lhs: V, rhs: V) -> Bool { true }\nstatic func +=(l: inout V, r: V) {}",
            "func reduce(_ x: Int) -> Int { x }; func `default`() {}; func _f() {}",
            "let prefix = \"napcat-\"; let p = s.hasPrefix(prefix); let o = operatorName + cooperator",
            "/// the func below takes a prefix, postfix or infix",
            "let q = a + b - c * d / e % f; let t = !g && h || i ?? j; n /= 2",
            "let h = caf\u{E9} / 2 + \u{3C0}/2",
        ]
        for text in near {
            #expect(Self.operatorDeclarationLines(in: text).isEmpty, "over-match: '\(text)' was flagged")
        }
    }

    /// The zero-width scalars, by name (each is a format scalar too).
    static let zeroWidthScalars: Set<Unicode.Scalar> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}", "\u{180E}"]

    /// Why the raw scalar `scalar`, after `previous`, is one a lock could
    /// read apart from the compiler, or nil: a control character other than
    /// tab, LF and CR; a format or zero-width scalar, or any other Unicode
    /// calls default-ignorable (drawn as nothing); a scalar joined to the
    /// whitespace before it (a combining mark, or any scalar that makes one
    /// character with it), which a character-wise reading drops with the
    /// whitespace while the compiler reads it as part of the next name; or a
    /// scalar that compares equal to another (the Kelvin sign and the letter
    /// K), which a text comparison matches while the compiler reads two
    /// names.
    static func hiddenScalarReason(_ scalar: Unicode.Scalar, after previous: Unicode.Scalar?) -> String? {
        if scalar.isASCII {
            let allowed: Bool = (scalar.value >= 0x20 && scalar.value != 0x7F) || scalar == "\t" || scalar == "\n" || scalar == "\r"
            return allowed ? nil : "a control character"
        }
        let properties: Unicode.Scalar.Properties = scalar.properties
        let category: Unicode.GeneralCategory = properties.generalCategory
        if category == .control { return "a control character" }
        if category == .format || zeroWidthScalars.contains(scalar) || properties.isDefaultIgnorableCodePoint {
            return "an invisible scalar"
        }
        if let previous, previous.properties.isWhitespace {
            let marks: [Unicode.GeneralCategory] = [.nonspacingMark, .spacingMark, .enclosingMark]
            if marks.contains(category) || String(String.UnicodeScalarView([previous, scalar])).count == 1 {
                return "joined to the whitespace before it"
            }
        }
        let composed: String = String(Character(scalar)).precomposedStringWithCanonicalMapping
        return composed.unicodeScalars.elementsEqual([scalar]) ? nil : "equal, as text, to another scalar"
    }

    /// Each line of `text` holding a `hiddenScalarReason`, as its number and
    /// the scalars' code points (the scalars themselves would not show).
    static func hiddenScalarLines(in text: String) -> [String] {
        var found: [String] = []
        var codes: [String] = []
        var line: Int = 1
        var previous: Unicode.Scalar? = nil
        for scalar in text.unicodeScalars {
            if let reason = Self.hiddenScalarReason(scalar, after: previous) {
                let hex: String = String(scalar.value, radix: 16, uppercase: true)
                codes.append("U+" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex + " (" + reason + ")")
            }
            if scalar == "\n" {
                if !codes.isEmpty { found.append("line \(line): " + codes.joined(separator: ", ")) }
                codes = []
                line += 1
            }
            previous = scalar
        }
        if !codes.isEmpty { found.append("line \(line): " + codes.joined(separator: ", ")) }
        return found
    }

    /// `hiddenScalarLines` of each RAW source, as failures.
    static func hiddenScalarFailures(_ sources: [(name: String, text: String)]) -> [String] {
        sources.flatMap { source in
            hiddenScalarLines(in: source.text).map {
                "\(source.name): \($0) — a scalar a lock could read apart from the compiler; write it as a \\u{…} escape"
            }
        }
    }

    /// No source holds a scalar a lock could read apart from the compiler,
    /// read from the RAW text with no lexer: the four Mac targets and the
    /// phone app hold no `hiddenScalarLines` (none today). The locks read
    /// text: a split by characters drops a scalar joined to a space, and a
    /// text comparison matches a scalar to its canonical equal, while the
    /// compiler reads each as part of a name; an invisible or control
    /// scalar hides a token from a reader and can stand as a whole name. The
    /// rule reads comments and string literals too (a string writes such a
    /// scalar as an escape).
    @Test func noSourceHoldsAScalarALockCouldReadApart() throws {
        let sources: [(name: String, text: String)] = try Self.rawScanSources()
        let failures: [String] = Self.hiddenScalarFailures(sources)
        #expect(failures.isEmpty, "\(failures)")
        #expect(sources.count > 120, "vacuity: only \(sources.count) files read")
        for directory in Self.rawScanDirectories {
            #expect(sources.contains { $0.name.hasPrefix(directory + "/") }, "vacuity: \(directory) is read")
        }
        var nonASCII: Int = 0
        for source in sources {
            for scalar in source.text.unicodeScalars where !scalar.isASCII { nonASCII += 1 }
        }
        #expect(nonASCII > 1_000, "vacuity: the sources' own non-ASCII text (dashes, arrows, signs) is read and allowed")
        // Each shape flagged on its one line.
        let shapes: [String] = [
            "return \u{200D}ApprovalSigning.decisionMessage(wireVersion: 1)",
            "        \u{200D}",
            "let a = 1 \u{200B}+ 2",
            "let \u{2060}zz = 1",
            "\u{FEFF}import Foundation",
            "let s = \"a\u{202E}b\"",
            "let a\u{AD}b = 1",
            "let \u{3164} = 1",
            "let a = 1 \u{34F}+ 2",
            "let s = \"a\u{FE0E}\"",
            "let a = 1\u{B}+ 2",
            "let a = 1\u{C}+ 2",
            "let a = 1\u{0}+ 2",
            "let s = \"\u{1B}[0m\"",
            "let a = 1\u{7F}",
            "let s = \"\u{85}\"",
            "return \u{301}zz",
            "\t\u{20DD}zz",
            "return \u{FF9E}zz",
            "let n = \u{A0}\u{301}2",
            "let \u{212A}ey = 1",
            "let q = a \u{37E} b",
        ]
        for line in shapes {
            #expect(Self.hiddenScalarLines(in: line).count == 1, "canary '\(line.unicodeScalars.map { $0.value })' was NOT caught")
        }
        // … on its own line, in any of the five directories.
        for directory in Self.rawScanDirectories {
            let path: String = try #require(sources.first { $0.name.hasPrefix(directory + "/") }).name
            let planted: [(name: String, text: String)] = sources.map { $0.name == path ? ($0.name, $0.text + "        \u{200D}\n") : $0 }
            let flagged: [String] = Self.hiddenScalarFailures(planted)
            #expect(flagged.count == 1 && flagged.allSatisfy { $0.hasPrefix(path + ": line ") },
                    "canary 'an invisible statement, in \(path)' was NOT caught: \(flagged)")
        }
        // Over-match controls: accented text precomposed and after a letter,
        // dashes, an ellipsis, arrows and signs, an emoji, full-width forms,
        // tabs, CRLF line ends, and the escapes that spell the banned scalars.
        let near: [String] = [
            "let s = \"caf\u{E9} na\u{EF}ve r\u{E9}sum\u{E9} \u{E4}\" // a \u{2014} b \u{2013} c\u{2026}",
            "let d = \"cafe\u{301} and e\u{301}\u{316}\"",
            "/// \u{2192} \u{21D2} \u{2264} \u{2265} \u{2260} \u{D7} \u{A7} \u{2318}, \u{201C}q\u{201D} \u{203A}",
            "let e = \"\u{1F642} \u{FF26}\u{FF28} \u{663}\"",
            "\tlet a = 1\r\n\tlet b = 2\r\n",
            "let z = \"\\u{200D}\\u{FEFF}\\u{0}\" // written as escapes",
        ]
        for text in near {
            #expect(Self.hiddenScalarLines(in: text).isEmpty, "over-match: \(Self.hiddenScalarLines(in: text))")
        }
    }

    // MARK: What the compiler builds, the locks read (#184)

    /// Lines the compiler builds and the stripper read apart from it before
    /// the fix above, each with code behind it that every lock reading its
    /// file missed. As the locks read the disk, each plant goes into the RAW
    /// sources and through the stripper.
    static func operatorPrefix(_ n: Int) -> String { "let zzA\(n) = [6].reduce(3, /); let zzB\(n) = \"a/\"; let zzC\(n) = \"//\"; " }
    static func equalsPrefix(_ n: Int) -> String { "let zzR\(n) = /=a\"/; let zzC\(n) = \"//\"; " }

    static let lookupsBehindAnOperator: String = [
        "\nenum ZZDyn {\n    static func zz() {\n",
        "        \(operatorPrefix(1))guard let cls = Bundle(identifier: \"com.apple.\" + \"CloudKit\")?.classNamed(\"CK\" + \"Container\") as AnyObject? else { return }\n",
        "        \(operatorPrefix(2))let c = cls.perform(NSSelectorFromString(\"containerWith\" + \"Identifier:\"), with: \"iCloud.zz\")?.takeUnretainedValue() as? NSObject\n",
        "        \(operatorPrefix(3))let db = c?.value(forKey: \"private\" + \"CloudDatabase\") as? NSObject\n",
        "        let done: @convention(block) (AnyObject?, AnyObject?) -> Void = { _, _ in }\n",
        "        \(operatorPrefix(4))_ = db?.perform(NSSelectorFromString(\"fetchAllRecordZones\" + \"WithCompletionHandler:\"), with: done as AnyObject)\n",
        "    }\n}\n",
    ].joined()

    static let lookupsInAnInterpolationLine: String = [
        "\nfunc zzDo(_ f: () -> Void) -> String { f(); return \"\" }\n",
        "enum ZZDyn {\n    static func zz() -> String {\n",
        "        let zzA = [6].reduce(3, /); let zzB = \"/\"; let zzS = \"\"\"\n",
        "        // \\(zzDo { guard let cls = Bundle(identifier: \"com.apple.\" + \"CloudKit\")?.classNamed(\"CK\" + \"Container\") as AnyObject? else { return }; ",
        "let c = cls.perform(NSSelectorFromString(\"containerWith\" + \"Identifier:\"), with: \"iCloud.zz\")?.takeUnretainedValue() as? NSObject; ",
        "let db = c?.value(forKey: \"private\" + \"CloudDatabase\") as? NSObject; ",
        "let done: @convention(block) (AnyObject?, AnyObject?) -> Void = { _, _ in }; ",
        "_ = db?.perform(NSSelectorFromString(\"fetchAllRecordZones\" + \"WithCompletionHandler:\"), with: done as AnyObject) })\n",
        "        \"\"\" // \"\"\"\n",
        "        return zzS + \"\\(zzA)\" + zzB\n    }\n}\n",
    ].joined()

    static let shadowBehindAnOperator: String = [
        "\nextension CloudKitMessageSender {\n",
        "    static let zzA = [6].reduce(3, /); static let zzB = \"a/\"; static let zzC = \"//\"; static func LiveCloudKitAlertStore<C: NSObject, R>(container: C) -> R? {\n",
        "        \(operatorPrefix(1))let db = container.value(forKey: \"private\" + \"CloudDatabase\") as? NSObject\n",
        "        let done: @convention(block) (AnyObject?, AnyObject?) -> Void = { _, _ in }\n",
        "        \(operatorPrefix(2))_ = db?.perform(NSSelectorFromString(\"fetchAllRecordZones\" + \"WithCompletionHandler:\"), with: done as AnyObject)\n",
        "        return nil\n    }\n}\n",
    ].joined()

    static let lookupsBehindAnEqualsRegex: String = [
        "\nenum ZZDyn {\n    static func zz() {\n",
        "        \(equalsPrefix(1))guard let cls = Bundle(identifier: \"com.apple.\" + \"CloudKit\")?.classNamed(\"CK\" + \"Container\") as AnyObject? else { return }\n",
        "        \(equalsPrefix(2))let c = cls.perform(NSSelectorFromString(\"containerWith\" + \"Identifier:\"), with: \"iCloud.zz\")?.takeUnretainedValue() as? NSObject\n",
        "        \(equalsPrefix(3))let db = c?.value(forKey: \"private\" + \"CloudDatabase\") as? NSObject\n",
        "        let done: @convention(block) (AnyObject?, AnyObject?) -> Void = { _, _ in }\n",
        "        \(equalsPrefix(4))_ = db?.perform(NSSelectorFromString(\"fetchAllRecordZones\" + \"WithCompletionHandler:\"), with: done as AnyObject)\n",
        "    }\n}\n",
    ].joined()

    /// The record path's plant: a member of the pairing source, before its
    /// database accessor, and two top-level helpers after the file.
    static let recordPathAnchor: String = "    private func resolvedDatabase() -> (any PairingRecordDatabase)? {"
    static let recordPathMember: String = [
        "    func zzNote() -> String {\n",
        "        let zzA = [6].reduce(3, /); let zzB = \"/\"; let zzS = \"\"\"\n",
        "        // \\(zzDo { let op = Self.makeFetchOperation(recordName: String(repeating: \"a\", count: 64)) { _ in }; ",
        "resolvedDatabase()?.submit(op); ZZHeld.database = op.database })\n",
        "        \"\"\" // \"\"\"\n",
        "        return zzS + \"\\(zzA)\" + zzB\n    }\n\n",
    ].joined()
    static let recordPathTail: String =
        "\nenum ZZHeld { nonisolated(unsafe) static var database: AnyObject? }\nfunc zzDo(_ f: () -> Void) -> String { f(); return \"\" }\n"

    /// The same code behind a bare regex opened after a custom prefix
    /// operator that ends in a scalar Unicode calls alphabetic, or in a
    /// combining mark: the stripper read that `/` as a division, and the
    /// raw-text slash lock took the scalar for an operand's.
    static let alphabeticOperator: String = "\u{2E2F}"
    static let markedOperator: String = "+\u{345}"
    static func customOperatorPrefix(_ n: Int, _ op: String) -> String { "let zzR\(n) = \(op)/a\"/; let zzC\(n) = \"//\"; " }
    static func lookupsBehind(_ op: String, declared declaration: String) -> String {
        [
            declaration,
            "\nenum ZZDyn {\n    static func zz() {\n",
            "        \(customOperatorPrefix(1, op))guard let cls = Bundle(identifier: \"com.apple.\" + \"CloudKit\")?.classNamed(\"CK\" + \"Container\") as AnyObject? else { return }\n",
            "        \(customOperatorPrefix(2, op))let c = cls.perform(NSSelectorFromString(\"containerWith\" + \"Identifier:\"), with: \"iCloud.zz\")?.takeUnretainedValue() as? NSObject\n",
            "        \(customOperatorPrefix(3, op))let db = c?.value(forKey: \"private\" + \"CloudDatabase\") as? NSObject\n",
            "        let done: @convention(block) (AnyObject?, AnyObject?) -> Void = { _, _ in }\n",
            "        \(customOperatorPrefix(4, op))_ = db?.perform(NSSelectorFromString(\"fetchAllRecordZones\" + \"WithCompletionHandler:\"), with: done as AnyObject)\n",
            "    }\n}\n",
        ].joined()
    }
    static func lookupsBehindACustomOperator(_ op: String) -> String {
        lookupsBehind(op, declared: "\nprefix operator \(op)\nprefix func \(op) <T>(x: T) -> T { x }")
    }
    /// … with the operator's declaration itself behind such a regex.
    static let lookupsBehindAHiddenCustomOperator: String = lookupsBehind(alphabeticOperator, declared:
        "\n\(customOperatorPrefix(0, alphabeticOperator))prefix operator \(alphabeticOperator)\nprefix func \(alphabeticOperator) <T>(x: T) -> Int { 0 }")
    static let recordPathMemberBehindACustomOperator: String =
        recordPathMember.replacingOccurrences(of: "let zzA = [6].reduce(3, /); ", with: "let zzA = \(alphabeticOperator)/a\"/; ")
    static let customOperatorTail: String = "prefix operator \(alphabeticOperator)\nprefix func \(alphabeticOperator) <T>(x: T) -> Int { 0 }\n"

    /// Each plant above, as the disk would hold it, is caught by the locks
    /// that catch the same code written plainly: the lookup and key-value
    /// coding bans, the live classes' word pins, the record path's seam-flow
    /// and iCloud locks. And look-alikes — a division, a compound
    /// assignment, slashes in strings and in comments — stay plain code, so
    /// a banned word in a trailing comment beside them stays out.
    @Test func theLocksReadWhatTheCompilerBuilds() throws {
        let raw: ApprovalChannelStructureTests.Sources = try ApprovalChannelStructureTests.sources { $0 }
        let model: String = "MenuStateModel.swift"
        let record: String = ApprovalRecordPathStructureTests.recordPathFile
        func read(_ sources: ApprovalChannelStructureTests.Sources, _ strip: (String) -> String) -> ApprovalChannelStructureTests.Sources {
            sources.map { ($0.name, strip($0.text)) }
        }
        func appended(_ text: String) -> ApprovalChannelStructureTests.Sources {
            ApprovalChannelStructureTests.mutate(raw, model) { $0 + text }
        }
        let lookups: [(String, ApprovalChannelStructureTests.Sources)] = [
            ("lookups behind an operator slash", appended(Self.lookupsBehindAnOperator)),
            ("lookups in an interpolation line of a string opened behind one", appended(Self.lookupsInAnInterpolationLine)),
            ("lookups behind a regex opening with =", appended(Self.lookupsBehindAnEqualsRegex)),
            ("a factory's class shadowed behind an operator slash", appended(Self.shadowBehindAnOperator)),
            ("lookups behind a custom operator ending in an alphabetic scalar", appended(Self.lookupsBehindACustomOperator(Self.alphabeticOperator))),
            ("lookups behind a custom operator ending in a combining mark", appended(Self.lookupsBehindACustomOperator(Self.markedOperator))),
            ("lookups behind a custom operator declared behind one", appended(Self.lookupsBehindAHiddenCustomOperator)),
        ]
        for (name, planted) in lookups {
            #expect(planted.map { $0.text } != raw.map { $0.text }, "canary '\(name)' did not apply")
            let code: ApprovalChannelStructureTests.Sources = read(planted, Self.codeOnly)
            #expect(!PairingStructureTests.objcLookupFailures(code).isEmpty, "canary '\(name)' was NOT caught by the lookup ban")
            #expect(!PhoneTransportStructureTests.appKeyValueCodingFailures(code).isEmpty,
                    "canary '\(name)' was NOT caught by the key-value coding ban")
        }
        let shadow: ApprovalChannelStructureTests.Sources = read(appended(Self.shadowBehindAnOperator), Self.codeOnly)
        #expect(!PhoneTransportStructureTests.liveClassWordFailures(shadow).isEmpty,
                "canary 'a factory's class shadowed behind an operator slash' was NOT caught by the live classes' word pin")
        #expect(ApprovalChannelStructureTests.text(record, in: raw).components(separatedBy: Self.recordPathAnchor).count == 2,
                "vacuity: the record path's plant has its one anchor")
        let recordPlanted: ApprovalChannelStructureTests.Sources = ApprovalChannelStructureTests.mutate(raw, record) {
            $0.replacingOccurrences(of: Self.recordPathAnchor, with: Self.recordPathMember + Self.recordPathAnchor) + Self.recordPathTail
        }
        let uncut: ApprovalChannelStructureTests.Sources = read(recordPlanted, Self.wholeLineCommentsRemoved)
        #expect(!ApprovalRecordPathStructureTests.seamFlowFailures(uncut).isEmpty,
                "canary 'the record path's fetch kept from an interpolation line' was NOT caught by the seam-flow lock")
        #expect(!ApprovalRecordPathStructureTests.iCloudFailures(uncut).isEmpty,
                "canary 'the record path's fetch kept from an interpolation line' was NOT caught by the iCloud lock")
        #expect(Self.recordPathMemberBehindACustomOperator != Self.recordPathMember, "vacuity: the custom operator's member differs")
        let customMember: String = Self.recordPathMemberBehindACustomOperator + Self.recordPathAnchor
        let customTail: String = Self.recordPathTail + Self.customOperatorTail
        let customPlanted: ApprovalChannelStructureTests.Sources = ApprovalChannelStructureTests.mutate(raw, record) {
            $0.replacingOccurrences(of: Self.recordPathAnchor, with: customMember) + customTail
        }
        let customUncut: ApprovalChannelStructureTests.Sources = read(customPlanted, Self.wholeLineCommentsRemoved)
        #expect(!ApprovalRecordPathStructureTests.seamFlowFailures(customUncut).isEmpty,
                "canary 'the record path's fetch behind a custom operator' was NOT caught by the seam-flow lock")
        #expect(!ApprovalRecordPathStructureTests.iCloudFailures(customUncut).isEmpty,
                "canary 'the record path's fetch behind a custom operator' was NOT caught by the iCloud lock")
        // Over-match controls: look-alikes, then a banned word in a trailing
        // comment that must stay stripped.
        let lookAlikes: String = [
            "\nfunc zzLookAlikes(_ n: Int) -> Int {\n",
            "    var m = n; m /= 2; let zzP = \"a/b\" // never NSSelectorFromString(s), never value(forKey:)\n",
            "    let zzQ = (m)/(2) + m / (2); let zzU = \"https://x/\\(zzP)\" // never classNamed(_:)\n",
            "    let caf\u{E9} = m; let zzE = caf\u{E9}/2 + caf\u{E9} / 2; let zzG = \"a/\" // never NSSelectorFromString(s)\n",
            "    let zzF = (zzE > 1 ? -zzE : +zzE) * 3/1 + (zzG.isEmpty ? 0 : 1); let zzH = \"/\" // never value(forKey:)\n",
            "    return zzQ + zzU.count + zzF + zzH.count // see a/b, (c)/(d), ~/.claude/x\n}\n",
        ].joined()
        let plain: ApprovalChannelStructureTests.Sources = read(appended(lookAlikes), Self.codeOnly)
        #expect(PairingStructureTests.objcLookupFailures(plain).isEmpty, "over-match: \(PairingStructureTests.objcLookupFailures(plain))")
        #expect(PhoneTransportStructureTests.appKeyValueCodingFailures(plain).isEmpty,
                "over-match: \(PhoneTransportStructureTests.appKeyValueCodingFailures(plain))")
    }

    static func swiftSources(_ strip: (String) -> String = codeOnly) throws -> [(name: String, text: String)] {
        let dir = sourcesDir()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        return try names.map { ($0, strip(try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8))) }
    }

    /// The files that make up the B2 subsystem. F3 stage 1 added the
    /// CloudKit sender and the composite in front of both senders: they are
    /// delivery files like the ntfy one, so the same no-spawn / no-privilege /
    /// no-error-description / log rules apply to them. Issue #103 added the
    /// topic's keychain store and its generator: they hold the secret, so
    /// they obey them too.
    static let b2Files = [
        "LidGuardPolicy.swift",
        "LidGuardController.swift",
        "MessageSender.swift",
        "NtfyMessageSender.swift",
        "SystemSleepSource.swift",
        "CloudKitMessageSender.swift",
        "CompositeMessageSender.swift",
        "KeychainTopicStore.swift",
        "NtfyTopicGenerator.swift",
    ]

    /// Files scanned by the no-topic-in-logs lint: the B2 subsystem PLUS the
    /// five menu files, which see the topic (the model mirrors it so the editor
    /// can be prefilled, and the editor renders it). They contain zero `logger.`
    /// calls today; including them turns that fact into a lock, so the first log
    /// line added there has to obey the same rules (security review 2026-09-09).
    ///
    /// Deliberately NOT folded into `b2Files`: the privileged-surface lint would
    /// then trip over MenuContentView's legitimate "sudo ./scripts/setup.sh"
    /// instruction text.
    static let logScannedFiles = b2Files + [
        "DefaultsKeys.swift",          // the topic's one-time keychain move reads the legacy value (#103)
        "MenuStateModel.swift",
        "MenuPanelView.swift",
        "MenuPanelVariants.swift",
        "MenuContentView.swift",
        "TopicFieldVisibility.swift",   // the editor's masked topic passes through it (issue #10)
    ] + SettingsWindowTests.settingsFiles

    /// Every menu source file (2026-10-18 redesign split the view into two
    /// files — a new panel file must be added here). Slice W adds the
    /// Settings window's files (`SettingsWindowTests.settingsFiles`).
    static let menuFiles = ["MenuStateModel.swift", "MenuPanelView.swift", "MenuPanelVariants.swift",
                            "MenuContentView.swift", "TopicFieldVisibility.swift"] + SettingsWindowTests.settingsFiles

    /// What counts as "a line that emits output", matched case-INSENSITIVELY
    /// (so `osLogger.`/`alertLogger.` cannot slip past). `Logger` is the only
    /// one this codebase uses; the other three are here so that reaching for a
    /// cruder tool — which has no `privacy:` annotation at all, and on
    /// `print`/`NSLog` no redaction whatsoever — cannot become a way around the
    /// no-topic-in-logs rule (I-4, review closure pass 2026-09-09). The scanned
    /// files contain none of them today.
    static let logCallTokens = ["logger.", "print(", "nslog", "os_log"]

    // MARK: - Log-call extraction (H1 — shared with FinishAlertStructureTests)

    /// Log-emitting METHODS — every `os.Logger` level — matched as `.name(`
    /// (case-insensitive, spaces/tabs allowed before the paren) on ANY
    /// receiver, so an aliased or renamed logger is still found.
    static let logMethodNames = ["notice", "error", "fault", "log", "debug", "info", "warning", "critical", "trace"]

    /// Log-emitting free FUNCTIONS (no `privacy:` support at all), matched as
    /// `name(` the same way.
    static let logFunctionNames = ["print", "nslog", "os_log"]

    /// One extracted log call: the 1-based line it starts on, and its text
    /// from the opener (`.notice(`, `print(` …) through the balanced closing
    /// parenthesis — ACROSS lines — or to end of input when it never closes.
    struct LogCall {
        let line: Int
        let text: String
        let closed: Bool
        var isSingleLine: Bool { closed && !text.contains("\n") }
    }

    /// Every log call in comment-stripped `code`. Over-inclusive by design
    /// (an enum pattern like `case .error(let m)` is extracted too and simply
    /// passes the content rules); it must never MISS a call.
    static func logCalls(in code: String) -> [LogCall] {
        let chars = Array(code)
        let lower = chars.map { $0.isASCII ? Character($0.lowercased()) : $0 }
        let methods = logMethodNames.map { Array($0) }
        let functions = logFunctionNames.map { Array($0) }
        func word(_ pattern: [Character], at index: Int) -> Bool {
            guard index + pattern.count <= lower.count else { return false }
            for k in pattern.indices where lower[index + k] != pattern[k] { return false }
            return true
        }
        func paren(after index: Int) -> Int? {
            var i = index
            while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
            return i < chars.count && chars[i] == "(" ? i : nil
        }
        var calls: [LogCall] = []
        var line = 1
        for start in chars.indices {
            if chars[start] == "\n" {
                line += 1
                continue
            }
            let open: Int? = chars[start] == "."
                ? methods.lazy.compactMap { word($0, at: start + 1) ? paren(after: start + 1 + $0.count) : nil }.first
                : functions.lazy.compactMap { word($0, at: start) ? paren(after: start + $0.count) : nil }.first
            guard let open else { continue }
            let end = callEnd(chars, open: open)
            calls.append(LogCall(line: line, text: String(chars[start...(end ?? chars.count - 1)]), closed: end != nil))
        }
        return calls
    }

    /// Index of the `)` closing the call whose `(` is at `open`, or nil. Code
    /// parentheses are balanced; string literals (`"…"`, `"""…"""`) are
    /// skipped, so a `(` or `)` inside a message cannot end the call early or
    /// late — but each `\( … )` interpolation inside one is code again.
    static func callEnd(_ chars: [Character], open: Int) -> Int? {
        enum Mode { case code(depth: Int), string(multiline: Bool) }
        func tripleQuote(at i: Int) -> Bool {
            i + 2 < chars.count && chars[i] == "\"" && chars[i + 1] == "\"" && chars[i + 2] == "\""
        }
        var stack: [Mode] = [.code(depth: 0)]
        var i = open
        while i < chars.count, let mode = stack.last {
            switch mode {
            case .code(let depth):
                if chars[i] == "(" {
                    stack[stack.count - 1] = .code(depth: depth + 1)
                } else if chars[i] == ")" {
                    if depth > 1 {
                        stack[stack.count - 1] = .code(depth: depth - 1)
                    } else if stack.count == 1 {
                        return i                                   // the call's own `)`
                    } else {
                        stack.removeLast()                         // an interpolation ends
                    }
                } else if chars[i] == "\"" {
                    let triple = tripleQuote(at: i)
                    stack.append(.string(multiline: triple))
                    if triple { i += 2 }
                }
            case .string(let multiline):
                if chars[i] == "\\" {
                    if i + 1 < chars.count, chars[i + 1] == "(" { stack.append(.code(depth: 1)) }
                    i += 1                                         // the escaped char / the `(`
                } else if multiline ? tripleQuote(at: i) : chars[i] == "\"" {
                    stack.removeLast()
                    if multiline { i += 2 }
                }
            }
            i += 1
        }
        return nil
    }

    /// The ONE logger declaration a scanned file may carry.
    static let loggerDeclarationPattern =
        #"^[ \t]*private static let logger = Logger\(subsystem: "com\.muratalkan\.napcat", category: "[a-z]+"\)[ \t]*$"#

    /// H1 shape rules, shared by both log lints (comment-stripped `code`):
    ///  1. every log call starts AND ends on one physical line;
    ///  2. at most one logger declaration, exactly `loggerDeclarationPattern`;
    ///  3. outside it, `Logger` never appears, and `logger` (any identifier
    ///     containing it, any case) appears ONLY as the receiver of a log call
    ///     (`logger.notice(` …): no alias (`let l = Self.logger`), no escape
    ///     (`f(Self.logger)`), no second logger.
    static func logShapeFailures(_ code: String, file: String) -> [String] {
        var failures: [String] = []
        for call in logCalls(in: code) where !call.isSingleLine {
            let head = call.text.prefix { $0 != "\n" }
            failures.append(call.closed
                ? "\(file):\(call.line): log call spans lines — every log call must start and end on one physical line: \(head)"
                : "\(file):\(call.line): log call never closes: \(head)")
        }
        var declarations = 0
        for (offset, line) in code.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let text = String(line)
            if text.range(of: loggerDeclarationPattern, options: .regularExpression) != nil {
                declarations += 1
                continue
            }
            var cursor = text.startIndex
            while let range = text.range(of: "[A-Za-z_][A-Za-z0-9_]*", options: .regularExpression,
                                         range: cursor..<text.endIndex) {
                cursor = range.upperBound
                let identifier = String(text[range])
                guard identifier.lowercased().contains("logger") else { continue }
                let tail = text[range.upperBound...]
                let isReceiver = identifier == "logger" && logMethodNames.contains { name in
                    tail.hasPrefix("." + name)
                        && tail.dropFirst(name.count + 1).drop(while: { $0 == " " || $0 == "\t" }).first == "("
                }
                if !isReceiver {
                    failures.append("\(file):\(offset + 1): '\(identifier)' outside the single logger declaration "
                        + "and not a log-call receiver (logger alias / escape): \(text)")
                }
            }
        }
        if declarations > 1 {
            failures.append("\(file): \(declarations) logger declarations — at most one per file")
        }
        return failures
    }

    /// What the content rules scan: every line holding a `logCallTokens`
    /// token (the pre-H1 unit) PLUS the full text of every extracted log call
    /// — so a secret or an unannotated interpolation on a continuation line is
    /// seen as well.
    static func logScanUnits(_ code: String) -> [String] {
        code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { line in logCallTokens.contains { line.lowercased().contains($0) } }
            + logCalls(in: code).map(\.text)
    }

    // MARK: - Symbol confinement

    /// THE NETWORKING ALLOWLIST (issue #111 amendment — explicit, three names):
    /// the only Sources files that may reference the URL Loading System. The
    /// ntfy sender (B2/Track C publishes), the CloudKit sender (F3 stage 1 —
    /// it names CloudKit only and needs no URL loading at all, but is a
    /// sanctioned networking file), and the update check's GitHub client
    /// (one pinned, unauthenticated GET — `UpdateCheckStructureTests`). A
    /// fourth networking file is a deliberate amendment of THIS list, never
    /// a quiet addition. (The Network framework has its own one-file
    /// confinement: ConnectivityStructureTests — a path monitor that opens no
    /// connection — so none of these three may import it either.)
    static let networkingFiles = ["NtfyMessageSender.swift", "CloudKitMessageSender.swift", "GitHubReleaseChecker.swift"]

    /// What "references the URL Loading System" means: the session, the
    /// request, and every task kind. Matched case-sensitively in
    /// comment-stripped code (doc comments may name the boundary).
    static let networkingTokens = ["URLSession", "URLRequest", "dataTask", "downloadTask", "uploadTask",
                                   "webSocketTask", "streamTask", "NSURLConnection", "CFHTTPMessage", "CFReadStreamCreateForHTTPRequest"]

    /// Banned EVERYWHERE, the allowlist included: the shared session (it
    /// keeps cookies, a cache and credentials across the process) and the
    /// task kinds no sanctioned file uses.
    static let bannedEverywhereTokens = ["URLSession.shared", "downloadTask", "uploadTask", "webSocketTask",
                                         "streamTask", "NSURLConnection", "CFHTTPMessage",
                                         "CFReadStreamCreateForHTTPRequest"]

    static func networkingConfinementFailures(_ sources: [(name: String, text: String)]) -> [String] {
        var failures: [String] = []
        for (name, text) in sources {
            let tokens = networkingFiles.contains(name) ? bannedEverywhereTokens : networkingTokens
            for token in tokens where text.contains(token) {
                failures.append("'\(token)' in \(name) — URL loading stays in the three sanctioned files \(networkingFiles)")
            }
        }
        // Every allowlisted file is real, and the two HTTP clients really
        // hold the session, the request and the data task (non-vacuous).
        for file in networkingFiles where !sources.contains(where: { $0.name == file }) {
            failures.append("\(file) is not in Sources/NapCat — update the networking allowlist")
        }
        for file in ["NtfyMessageSender.swift", "GitHubReleaseChecker.swift"] {
            let text = sources.first { $0.name == file }?.text ?? ""
            for token in ["URLSession", "URLRequest", "dataTask"] where !text.contains(token) {
                failures.append("'\(token)' not found in \(file) — the allowlist lint would be vacuous")
            }
        }
        return failures
    }

    @Test func urlLoadingIsConfinedToTheThreeSanctionedFiles() throws {
        let sources = try Self.swiftSources()
        #expect(Self.networkingConfinementFailures(sources).isEmpty, "\(Self.networkingConfinementFailures(sources))")
        #expect(Self.networkingFiles.count == 3, "the allowlist is explicit: three names")

        func mutate(_ name: String, _ transform: (String) -> String) -> [(name: String, text: String)] {
            sources.map { $0.name == name ? ($0.name, transform($0.text)) : $0 }
        }
        let canaries: [(String, [(name: String, text: String)])] = [
            ("the menu owner opens a session", mutate("MenuContentView.swift") {
                $0 + "\nlet canary = URLSession(configuration: .ephemeral)" }),
            ("the update controller opens a session", mutate("UpdateCheckController.swift") {
                $0 + "\nlet canary = URLSession(configuration: .ephemeral)" }),
            ("the model builds a request", mutate("MenuStateModel.swift") {
                $0 + "\nlet canary = URLRequest(url: URL(fileURLWithPath: \"/\"))" }),
            ("the app starts a task", mutate("NapCatApp.swift") { $0 + "\nlet canary = s.dataTask(with: r)" }),
            ("a checker uses the shared session", mutate("GitHubReleaseChecker.swift") {
                $0 + "\nlet canary = URLSession.shared" }),
            ("the ntfy sender downloads", mutate("NtfyMessageSender.swift") { $0 + "\nlet canary = s.downloadTask(with: r)" }),
            ("a fourth networking file", sources + [("ReleaseNotesFetcher.swift", "let canary = URLRequest(url: u)")]),
            ("the checker loses its session", mutate("GitHubReleaseChecker.swift") {
                $0.replacingOccurrences(of: "URLSession", with: "Session") }),
            // #155: a URL in a string literal no longer hides the rest of its line.
            ("a session behind a URL", mutate("MenuContentView.swift") {
                $0 + Self.codeOnly("\nlet u = \"https://ntfy.sh\"; let canary = URLSession(configuration: .ephemeral)") }),
            // Security spot-check H9 (the R-H9-155 plant): a bare regex after
            // `switch` holding a quote, then the URL, then the token.
            ("H9a: a session behind a URL after a bare regex", mutate("SettingsPanes.swift") {
                $0 + Self.codeOnly("\nprivate func h9() { switch /\"/ { default: let u = \"https://x\"; _ = (u, URLSession.shared) } }") }),
            ("H9, multi-line: a session in a //-led interpolation line", mutate("SettingsPanes.swift") {
                $0 + Self.codeOnly("\nprivate func h9m() -> String {\n    switch /\"\"\"/ { default: break }\n    let s = \"\"\"\n"
                    + "    // \\(URLSession.shared)\n    \"\"\"\n    switch /\"\"\"/ { default: break }\n    return s\n}") }),
        ]
        for (name, mutant) in canaries {
            #expect(!Self.networkingConfinementFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Negative control: a doc comment may NAME URLSession anywhere.
        #expect(Self.networkingConfinementFailures(mutate("MenuStateModel.swift") {
            $0 + Self.codeOnly("\n/// never URLSession, never URLRequest")
        }).isEmpty)
    }

    /// Each externally-visible capability may appear in ONE file only, repo
    /// wide. Vacuity is guarded: the token must really be present there.
    /// `session(for:` (security review L4): the sender's internal per-lane
    /// accessor hands out a live URLSession, so no other Sources file may call
    /// it — that would reach `downloadTask` / `data(from:)` without ever naming
    /// `URLSession`. (Tests are not scanned; they may invalidate the sessions.)
    ///
    /// F3 stage 1 AMENDMENT (deliberate, issue #64): CloudKitMessageSender.swift
    /// is the SECOND sanctioned networking file — for CloudKit symbols and the
    /// entitlement probe ONLY.
    ///
    /// Issue #111 AMENDMENT (deliberate): `URLSession` / `URLRequest` /
    /// `dataTask` moved from this one-owner table to the explicit three-file
    /// networking allowlist above (`urlLoadingIsConfinedToTheThreeSanctionedFiles`).
    /// The publish-only capabilities stay single-owner here: a request BODY
    /// (`httpBody`), the per-header writer the ntfy headers use (`setValue` —
    /// the GitHub client sets its two headers as one dictionary), and the
    /// per-lane session accessor.
    ///
    /// F4 slice S3 AMENDMENT (deliberate, issue #146): CloudKitApprovalRecords.swift
    /// may also name CloudKit's RECORD vocabulary — exactly the four tokens in
    /// `approvalRecordVocabulary`, so it can build the approval records and
    /// their operation. Every token that names a door to iCloud (the
    /// container, the database, the account check, the entitlement probe)
    /// stays single-owner. That alone does NOT stop the file running an
    /// operation: a CKDatabaseOperation run with no database set targets the
    /// user's private database (Apple's `CKDatabaseOperation.database`), so a
    /// `.start()` or a queue reaches iCloud naming none of these tokens
    /// (security review G1). ApprovalRecordPathStructureTests lock 4 closes
    /// that: an allow-list of the file's CloudKit identifiers, and no way to
    /// run an operation but the database seam.
    ///
    /// The CloudKit import is matched in ANY form (`cloudKitImport`): the
    /// literal "import CloudKit" let a scoped `import class CloudKit.X` into a
    /// third file (security review G2).
    static let approvalRecordsFile = "CloudKitApprovalRecords.swift"
    static let approvalRecordVocabulary: Set<String> = ["import CloudKit", "CKRecord", "CKModifyRecordsOperation", "CKError"]

    static let oneOwnerTable: [String: String] = [
        "httpBody": "NtfyMessageSender.swift",
        "setValue": "NtfyMessageSender.swift",
        "session(for:": "NtfyMessageSender.swift",
        "IORegisterForSystemPower": "SystemSleepSource.swift",
        "IODeregisterForSystemPower": "SystemSleepSource.swift",
        "IOAllowPowerChange": "SystemSleepSource.swift",
        "IONotificationPortSetDispatchQueue": "SystemSleepSource.swift",
        "import CloudKit": "CloudKitMessageSender.swift",
        "CKContainer": "CloudKitMessageSender.swift",
        "CKDatabase": "CloudKitMessageSender.swift",
        "CKRecord": "CloudKitMessageSender.swift",
        "CKModifyRecordsOperation": "CloudKitMessageSender.swift",
        "CKAccountStatus": "CloudKitMessageSender.swift",
        "CKError": "CloudKitMessageSender.swift",
        "SecTaskCreateFromSelf": "CloudKitMessageSender.swift",
        "SecTaskCopyValueForEntitlement": "CloudKitMessageSender.swift",
    ]

    /// An import of the CloudKit module in ANY form: `import CloudKit`,
    /// `@_exported import CloudKit`, `internal import CloudKit`, a scoped
    /// `import class CloudKit.CKFetchRecordsOperation`, split over lines or
    /// with a block comment between the words (security review G2), or with
    /// a trailing `//` comment ending a line inside it (`import // note`,
    /// then `CloudKit` on the next line: the security re-check, N2).
    static let cloudKitImport: String = {
        let gap = #"(?:\s|/\*[\s\S]*?\*/|//[^\n]*)+"#
        return #"\bimport"# + gap + #"(?:\w+"# + gap + #")?`?CloudKit\b"#
    }()

    /// Whether a source names `token`: the CloudKit import in any form,
    /// matched on the `uncut` text (`wholeLineCommentsRemoved`, so no URL can
    /// hide it); every other token as a substring of the `code` (`codeOnly`).
    static func names(_ token: String, code: String, uncut: String) -> Bool {
        token == "import CloudKit" ? uncut.range(of: cloudKitImport, options: .regularExpression) != nil : code.contains(token)
    }

    /// `sources`: Sources/NapCat with whole-line comments removed
    /// (`swiftSources(wholeLineCommentsRemoved)`).
    static func oneOwnerFailures(_ sources: [(name: String, text: String)]) -> [String] {
        let scanned = sources.map { (name: $0.name, code: codeOnly($0.text), uncut: $0.text) }
        var failures: [String] = []
        for (token, owner) in oneOwnerTable.sorted(by: { $0.key < $1.key }) {
            for source in scanned where names(token, code: source.code, uncut: source.uncut) {
                let shared = source.name == approvalRecordsFile && approvalRecordVocabulary.contains(token)
                if source.name != owner && !shared {
                    failures.append("'\(token)' leaked into \(source.name) — it must stay in \(owner)")
                }
            }
            if !scanned.contains(where: { $0.name == owner && names(token, code: $0.code, uncut: $0.uncut) }) {
                failures.append("'\(token)' not found in \(owner) — this lint would be vacuous")
            }
        }
        if !approvalRecordVocabulary.isSubset(of: Set(oneOwnerTable.keys)) {
            failures.append("the amendment names table tokens only")
        }
        guard let approvals = scanned.first(where: { $0.name == approvalRecordsFile }) else {
            return failures + ["\(approvalRecordsFile) not found — the amendment would be vacuous"]
        }
        for token in approvalRecordVocabulary.sorted() where !names(token, code: approvals.code, uncut: approvals.uncut) {
            failures.append("'\(token)' not in \(approvalRecordsFile) — the amendment names only what it uses (vacuity)")
        }
        // The amendment shares the record vocabulary, never a door to iCloud.
        for token in oneOwnerTable.keys.sorted() where !approvalRecordVocabulary.contains(token)
            && names(token, code: approvals.code, uncut: approvals.uncut) {
            failures.append("'\(token)' in \(approvalRecordsFile) — only the record vocabulary is shared")
        }
        return failures
    }

    @Test func externalCapabilitiesAreConfinedToOneFileEach() throws {
        let sources = try Self.swiftSources(Self.wholeLineCommentsRemoved)
        #expect(Self.oneOwnerFailures(sources).isEmpty, "\(Self.oneOwnerFailures(sources))")
    }

    /// The one-owner audit, run against mutated copies (security review 2,
    /// #146): each must fail it.
    @Test func theOneOwnerAuditCatchesEachBreach() throws {
        let sources = try Self.swiftSources(Self.wholeLineCommentsRemoved)
        func mutate(_ name: String, _ transform: (String) -> String) -> [(name: String, text: String)] {
            sources.map { $0.name == name ? ($0.name, transform($0.text)) : $0 }
        }
        let canaries: [(String, [(name: String, text: String)])] = [
            // Security review 2 (#146), G2: a third file, scoped import.
            ("a third CloudKit file, scoped import (G2)", sources + [("ZZFetchRecords.swift",
                "import class CloudKit.CKFetchRecordsOperation\nfunc f() { CKFetchRecordsOperation(recordIDs: []).start() }")]),
            ("an exported import", mutate("NapCatApp.swift") { "@_exported import CloudKit\n" + $0 }),
            ("an access-level import", mutate("CompositeMessageSender.swift") { "internal import CloudKit\n" + $0 }),
            ("a scoped import over three lines", mutate("MenuStateModel.swift") { "import\n    enum\n    CloudKit.CKError\n" + $0 }),
            ("a block comment inside the import", mutate("LidGuardController.swift") {
                "import /* zones */ struct CloudKit.CKRecordZone\n" + $0 }),
            // The security re-check (#146), N2: a trailing comment inside the import.
            ("a third CloudKit file, trailing-comment import (N2)", sources + [("ZZN2Fetch.swift",
                "import // fetch only\n    CloudKit\nfunc n2() { CKFetchRecordsOperation(recordIDs: []).start() }")]),
            ("a trailing comment after the import's kind", mutate("MessageSender.swift") {
                "import class // one type only\n    CloudKit.CKFetchRecordsOperation\n" + $0 }),
            ("a record token in a third file", mutate("MessageSender.swift") { $0 + "\nlet canary: CKRecord? = nil" }),
            ("the approvals file takes a container", mutate(Self.approvalRecordsFile) { $0 + "\nlet canary = CKContainer.default()" }),
            // #155: a URL in a string literal no longer hides the rest of its line.
            ("a record token behind a URL", mutate("MessageSender.swift") {
                $0 + "\nlet u = \"https://www.icloud.com\"; let canary: CKRecord? = nil" }),
        ]
        for (name, mutant) in canaries {
            #expect(!Self.oneOwnerFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: a doc comment may say what it rules out, and a
        // type named after CloudKit is not an import of it.
        #expect(Self.oneOwnerFailures(mutate("MenuStateModel.swift") {
            $0 + Self.wholeLineCommentsRemoved("\n/// two files import CloudKit; never import class CloudKit.CKRecord")
                + "\nimport NapCatWire\nlet canary = CloudKitMessageSender.self"
        }).isEmpty)
    }

    /// The B2 subsystem spawns NOTHING. Before B4 the osascript sender was the
    /// one permitted spawner; the ntfy channel needs no subprocess at all, so
    /// the exception is gone and the rule covers every file.
    @Test func theSubsystemNeverSpawnsAProcess() throws {
        let sources = try Self.swiftSources()
        let spawnTokens = ["Process(", "posix_spawn", "NSTask", "system(", "popen", "osascript"]
        for (name, text) in sources where Self.b2Files.contains(name) {
            for token in spawnTokens {
                #expect(!text.contains(token), "'\(token)' in \(name) — B2 must never spawn a process")
            }
        }
    }

    /// B2 adds ZERO privileged surface: no sudo, no pmset, no smc, no PLAN §4
    /// command anywhere in the subsystem.
    @Test func theSubsystemHasNoPrivilegedSurface() throws {
        let sources = try Self.swiftSources()
        let forbidden = ["sudo", "pmset", "PrivilegedCommand", "/usr/local/napcat", "disablesleep"]
        for (name, text) in sources where Self.b2Files.contains(name) {
            for token in forbidden {
                #expect(!text.contains(token), "'\(token)' in \(name) — B2 must stay unprivileged")
            }
        }
    }

    /// Every B2 type is constructed through the gated factories in
    /// LidGuardController.swift. Since Track C the ntfy sender is SHARED: it
    /// is built exactly once, by `makeSharedSender` (same debug-sim gate), and
    /// injected — `makeIfEnabled` no longer constructs one privately.
    @Test func theSubsystemHasASingleConstructionSite() throws {
        let sources = try Self.swiftSources()
        let constructors = [
            "LidGuardController(",
            "IOKitSystemSleepSource(",
            "NtfyMessageSender(",
        ]
        for token in constructors {
            for (name, text) in sources where text.contains(token) {
                #expect(name == "LidGuardController.swift",
                        "'\(token)' in \(name) — construction must go through LidGuardController.makeIfEnabled / makeSharedSender")
            }
        }
        // ONE sender construction site, inside the gated shared factory.
        let controller = try #require(sources.first { $0.name == "LidGuardController.swift" })
        #expect(controller.text.components(separatedBy: "NtfyMessageSender(").count - 1 == 1,
                "the ntfy sender must be constructed exactly once (makeSharedSender) and injected")
        // NapCatApp must reach the feature only through the gated factories.
        let app = try #require(sources.first { $0.name == "NapCatApp.swift" })
        #expect(app.text.contains("LidGuardController.makeIfEnabled("))
        #expect(!app.text.contains("LidGuardController("))
        #expect(app.text.contains("LidGuardController.makeSharedSender("))
        #expect(!app.text.contains("NtfyMessageSender("), "the app injects the shared sender — it never builds one")
    }

    /// A `NtfyDestination` is the ONLY thing that ever becomes a URL, so it
    /// must only ever be built by the validator. Any other source file
    /// assembling one by hand would bypass the ntfy grammar check.
    @Test func onlyThePolicyMayConstructADestination() throws {
        let sources = try Self.swiftSources()
        for (name, text) in sources where text.contains("NtfyDestination(") {
            #expect(name == "LidGuardPolicy.swift",
                    "'NtfyDestination(' in \(name) — build it through LidGuardPolicy.destination(server:topic:)")
        }
        let policy = try #require(sources.first { $0.name == "LidGuardPolicy.swift" })
        #expect(policy.text.contains("NtfyDestination("), "lint would be vacuous")
    }

    // MARK: - The sleep path reads the in-memory topic (issue #103)

    /// The `{ … }` body of the first member whose declaration starts with
    /// `declaration` (matched at the start of a line, after indentation), as
    /// a range from the declaration's first character through the closing
    /// brace. The body is the first `{` OUTSIDE the parameter list (a default
    /// argument may be a closure), and string literals are skipped, so a
    /// brace in a message cannot end it early.
    static func memberRange(_ declaration: String, in code: String) -> Range<String.Index>? {
        var lineStart = code.startIndex
        var found: String.Index?
        while lineStart < code.endIndex {
            let lineEnd = code[lineStart...].firstIndex(of: "\n") ?? code.endIndex
            let line = code[lineStart..<lineEnd]
            let indent = line.prefix { $0 == " " }
            if line.dropFirst(indent.count).hasPrefix(declaration) {
                found = line.index(lineStart, offsetBy: indent.count)
                break
            }
            lineStart = lineEnd < code.endIndex ? code.index(after: lineEnd) : code.endIndex
        }
        guard let start = found else { return nil }
        var parens = 0
        var opening: String.Index?
        for index in code[start...].indices {
            let char = code[index]
            if char == "(" { parens += 1 } else if char == ")" { parens -= 1 }
            if char == "{" && parens == 0 {
                opening = index
                break
            }
        }
        guard let open = opening else { return nil }
        var depth = 0
        var inString = false
        var index = open
        while index < code.endIndex {
            let char = code[index]
            if inString {
                if char == "\\" {
                    index = code.index(after: index)
                } else if char == "\"" {
                    inString = false
                }
            } else if char == "\"" {
                inString = true
            } else if char == "{" {
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0 { return start..<code.index(after: index) }
            }
            if index < code.endIndex { index = code.index(after: index) }
        }
        return nil
    }

    /// Everything in LidGuardController.swift that reaches the topic's
    /// persistent store rather than its in-memory copy.
    static let topicStoreTokens = ["topicStore", "TopicStore", "TopicKeychainMigration", "startupTopic", ".read()"]

    /// The ONLY members that may: construction (the one startup read, and the
    /// factory that forwards the store to it) and the save path.
    static let topicStoreMembers = ["init(", "static func makeIfEnabled(", "private static func startupTopic(",
                                    "private func commitTopic("]
    static let topicStoreDeclaration = "private let topicStore: TopicStore"

    /// What the WillSleep path runs: the power message table, the sleep and
    /// wake handlers, the snapshot, and every config read the snapshot makes.
    static let sleepPathMembers = ["func handle(", "private func handleWillSleep(", "private func handleWake(",
                                   "private func snapshot(busy:", "var storedDestination:", "var storedTopic:",
                                   "var storedServer:", "var isEnabled:", "var primedAt:"]

    static func sleepPathLintFailures(_ code: String) -> [String] {
        var failures: [String] = []
        var allowed: [Range<String.Index>] = []
        for member in topicStoreMembers {
            guard let range = memberRange(member, in: code) else {
                failures.append("'\(member)' not found — keep the lint's member list in sync")
                continue
            }
            allowed.append(range)
        }
        let declarations = code.ranges(of: topicStoreDeclaration)
        if declarations.count != 1 { failures.append("expected exactly one '\(topicStoreDeclaration)'") }
        allowed += declarations
        for token in topicStoreTokens {
            for occurrence in code.ranges(of: token)
            where !allowed.contains(where: { $0.contains(occurrence.lowerBound) }) {
                let line = code[..<occurrence.lowerBound].filter { $0 == "\n" }.count + 1
                failures.append("line \(line): '\(token)' outside construction and the save path — "
                    + "the topic is read once at startup and kept in memory")
            }
        }
        for member in sleepPathMembers {
            guard let range = memberRange(member, in: code) else {
                failures.append("sleep-path member '\(member)' not found — this lint would be vacuous")
                continue
            }
            for token in topicStoreTokens where code[range].contains(token) {
                failures.append("'\(token)' in sleep-path member '\(member)'")
            }
        }
        if let topic = memberRange("var storedTopic:", in: code), !code[topic].contains("return topic") {
            failures.append("storedTopic must return the in-memory copy")
        }
        return failures
    }

    /// Issue #103: the WillSleep path touches only the in-memory topic. The
    /// keychain is read once, at construction (`startupTopic`), and written
    /// only when a new topic is saved; every sleep-path member reads memory.
    /// LidGuardControllerTests proves the same at runtime (read count).
    @Test func theSleepPathTouchesOnlyTheInMemoryTopic() throws {
        let controller = try #require(try Self.swiftSources().first { $0.name == "LidGuardController.swift" })
        let failures = Self.sleepPathLintFailures(controller.text)
        #expect(failures.isEmpty, "\(failures)")
        // The store is reached at all (non-vacuous): one startup read, one
        // save path, and the migration only from the startup read.
        let text = controller.text
        #expect(text.components(separatedBy: "store.read()").count - 1 == 1, "exactly one startup read")
        #expect(text.contains("topicStore.write(") && text.contains("topicStore.delete()"))
        #expect(text.components(separatedBy: "TopicKeychainMigration.run(").count - 1 == 1)
    }

    /// Canary: a store read in the sleep handler, in the snapshot, in the
    /// topic getter, or in a NEW member must each be caught.
    @Test func theSleepPathLintCatchesMutants() throws {
        let original = try #require(try Self.swiftSources().first { $0.name == "LidGuardController.swift" }).text
        try #require(Self.sleepPathLintFailures(original).isEmpty, "canary baseline must be clean")
        let mutants: [(String, String, String)] = [
            ("store read in the WillSleep handler",
             "        guard let busy = busyProvider() else {",
             "        _ = topicStore.read()\n        guard let busy = busyProvider() else {"),
            ("migration re-run in the snapshot",
             "        let destination = storedDestination\n",
             "        _ = TopicKeychainMigration.run(defaults: defaults, store: topicStore)\n"
                + "        let destination = storedDestination\n"),
            ("topic getter reads the store",
             "        return topic\n    }",
             "        if case .found(let fresh) = topicStore.read() { return fresh }\n        return topic\n    }"),
            ("a new member reloads the store",
             "    private func handleWake(",
             "    func reloadTopic() { if case .found(let t) = topicStore.read() { _ = t } }\n\n    private func handleWake("),
            ("getter no longer returns memory",
             "        return topic\n    }", "        return \"\"\n    }"),
        ]
        for (name, target, replacement) in mutants {
            let mutant = original.replacingOccurrences(of: target, with: replacement)
            #expect(mutant != original, "canary setup '\(name)': target text must exist")
            #expect(!Self.sleepPathLintFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: - Debug-simulator absence

    @Test @MainActor func theSubsystemIsAbsentInDebugSimulatorMode() {
        #expect(!LidGuardPolicy.lidGuardMayBeConstructed(debugBattery: true))
        #expect(LidGuardPolicy.lidGuardMayBeConstructed(debugBattery: false))

        let suite = "com.muratalkan.napcat.tests.lidguard.structure"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // No sender — hence no URLSession, no network — in debugBattery mode.
        #expect(LidGuardController.makeSharedSender(debugBattery: true) == nil,
                "debugBattery mode must not construct the ntfy sender")

        let detection = ClaudeActivityController.makeIfEnabled(debugBattery: false)
        let keychain = FakeTopicStore("napcat-structure")
        // The predicate is checked FIRST: even an injected sender cannot
        // bring the lid guard into debugBattery mode.
        #expect(LidGuardController.makeIfEnabled(
            debugBattery: true,
            defaults: defaults,
            stayAwakeMirror: ObservedStayAwakeMirror(),
            detection: detection,
            sender: RecordingMessageSender(),
            topicStore: keychain
        ) == nil, "debugBattery mode must not construct the lid guard")
        #expect(LidGuardController.makeIfEnabled(
            debugBattery: true,
            defaults: defaults,
            stayAwakeMirror: ObservedStayAwakeMirror(),
            detection: detection,
            sender: LidGuardController.makeSharedSender(debugBattery: true),
            topicStore: keychain
        ) == nil)

        // Without the B1 detection stack there is nothing to notify about.
        #expect(LidGuardController.makeIfEnabled(
            debugBattery: false,
            defaults: defaults,
            stayAwakeMirror: ObservedStayAwakeMirror(),
            detection: nil,
            sender: RecordingMessageSender(),
            topicStore: keychain
        ) == nil)

        // Without a sender there is nothing to deliver with.
        #expect(LidGuardController.makeIfEnabled(
            debugBattery: false,
            defaults: defaults,
            stayAwakeMirror: ObservedStayAwakeMirror(),
            detection: detection,
            sender: nil,
            topicStore: keychain
        ) == nil)
        // No construction, so no keychain: the store was never touched.
        #expect(keychain.readCount == 0 && keychain.writeCount == 0 && keychain.deleteCount == 0)

        // Outside debugBattery mode the shared sender IS built (two idle
        // URLSessions — no task is created, nothing touches the network).
        let shared = LidGuardController.makeSharedSender(debugBattery: false)
        #expect(shared != nil)
        if let shared {
            for lane in NtfySendLane.allCases { shared.session(for: lane).invalidateAndCancel() }
        }
    }

    /// The panel and model stay free of every low-level symbol (extends the B1
    /// rule to the B2 tokens).
    @Test func menuFilesStayFreeOfTheB2Capabilities() throws {
        let dir = Self.sourcesDir()
        for file in Self.menuFiles {
            let text = Self.codeOnly(try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8))
            for token in ["URLSession", "URLRequest", "dataTask", "osascript",
                          "IORegisterForSystemPower", "IOAllowPowerChange"] {
                #expect(!text.contains(token), "'\(token)' must not appear in \(file)")
            }
        }
    }

    // MARK: - The topic is a password

    /// The ntfy topic is the ONLY access control on the feed and it rides
    /// inside the request URL. So no B2 output — `Logger`, `print`, `NSLog`
    /// or `os_log` — may name a topic or a URL, and every interpolation in it
    /// must carry an explicit `privacy:` annotation.
    ///
    /// Scanned units (H1): every line holding a `logCallTokens` token, AND the
    /// whole text of every log call (`logCalls`, extracted across lines on any
    /// receiver) — plus the shared shape rules: one physical line per call,
    /// one logger declaration, no logger alias. Case-INSENSITIVE throughout: a
    /// differently-named logger (`osLogger`, `alertLogger`, …) must not slip
    /// past (canary-caught in the 2026-09-09 security review).
    static func logLintFailures(_ code: String, file: String) -> [String] {
        var failures = logShapeFailures(code, file: file)
        for unit in logScanUnits(code) {
            for secret in ["topic", "Topic", "absoluteString", ".url", "request.url", "endpoint"]
            where unit.contains(secret) {
                failures.append("\(file): a log call must never carry '\(secret)' — the ntfy topic is a password: \(unit)")
            }
            let interpolations = unit.components(separatedBy: "\\(").count - 1
            let annotations = unit.components(separatedBy: "privacy:").count - 1
            if interpolations != annotations {
                failures.append("\(file): every interpolation in a log call needs an explicit privacy level: \(unit)")
            }
        }
        return failures
    }

    @Test func noLidGuardLogLineCanEchoTheTopicOrTheUrl() throws {
        let sources = try Self.swiftSources()
        var scanned = 0
        for (name, text) in sources where Self.logScannedFiles.contains(name) {
            scanned += Self.logCalls(in: text).count
            let failures = Self.logLintFailures(text, file: name)
            #expect(failures.isEmpty, "\(failures)")
        }
        #expect(scanned >= 10, "only \(scanned) log calls scanned — this lint would be (nearly) vacuous")
        // Every scanned file must really exist under that name, or a rename
        // would silently drop it out of the lint.
        for name in Self.logScannedFiles {
            #expect(sources.contains { $0.name == name },
                    "\(name) is not in Sources/NapCat — update the lint's file list")
        }
    }

    /// H1 canaries, injected into EVERY scanned file: a call split across
    /// lines with the topic on the continuation line, an aliased / escaped /
    /// second logger, and an unannotated interpolation hidden on a
    /// continuation line (a line-based scan sees none of them) must each be
    /// caught BY THE RULE THAT TARGETS IT; a clean one-line call must pass.
    @Test func lidGuardLogLintCatchesMutants() throws {
        let sources = try Self.swiftSources()
        let split = "func canary() {\n    Self.logger.notice(\n        \"lid guard: \\(destination.topic, privacy: .private)\")\n}"
        let hidden = "func canary() {\n    Self.logger.notice(\"\"\"\n        lid guard: \\(reason.rawValue)\n        \"\"\")\n}"
        let mutants: [(name: String, code: String, expected: [String])] = [
            ("multi-line split", split, ["spans lines", "'topic'"]),
            ("aliased logger", "func canary() { let l = Self.logger; l.notice(\"lid guard\") }", ["logger alias"]),
            ("aliased bare logger", "func canary() { let l = logger; l.notice(\"lid guard\") }", ["logger alias"]),
            ("escaped logger", "func canary() { relay(Self.logger) }", ["logger alias"]),
            ("second logger", "let other = Logger(subsystem: \"x\", category: \"y\")", ["logger alias"]),
            ("renamed logger", "func canary() { osLogger.notice(\"lid guard\") }", ["logger alias"]),
            ("hidden interpolation", hidden, ["explicit privacy level", "spans lines"]),
            ("never closes", "func canary() { Self.logger.notice(\"lid guard\"", ["never closes"]),
        ]
        var checked = 0
        for (file, text) in sources where Self.logScannedFiles.contains(file) {
            try #require(Self.logLintFailures(text, file: file).isEmpty, "canary baseline must be clean")
            for (name, code, expected) in mutants {
                let failures = Self.logLintFailures(text + "\n" + code + "\n", file: file)
                for marker in expected {
                    #expect(failures.contains { $0.contains(marker) },
                            "canary '\(name)' in \(file) was NOT caught by the '\(marker)' rule: \(failures)")
                }
            }
            let clean = "func canary() { Self.logger.notice(\"lid guard: \\(count, privacy: .public)\") }"
            #expect(Self.logLintFailures(text + "\n" + clean + "\n", file: file).isEmpty,
                    "a clean one-line call must not trip the lint in \(file)")
            checked += 1
        }
        #expect(checked == Self.logScannedFiles.count)
    }

    /// The extractor itself: string-aware balancing (a `(`/`)` inside a
    /// message neither ends nor extends the call), interpolations scanned as
    /// code, any receiver, spaces before the paren, and no false openers.
    @Test func logCallExtractionIsStringAwareAndReceiverAgnostic() {
        let code = """
            Self.logger.notice("disarmed (\\(r, privacy: .public)), x")
            l.error("a) \\(b)")
            print ("p")
            let x = foo.information(1) + bar.logger
            NSLog("n")
            Self.logger.notice(
                "two")
            Self.logger.fault("x"
            """
        let calls = Self.logCalls(in: code)
        #expect(calls.map(\.text) == [
            ".notice(\"disarmed (\\(r, privacy: .public)), x\")",
            ".error(\"a) \\(b)\")",
            "print (\"p\")",
            "NSLog(\"n\")",
            ".notice(\n    \"two\")",
            ".fault(\"x\"",
        ])
        #expect(calls.map(\.line) == [1, 2, 3, 5, 6, 8])
        #expect(calls.map(\.isSingleLine) == [true, true, true, true, false, false])
        #expect(calls.map(\.closed) == [true, true, true, true, true, false])
    }

    /// F1 (2026-10-18): the fire-gate SKIP line used to be `.debug`, which
    /// macOS does not persist — `log show` could not see the skip reason, and a
    /// one-click "Pause detection" (every sleep skipped `noTaskInFlight`) stayed
    /// invisible for five weeks across two hardware drills. It must be logged at
    /// a PERSISTED level, keep its one public reason field, and no B2 line may
    /// drop back to a level macOS discards (`.debug`/`.trace`, or `.info`, which
    /// is memory-only by default).
    @Test func fireGateSkipReasonIsLoggedAtAPersistedLevel() throws {
        let sources = try Self.swiftSources()
        let controller = try #require(sources.first { $0.name == "LidGuardController.swift" })
        let skipLines = controller.text.split(separator: "\n").filter { $0.contains("sleeping, no alert") }
        #expect(skipLines.count == 1, "expected exactly one skip line, found \(skipLines.count)")
        let line = try #require(skipLines.first)
        #expect(line.contains("logger.notice("), "the skip reason must be persisted: \(line)")
        #expect(line.contains("\\(reason.rawValue, privacy: .public)"), "the reason field must stay public")
        #expect(line.components(separatedBy: "\\(").count - 1 == 1, "no new interpolations on the skip line")

        for (name, text) in sources where Self.b2Files.contains(name) {
            for level in ["logger.debug(", "logger.trace(", "logger.info("] {
                #expect(!text.contains(level), "\(name): '\(level)' is not persisted by macOS — use .notice or higher")
            }
        }
    }

    /// The failure detail that reaches the menu and the (private) log comes
    /// from a fixed vocabulary, never from an error's own message — those can
    /// embed the failing URL.
    @Test func senderFailureDetailsNeverComeFromAnErrorDescription() throws {
        let sources = try Self.swiftSources()
        for (name, text) in sources where Self.b2Files.contains(name) {
            #expect(!text.contains("localizedDescription"),
                    "\(name): localizedDescription can carry the failing URL, which carries the topic")
        }
    }

    // MARK: - Sender API surface (body is app-generated, enforced by shape)

    /// The one send entry point takes NO free-text parameter — byte-locked, so
    /// adding a `body:`/`text:` String would fail here. Since B4 it carries no
    /// String at all: the destination is a pre-validated struct.
    @Test func theSenderApiCannotCarryFreeText() throws {
        let source = try String(
            contentsOf: Self.sourcesDir().appendingPathComponent("MessageSender.swift"),
            encoding: .utf8
        )
        let expected = [
            "    func send(",
            "        _ kind: LidGuardMessageKind,",
            "        to destination: NtfyDestination,",
            "        at firedAt: Date,",
            "        completion: @escaping @Sendable (MessageSendOutcome) -> Void",
            "    )",
        ].joined(separator: "\n")
        #expect(source.contains(expected), "the MessageSender signature changed — re-review the free-text guarantee")

        // Within the protocol declaration there is now NO String parameter.
        let start = try #require(source.range(of: "protocol MessageSender"))
        let body = source[start.upperBound...]
        let end = try #require(body.range(of: "\n}"))
        let declaration = String(body[..<end.lowerBound])
        let stringParameters = declaration.components(separatedBy: ": String").count - 1
        #expect(stringParameters == 0, "expected no String parameter at all, found \(stringParameters)")
        for forbidden in ["body:", "text:", "message:", "subject:"] {
            #expect(!declaration.contains(forbidden), "'\(forbidden)' would let caller text reach a message")
        }
    }

    /// The dry-run sender proves the produced body really is the template —
    /// for all five closed kinds (alert healing added the restore push).
    @Test func theDryRunSenderProducesOnlyTemplateBodies() {
        let destination = NtfyDestination(server: "https://ntfy.sh", topic: "napcat-structure")
        let sender = RecordingMessageSender()
        let kinds: [LidGuardMessageKind] = [
            .lidAlert(busySessionCount: 2),
            .test,
            .sessionFinished(minutes: 42, folded: 1, stillWorking: 1),
            .needsAttention(minutes: 12, stillWorking: 0),
            .connectionRestored(minutes: 14, deliveredLate: 2, dropped: 0, lidMissed: 1),
        ]
        for kind in kinds {
            sender.send(kind, to: destination, at: Date(timeIntervalSince1970: 0)) { _ in }
        }
        let bodies = sender.bodies(clockTime: "22:49")
        #expect(bodies.count == kinds.count)
        for (body, kind) in zip(bodies, kinds) {
            #expect(body == LidGuardPolicy.messageBody(kind: kind, clockTime: "22:49"))
        }
        #expect(bodies[2] == "A Claude session finished after 42 min — 1 still working")
        #expect(bodies[3] == "Claude is waiting for you — 12 min in")
        #expect(bodies[4] == "Connection was down 14 min. 2 session alerts delivered late. 1 lid alert missed.")
        // Closed-set lock: a sixth kind will not compile until it is added here.
        for kind in kinds {
            switch kind {
            case .lidAlert, .test, .sessionFinished, .needsAttention, .connectionRestored: break
            }
        }
    }

    // MARK: - What B4 removed (regression locks)

    /// The iMessage channel is gone repo-wide: no sender, no probe, no bundled
    /// AppleScript, no Makefile rule, and no source naming Messages automation.
    @Test func theIMessageChannelIsFullyRemoved() throws {
        let fileManager = FileManager.default
        for removed in [
            "Sources/NapCat/OSAScriptMessageSender.swift",
            "Sources/NapCat/AutomationPermissionProbe.swift",
            "Resources/napcat-send-imessage.applescript",
        ] {
            #expect(!fileManager.fileExists(atPath: Self.repoRoot().appendingPathComponent(removed).path),
                    "\(removed) must be gone after the ntfy swap")
        }

        let sources = try Self.swiftSources()
        for (name, text) in sources {
            for token in ["osascript", "AEDeterminePermissionToAutomateTarget",
                          "com.apple.MobileSMS", "AECreateDesc", "AutomationPermission"] {
                #expect(!text.contains(token), "'\(token)' still in \(name) — the iMessage channel is retired")
            }
        }

        let makefile = try String(contentsOf: Self.repoRoot().appendingPathComponent("Makefile"), encoding: .utf8)
        #expect(!makefile.contains("applescript"), "the Makefile must no longer bundle an AppleScript")
        #expect(makefile.contains("napcat-watchdog.sh"), "lint would be vacuous if resource copying vanished")
    }

    /// NapCat now drives no other application, so it must request no
    /// Automation (TCC) permission — an unused purpose string would be a
    /// standing, unexplained privacy prompt waiting to happen.
    @Test func infoPlistDeclaresNoAppleEventsUsage() throws {
        let plist = try String(
            contentsOf: Self.repoRoot().appendingPathComponent("Resources/Info.plist"),
            encoding: .utf8
        )
        #expect(!plist.contains("<key>NSAppleEventsUsageDescription</key>"))
        #expect(plist.contains("LSUIElement"), "lint would be vacuous if the plist were empty")
    }
}

/// The IOKit power-message table, verified without registering anything: the
/// four message numbers are derived from `iokit_common_msg` and mapped to the
/// events the controller acts on.
struct SystemSleepMessageTests {
    @Test func messageNumbersMatchIOMessageHeaderValues() {
        #expect(IOKitSystemSleepSource.canSystemSleepMessage == 0xE000_0270)
        #expect(IOKitSystemSleepSource.systemWillSleepMessage == 0xE000_0280)
        #expect(IOKitSystemSleepSource.systemWillNotSleepMessage == 0xE000_0290)
        #expect(IOKitSystemSleepSource.systemHasPoweredOnMessage == 0xE000_0300)
        #expect(IOKitSystemSleepSource.systemWillPowerOnMessage == 0xE000_0320)
    }

    @Test func theMessageTableMapsEveryHandledNotification() {
        #expect(IOKitSystemSleepSource.event(forMessageType: IOKitSystemSleepSource.canSystemSleepMessage) == .canSystemSleep)
        #expect(IOKitSystemSleepSource.event(forMessageType: IOKitSystemSleepSource.systemWillSleepMessage) == .systemWillSleep)
        #expect(IOKitSystemSleepSource.event(forMessageType: IOKitSystemSleepSource.systemWillPowerOnMessage) == .systemWillPowerOn)
        #expect(IOKitSystemSleepSource.event(forMessageType: IOKitSystemSleepSource.systemHasPoweredOnMessage) == .systemHasPoweredOn)
        // Needs no reply — ignoring it cannot delay a sleep.
        #expect(IOKitSystemSleepSource.event(forMessageType: IOKitSystemSleepSource.systemWillNotSleepMessage) == nil)
        #expect(IOKitSystemSleepSource.event(forMessageType: 0) == nil)
    }

    /// A fresh source registers nothing until it is started.
    @Test func aFreshIOKitSourceIsNotRunning() {
        #expect(!IOKitSystemSleepSource().isRunning)
    }

    /// If `stop()` races a callback that IOKit already queued, there is no
    /// handler left to answer it — the source must acknowledge anyway, or
    /// macOS waits out its ~30 s timeout before that sleep.
    ///
    /// The source is deliberately never `start`ed here: registering the test
    /// process for real system power notifications would put a do-nothing
    /// handler on this machine's sleep path.
    @Test func aQueuedNotificationIsAcknowledgedEvenWithNoHandlerInstalled() {
        let source = IOKitSystemSleepSource()
        #expect(!source.isRunning)
        for event in [SystemSleepEvent.canSystemSleep, .systemWillSleep,
                      .systemWillPowerOn, .systemHasPoweredOn] {
            let recorder = AckRecorder()
            source.dispatch(event: event, ack: recorder.ack)
            #expect(recorder.performedCount == 1, "\(event) must never be left unanswered")
        }
    }

    @Test func theAckTokenIsIdempotent() {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func bump() {
                lock.lock()
                value += 1
                lock.unlock()
            }
            var count: Int {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
        }
        let counter = Counter()
        let ack = SystemSleepAck { counter.bump() }
        #expect(!ack.didAllow)
        ack.allow()
        ack.allow()
        ack.allow()
        #expect(counter.count == 1, "IOAllowPowerChange must run exactly once per notification")
        #expect(ack.allowCallCount == 3)
        #expect(ack.didAllow)
        // The wake ack does nothing at all.
        SystemSleepAck.noOp().allow()
    }
}
