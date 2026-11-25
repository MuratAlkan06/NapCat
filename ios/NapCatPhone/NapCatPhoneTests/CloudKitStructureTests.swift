import Foundation
import NapCatWire
import Testing

/// Structural locks over the repository's own source text, read from the
/// checkout (the simulator test host can read the Mac's file system). Each
/// rule is also run against a mutated copy, so a rule that could never fail
/// fails here instead.
///
/// 1. The wire's identifiers are spelled once, in NapCatWire: no other Swift
///    file in either app (or in these tests) holds the subscription ID or
///    the container ID, and no receiver source spells a record key itself.
/// 2. CloudKit lives in ONE receiver file (no other file imports it in any
///    form, a scoped `import class CloudKit.X` included), and a container is
///    built at ONE site, `makeLive()`, whose first statement is the
///    `LiveCapability` guard (an unentitled construction traps). No test
///    names a container constructor at all. (#153: however the
///    construction is spelled.) AMENDED (S-PAIR-C1.6, #172): at TWO sites,
///    `makeLive()` and `makeLiveApprovalDatabase()`, each opening on that
///    guard and each building one container.
/// 3. (#153) The alert lane's one database write is the subscription save:
///    the file's CloudKit identifiers are an exact allow-list, `save` and
///    the private database are pinned to their lines, and no other
///    database write is named.
@Suite struct CloudKitStructureTests {
    typealias Source = (path: String, text: String)

    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // NapCatPhoneTests
        .deletingLastPathComponent() // NapCatPhone
        .deletingLastPathComponent() // ios
        .deletingLastPathComponent() // repository root
    static let wireFile = "Sources/NapCatWire/AlertWire.swift"
    static let appDir = "ios/NapCatPhone/NapCatPhone"
    static let testsDir = "ios/NapCatPhone/NapCatPhoneTests"
    static let cloudKitFile = "ios/NapCatPhone/NapCatPhone/Live/CloudKitAlertSource.swift"

    static let container = "CKContainer"
    /// AMENDED (S-PAIR-C1.6, #172): two factories, the alerts' and the
    /// approvals database's, each opening on the capability guard and each
    /// building its one container.
    static let factoryHeads = ["static func makeLive() -> CloudKitAlertSource? {",
                               "static func makeLiveApprovalDatabase() -> (any CloudKitApprovalDatabase)? {"]
    static let capabilityGuard = "guard LiveCapability.isAvailable else { return nil }"

    /// Every `.swift` file under `directory` (repository-relative paths).
    static func swiftFiles(under directory: String) throws -> [Source] {
        let base = repoRoot.appendingPathComponent(directory).resolvingSymlinksInPath()
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        let baseComponents = base.pathComponents
        var files: [Source] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let components = url.resolvingSymlinksInPath().pathComponents
            guard components.starts(with: baseComponents) else { continue }
            let path = ([directory] + components.dropFirst(baseComponents.count)).joined(separator: "/")
            files.append((path, try String(contentsOf: url, encoding: .utf8)))
        }
        return files.sorted { $0.path < $1.path }
    }

    /// `//` comments removed, so doc comments may name what they document.
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

    /// WHOLE-LINE `//` comments removed only (a line whose first non-blank
    /// characters open a `//` comment). Unlike `codeOnly`, it keeps trailing
    /// comments: they can only over-match. AMENDED (#155): read through
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
    /// replaced by one space. Read through `lexemes`, so a `/*` inside a
    /// string literal cannot swallow the code after it. (The Mac's
    /// `LidGuardStructureTests.cleaned`.)
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
    /// text with its backticks removed and nothing else (no lexer involved),
    /// and `cleaned` — in addition to the raw text, never instead of it.
    static func constructorScanCopies(_ text: String) -> [String] {
        guard mayClean(text) else { return [text] }          // its own cleaned copy
        return [text, text.replacingOccurrences(of: "`", with: ""), cleaned(text)]
    }

    static func constructorScanCopies(_ sources: [Source]) -> [[Source]] {
        guard sources.contains(where: { mayClean($0.text) }) else { return [sources] }
        return [sources, sources.map { ($0.path, $0.text.replacingOccurrences(of: "`", with: "")) },
                sources.map { ($0.path, cleaned($0.text)) }]
    }

    /// Whether cleaning can change `text` at all: with no backtick and no
    /// `/*` (a block comment opens only there), every copy is the text.
    static func mayClean(_ text: String) -> Bool { text.contains("`") || text.contains("/*") }

    /// Every match of `pattern` in `text`, as written. Every #153 check and
    /// its probes run through this one engine (NSRegularExpression).
    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return ["<bad pattern \(pattern)>"] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    static func hits(_ pattern: String, in text: String) -> Bool { !matches(pattern, in: text).isEmpty }

    /// Every line holding a match of `pattern`, trimmed, with how many
    /// matches it holds: a site pin compares it to an exact allow-list.
    static func siteTally(_ pattern: String, in text: String) -> [String: Int] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return ["<bad pattern \(pattern)>": 1] }
        let lineEnd: (Character) -> Bool = { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
        var tally: [String: Int] = [:]
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else {
                tally["<a match of \(pattern) off the text>", default: 0] += 1
                continue
            }
            let start = text[..<range.lowerBound].lastIndex(where: lineEnd).map { text.index(after: $0) } ?? text.startIndex
            let end = text[range.lowerBound...].firstIndex(where: lineEnd) ?? text.endIndex
            tally[text[start..<end].trimmingCharacters(in: .whitespaces), default: 0] += 1
        }
        return tally
    }

    /// A site pin: `pattern`'s sites in `text` are exactly `allowed`.
    static func siteFailures(_ pattern: String, in text: String, file: String, allowed: [String: Int],
                             rule: String) -> [String] {
        let tally = siteTally(pattern, in: text)
        if tally == allowed { return [] }
        let off = tally.filter { allowed[$0.key] != $0.value }.map { "\($0.value)× \($0.key)" }.sorted()
        let gone = allowed.filter { tally[$0.key] != $0.value }.map(\.key).sorted()
        return ["'\(pattern)' in \(file) — \(rule): off the allow-list \(off); moved or gone \(gone)"]
    }

    /// `allowed` per app file (paths under `appDir`), keyed as
    /// `appSiteFailures` tallies: "path: line".
    static func appSites(_ byFile: [String: [String: Int]]) -> [String: Int] {
        var sites: [String: Int] = [:]
        for (file, lines) in byFile {
            for (line, count) in lines { sites["\(appDir)/\(file): \(line)"] = count }
        }
        return sites
    }

    /// A site pin across files (#166): every line holding a match of
    /// `pattern`, in every source as given, keyed "path: line", is exactly
    /// `allowed`; any other file holds none. Callers pass code (comments
    /// stripped, string literals in: a word in a string counts too, so a
    /// literal can only over-match).
    static func appSiteFailures(_ pattern: String, in sources: [Source], allowed: [String: Int], rule: String) -> [String] {
        var tally: [String: Int] = [:]
        for (path, text) in sources {
            for (line, count) in siteTally(pattern, in: text) { tally["\(path): \(line)", default: 0] += count }
        }
        if tally == allowed { return [] }
        let off = tally.filter { allowed[$0.key] != $0.value }.map { "\($0.value)× \($0.key)" }.sorted()
        let gone = allowed.filter { tally[$0.key] != $0.value }.map(\.key).sorted()
        return ["'\(pattern)' in the app — \(rule): off the allow-list \(off); moved or gone \(gone)"]
    }

    /// An adoption of the protocol `name`, however it is declared (#166,
    /// security review B11-B13): a type, an extension or a refining protocol
    /// naming it in its inheritance or `where` clause, the clause continued
    /// over any number of lines; or a typealias naming it, since a type
    /// adopting the alias names nothing else. Read it in every constructor
    /// scan copy: a block comment holding a `{` ends the clause early in the
    /// raw text. A keyword in a string can only over-match.
    static func adoptionPattern(_ name: String) -> String {
        let word = #"\b"# + name + #"\b"#
        return #"\b(?:class|struct|actor|enum|extension|protocol)\b[^{]*?:[^{]*?"# + word
            + #"|\btypealias\b[^=]*=[^{};]*?"# + word
    }

    /// Every name standing for the protocol `seam` (#168, the PR #167
    /// review's lock-shape follow-up (c)): the seam itself, and every
    /// typealias of one of those names and every protocol refining one,
    /// declared in ANY file given — Fixtures/ included, where adopting a seam
    /// is allowed but declaring a new name for it would let a live file adopt
    /// it unseen — collected until nothing new appears, in every constructor
    /// scan copy. A lock then scans each collected name as it scans the seam.
    static func seamNames(_ seam: String, in sources: [Source]) -> Set<String> {
        var names: Set<String> = [seam]
        let copies = sources.flatMap { constructorScanCopies(codeOnly($0.text)) }
        var grew = true
        while grew {
            grew = false
            for name in names.sorted() {
                let word = #"\b"# + name + #"\b"#
                let rest = oneDeclaration
                for pattern in [#"\btypealias\s+(\w+)\b[^=]*="# + rest + word,
                                #"\bprotocol\s+(\w+)\b[^{]*?:"# + rest + word] {
                    guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                    for copy in copies {
                        for match in regex.matches(in: copy, range: NSRange(copy.startIndex..., in: copy)) {
                            guard let range = Range(match.range(at: 1), in: copy) else { continue }
                            if names.insert(String(copy[range])).inserted { grew = true }
                        }
                    }
                }
            }
        }
        return names
    }

    /// One declaration at a time: a right-hand side or a clause may run onto
    /// the next line, but never into another declaration.
    static let oneDeclaration = #"(?:(?!\b(?:typealias|protocol|struct|class|actor|enum|extension|func|var|let)\b)[^{};])*?"#

    /// The class route to a seam, banned outright (the S-PAIR-C1 security
    /// review's R2). Fixtures/ may adopt `seam` — or any other name for it
    /// (`seamNames`) — only in the declaration of a type nothing can inherit
    /// from: a `struct`, an `enum`, an `actor` or a `final class`. A plain
    /// class there let a live `final class` subclass it and inherit the seam
    /// with no seam in its own clause (P3, P4); an extension there could hand
    /// the seam to a class declared anywhere, live ones included. (Banned at
    /// the source rather than chased by name: no spelling of the live
    /// subclass — an alias, a generic, a module prefix — matters then.)
    /// Every fixture conformer is an actor, a struct or a final class.
    /// Read in every constructor scan copy: a `final` in a block comment is
    /// no `final`.
    ///
    /// AMENDED (S-PAIR-C1.5, #170, the C1 security delta check's (e)):
    /// a `final` counts only as a modifier ON THE CLASS'S OWN LINE (its
    /// attributes and an access level beside it, spaces between). The old
    /// check read any `final` ending the text before the class, so an
    /// identifier named `final` ending the line above (PN1:
    /// `ReviewerFlags.final`, then a plain `class` adopting the writer) made
    /// the class look final. And every `final` in Fixtures/ must be such a
    /// modifier: a name spelled `final` there is a failure in itself.
    static let finalModifier = #"\bfinal[ \t]+(?:(?:public|package|internal|fileprivate|private)[ \t]+)?class\b"#
    static let finalClassLine =
        #"^[ \t]*(?:@\w+(?:\([^)\n]*\))?[ \t]+)*(?:(?:public|package|internal|fileprivate|private)[ \t]+)?final[ \t]+"#
            + #"(?:(?:public|package|internal|fileprivate|private)[ \t]+)?$"#

    static func fixtureConformerFailures(_ seam: String, in app: [Source]) -> [String] {
        let names = seamNames(seam, in: app).sorted()
        var failures: [String] = []
        for (path, text) in app where path.hasPrefix("\(appDir)/Fixtures/") {
            for copy in constructorScanCopies(codeOnly(text)) {
                if matchCount(#"\bfinal\b"#, in: copy) != matchCount(finalModifier, in: copy) {
                    failures.append("\(path) spells `final` other than as its class's modifier on the class's own line — "
                                    + "an identifier named final could pass for one")
                }
                for name in names {
                    // Each header on its own, `oneDeclaration` at a time, so no
                    // other declaration's match swallows it (`class func` and
                    // its kin declare a member, not a class).
                    let clause = oneDeclaration + ":" + oneDeclaration + #"\b"# + name + #"\b"#
                    let classHead = #"\bclass\s+(?!(?:func|var|let|subscript|override|final)\b)\w+"# + clause
                    let extensionHead = #"\bextension\b"# + clause
                    if hits(extensionHead, in: copy) {
                        failures.append("\(path) adopts \(name) by an extension — it could hand the seam to any class; "
                                        + "a fixture adopts a seam in its own declaration")
                    }
                    guard let regex = try? NSRegularExpression(pattern: classHead) else { continue }
                    for match in regex.matches(in: copy, range: NSRange(copy.startIndex..., in: copy)) {
                        guard let range = Range(match.range, in: copy) else { continue }
                        // The class keyword's own line, up to the keyword.
                        let line = copy[..<range.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
                        if hits(finalClassLine, in: String(line)) { continue }
                        failures.append("\(path) adopts \(name) in a class that is not final — a live subclass would inherit "
                                        + "the seam unseen; a fixture conformer is a struct, an enum, an actor or a final class")
                    }
                }
            }
        }
        return unique(failures)
    }

    /// `failures` without repeats, in order.
    static func unique(_ failures: [String]) -> [String] {
        var seen = Set<String>()
        return failures.filter { seen.insert($0).inserted }
    }

    // MARK: Lexing (issue #155: a `//` inside a string literal is not a comment)
    //
    // The Mac's twin is LidGuardStructureTests.lexemes; keep the two alike.

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
    /// `f()/2`) is never one.
    static func bareRegexOpens(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        let next = index + 1
        guard next < scalars.count, !scalars[next].properties.isWhitespace, scalars[next] != "=" else { return false }
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
        while cursor < scalars.count, !isLineEnd(scalars[cursor]) {
            if scalars[cursor] == "\\" {
                cursor += 2
                continue
            }
            if scalars[cursor] == "/" { return true }
            cursor += 1
        }
        return false
    }

    /// An import of the CloudKit module in ANY form: `import CloudKit`,
    /// `@_exported import CloudKit`, a scoped `import class CloudKit.X`, split
    /// over lines, with a block comment between the words, or with a trailing
    /// `//` comment ending a line inside it (`import // note`, then `CloudKit`
    /// on the next line: the security re-check, N2). The literal "import
    /// CloudKit" missed the scoped form (security review 2, G2).
    static let cloudKitImport: String = {
        let gap = #"(?:\s|/\*[\s\S]*?\*/|//[^\n]*)+"#
        return #"\bimport"# + gap + #"(?:\w+"# + gap + #")?`?CloudKit\b"#
    }()

    static func occurrences(of token: String, in text: String) -> Int {
        text.components(separatedBy: token).count - 1
    }

    /// How many times `pattern` matches in `text`.
    static func matchCount(_ pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return -1 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// From a declaration line to the first closing brace at its indentation.
    static func body(after head: String, in code: String) -> String? {
        guard let start = code.range(of: head) else { return nil }
        let lineStart = code[..<start.lowerBound].lastIndex(of: "\n").map { code.index(after: $0) } ?? code.startIndex
        let indent = String(code[lineStart..<start.lowerBound].prefix { $0 == " " })
        let tail = code[start.upperBound...]
        guard let end = tail.range(of: "\n\(indent)}") else { return nil }
        return String(tail[..<end.lowerBound])
    }

    // MARK: Rule 1: the wire is spelled once

    static let wireIdentifiers = [AlertWire.subscriptionID, AlertWire.containerIdentifier]
    /// The record keys and lane values as quoted literals.
    static let wireKeys = ([AlertWire.recordType] + AlertWire.Field.allCases.map(\.rawValue)
        + AlertWire.Lane.allCases.map(\.rawValue)).map { "\"\($0)\"" }

    /// `scanned`: both apps' sources and these tests. `receiver`: the
    /// receiver app's sources only.
    static func wireFailures(scanned: [Source], receiver: [Source]) -> [String] {
        var failures: [String] = []
        for identifier in wireIdentifiers {
            let holders = scanned.filter { $0.text.contains(identifier) }.map(\.path)
            if holders != [wireFile] {
                failures.append("'\(identifier)' is spelled in \(holders), expected only \(wireFile)")
            }
        }
        for (path, text) in receiver {
            for key in wireKeys where codeOnly(text).contains(key) {
                failures.append("\(path) spells the wire key \(key); use AlertWire")
            }
        }
        return failures
    }

    static func scannedSources() throws -> [Source] {
        try swiftFiles(under: "Sources") + swiftFiles(under: appDir) + swiftFiles(under: testsDir)
    }

    @Test func theScanSeesTheRepository() throws {
        let paths = try Self.scannedSources().map(\.path)
        #expect(paths.contains(Self.wireFile))
        #expect(paths.contains(Self.cloudKitFile))
        #expect(paths.contains("\(Self.testsDir)/CloudKitStructureTests.swift"))
        #expect(paths.contains("Sources/NapCat/CloudKitMessageSender.swift"))
    }

    @Test func theWireIsSpelledOnlyInNapCatWire() throws {
        let failures = Self.wireFailures(scanned: try Self.scannedSources(), receiver: try Self.swiftFiles(under: Self.appDir))
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test func theWireRuleCatchesACopiedLiteral() throws {
        let receiver = try Self.swiftFiles(under: Self.appDir)
        let pasted = receiver.map { source -> Source in
            source.path == Self.cloudKitFile
                ? (source.path, source.text + "\nlet id = \"\(AlertWire.subscriptionID)\"\nlet key = \"\(AlertWire.Field.firedAt.rawValue)\"\n")
                : source
        }
        let failures = Self.wireFailures(scanned: try Self.scannedSources().filter { $0.path != Self.cloudKitFile }
            + pasted.filter { $0.path == Self.cloudKitFile }, receiver: pasted)
        #expect(failures.contains { $0.contains(AlertWire.subscriptionID) })
        #expect(failures.contains { $0.contains("\"\(AlertWire.Field.firedAt.rawValue)\"") })
    }

    // MARK: Rule 2: one CloudKit file, one container site, behind the gate

    static func containerFailures(receiver: [Source], tests: [Source]) -> [String] {
        var failures: [String] = []
        let constructor = container + "("
        let sites = receiver.flatMap { source in
            Array(repeating: source.path, count: occurrences(of: constructor, in: codeOnly(source.text)))
        }
        if sites != [cloudKitFile, cloudKitFile] {
            failures.append("\(constructor) appears at \(sites), expected exactly twice, in \(cloudKitFile)")
        }
        for (path, text) in receiver + tests {
            for token in [container + ".default", container + ".init", container + ".self"]
            where codeOnly(text).contains(token) {
                failures.append("\(token) in \(path): makeLive() is the only route to a container")
            }
        }
        for (path, text) in tests where codeOnly(text).contains(constructor) {
            failures.append("\(path) builds a container; tests use fixture databases only")
        }
        for (path, text) in receiver where path != cloudKitFile
            && wholeLineCommentsRemoved(text).range(of: cloudKitImport, options: .regularExpression) != nil {
            failures.append("\(path) imports CloudKit; only \(cloudKitFile) may")
        }
        let file = codeOnly(receiver.first { $0.path == cloudKitFile }?.text ?? "")
        for head in factoryHeads {
            guard let factory = body(after: head, in: file) else {
                failures.append("'\(head)' not found in \(cloudKitFile)")
                continue
            }
            let statements = factory.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if statements.first != capabilityGuard {
                failures.append("'\(head)' must open with '\(capabilityGuard)', found '\(statements.first ?? "")'")
            }
            if occurrences(of: constructor, in: factory) != 1 {
                failures.append("'\(head)' must build exactly one \(constructor)")
            }
        }
        return failures
    }

    /// `containerFailures` over the sources as given, their cleaned copies,
    /// and the construction spelling of each (#153): a spaced, backticked or
    /// comment-split container construction is a construction too.
    static func containerFailuresInEveryCopy(receiver: [Source], tests: [Source]) -> [String] {
        func spelled(_ sources: [Source]) -> [Source] { sources.map { ($0.path, RecordPathStructureTests.constructionSpelling($0.text)) } }
        func code(_ sources: [Source]) -> [Source] { sources.map { ($0.path, codeOnly($0.text)) } }   // stripped once
        let receivers = constructorScanCopies(code(receiver))
        let testers = constructorScanCopies(code(tests))
        // Copy for copy; a set that is its own cleaned copy (one entry) stands
        // for all three. (Never `zip`: it would drop the other set's copies.)
        return unique((0..<max(receivers.count, testers.count)).flatMap { index in
            let receiver = receivers[min(index, receivers.count - 1)]
            let tests = testers[min(index, testers.count - 1)]
            return containerFailures(receiver: receiver, tests: tests)
                + containerFailures(receiver: spelled(receiver), tests: spelled(tests))
        })
    }

    @Test func aContainerIsBuiltOnceBehindTheCapabilityGate() throws {
        let failures = Self.containerFailuresInEveryCopy(receiver: try Self.swiftFiles(under: Self.appDir),
                                                         tests: try Self.swiftFiles(under: Self.testsDir))
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test func theContainerRuleCatchesEachBreach() throws {
        let receiver = try Self.swiftFiles(under: Self.appDir)
        let tests = try Self.swiftFiles(under: Self.testsDir)
        func mutated(_ transform: (String) -> String) -> [Source] {
            receiver.map { $0.path == Self.cloudKitFile ? ($0.path, transform($0.text)) : $0 }
        }
        // The guard removed.
        let unguarded = mutated { $0.replacingOccurrences(of: Self.capabilityGuard, with: "") }
        #expect(!Self.containerFailures(receiver: unguarded, tests: tests).isEmpty)
        // A third construction site.
        let second = mutated { $0 + "\nlet spare = \(Self.container)(identifier: \"x\")\n" }
        #expect(!Self.containerFailures(receiver: second, tests: tests).isEmpty)
        // S-PAIR-C1.6 (#172): the approvals factory alone unguarded, or its
        // construction moved out of it to a third site.
        let approvalsHead = Self.factoryHeads[1] + "\n        " + Self.capabilityGuard + "\n"
        let approvalsUnguarded = mutated { $0.replacingOccurrences(of: approvalsHead, with: Self.factoryHeads[1] + "\n") }
        #expect(approvalsUnguarded.map { $0.text } != receiver.map { $0.text }, "canary 'the approvals factory unguarded' did not apply")
        #expect(!Self.containerFailures(receiver: approvalsUnguarded, tests: tests).isEmpty,
                "canary 'the approvals factory unguarded' was NOT caught")
        let moved = mutated {
            $0.replacingOccurrences(of: "        let container = \(Self.container)(identifier: ApprovalWire.containerIdentifier)\n"
                                        + "        return LiveCloudKitApprovalDatabase(container: container)\n",
                                    with: "        return LiveCloudKitApprovalDatabase(container: spareContainer)\n")
                + "\nlet spareContainer = \(Self.container)(identifier: ApprovalWire.containerIdentifier)\n" }
        #expect(moved.map { $0.text } != receiver.map { $0.text }, "canary 'the approvals container built outside its factory' did not apply")
        #expect(!Self.containerFailures(receiver: moved, tests: tests).isEmpty,
                "canary 'the approvals container built outside its factory' was NOT caught")
        // CloudKit imported elsewhere in the app.
        let leaked = receiver.map { $0.path.hasSuffix("AlertFeed.swift") ? ($0.path, "import CloudKit\n" + $0.text) : $0 }
        #expect(!Self.containerFailures(receiver: leaked, tests: tests).isEmpty)
        // … in any form (security review 2, G2): scoped, re-exported, split;
        // and split by a trailing comment (the security re-check, N2).
        for importLine in ["import class CloudKit.CKModifyRecordsOperation", "@_exported import CloudKit",
                           "import\n    struct\n    CloudKit.CKRecordZone", "import /* ops */ CloudKit",
                           "import // fetch only\n    CloudKit", "import class // one type only\n    CloudKit.CKFetchRecordsOperation"] {
            let scoped = receiver.map { $0.path.hasSuffix("AlertFeed.swift") ? ($0.path, importLine + "\n" + $0.text) : $0 }
            #expect(!Self.containerFailures(receiver: scoped, tests: tests).isEmpty, "canary '\(importLine)' was NOT caught")
        }
        // #155: a URL in a string literal no longer hides the rest of its line.
        let behindURL = mutated { $0 + "\nlet u = \"https://www.icloud.com\"; let spare = \(Self.container)(identifier: \"x\")\n" }
        #expect(!Self.containerFailures(receiver: behindURL, tests: tests).isEmpty, "canary 'a site behind a URL' was NOT caught")
        // Security spot-check H9, as planted (R-H9-PHONE): a bare regex after
        // `switch` holding a quote, then the URL, then the site.
        let afterRegex = mutated { $0 + "\nprivate func h9() { switch /\"/ { default: let u = \"https://x\"; "
            + "_ = (u, \(Self.container)(identifier: AlertWire.containerIdentifier)) } }\n" }
        #expect(!Self.containerFailures(receiver: afterRegex, tests: tests).isEmpty,
                "canary 'H9a: a site behind a URL after a bare regex' was NOT caught")
        // A test that builds a container.
        let rogue = tests + [("\(Self.testsDir)/Rogue.swift", "let c = \(Self.container)(identifier: \"x\")")]
        #expect(!Self.containerFailures(receiver: receiver, tests: rogue).isEmpty)
        // #153: however the construction is spelled (the container's name is
        // split here too: no test spells its constructor).
        for planted in [Self.container + " (identifier: \"x\")", "`" + Self.container + "`(identifier: \"x\")",
                        Self.container + "/* x */(identifier: \"x\")", Self.container + " . init(identifier: \"x\")"] {
            let spare = mutated { $0 + "\nlet spare = " + planted + "\n" }
            #expect(!Self.containerFailuresInEveryCopy(receiver: spare, tests: tests).isEmpty, "canary '\(planted)' was NOT caught")
        }
        let backtickedTest = tests + [("\(Self.testsDir)/Rogue.swift", "let c = `" + Self.container + "`(identifier: \"x\")")]
        #expect(!Self.containerFailuresInEveryCopy(receiver: receiver, tests: backtickedTest).isEmpty,
                "canary 'a test builds a backticked container' was NOT caught")
        // A comment naming the constructor is fine.
        let commented = mutated { $0 + "\n// \(Self.container)(identifier:) traps unentitled\n" }
        #expect(Self.containerFailures(receiver: commented, tests: tests).isEmpty)
        // So is a whole-line comment naming the import, elsewhere in the app.
        let noted = receiver.map {
            $0.path.hasSuffix("AlertFeed.swift") ? ($0.path, "/// never import class CloudKit.CKRecord here\n" + $0.text) : $0
        }
        #expect(Self.containerFailures(receiver: noted, tests: tests).isEmpty)
    }

    // MARK: Rule 3: the alert lane's one database write is the subscription save (#153)

    /// The CloudKit file holds the alert lane (a sanctioned private-database
    /// reader that saves ONE thing, its push subscription) and the decision
    /// record path (RecordPathStructureTests). In the security re-check a
    /// `LiveCloudKitAlertDatabase` extension saved a `CKRecord.init` decision
    /// straight to the private database, and every suite passed. So the
    /// file's database writes are confined by allow-lists, as the Mac's
    /// record path's are: its CloudKit identifiers are exact (another door
    /// fails by default); `save` is named only by the subscription's seam and
    /// its one live save; the private database is reached only by the live
    /// database's four configured requests; the subscription goes only to
    /// that save; and no other database write, other database or `add` is
    /// named at all (`add` as a word: an extension's implicit self names no
    /// dot).
    static let cloudKitIdentifiers: Set<String> = [
        "CKAccountStatus", "CKContainer", "CKCurrentUserDefaultName", "CKError", "CKErrorDomain", "CKModifyRecordsOperation",
        "CKNotification", "CKOperation", "CKPartialErrorsByItemIDKey", "CKQuery", "CKQueryNotification",
        "CKQuerySubscription", "CKRecord", "CKRecordValue", "CKRecordZone", "CKSubscription",
    ]

    static let configuredDatabase = "try await container.privateCloudDatabase.configuredWith(configuration: configuration) { database in"
    static let subscriptionSave = "try await database.save(Self.makeSubscription())"

    /// S-PAIR-C1.6 (#172): the live approvals database (the record path's
    /// seam's one app conformer) reads the private database on this line
    /// and runs what it admits on its `add` lines, nowhere else.
    static let approvalsDatabaseRead = "container.privateCloudDatabase.add(operation)"
    static let approvalsAddSites: [String: Int] = ["container.privateCloudDatabase.add(operation)": 1]

    static let alertLaneSites: [(pattern: String, sites: [String: Int], rule: String)] = [
        (#"\bsave\b"#, [subscriptionSave: 1, "func save(_ subscription: CKSubscription) async throws": 1,
                        "func save(_ subscription: CKSubscription) async throws {": 1, "try await database.save(subscription)": 1],
         "the one save is the subscription's"),
        (#"\bprivateCloudDatabase\b"#, [configuredDatabase: 3, "_ = " + configuredDatabase: 1, approvalsDatabaseRead: 1],
         "the private database is reached only by the live databases: the alerts' configured requests, the approvals' one read"),
        (#"\badd\b"#, approvalsAddSites, "only the live approvals database adds an operation, on its pinned lines"),
        (#"\bconfiguredWith\b"#, [configuredDatabase: 3, "_ = " + configuredDatabase: 1],
         "a configured database comes only from the private one"),
        (#"\bmakeSubscription\b"#, ["static func makeSubscription() -> CKQuerySubscription {": 1, subscriptionSave: 1],
         "the subscription goes only to the one save"),
    ]

    /// Named nowhere in the CloudKit file: every other database write, the
    /// other databases, and `add`. AMENDED (S-PAIR-C1.6, #172): `add` moves
    /// to `alertLaneSites`, pinned to the live approvals database's lines.
    static let alertLaneBans = [
        #"\b(?:modifyRecords|modifySubscriptions|modifyRecordZones|delete|deleteRecord|deleteSubscription|deleteRecordZone)\b"#,
        #"\b(?:publicCloudDatabase|sharedCloudDatabase)\b"#, #"\bdatabase\s*\(\s*with\b"#,
    ]

    static func alertLaneWriteFailures(receiver: [Source]) -> [String] {
        let file = wholeLineCommentsRemoved(receiver.first { $0.path == cloudKitFile }?.text ?? "")
        var failures: [String] = []
        let named = Set(matches(#"\bCK\w*"#, in: file))
        for identifier in named.subtracting(cloudKitIdentifiers).sorted() {
            failures.append("'\(identifier)' in \(cloudKitFile) — not on the CloudKit file's allow-list")
        }
        for identifier in cloudKitIdentifiers.subtracting(named).sorted() {
            failures.append("'\(identifier)' is allow-listed but unused in \(cloudKitFile) — the list stays exact")
        }
        for (pattern, sites, rule) in alertLaneSites {
            failures += siteFailures(pattern, in: file, file: cloudKitFile, allowed: sites, rule: rule)
        }
        for (path, text) in receiver where path != cloudKitFile && hits(#"\bmakeSubscription\b"#, in: wholeLineCommentsRemoved(text)) {
            failures.append("\(path) reaches the push subscription — only the CloudKit file saves it")
        }
        for pattern in alertLaneBans where hits(pattern, in: file) {
            failures.append("'\(pattern)' in \(cloudKitFile) — the alert lane's one write is the subscription save")
        }
        return failures
    }

    @Test func theAlertLanesOneWriteIsTheSubscriptionSave() throws {
        let receiver = try Self.swiftFiles(under: Self.appDir)
        #expect(Self.alertLaneWriteFailures(receiver: receiver).isEmpty, "\(Self.alertLaneWriteFailures(receiver: receiver))")
        func mutated(_ transform: (String) -> String) -> [Source] {
            receiver.map { $0.path == Self.cloudKitFile ? ($0.path, transform($0.text)) : $0 }
        }
        let mutants: [(String, [Source])] = [
            // The security re-check (#146), the phone's alert-lane plant, as planted.
            ("the live database extended to save a decision", mutated {
                $0 + "\nextension LiveCloudKitAlertDatabase {\n    func alertLaneProbe(_ p: PromptID) async throws {\n"
                    + "        _ = try await container.privateCloudDatabase.save(CKRecord.init(recordType: "
                    + "ApprovalWire.RecordType.decision.rawValue,\n            recordID: CloudKitAlertSource.decisionRecordID(for: p)))\n    }\n}" }),
            // … and the doors around it.
            ("a record saved through a configured database", mutated {
                $0.replacingOccurrences(of: "try await database.save(subscription)",
                                        with: "try await database.save(subscription)\n            _ = try await database.save(spare)") }),
            ("a batch modify", mutated {
                $0 + "\nextension LiveCloudKitAlertDatabase { func f(_ r: CKRecord) async throws { "
                    + "_ = try await container.privateCloudDatabase.modifyRecords(saving: [r], deleting: []) } }" }),
            ("a subscription deleted", mutated {
                $0 + "\nextension LiveCloudKitAlertDatabase { func f() async throws { "
                    + "_ = try await container.privateCloudDatabase.deleteSubscription(withID: \"x\") } }" }),
            ("an add on the database's implicit self", mutated {
                $0 + "\nextension CKDatabase { func go(_ o: CKDatabaseOperation) { add(o) } }" }),
            ("the private database held", mutated {
                $0 + "\nextension LiveCloudKitAlertDatabase { var spare: Any { container.privateCloudDatabase } }" }),
            ("the shared database", mutated {
                $0 + "\nextension LiveCloudKitAlertDatabase { var spare: Any { container.sharedCloudDatabase } }" }),
            ("a second subscription saved", mutated {
                $0 + "\nextension CloudKitAlertSource { func f() async throws { try await database.save(Self.makeSubscription()) } }" }),
            ("the subscription built elsewhere", receiver.map {
                $0.path.hasSuffix("AlertFeed.swift") ? ($0.path, $0.text + "\nlet s = CloudKitAlertSource.makeSubscription()") : $0 }),
            ("a zone door", mutated { $0 + "\nlet z = CKModifyRecordZonesOperation(recordZonesToSave: [], recordZoneIDsToDelete: nil)" }),
            // S-PAIR-C1.6 (#172): the live approvals database's adds are
            // pinned — a second one beside its own, and one in the alerts'
            // live database.
            ("a second add in the approvals database", mutated {
                $0.replacingOccurrences(of: "        " + Self.approvalsDatabaseRead + "\n",
                                        with: "        " + Self.approvalsDatabaseRead + "\n        container.privateCloudDatabase.add(spare)\n") }),
            ("an add in the alerts' live database", mutated {
                $0 + "\nextension LiveCloudKitAlertDatabase { func spare(_ o: CKModifyRecordsOperation) { "
                    + Self.approvalsDatabaseRead.replacingOccurrences(of: "(operation)", with: "(o)") + " } }" }),
            ("an allow-listed identifier dropped", mutated {
                $0.replacingOccurrences(of: "ownerName: CKCurrentUserDefaultName", with: "ownerName: \"__defaultOwner__\"") }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != receiver.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.alertLaneWriteFailures(receiver: mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        let probes = ["db.deleteRecord(withID: i)", "c.publicCloudDatabase", "c.database(with: .shared)"]
        #expect(probes.count == Self.alertLaneBans.count)
        for (pattern, probe) in zip(Self.alertLaneBans, probes) {
            #expect(Self.hits(pattern, in: probe), "'\(pattern)' does not match '\(probe)'")
        }
        // Over-match controls: words that only contain a banned one, and a
        // whole-line comment naming what it rules out.
        #expect(Self.alertLaneWriteFailures(receiver: mutated {
            $0 + "\nfunc f(d: Date) -> Date { d.addingTimeInterval(1) }\nlet saved = 1, savePolicyName = \"x\", toDelete = 0"
                + "\n/// never database.save(record), never modifyRecords, never add(operation)\n"
        }).isEmpty)
    }

    // MARK: The strippers themselves (#155)

    /// As the Mac's `theStrippersReadLiteralsAndComments`: a `//` in a string,
    /// raw string, interpolation, block comment or regex literal opens no
    /// comment; a real trailing or doc comment still goes; CR and CRLF end a
    /// line.
    @Test func theStrippersReadLiteralsAndComments() {
        let codeOnlyCases: [(String, String, String)] = [
            // (No test spells the container constructor, rule 2: a neutral token.)
            ("a URL, then a token", "let u = \"https://x\"; let c = tokenZ(identifier: i) // note",
             "let u = \"https://x\"; let c = tokenZ(identifier: i) "),
            ("an escaped quote", "let a = \"\\\"//\"; tokenA // c", "let a = \"\\\"//\"; tokenA "),
            ("a string inside an interpolation", "let a = \"\\(f(\"(\", \"//\"))\"; tokenC // c",
             "let a = \"\\(f(\"(\", \"//\"))\"; tokenC "),
            ("a quote inside a raw string", "let r = #\"a\"//\"#; tokenE // c", "let r = #\"a\"//\"#; tokenE "),
            ("a multi-line string", "let m = \"\"\"\n// not a comment\n\"\"\"\ntokenG // z", "let m = \"\"\"\n// not a comment\n\"\"\"\ntokenG "),
            ("a nested block comment", "/* a /* b */ // in */ tokenI // c", "/* a /* b */ // in */ tokenI "),
            ("a bare regex holding a quote", "let r = /\"/; tokenL // c", "let r = /\"/; tokenL "),
            ("a division is no regex", "let q = a / b // half\nlet h = n/2 // c", "let q = a / b \nlet h = n/2 "),
            ("CRLF line ends", "// c\r\nlet x = tokenN // c\r\n", "\r\nlet x = tokenN \r\n"),
            ("a doc comment", "/// doc tokenO\nlet x = 1", "\nlet x = 1"),
            // Security spot-check H9 (as the Mac's table): a bare regex after
            // `switch` holding a quote is a regex, spaced or not.
            ("H9a: a bare regex after switch holding a quote", "switch /\"/ { default: let u = \"https://x\"; tokenT } // c",
             "switch /\"/ { default: let u = \"https://x\"; tokenT } "),
            ("a bare regex right after switch", "switch/\"/ { default: let u = \"https://x\"; tokenU } // c",
             "switch/\"/ { default: let u = \"https://x\"; tokenU } "),
        ]
        for (name, text, code) in codeOnlyCases {
            #expect(Self.codeOnly(text) == code, "codeOnly, \(name): \(Self.codeOnly(text).debugDescription)")
        }
        let wholeLineCases: [(String, String, String)] = [
            ("a whole-line comment goes, a trailing one stays", "// c\n  /// d\nlet x = 1 // t", "\n\nlet x = 1 // t"),
            ("a multi-line string line opening with //", "let m = \"\"\"\n// \\(tokenP)\n\"\"\"", "let m = \"\"\"\n// \\(tokenP)\n\"\"\""),
            ("CRLF line ends", "// c\r\nlet x = tokenR\r\n", "\r\nlet x = tokenR\r\n"),
            ("H9: a multi-line string after a bare regex holding \"\"\"",
             "switch /\"\"\"/ { default: break }\nlet s = \"\"\"\n// \\(tokenX)\n\"\"\"\nswitch /\"\"\"/ { default: break }",
             "switch /\"\"\"/ { default: break }\nlet s = \"\"\"\n// \\(tokenX)\n\"\"\"\nswitch /\"\"\"/ { default: break }"),
        ]
        for (name, text, uncut) in wholeLineCases {
            #expect(Self.wholeLineCommentsRemoved(text) == uncut,
                    "wholeLineCommentsRemoved, \(name): \(Self.wholeLineCommentsRemoved(text).debugDescription)")
        }
    }
}
