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
/// 2. CloudKit lives in ONE receiver file, and a container is built at ONE
///    site, `makeLive()`, whose first statement is the `LiveCapability`
///    guard (an unentitled construction traps). No test names a container
///    constructor at all.
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
    static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.range(of: "//").map { line[..<$0.lowerBound] } ?? line }
            .joined(separator: "\n")
    }

    static func occurrences(of token: String, in text: String) -> Int {
        text.components(separatedBy: token).count - 1
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
        for (path, text) in receiver where path != cloudKitFile && codeOnly(text).contains("import CloudKit") {
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
        // A test that builds a container.
        let rogue = tests + [("\(Self.testsDir)/Rogue.swift", "let c = \(Self.container)(identifier: \"x\")")]
        #expect(!Self.containerFailures(receiver: receiver, tests: rogue).isEmpty)
        // A comment naming the constructor is fine.
        let commented = mutated { $0 + "\n// \(Self.container)(identifier:) traps unentitled\n" }
        #expect(Self.containerFailures(receiver: commented, tests: tests).isEmpty)
    }
}
