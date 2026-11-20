// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// F3 stage 1 — structural locks for the CloudKit transport, each
/// canary-proven in-suite (a mutated copy of the shipped sources must trip the
/// rule; a comment naming the token must not), in the style of
/// `ConnectivityStructureTests`.
///
/// The headline lock: `CKContainer(identifier:)` TRAPS in an unentitled
/// process (spike-proven), and ad-hoc `make` builds are unentitled by design.
/// So a container is constructed at exactly ONE site, in the one sanctioned
/// file, inside `makeLiveStore()`, whose FIRST statement is the entitlement
/// probe's guard — and nothing else can build the live store.
struct PhoneTransportStructureTests {
    static let cloudKitFile = "CloudKitMessageSender.swift"
    static let factoryHead = "static func makeLiveStore() -> (any CloudKitAlertStore)? {"
    static let probeGuard = "guard CloudKitEntitlementProbe.isEntitled else { return nil }"

    static func sources() throws -> [(name: String, text: String)] {
        try LidGuardStructureTests.swiftSources()
    }

    static func mutate(_ sources: [(name: String, text: String)], _ name: String,
                       _ transform: (String) -> String) -> [(name: String, text: String)] {
        sources.map { $0.name == name ? ($0.name, transform($0.text)) : $0 }
    }

    /// The body of a function from its declaration line to the first closing
    /// brace at the declaration's own indentation.
    static func body(after head: String, in code: String) -> String? {
        guard let start = code.range(of: head) else { return nil }
        let lineStart = code[..<start.lowerBound].lastIndex(of: "\n").map { code.index(after: $0) } ?? code.startIndex
        let indent = String(code[lineStart..<start.lowerBound].prefix { $0 == " " })
        let tail = code[start.upperBound...]
        guard let end = tail.range(of: "\n\(indent)}") else { return nil }
        return String(tail[..<end.lowerBound])
    }

    static func occurrences(of token: String, in text: String) -> Int {
        text.components(separatedBy: token).count - 1
    }

    static func containerConstructionFailures(_ sources: [(name: String, text: String)]) -> [String] {
        var failures: [String] = []
        // 1. ONE construction site, repo wide, in the sanctioned file.
        let sites = sources.flatMap { source in
            Array(repeating: source.name, count: occurrences(of: "CKContainer(", in: source.text))
        }
        if sites != [cloudKitFile] {
            failures.append("CKContainer( appears at \(sites) — expected exactly once, in \(cloudKitFile)")
        }
        // 2. No other way to reach a container.
        for (name, text) in sources {
            for token in ["CKContainer.default", "CKContainer.init", "CKContainer.self"] where text.contains(token) {
                failures.append("'\(token)' in \(name) — the probe-gated factory is the only route to a container")
            }
        }
        // 3. That site sits inside makeLiveStore, behind the probe guard,
        //    which is the function's FIRST statement.
        let file = sources.first { $0.name == cloudKitFile }?.text ?? ""
        if let factory = body(after: factoryHead, in: file) {
            let statements = factory.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if statements.first != probeGuard {
                failures.append("makeLiveStore must open with '\(probeGuard)' — found '\(statements.first ?? "")'")
            }
            if occurrences(of: "CKContainer(", in: factory) != 1 {
                failures.append("the one CKContainer( must be inside makeLiveStore")
            }
            if let guardAt = factory.range(of: probeGuard), let buildAt = factory.range(of: "CKContainer("),
               buildAt.lowerBound < guardAt.upperBound {
                failures.append("the container is built before the probe guard")
            }
        } else {
            failures.append("'\(factoryHead)' not found in \(cloudKitFile)")
        }
        // 4. The live store (which holds the container) is built only there,
        //    and the factory is reached only from the sanctioned file.
        let storeSites = sources.flatMap { source in
            Array(repeating: source.name, count: occurrences(of: "LiveCloudKitAlertStore(", in: source.text))
        }
        if storeSites != [cloudKitFile] {
            failures.append("LiveCloudKitAlertStore( appears at \(storeSites) — expected once, in makeLiveStore")
        }
        for (name, text) in sources where name != cloudKitFile && text.contains("makeLiveStore(") {
            failures.append("makeLiveStore( called from \(name) — only the sender's default store factory may")
        }
        return failures
    }

    @Test func aContainerIsBuiltOnlyBehindTheEntitlementProbe() throws {
        let sources = try Self.sources()
        let failures = Self.containerConstructionFailures(sources)
        #expect(failures.isEmpty, "\(failures)")

        let canaries: [(String, [(name: String, text: String)])] = [
            ("guard removed", Self.mutate(sources, Self.cloudKitFile) {
                $0.replacingOccurrences(of: Self.probeGuard, with: "") }),
            ("guard weakened", Self.mutate(sources, Self.cloudKitFile) {
                $0.replacingOccurrences(of: Self.probeGuard, with: "guard true else { return nil }") }),
            ("built before the guard", Self.mutate(sources, Self.cloudKitFile) {
                $0.replacingOccurrences(of: Self.factoryHead,
                                        with: Self.factoryHead + "\n        _ = CKContainer(identifier: \"x\")") }),
            ("second site in the sanctioned file", Self.mutate(sources, Self.cloudKitFile) {
                $0 + "\nlet stray = CKContainer(identifier: \"x\")" }),
            ("a site in another file", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nlet stray = CKContainer(identifier: \"x\")" }),
            ("default container", Self.mutate(sources, Self.cloudKitFile) {
                $0 + "\nlet stray = CKContainer.default()" }),
            ("init spelling", Self.mutate(sources, "MenuContentView.swift") {
                $0 + "\nlet stray = CKContainer.init(identifier: \"x\")" }),
            ("live store built elsewhere", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nlet stray = LiveCloudKitAlertStore(container: c)" }),
            ("factory called elsewhere", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nlet stray = CloudKitMessageSender.makeLiveStore()" }),
        ]
        for (name, mutant) in canaries {
            #expect(!Self.containerConstructionFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Negative control: a comment may name the constructor anywhere.
        let commented = Self.mutate(sources, "NapCatApp.swift") { $0 + "\n// never CKContainer(identifier:) here" }
        #expect(Self.containerConstructionFailures(commented.map {
            ($0.name, LidGuardStructureTests.codeOnly($0.text))
        }).isEmpty)
    }

    /// CloudKit is touched on the send path only: opening the menu reads
    /// stored state and never builds a store, checks the account, or saves.
    @Test func menuOpenNeverReachesCloudKit() throws {
        let menu = LidGuardStructureTests.codeOnly(try String(
            contentsOf: LidGuardStructureTests.sourcesDir().appendingPathComponent("MenuContentView.swift"),
            encoding: .utf8))
        let open = try #require(menu.range(of: "func menuWillOpen("))
        let tail = menu[open.upperBound...]
        let end = tail.range(of: "\n    private func ")?.lowerBound ?? tail.endIndex
        let body = tail[..<end]
        for token in ["accountStatus", "makeLiveStore", "CloudKitMessageSender", ".send("] {
            #expect(!body.contains(token), "'\(token)' in menuWillOpen — opening the menu must not reach iCloud")
        }
    }
}
