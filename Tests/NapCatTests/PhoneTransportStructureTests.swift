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

    /// `containerConstructionFailures` over the sources as given, their
    /// cleaned copies, and the construction spelling of each (#153): a
    /// spaced `CKContainer (identifier:)`, a backticked one and one split by
    /// a block comment are constructions too.
    static func containerFailuresInEveryCopy(_ sources: [(name: String, text: String)]) -> [String] {
        let copies = LidGuardStructureTests.constructorScanCopies(sources)
        let spelled = copies.map { $0.map { ($0.name, ApprovalChannelStructureTests.constructionSpelling($0.text)) } }
        return ApprovalRecordPathStructureTests.unique((copies + spelled).flatMap(containerConstructionFailures))
    }

    @Test func aContainerIsBuiltOnlyBehindTheEntitlementProbe() throws {
        let sources = try Self.sources()
        let failures = Self.containerFailuresInEveryCopy(sources)
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
            // #155: a URL in a string literal no longer hides the rest of its line.
            ("a site behind a URL", Self.mutate(sources, "NapCatApp.swift") {
                $0 + LidGuardStructureTests.codeOnly(
                    "\nlet u = \"https://www.icloud.com\"; let stray = CKContainer(identifier: \"x\")") }),
        ]
        for (name, mutant) in canaries {
            #expect(!Self.containerFailuresInEveryCopy(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // #153: a construction however spelled, read through the cleaned
        // copies and the construction spelling.
        for planted in ["let stray = CKContainer (identifier: \"x\")", "let stray = `CKContainer`(identifier: \"x\")",
                        "let stray = CKContainer/* x */(identifier: \"x\")", "let stray = CKContainer . init(identifier: \"x\")"] {
            let mutant = Self.mutate(sources, "NapCatApp.swift") { $0 + "\n" + planted }
            #expect(!Self.containerFailuresInEveryCopy(mutant).isEmpty, "canary '\(planted)' was NOT caught")
        }
        // Negative control: a comment may name the constructor anywhere.
        let commented = Self.mutate(sources, "NapCatApp.swift") { $0 + "\n// never CKContainer(identifier:) here" }
        #expect(Self.containerFailuresInEveryCopy(commented.map {
            ($0.name, LidGuardStructureTests.codeOnly($0.text))
        }).isEmpty)
    }

    // MARK: - The alert lane writes its alert and nothing else (#153)

    /// The alert lane predates F4's approval records and is a sanctioned
    /// private-database writer. Its locks pinned the alert record's schema,
    /// not every way the file could build or save a record: in the security
    /// re-check a `LiveCloudKitAlertStore` extension `database.add`-ed a
    /// hand-built operation saving a `CKRecord.init` PromptRequest, and every
    /// suite passed. So, as the record path's locks 4 and 8 do, the file's
    /// writes are confined to its alert by allow-lists, not by bans alone:
    /// - its CloudKit identifiers are an exact allow-list (another door —
    ///   `CKModifySubscriptionsOperation`, `CKDatabaseOperation`, `CKShare` —
    ///   fails by default);
    /// - it builds one record and one operation, however spelled;
    /// - its ONE database write is the alert's: `add` is named once, to add
    ///   `makeSaveOperation`'s operation; `save` only by the alert store's
    ///   seam and the one sentence that says it; the private database once,
    ///   by the live store;
    /// - the record goes only into that operation (`makeRecord`) and the
    ///   operation only to that `add` (`makeSaveOperation`, `operation` and
    ///   the operation type, each pinned to its lines);
    /// - and no other database write, other database, or operation runner is
    ///   named at all.
    static let alertLaneIdentifiers: Set<String> = [
        "CKAccountStatus", "CKContainer", "CKDatabase", "CKError", "CKErrorDomain", "CKModifyRecordsOperation",
        "CKOperation", "CKPartialErrorsByItemIDKey", "CKRecord", "CKRecordZone",
    ]

    static let alertLaneConstructions = [
        "CKRecord": "let record = CKRecord(recordType: AlertWire.recordType, recordID: recordID)",
        "CKModifyRecordsOperation":
            "let operation = CKModifyRecordsOperation(recordsToSave: [makeRecord(payload)], recordIDsToDelete: nil)",
    ]

    static let alertSave = "database.add(CloudKitMessageSender.makeSaveOperation(payload, completion: completion))"
    static let alertOperation = "let operation = CKModifyRecordsOperation(recordsToSave: [makeRecord(payload)], recordIDsToDelete: nil)"

    /// Each word, and every line of the alert-lane file allowed to name it.
    static let alertLaneSites: [(pattern: String, sites: [String: Int], rule: String)] = [
        (#"\badd\b"#, [alertSave: 1], "the one database write adds the alert's own operation"),
        (#"\bsave\b"#, ["func save(_ payload: CloudKitAlertPayload, completion: @escaping @Sendable ((any Error)?) -> Void)": 1,
                        "func save(_ payload: CloudKitAlertPayload, completion: @escaping @Sendable ((any Error)?) -> Void) {": 1,
                        "store.save(payload) { [weak self] error in": 1,
                        "static let permissionText = \"iCloud denied permission to save the alert\"": 1],
         "save is the alert store's seam, never a database's"),
        (#"\bprivateCloudDatabase\b"#, ["self.database = container.privateCloudDatabase": 1],
         "the private database is reached once, by the live store"),
        (#"\bmakeSaveOperation\b"#, ["static func makeSaveOperation(": 1, alertSave: 1],
         "the save operation goes only to the one add"),
        (#"\bmakeRecord\b"#, ["static func makeRecord(_ payload: CloudKitAlertPayload) -> CKRecord {": 1, alertOperation: 1],
         "the alert record goes only into the save operation"),
        (#"\boperation\b"#, [alertOperation: 1, "operation.savePolicy = .ifServerRecordUnchanged": 1, "operation.isAtomic = true": 1,
                             "operation.configuration = configuration": 1, "operation.perRecordSaveBlock = { _, result in": 1,
                             "operation.modifyRecordsResultBlock = { result in": 1, "return operation": 1],
         "the factory builds, configures and returns its operation, nothing else"),
        (#"\bCKModifyRecordsOperation\b"#, [") -> CKModifyRecordsOperation {": 1, alertOperation: 1],
         "the operation type is named by the factory and its one construction"),
    ]

    /// Named nowhere in the alert-lane file: every other database write, the
    /// other databases, and every way to run an operation but the one `add`.
    static let alertLaneBans = [
        #"\b(?:modifyRecords|modifySubscriptions|modifyRecordZones|delete|deleteRecord|deleteSubscription|deleteRecordZone)\b"#,
        #"\b(?:publicCloudDatabase|sharedCloudDatabase|configuredWith)\b"#, #"\bdatabase\s*\(\s*with\b"#,
        #"\bstart\b"#, #"\bmain\b"#, #"\bOperationQueue\b"#, #"\baddOperations?\b"#, #"\bperform\b"#, #"#selector\b"#,
        #"\bSelector\b"#, #"\bNSSelectorFromString\b"#,
    ]

    /// `sources`: Sources/NapCat with whole-line comments removed.
    static func alertLaneWriteFailures(_ sources: [(name: String, text: String)]) -> [String] {
        typealias Lock = ApprovalRecordPathStructureTests
        let file = sources.first { $0.name == cloudKitFile }?.text ?? ""
        var failures: [String] = []
        let named = Set(Lock.matches(#"\bCK\w*"#, in: file))
        for identifier in named.subtracting(alertLaneIdentifiers).sorted() {
            failures.append("'\(identifier)' in \(cloudKitFile) — not on the alert lane's CloudKit allow-list")
        }
        for identifier in alertLaneIdentifiers.subtracting(named).sorted() {
            failures.append("'\(identifier)' is allow-listed but unused in \(cloudKitFile) — the list stays exact")
        }
        failures += Lock.constructionFailures(file, file: cloudKitFile, sites: alertLaneConstructions)
        for (pattern, sites, rule) in alertLaneSites {
            failures += Lock.siteFailures(pattern, in: file, file: cloudKitFile, allowed: sites, rule: rule)
        }
        for (name, text) in sources where name != cloudKitFile
            && (Lock.hits(#"\bmakeSaveOperation\b"#, in: text) || Lock.hits(#"\bmakeRecord\b"#, in: text)) {
            failures.append("\(name) reaches the alert's record or save operation — only the alert lane may")
        }
        for pattern in alertLaneBans where Lock.hits(pattern, in: file) {
            failures.append("'\(pattern)' in \(cloudKitFile) — the alert lane's one write is the alert's own add")
        }
        return failures
    }

    @Test func theAlertLaneWritesItsAlertAndNothingElse() throws {
        let sources = try LidGuardStructureTests.swiftSources(LidGuardStructureTests.wholeLineCommentsRemoved)
        #expect(Self.alertLaneWriteFailures(sources).isEmpty, "\(Self.alertLaneWriteFailures(sources))")
        let file = Self.cloudKitFile
        let mutants: [(String, [(name: String, text: String)])] = [
            // The security re-check (#146), both alert-lane plants, as planted.
            ("the sender extended to add a hand-built operation", Self.mutate(sources, file) {
                $0 + "\nextension CloudKitMessageSender {\n    static func alertLaneProbe(_ id: PromptID) {\n"
                    + "        let r = CKRecord.init(recordType: ApprovalWire.RecordType.prompt.rawValue,\n"
                    + "                              recordID: CKRecord.ID(recordName: id.hex))\n"
                    + "        CKContainer(identifier: AlertWire.containerIdentifier).privateCloudDatabase.add(\n"
                    + "            CKModifyRecordsOperation(recordsToSave: [r], recordIDsToDelete: nil))\n    }\n}" }),
            ("the live store extended to add a hand-built operation", Self.mutate(sources, file) {
                $0 + "\nextension LiveCloudKitAlertStore {\n    func alertLaneProbe(_ id: PromptID) {\n"
                    + "        let r = CKRecord.init(recordType: ApprovalWire.RecordType.prompt.rawValue,\n"
                    + "                              recordID: CKRecord.ID(recordName: id.hex))\n"
                    + "        database.add(CKModifyRecordsOperation(recordsToSave: [r], recordIDsToDelete: nil))\n    }\n}" }),
            // … and the doors around them.
            ("a database save of a record", Self.mutate(sources, file) {
                $0 + "\nextension LiveCloudKitAlertStore { func f(_ r: CKRecord) { database.save(r) { _, _ in } } }" }),
            ("a batch modify", Self.mutate(sources, file) {
                $0 + "\nextension LiveCloudKitAlertStore { func f(_ r: CKRecord) async throws { "
                    + "_ = try await database.modifyRecords(saving: [r], deleting: []) } }" }),
            ("an add on the database's implicit self", Self.mutate(sources, file) {
                $0 + "\nextension CKDatabase { func go(_ o: CKModifyRecordsOperation) { add(o) } }" }),
            ("a backticked add", Self.mutate(sources, file) {
                $0 + "\nextension LiveCloudKitAlertStore { func f(_ o: CKModifyRecordsOperation) { database.`add`(o) } }" }),
            ("the alert's own operation started", Self.mutate(sources, file) {
                $0 + "\nfunc f(p: CloudKitAlertPayload) { CloudKitMessageSender.makeSaveOperation(p) { _ in }.start() }" }),
            ("the alert's record saved by another operation", Self.mutate(sources, "CompositeMessageSender.swift") {
                $0 + "\nfunc f(p: CloudKitAlertPayload) -> Any { CloudKitMessageSender.makeRecord(p) }" }),
            ("the operation pointed at a database", Self.mutate(sources, file) {
                $0.replacingOccurrences(of: "        operation.isAtomic = true\n",
                                        with: "        operation.isAtomic = true\n        operation.database = nil\n") }),
            ("a subscription door", Self.mutate(sources, file) {
                $0 + "\nlet s = CKModifySubscriptionsOperation(subscriptionsToSave: [], subscriptionIDsToDelete: nil)" }),
            ("the public database", Self.mutate(sources, file) {
                $0.replacingOccurrences(of: "container.privateCloudDatabase", with: "container.publicCloudDatabase") }),
            ("a record deleted", Self.mutate(sources, file) {
                $0 + "\nextension LiveCloudKitAlertStore { func f(_ i: CKRecord.ID) async throws { _ = try await database.deleteRecord(withID: i) } }" }),
            ("an allow-listed identifier dropped", Self.mutate(sources, file) {
                $0.replacingOccurrences(of: "zoneID: CKRecordZone.ID.default)", with: "zoneID: .default)") }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.alertLaneWriteFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Each ban compiles and bites through the lock's own engine.
        let probes = ["db.modifyRecords(saving: r)", "c.sharedCloudDatabase", "c.database(with: .private)", "o.start()", "o.main()",
                      "OperationQueue.main", "q.addOperation(o)", "o.perform(s)", "#selector(Operation.start)",
                      "Selector((\"start\"))", "NSSelectorFromString(\"start\")"]
        #expect(probes.count == Self.alertLaneBans.count)
        for (pattern, probe) in zip(Self.alertLaneBans, probes) {
            #expect(ApprovalRecordPathStructureTests.hits(pattern, in: probe), "'\(pattern)' does not match '\(probe)'")
        }
        // Over-match controls: words that only contain a banned one, and a
        // whole-line comment naming what it rules out.
        #expect(Self.alertLaneWriteFailures(Self.mutate(sources, file) {
            $0 + "\nfunc f(s: String, d: Date) -> Bool { s.startIndex == s.endIndex && d.addingTimeInterval(1) > d }"
                + "\nlet saveResult = 1, savePolicyName = \"x\", toDelete = 0, domain = \"maintained\""
                + LidGuardStructureTests.wholeLineCommentsRemoved(
                    "\n    /// never database.save(record), never modifyRecords, never a second add(operation)")
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
                $0.replacingOccurrences(of: "            sender: sender,\n            topicStore:",
                                        with: "            sender: ntfy,\n            topicStore:") }),
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
