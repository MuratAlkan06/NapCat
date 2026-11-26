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
    /// read IN ADDITION to the raw text, never instead of it.
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
    /// regex after `switch`). So every opener shape is pinned by the
    /// stripper tables and by a canary in a lock that reads it.
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

    /// Whether the `/` at `index` (not `//` or `/*`) opens a bare regex
    /// literal: an expression can start there (nothing before it on its
    /// line; a space or tab right before it, since with none after it Swift
    /// 6 never reads that `/` as a division (security spot-check H9); or an
    /// operator, an opening bracket, a separator or a keyword that precedes
    /// an expression, `switch/"/` included), no space follows it, and an
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
