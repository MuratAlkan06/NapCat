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

    // MARK: - The composite: one gated construction site, injected everywhere

    static let compositeFile = "CompositeMessageSender.swift"
    static let compositeFactoryHead =
        "static func makeIfEnabled(wrapping ntfy: (any MessageSender)?, defaults: UserDefaults) -> CompositeMessageSender? {"
    static let appWrap = "let sender = CompositeMessageSender.makeIfEnabled(wrapping: ntfy, defaults: defaults)"

    static func compositeWiringFailures(_ sources: [(name: String, text: String)]) -> [String] {
        var failures: [String] = []
        // The composite and its CloudKit sender are built ONCE, in the
        // gated factory, which bails out first when there is no ntfy sender
        // (debugBattery mode).
        for token in ["CompositeMessageSender(", "CloudKitMessageSender("] {
            let sites = sources.flatMap { source in
                Array(repeating: source.name, count: occurrences(of: token, in: source.text))
            }
            if sites != [compositeFile] {
                failures.append("\(token) appears at \(sites) — expected exactly once, in \(compositeFile)")
            }
        }
        let composite = sources.first { $0.name == compositeFile }?.text ?? ""
        if let factory = body(after: compositeFactoryHead, in: composite) {
            let statements = factory.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if statements.first != "guard let ntfy else { return nil }" {
                failures.append("makeIfEnabled must bail out first without an ntfy sender (debugBattery mode)")
            }
            for token in ["CompositeMessageSender(", "CloudKitMessageSender("] where !factory.contains(token) {
                failures.append("\(token) must be built inside makeIfEnabled")
            }
        } else {
            failures.append("'\(compositeFactoryHead)' not found in \(compositeFile)")
        }
        // The app wraps the ONE ntfy sender and hands the composite — never
        // the bare ntfy sender — to both features.
        let app = sources.first { $0.name == "NapCatApp.swift" }?.text ?? ""
        if occurrences(of: appWrap, in: app) != 1 {
            failures.append("NapCatApp must wrap the shared ntfy sender exactly once: '\(appWrap)'")
        }
        if occurrences(of: "sender: sender", in: app) != 2 {
            failures.append("the lid guard and the finish alert must both receive the composite ('sender: sender')")
        }
        if app.contains("sender: ntfy") || app.contains("sender: ntfySender") {
            failures.append("a feature receives the bare ntfy sender, bypassing the composite")
        }
        if let wrap = app.range(of: appWrap), let lid = app.range(of: "LidGuardController.makeIfEnabled("),
           !(wrap.upperBound < lid.lowerBound) {
            failures.append("the composite must be built before the features that receive it")
        }
        return failures
    }

    @Test func theCompositeHasOneGatedSiteAndBothFeaturesGetIt() throws {
        let sources = try Self.sources()
        let failures = Self.compositeWiringFailures(sources)
        #expect(failures.isEmpty, "\(failures)")

        let canaries: [(String, [(name: String, text: String)])] = [
            ("app builds a CloudKit sender", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nlet stray = CloudKitMessageSender()" }),
            ("second composite", Self.mutate(sources, "LidGuardController.swift") {
                $0 + "\nlet stray = CompositeMessageSender(ntfy: a, phone: b, defaults: d)" }),
            ("debug gate dropped", Self.mutate(sources, Self.compositeFile) {
                $0.replacingOccurrences(of: "guard let ntfy else { return nil }", with: "let ntfy = ntfy!") }),
            ("lid guard gets the bare ntfy sender", Self.mutate(sources, "NapCatApp.swift") {
                $0.replacingOccurrences(of: "sender: sender\n        )\n        self.lidGuard",
                                        with: "sender: ntfy\n        )\n        self.lidGuard") }),
            ("wrap removed", Self.mutate(sources, "NapCatApp.swift") {
                $0.replacingOccurrences(of: Self.appWrap, with: "let sender = ntfy") }),
        ]
        for (name, mutant) in canaries {
            #expect(!Self.compositeWiringFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    /// Runtime half: in debugBattery mode there is no ntfy sender, hence no
    /// composite and no CloudKit sender; outside it the composite exists and
    /// building it touched nothing (the toggle is off by default, so a send
    /// goes to the wrapped sender).
    @Test func theCompositeIsAbsentInDebugSimulatorMode() {
        let suite = "com.muratalkan.napcat.tests.phone.structure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(CompositeMessageSender.makeIfEnabled(
            wrapping: LidGuardController.makeSharedSender(debugBattery: true), defaults: defaults) == nil)
        #expect(CompositeMessageSender.makeIfEnabled(wrapping: nil, defaults: defaults) == nil)

        let wrapped = RecordingMessageSender()
        let composite = CompositeMessageSender.makeIfEnabled(wrapping: wrapped, defaults: defaults)
        #expect(composite != nil)
        let destination = NtfyDestination(server: "https://ntfy.sh", topic: "napcat-phone-structure")
        composite?.send(.test, to: destination, at: Date(timeIntervalSince1970: 0)) { _ in }
        #expect(wrapped.sends.count == 1, "toggle off by default: the wrapped sender carries the alert")
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
