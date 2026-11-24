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
///    names a container constructor at all.
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
    static let factoryHead = "static func makeLive() -> CloudKitAlertSource? {"
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
    /// literal ends with its line even when unterminated, so a misreading
    /// never outlives its line. Every misreading either keeps text (which
    /// only over-matches) or cuts at a `//` the old line cut cut at too.
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
    /// line, or an operator, an opening bracket, a separator or a keyword
    /// that precedes an expression), no space follows it, and an unescaped
    /// `/` closes it on the same line. A division (`a / b`, `n/2`, `f()/2`)
    /// is never one.
    static func bareRegexOpens(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        let next = index + 1
        guard next < scalars.count, !scalars[next].properties.isWhitespace, scalars[next] != "=" else { return false }
        var before = index - 1
        while before >= 0, scalars[before] == " " || scalars[before] == "\t" { before -= 1 }
        var opens = before < 0 || isLineEnd(scalars[before]) || "([{,:;=!&|?^~<>+-*%".unicodeScalars.contains(scalars[before])
        if !opens, scalars[before].properties.isAlphabetic {
            var wordStart = before
            while wordStart > 0, scalars[wordStart - 1].properties.isAlphabetic { wordStart -= 1 }
            let word = String(String.UnicodeScalarView(scalars[wordStart...before]))
            let identifierChar = wordStart > 0 && (scalars[wordStart - 1] == "_" || scalars[wordStart - 1].properties.numericType != nil)
            opens = !identifierChar && ["return", "in", "throw", "try", "await", "case", "where", "if", "guard", "while",
                                        "else", "is", "as", "repeat", "some", "any"].contains(word)
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
        if sites != [cloudKitFile] {
            failures.append("\(constructor) appears at \(sites), expected exactly once, in \(cloudKitFile)")
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
        guard let factory = body(after: factoryHead, in: file) else {
            failures.append("'\(factoryHead)' not found in \(cloudKitFile)")
            return failures
        }
        let statements = factory.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if statements.first != capabilityGuard {
            failures.append("makeLive must open with '\(capabilityGuard)', found '\(statements.first ?? "")'")
        }
        if occurrences(of: constructor, in: factory) != 1 {
            failures.append("the one \(constructor) must be inside makeLive")
        }
        return failures
    }

    @Test func aContainerIsBuiltOnceBehindTheCapabilityGate() throws {
        let failures = Self.containerFailures(receiver: try Self.swiftFiles(under: Self.appDir),
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
        // A second construction site.
        let second = mutated { $0 + "\nlet spare = \(Self.container)(identifier: \"x\")\n" }
        #expect(!Self.containerFailures(receiver: second, tests: tests).isEmpty)
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
        // A test that builds a container.
        let rogue = tests + [("\(Self.testsDir)/Rogue.swift", "let c = \(Self.container)(identifier: \"x\")")]
        #expect(!Self.containerFailures(receiver: receiver, tests: rogue).isEmpty)
        // A comment naming the constructor is fine.
        let commented = mutated { $0 + "\n// \(Self.container)(identifier:) traps unentitled\n" }
        #expect(Self.containerFailures(receiver: commented, tests: tests).isEmpty)
        // So is a whole-line comment naming the import, elsewhere in the app.
        let noted = receiver.map {
            $0.path.hasSuffix("AlertFeed.swift") ? ($0.path, "/// never import class CloudKit.CKRecord here\n" + $0.text) : $0
        }
        #expect(Self.containerFailures(receiver: noted, tests: tests).isEmpty)
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
        ]
        for (name, text, code) in codeOnlyCases {
            #expect(Self.codeOnly(text) == code, "codeOnly, \(name): \(Self.codeOnly(text).debugDescription)")
        }
        let wholeLineCases: [(String, String, String)] = [
            ("a whole-line comment goes, a trailing one stays", "// c\n  /// d\nlet x = 1 // t", "\n\nlet x = 1 // t"),
            ("a multi-line string line opening with //", "let m = \"\"\"\n// \\(tokenP)\n\"\"\"", "let m = \"\"\"\n// \\(tokenP)\n\"\"\""),
            ("CRLF line ends", "// c\r\nlet x = tokenR\r\n", "\r\nlet x = tokenR\r\n"),
        ]
        for (name, text, uncut) in wholeLineCases {
            #expect(Self.wholeLineCommentsRemoved(text) == uncut,
                    "wholeLineCommentsRemoved, \(name): \(Self.wholeLineCommentsRemoved(text).debugDescription)")
        }
    }
}
