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
///
/// AMENDED (S-PAIR-C1.5, #170, the live pairing transport — deliberate): a
/// SECOND container site joins the first, for the pairing record's live
/// database, under the same rule — in the sanctioned file, inside its own
/// factory (`makeLivePairingDatabase()`), whose first statement is the same
/// probe guard; its live database is built only there, and the factory is
/// called only by the pairing controller's wiring (`makeIfEnabled`).
///
/// AMENDED (S-PAIR-C1.5, the C1.5 security review's R2 and R3): each factory
/// is named, as a WORD, at its declaration and its one wiring line alone (an
/// unapplied reference is a site too, not only a call); every line of the
/// sender naming its `database` is pinned; and the live pairing database's
/// two submits and its own check (`PairingRecordGuard`) are pinned whole.
///
/// AMENDED (S-PAIR-C1.5, the C1.5 security delta re-check's F-B): every line
/// of the sender naming a `container` is pinned too, and key-value coding is
/// named nowhere in the sender, both in every scan copy.
///
/// AMENDED (S-PAIR-C1.5, the delta re-check's round 2, F-C): a line pin
/// holds its own line, not the next one, so the two live classes are pinned
/// whole, an extension of either is banned in the sender, and key-value
/// coding's evaluators and observers join its ban: any new line naming a
/// container fails; the live classes are pinned whole.
struct PhoneTransportStructureTests {
    static let cloudKitFile = "CloudKitMessageSender.swift"
    static let factoryHead = "static func makeLiveStore() -> (any CloudKitAlertStore)? {"
    static let pairingFactoryHead = "static func makeLivePairingDatabase() -> (any PairingRecordDatabase)? {"
    static let probeGuard = "guard CloudKitEntitlementProbe.isEntitled else { return nil }"
    /// The pairing factory's one caller: the controller's wiring.
    static let pairingWiring = "source: CloudKitPairingRecords(database: { CloudKitMessageSender.makeLivePairingDatabase() }), keys: keys,"
    /// The alert store factory's one caller: the sender's default store.
    static let storeDefault = "makeStore: @escaping @Sendable () -> (any CloudKitAlertStore)? = { CloudKitMessageSender.makeLiveStore() }"

    /// The C1.5 security review's R2 (its F2: `let make =
    /// CloudKitMessageSender.makeLivePairingDatabase` in any file, then
    /// `make()?.submit(…)`, passed every lock): each factory's name, as a
    /// word, in every scan copy, sits on its declaration and its one wiring
    /// line and nowhere else in Sources/NapCat.
    static let factoryWordSites: [(pattern: String, allowed: [String: [String: Int]], rule: String)] = [
        (#"\bmakeLiveStore\b"#, [cloudKitFile: [factoryHead: 1, storeDefault: 1]],
         "the alert store's factory is declared once and named once, by the sender's default store"),
        (#"\bmakeLivePairingDatabase\b"#, [cloudKitFile: [pairingFactoryHead: 1], "PairingController.swift": [pairingWiring: 1]],
         "the pairing database's factory is declared once and named once, by the pairing controller's wiring"),
    ]

    static func factoryWordFailures(_ sources: [(name: String, text: String)]) -> [String] {
        factoryWordSites.flatMap { PairingStructureTests.appSiteFailures($0.pattern, in: sources, allowed: $0.allowed, rule: $0.rule) }
    }

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

    /// `body(after:in:)` at EVERY occurrence of `head`, in order — `nil` for
    /// one with no closing brace (`body(after:in:)` reads the first alone).
    static func bodies(after head: String, in code: String) -> [String?] {
        var found: [String?] = []
        var from = code.startIndex
        while let start = code.range(of: head, range: from..<code.endIndex) {
            let lineStart = code[..<start.lowerBound].lastIndex(of: "\n").map { code.index(after: $0) } ?? code.startIndex
            let indent = String(code[lineStart..<start.lowerBound].prefix { $0 == " " })
            let tail = code[start.upperBound...]
            found.append(tail.range(of: "\n\(indent)}").map { String(tail[..<$0.lowerBound]) })
            from = start.upperBound
        }
        return found
    }

    static func occurrences(of token: String, in text: String) -> Int {
        text.components(separatedBy: token).count - 1
    }

    static func containerConstructionFailures(_ sources: [(name: String, text: String)]) -> [String] {
        var failures: [String] = []
        // 1. TWO construction sites (S-PAIR-C1.5), repo wide, both in the
        //    sanctioned file.
        let sites = sources.flatMap { source in
            Array(repeating: source.name, count: occurrences(of: "CKContainer(", in: source.text))
        }
        if sites != [cloudKitFile, cloudKitFile] {
            failures.append("CKContainer( appears at \(sites) — expected exactly twice, in \(cloudKitFile)")
        }
        // 2. No other way to reach a container.
        for (name, text) in sources {
            for token in ["CKContainer.default", "CKContainer.init", "CKContainer.self"] where text.contains(token) {
                failures.append("'\(token)' in \(name) — the probe-gated factories are the only routes to a container")
            }
        }
        // 3. Each site sits inside its factory, behind the probe guard,
        //    which is the function's FIRST statement.
        let file = sources.first { $0.name == cloudKitFile }?.text ?? ""
        for (head, name) in [(factoryHead, "makeLiveStore"), (pairingFactoryHead, "makeLivePairingDatabase")] {
            guard let factory = body(after: head, in: file) else {
                failures.append("'\(head)' not found in \(cloudKitFile)")
                continue
            }
            let statements = factory.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if statements.first != probeGuard {
                failures.append("\(name) must open with '\(probeGuard)' — found '\(statements.first ?? "")'")
            }
            if occurrences(of: "CKContainer(", in: factory) != 1 {
                failures.append("one CKContainer( must be inside \(name)")
            }
            if let guardAt = factory.range(of: probeGuard), let buildAt = factory.range(of: "CKContainer("),
               buildAt.lowerBound < guardAt.upperBound {
                failures.append("the container is built before the probe guard in \(name)")
            }
        }
        // 4. Each live database (which holds a container) is built only in
        //    its factory; the alert store's factory is reached only from the
        //    sanctioned file, the pairing one only by the controller's wiring.
        for (type, factory) in [("LiveCloudKitAlertStore(", "makeLiveStore"),
                                ("LivePairingRecordDatabase(", "makeLivePairingDatabase")] {
            let storeSites = sources.flatMap { source in
                Array(repeating: source.name, count: occurrences(of: type, in: source.text))
            }
            if storeSites != [cloudKitFile] {
                failures.append("\(type) appears at \(storeSites) — expected once, in \(factory)")
            }
        }
        for (name, text) in sources where name != cloudKitFile && text.contains("makeLiveStore(") {
            failures.append("makeLiveStore( called from \(name) — only the sender's default store factory may")
        }
        let pairingCalls = sources.flatMap { source in
            Array(repeating: source.name, count: occurrences(of: "makeLivePairingDatabase(", in: source.text))
        }
        if pairingCalls.sorted() != [cloudKitFile, "PairingController.swift"]
            || occurrences(of: pairingWiring, in: sources.first { $0.name == "PairingController.swift" }?.text ?? "") != 1 {
            failures.append("makeLivePairingDatabase( at \(pairingCalls) — declared once, called once, by the pairing controller's wiring")
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
        return ApprovalRecordPathStructureTests.unique((copies + spelled).flatMap(containerConstructionFailures)
                                                       + factoryWordFailures(sources))
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
            // S-PAIR-C1.5 (#170): the pairing database's factory, as the store's.
            ("the pairing factory's guard removed", Self.mutate(sources, Self.cloudKitFile) {
                $0.replacingOccurrences(of: Self.pairingFactoryHead + "\n        " + Self.probeGuard, with: Self.pairingFactoryHead) }),
            ("the pairing factory's guard weakened", Self.mutate(sources, Self.cloudKitFile) {
                $0.replacingOccurrences(of: Self.pairingFactoryHead + "\n        " + Self.probeGuard,
                                        with: Self.pairingFactoryHead + "\n        guard true else { return nil }") }),
            ("a third container, in a third factory", Self.mutate(sources, Self.cloudKitFile) {
                $0 + "\nenum Spare {\n    static func make() -> CKContainer? {\n        " + Self.probeGuard
                    + "\n        return CKContainer(identifier: \"x\")\n    }\n}" }),
            ("the pairing database built elsewhere", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nlet stray = LivePairingRecordDatabase(container: c)" }),
            ("the pairing factory called elsewhere", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nlet stray = CloudKitMessageSender.makeLivePairingDatabase()" }),
            ("the pairing factory called twice in the wiring", Self.mutate(sources, "PairingController.swift") {
                $0 + "\nlet stray = CloudKitMessageSender.makeLivePairingDatabase()" }),
            ("the wiring hands the source another database", Self.mutate(sources, "PairingController.swift") {
                $0.replacingOccurrences(of: Self.pairingWiring, with: "source: CloudKitPairingRecords(database: { spare }), keys: keys,"
                                            + " _ = CloudKitMessageSender.makeLivePairingDatabase()") }),
            // The C1.5 security review's R2: its RP2, as planted, and the
            // unapplied references around it.
            ("RP2: the live pairing database from any file, unapplied", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nextension MenuStateModel {\n    static func zzSecRevWipe(_ n: String) {\n"
                    + "        let make = CloudKitMessageSender.makeLivePairingDatabase\n"
                    + "        make()?.submit(.init(recordsToSave: nil, recordIDsToDelete: [.init(recordName: n, zoneID: .default)]))\n"
                    + "        make()?.submit(.fetchCurrentUserRecordOperation())\n    }\n}" }),
            ("the pairing factory unapplied", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nlet zzMake = CloudKitMessageSender.makeLivePairingDatabase" }),
            ("the pairing factory unapplied in its own file", Self.mutate(sources, Self.cloudKitFile) {
                $0 + "\nextension CloudKitMessageSender { static let zzMake = makeLivePairingDatabase }" }),
            ("the pairing factory unapplied in the wiring's file", Self.mutate(sources, "PairingController.swift") {
                $0 + "\nlet zzMake = CloudKitMessageSender.makeLivePairingDatabase" }),
            ("the alert store's factory unapplied (pre-existing)", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nlet zzStore = CloudKitMessageSender.makeLiveStore" }),
            ("the alert store's factory unapplied in its own file", Self.mutate(sources, Self.cloudKitFile) {
                $0 + "\nextension CloudKitMessageSender { static let zzStore = makeLiveStore }" }),
            ("a backticked unapplied factory", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nlet zzMake = CloudKitMessageSender.`makeLivePairingDatabase`" }),
        ]
        for (name, mutant) in canaries {
            #expect(!Self.containerFailuresInEveryCopy(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // R2: the word pins alone catch the unapplied references (the
        // construction checks above count calls, which these are not).
        for (file, planted) in [("NapCatApp.swift", "\nlet zzMake = CloudKitMessageSender.makeLivePairingDatabase"),
                                ("NapCatApp.swift", "\nlet zzStore = CloudKitMessageSender.makeLiveStore"),
                                (Self.cloudKitFile, "\nextension CloudKitMessageSender { static let zzMake = makeLivePairingDatabase }")] {
            #expect(Self.containerConstructionFailures(Self.mutate(sources, file) { $0 + planted }).isEmpty,
                    "vacuity: '\(planted)' is no call, so only the word pin can see it")
            #expect(!Self.factoryWordFailures(Self.mutate(sources, file) { $0 + planted }).isEmpty, "'\(planted)' was NOT caught")
        }
        // R2 over-match controls: words that only contain a factory's name,
        // and a whole-line comment naming both.
        #expect(Self.factoryWordFailures(Self.mutate(sources, "MenuStateModel.swift") {
            $0 + "\nlet makeLiveStoreCount = 1, zzmakeLivePairingDatabases = 2"
                + LidGuardStructureTests.codeOnly("\n/// never CloudKitMessageSender.makeLivePairingDatabase, never makeLiveStore()")
        }).isEmpty)
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
    ///
    /// AMENDED (S-PAIR-C1.5, #170 — deliberate): the file also holds the
    /// pairing record's live database, which runs the two operations the
    /// record path builds for the pairing record and builds none itself. The
    /// allow-list widens by the fetch operation's type alone; `add` gains
    /// that database's two `database.add(operation)` lines (its `submit`s,
    /// each named once here and called nowhere in this file); the private
    /// database gains its one read; and `operation` and the modify type gain
    /// those `submit` lines only.
    ///
    /// AMENDED (S-PAIR-C1.5, the C1.5 security review's R2 and R3 —
    /// deliberate): the pairing database checks what it is handed
    /// (`PairingRecordGuard`, pinned whole, named by the two submits alone),
    /// so the allow-list widens by `CKCurrentUserDefaultName` (the approvals
    /// zone's owner, a constant), and `operation` and the two operation types
    /// gain the check's lines; each submit is pinned whole; and every line
    /// naming the sender's `database` is pinned — its two holders, their two
    /// reads of the private database, and the three adds (F5 read the record
    /// by `database.record(for:)`, inside the pinned submit and beside it).
    static let alertLaneIdentifiers: Set<String> = [
        "CKAccountStatus", "CKContainer", "CKCurrentUserDefaultName", "CKDatabase", "CKError", "CKErrorDomain",
        "CKFetchRecordsOperation", "CKModifyRecordsOperation", "CKOperation", "CKPartialErrorsByItemIDKey", "CKRecord",
        "CKRecordZone",
    ]
    static let pairingSubmits = ["func submit(_ operation: CKFetchRecordsOperation) {": 1,
                                 "func submit(_ operation: CKModifyRecordsOperation) {": 1]
    static let pairingAdd = "database.add(operation)"

    /// The live pairing database's check, as each submit opens with it.
    static let pairingCheck = "guard PairingRecordGuard.admits(operation) else { return PairingRecordGuard.refuse(operation) }"
    /// Each submit, whole: the check, then the add.
    static let pairingSubmitBody = pairingCheck + " " + pairingAdd
    static let guardHead = "enum PairingRecordGuard {"
    static let guardFetchHead = "static func admits(_ operation: CKFetchRecordsOperation) -> Bool {"
    static let guardDeleteHead = "static func admits(_ operation: CKModifyRecordsOperation) -> Bool {"
    static let guardFetchIDs = "guard let ids = operation.recordIDs, ids.count == 1 else { return false }"
    static let guardDeleteIDs = "guard operation.recordsToSave?.isEmpty ?? true, let ids = operation.recordIDsToDelete, ids.count == 1"
        + " else { return false }"
    static let refuseFetchHead = "static func refuse(_ operation: CKFetchRecordsOperation) {"
    static let refuseDeleteHead = "static func refuse(_ operation: CKModifyRecordsOperation) {"
    static let refuseFetch = "operation.fetchRecordsResultBlock?(.failure(CKError(.invalidArguments)))"
    static let refuseDelete = "operation.modifyRecordsResultBlock?(.failure(CKError(.invalidArguments)))"
    static let pairingRecordCheck: String = "static func isPairingRecord(_ id: CKRecord.ID) -> Bool {"
        + " id.zoneID.zoneName == ApprovalWire.zoneName && id.zoneID.ownerName == CKCurrentUserDefaultName"
        + " && PairingResponseCheck.isRecordName(id.recordName) }"
    /// The check, whole: one record each way, by a pairing record's ID — the
    /// approvals zone of this account, a pairing record name — and a
    /// deletion saving nothing; a refusal tells the operation's own result
    /// block `invalidArguments`. (Its members joined, so no one expression
    /// is a long concatenation for the type-checker.)
    static let guardBody: String = [
        [guardFetchHead, guardFetchIDs, "return isPairingRecord(ids[0]) }"].joined(separator: " "),
        [guardDeleteHead, guardDeleteIDs, "return isPairingRecord(ids[0]) }"].joined(separator: " "),
        pairingRecordCheck,
        [refuseFetchHead, refuseFetch, "}"].joined(separator: " "),
        [refuseDeleteHead, refuseDelete, "}"].joined(separator: " "),
    ].joined(separator: " ")
    /// The check's operation lines (each submit's check holds two matches).
    static let guardOperationSites: [String: Int] = [pairingCheck: 4, guardFetchHead: 1, guardFetchIDs: 1, guardDeleteHead: 1,
                                                     guardDeleteIDs: 2, refuseFetchHead: 1, refuseFetch: 1, refuseDeleteHead: 1,
                                                     refuseDelete: 1]
    /// Every `operation` line of the pairing database and its check: the two
    /// submits' heads, their checks and adds, and the check's own lines.
    static let pairingOperationSites: [String: Int] = pairingSubmits.merging([pairingAdd: 2]) { $0 + $1 }
        .merging(guardOperationSites) { $0 + $1 }

    /// R3: every line naming the sender's `database`.
    static let databaseSites = ["private let database: CKDatabase": 2, "self.database = container.privateCloudDatabase": 2,
                                "database.add(CloudKitMessageSender.makeSaveOperation(payload, completion: completion))": 1,
                                pairingAdd: 2]

    static let alertLaneConstructions = [
        "CKRecord": "let record = CKRecord(recordType: AlertWire.recordType, recordID: recordID)",
        "CKModifyRecordsOperation":
            "let operation = CKModifyRecordsOperation(recordsToSave: [makeRecord(payload)], recordIDsToDelete: nil)",
    ]

    static let alertSave = "database.add(CloudKitMessageSender.makeSaveOperation(payload, completion: completion))"
    static let alertOperation = "let operation = CKModifyRecordsOperation(recordsToSave: [makeRecord(payload)], recordIDsToDelete: nil)"

    /// Each word, and every line of the alert-lane file allowed to name it.
    static let alertLaneSites: [(pattern: String, sites: [String: Int], rule: String)] = [
        (#"\badd\b"#, [alertSave: 1, pairingAdd: 2],
         "the database writes add the alert's own operation, and the pairing database's two handed-in operations"),
        (#"\bsave\b"#, ["func save(_ payload: CloudKitAlertPayload, completion: @escaping @Sendable ((any Error)?) -> Void)": 1,
                        "func save(_ payload: CloudKitAlertPayload, completion: @escaping @Sendable ((any Error)?) -> Void) {": 1,
                        "store.save(payload) { [weak self] error in": 1,
                        "static let permissionText = \"iCloud denied permission to save the alert\"": 1],
         "save is the alert store's seam, never a database's"),
        (#"\bprivateCloudDatabase\b"#, ["self.database = container.privateCloudDatabase": 2],
         "the private database is reached once by each live database"),
        (#"\bmakeSaveOperation\b"#, ["static func makeSaveOperation(": 1, alertSave: 1],
         "the save operation goes only to the one add"),
        (#"\bmakeRecord\b"#, ["static func makeRecord(_ payload: CloudKitAlertPayload) -> CKRecord {": 1, alertOperation: 1],
         "the alert record goes only into the save operation"),
        (#"\boperation\b"#, [alertOperation: 1, "operation.savePolicy = .ifServerRecordUnchanged": 1, "operation.isAtomic = true": 1,
                             "operation.configuration = configuration": 1, "operation.perRecordSaveBlock = { _, result in": 1,
                             "operation.modifyRecordsResultBlock = { result in": 1, "return operation": 1]
            .merging(pairingOperationSites) { $0 + $1 },
         "the factory builds, configures and returns its operation; the pairing database checks and adds what it is handed"),
        (#"\bCKModifyRecordsOperation\b"#, [") -> CKModifyRecordsOperation {": 1, alertOperation: 1,
                                            "func submit(_ operation: CKModifyRecordsOperation) {": 1,
                                            guardDeleteHead: 1, refuseDeleteHead: 1],
         "the operation type is named by the factory, its one construction, the pairing database's submit and its check"),
        (#"\bCKFetchRecordsOperation\b"#, ["func submit(_ operation: CKFetchRecordsOperation) {": 1, guardFetchHead: 1, refuseFetchHead: 1],
         "the fetch operation's type is named by the pairing database's submit and its check alone: nothing here builds one"),
        (#"\bsubmit\b"#, pairingSubmits, "the pairing database's two submits are declared here and called nowhere in this file"),
        (#"\bdatabase\b"#, databaseSites,
         "the sender's two databases are held, read from the container and added to — nothing else touches either"),
        (#"\bPairingRecordGuard\b"#, [guardHead: 1, pairingCheck: 4],
         "the pairing database's check is declared once and called by its two submits alone"),
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
        // R2/R3: each submit opens with the check, then adds; the check, whole.
        for (head, pinned, rule) in [("func submit(_ operation: CKFetchRecordsOperation) {", pairingSubmitBody,
                                      "the pairing database checks, then adds, each fetch"),
                                     ("func submit(_ operation: CKModifyRecordsOperation) {", pairingSubmitBody,
                                      "the pairing database checks, then adds, each deletion"),
                                     (guardHead, guardBody, "the pairing database's check admits one pairing record each way")] {
            guard let found = Self.body(after: head, in: file) else {
                failures.append("'\(head)' not found in \(cloudKitFile) — \(rule)")
                continue
            }
            if MenuPanelStructureTests.flat(found) != pinned { failures.append("\(rule) — exactly as pinned") }
        }
        for (name, text) in sources where name != cloudKitFile && Lock.hits(#"\bPairingRecordGuard\b"#, in: text) {
            failures.append("\(name) names the pairing database's check — its two submits alone call it")
        }
        for pattern in alertLaneBans where Lock.hits(pattern, in: file) {
            failures.append("'\(pattern)' in \(cloudKitFile) — the alert lane's one write is the alert's own add")
        }
        failures += containerNameFailures(file)
        failures += liveClassFailures(file)
        return failures
    }

    /// AMENDED (S-PAIR-C1.5, the C1.5 security delta re-check's F-B): its G2
    /// reached the private database from an extension of the live pairing
    /// database by key-value coding on the container —
    /// `container.value(forKey: "private" + "CloudDatabase")`, the key split —
    /// naming neither `database` nor `privateCloudDatabase`, the only words
    /// R3 pinned; as planted it passed every lock. So, in every scan copy:
    /// - every line of the sender naming a `container` is pinned: the two
    ///   factories' constructions, the two holders, their inits and their
    ///   reads of the private database, the alert store's account check, and
    ///   the two texts that say the word (any new line naming a container
    ///   fails; the live classes are pinned whole, `liveClassFailures` — a
    ///   line pin alone does not hold the line after it, round 2's F-C);
    /// - and key-value coding — a property read or written by its name as a
    ///   string, on any object — is named nowhere in the sender (no site
    ///   today; the record's fields are set by subscript). AMENDED (round
    ///   2, F-C): nor are its evaluators and observers — `NSExpression`,
    ///   `NSPredicate`, `NSSortDescriptor`, any `forKeyPath`, `#keyPath`,
    ///   `addObserver` (no site today).
    /// Belt and braces: each alone catches G2, on either live conformer.
    static let containerSites: [String: Int] = [
        "static let containerText = \"the NapCat iCloud container is not set up\"": 1,
        "return LiveCloudKitAlertStore(container: CKContainer(identifier: AlertWire.containerIdentifier))": 1,
        "return LivePairingRecordDatabase(container: CKContainer(identifier: ApprovalWire.containerIdentifier))": 1,
        "private let container: CKContainer": 2,
        "init(container: CKContainer) {": 2,
        "self.container = container": 4,
        "self.database = container.privateCloudDatabase": 2,
        "container.accountStatus { status, error in completion(status, error) }": 1,
        "static let containersEntitlement = \"com.apple.developer.icloud-container-identifiers\"": 1,
    ]

    /// Key-value coding's doors: `value(forKey:)`, `value(forKeyPath:)` and
    /// `value(forUndefinedKey:)`; every `setValue…`/`setValuesForKeys`/
    /// `setNilValueForKey`; the collection proxies and the bulk read.
    /// AMENDED (round 2, F-C — its N7 read the private database by
    /// `NSExpression(forKeyPath:)`'s evaluator): what evaluates a key path
    /// string — an expression, a predicate, a sort descriptor, any
    /// `forKeyPath` argument, `#keyPath` — and key-value observing.
    static let keyValueCodingBans = [#"\bvalue\s*\(\s*for(?:Undefined)?Key"#, #"\bset(?:Nil)?Values?\w*"#,
                                     #"\b(?:mutable(?:Ordered)?(?:Array|Set)Value|dictionaryWithValues)\b"#,
                                     #"\bNSExpression\b"#, #"\bNSPredicate\b"#, #"\bNSSortDescriptor\b"#, #"\bforKeyPath\b"#,
                                     #"#keyPath\b"#, #"\baddObserver\b"#]

    /// `file`: the sender, whole-line comments removed.
    static func containerSiteFailures(_ file: String) -> [String] {
        var failures: [String] = []
        for copy in LidGuardStructureTests.constructorScanCopies(file) {
            failures += ApprovalRecordPathStructureTests.siteFailures(
                #"\bcontainer\b"#, in: copy, file: cloudKitFile, allowed: containerSites,
                rule: "the containers are built, held and read for their database and account status on their pinned lines alone")
        }
        return ApprovalRecordPathStructureTests.unique(failures)
    }

    static func keyValueCodingFailures(_ file: String) -> [String] {
        var failures: [String] = []
        for copy in LidGuardStructureTests.constructorScanCopies(file) {
            for pattern in keyValueCodingBans where ApprovalRecordPathStructureTests.hits(pattern, in: copy) {
                failures.append("'\(pattern)' in \(cloudKitFile) — nothing reads or writes a property by its name as a string")
            }
        }
        return ApprovalRecordPathStructureTests.unique(failures)
    }

    static func containerNameFailures(_ file: String) -> [String] {
        ApprovalRecordPathStructureTests.unique(containerSiteFailures(file) + keyValueCodingFailures(file))
    }

    // MARK: - The two live classes, sealed (the delta re-check's round 2, F-C)

    /// AMENDED (S-PAIR-C1.5, the C1.5 security delta re-check's round 2,
    /// F-C): a line pin holds its own line, not the next one. A next line
    /// opening with `.member` (or a binary operator) extends a pinned
    /// expression and leaves the pinned line as it was: its N6 put `.zzAlso`
    /// under `self.database = container.privateCloudDatabase` in the live
    /// pairing database's init — a `CKDatabase` extension copying the
    /// database into a global, read in an extension of the class — and its
    /// N7 put `.zzKeep` under `self.container = container`, then read the
    /// private database off the copy by an `NSExpression` key path. Each
    /// passed every suite. So, in the sender:
    /// - each live class is pinned whole: its head once, its body flattened,
    ///   exactly as below (a new or longer line anywhere in it fails);
    /// - both `init(container:)` bodies — EVERY occurrence, since
    ///   `body(after:in:)` reads the first alone — are the holders' two
    ///   assignments and nothing more;
    /// - no extension of either live class is named, in every scan copy (no
    ///   site today), so no member joins a pinned body from outside it;
    /// - and the key-path evaluators join the key-value ban (above).
    static let alertStoreHead = "private final class LiveCloudKitAlertStore: CloudKitAlertStore, @unchecked Sendable {"
    static let pairingDatabaseHead = "private final class LivePairingRecordDatabase: PairingRecordDatabase, @unchecked Sendable {"
    static let liveInitHead = "init(container: CKContainer) {"
    static let liveInitBody = "self.container = container self.database = container.privateCloudDatabase"
    /// What both live classes open with: their two holders and their init.
    static let liveHolders: String = ["private let container: CKContainer", "private let database: CKDatabase",
                                      liveInitHead, liveInitBody, "}"].joined(separator: " ")
    /// The live alert store, whole: the holders, the account check, the one save.
    static let alertStoreBody: String = [
        liveHolders,
        "func accountStatus(completion: @escaping @Sendable (CKAccountStatus, (any Error)?) -> Void) {",
        "container.accountStatus { status, error in completion(status, error) } }",
        "func save(_ payload: CloudKitAlertPayload, completion: @escaping @Sendable ((any Error)?) -> Void) {",
        alertSave, "}",
    ].joined(separator: " ")
    /// The live pairing database, whole: the holders and the two checked submits.
    static let pairingDatabaseBody: String = [
        liveHolders,
        "func submit(_ operation: CKFetchRecordsOperation) {", pairingSubmitBody, "}",
        "func submit(_ operation: CKModifyRecordsOperation) {", pairingSubmitBody, "}",
    ].joined(separator: " ")
    static let liveClassExtension = #"\bextension\s+Live(?:PairingRecordDatabase|CloudKitAlertStore)\b"#

    /// `file`: the sender, whole-line comments removed.
    static func liveClassBodyFailures(_ file: String) -> [String] {
        var failures: [String] = []
        let flat: (String?) -> String = { body in body.map { MenuPanelStructureTests.flat($0) } ?? "<no closing brace>" }
        let classes: [(head: String, body: String, rule: String)] = [
            (alertStoreHead, alertStoreBody, "the live alert store is pinned whole: its holders, its account check and its one save"),
            (pairingDatabaseHead, pairingDatabaseBody, "the live pairing database is pinned whole: its holders and its two checked submits"),
        ]
        for (head, pinned, rule) in classes {
            let found: [String] = bodies(after: head, in: file).map(flat)
            if found != [pinned] { failures.append("\(rule) — once, exactly as pinned (\(found.count) found)") }
        }
        let inits: [String] = bodies(after: liveInitHead, in: file).map(flat)
        if inits != [liveInitBody, liveInitBody] {
            failures.append("both live inits hold the container and read its private database, nothing more — "
                            + "every occurrence, exactly as pinned (\(inits.count) found)")
        }
        return failures
    }

    static func liveClassExtensionFailures(_ file: String) -> [String] {
        var failures: [String] = []
        for copy in LidGuardStructureTests.constructorScanCopies(file)
        where ApprovalRecordPathStructureTests.hits(liveClassExtension, in: copy) {
            failures.append("'\(liveClassExtension)' in \(cloudKitFile) — no member joins a live class outside its pinned body")
        }
        return ApprovalRecordPathStructureTests.unique(failures)
    }

    static func liveClassFailures(_ file: String) -> [String] {
        ApprovalRecordPathStructureTests.unique(liveClassBodyFailures(file) + liveClassExtensionFailures(file))
    }

    /// F-C's canaries: N6 and N7, verbatim; N6 on the live alert store; and
    /// N6's copy made by a line opening with a binary operator. Each is
    /// caught by the body pin alone; without the read that follows it (an
    /// extension, an evaluator), each continuation is caught by the body pin
    /// and by nothing else in the alert lane's lock — the gap.
    @Test func theLiveClassesArePinnedWhole() throws {
        let sources = try LidGuardStructureTests.swiftSources(LidGuardStructureTests.wholeLineCommentsRemoved)
        let file = Self.cloudKitFile
        let sender = sources.first(where: { $0.name == file })?.text ?? ""
        #expect(Self.liveClassFailures(sender).isEmpty, "\(Self.liveClassFailures(sender))")
        #expect(Self.bodies(after: Self.liveInitHead, in: sender).count == 2, "vacuity: both live inits are read")
        // The re-check's texts (its gapplant.py), verbatim.
        let pairInit: String = "private final class LivePairingRecordDatabase: PairingRecordDatabase, @unchecked Sendable {\n"
            + "    private let container: CKContainer\n    private let database: CKDatabase\n\n    init(container: CKContainer) {\n"
            + "        self.container = container\n        self.database = container.privateCloudDatabase\n"
        let stash: String = "\nenum ZZStash { nonisolated(unsafe) static var db: CKDatabase?; nonisolated(unsafe) static var c: CKContainer? }\n"
            + "extension CKDatabase { var zzAlso: CKDatabase { ZZStash.db = self; return self } }\n"
            + "extension CKContainer { var zzKeep: CKContainer { ZZStash.c = self; return self } }\n"
        let n6Read: String = "extension LivePairingRecordDatabase {\n    func zz(_ i: CKRecord.ID) {\n"
            + "        ZZStash.db?.fetch(withRecordID: i) { _, _ in }\n    }\n}\n"
        let n7Old: String = "    init(container: CKContainer) {\n        self.container = container\n"
            + "        self.database = container.privateCloudDatabase\n    }\n\n    func submit(_ operation: CKFetchRecordsOperation) {"
        let n7New: String = "    init(container: CKContainer) {\n        self.container = container\n            .zzKeep\n"
            + "        self.database = container.privateCloudDatabase\n    }\n\n    func submit(_ operation: CKFetchRecordsOperation) {"
        let n7Read: String = "extension LivePairingRecordDatabase {\n    func zz(_ i: CKRecord.ID) {\n"
            + "        (NSExpression(forKeyPath: \"private\" + \"CloudDatabase\").expressionValue(with: ZZStash.c, context: nil) "
            + "as? CKDatabase)?.fetch(withRecordID: i) { _, _ in }\n    }\n}\n"
        // N6 on the live alert store: its head, and its extension's type.
        let alertInit: String = pairInit.replacingOccurrences(of: "LivePairingRecordDatabase: PairingRecordDatabase",
                                                              with: "LiveCloudKitAlertStore: CloudKitAlertStore")
        let n6AlertRead: String = n6Read.replacingOccurrences(of: "LivePairingRecordDatabase", with: "LiveCloudKitAlertStore")
        // A leading binary operator continues the line as `.zzAlso` did.
        let databaseLine: String = "        self.database = container.privateCloudDatabase\n    }\n\n    func submit(_ operation: CKFetchRecordsOperation) {"
        let operatorLine: String = "        self.database = container.privateCloudDatabase\n            + ZZTag()\n    }\n\n"
            + "    func submit(_ operation: CKFetchRecordsOperation) {"
        let operatorStash: String = "\nstruct ZZTag {}\nenum ZZHeld { nonisolated(unsafe) static var db: CKDatabase? }\n"
            + "func + (l: CKDatabase, r: ZZTag) -> CKDatabase { ZZHeld.db = l; return l }\n"
        let operatorRead: String = "func zzHeldRead(_ i: CKRecord.ID) {\n    ZZHeld.db?.fetch(withRecordID: i) { _, _ in }\n}\n"
        for anchor in [pairInit, alertInit, n7Old, databaseLine] {
            #expect(Self.occurrences(of: anchor, in: sender) == 1, "vacuity: each continuation plants once")
        }
        let n6Extend: (String) -> String = { $0.replacingOccurrences(of: pairInit, with: pairInit + "            .zzAlso\n") + stash }
        let n7Extend: (String) -> String = { $0.replacingOccurrences(of: n7Old, with: n7New) + stash }
        let n6AlertExtend: (String) -> String = { $0.replacingOccurrences(of: alertInit, with: alertInit + "            .zzAlso\n") + stash }
        let operatorExtend: (String) -> String = { $0.replacingOccurrences(of: databaseLine, with: operatorLine) + operatorStash }
        let continuations: [(name: String, extend: (String) -> String, read: String)] = [
            ("N6: the pairing database's database line continued by .zzAlso", n6Extend, n6Read),
            ("N7: the pairing database's container line continued by .zzKeep", n7Extend, n7Read),
            ("N6 on the live alert store", n6AlertExtend, n6AlertRead),
            ("the database line continued by a leading binary operator", operatorExtend, operatorRead),
        ]
        for (name, extend, read) in continuations {
            let planted: String = extend(sender) + read
            #expect(planted != sender, "canary '\(name)' did not apply")
            #expect(!Self.liveClassBodyFailures(planted).isEmpty, "canary '\(name)' was NOT caught by the body pin")
            // The continuation alone: the body pin, and nothing else in the lane's lock.
            let alone = Self.mutate(sources, file, extend)
            let text = alone.first(where: { $0.name == file })?.text ?? ""
            #expect(!Self.liveClassBodyFailures(text).isEmpty, "canary '\(name)' alone was NOT caught by the body pin")
            #expect(Self.alertLaneWriteFailures(alone) == Self.liveClassBodyFailures(text), "canary '\(name)' alone: another rule fired")
        }
        // The extension ban, alone, however the extension is spelled.
        let extensions: [String] = [n6Read, n6AlertRead, "extension `LivePairingRecordDatabase` { }",
                                    "extension /* x */ LiveCloudKitAlertStore: Equatable { }",
                                    "extension\n    LivePairingRecordDatabase { }"]
        for planted in extensions {
            let text: String = sender + "\n" + planted
            #expect(Self.liveClassBodyFailures(text).isEmpty, "vacuity: '\(planted)' leaves both bodies as pinned")
            #expect(!Self.liveClassExtensionFailures(text).isEmpty, "'\(planted)' was NOT caught by the extension ban")
        }
        // Each body: a member added or dropped, a decoy head before it, a
        // third init — each fails.
        let memberAdded: String = Self.alertStoreHead + "\n    var zz: Int { 0 }"
        let secondSubmit: String = "    func submit(_ operation: CKModifyRecordsOperation) {\n        " + Self.pairingCheck
            + "\n        database.add(operation)\n    }\n"
        let decoy: String = "/*\n" + Self.pairingDatabaseHead + "\n}\n*/\n" + sender
        let thirdInit: String = sender + "\nstruct ZZ {\n    init(container: CKContainer) {\n    }\n}"
        let bodyDoors: [(String, String)] = [
            ("a member added to the alert store", sender.replacingOccurrences(of: Self.alertStoreHead, with: memberAdded)),
            ("the pairing database's second submit dropped", sender.replacingOccurrences(of: secondSubmit, with: "")),
            ("a decoy head before the class", decoy),
            ("a third init", thirdInit),
        ]
        for (name, planted) in bodyDoors {
            #expect(planted != sender, "canary '\(name)' did not apply")
            #expect(!Self.liveClassBodyFailures(planted).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: words that only contain the class names, and
        // a whole-line comment inside a class body.
        let near: String = "\nlet zzExtensionLiveCloudKitAlertStore = 1\nstruct LiveCloudKitAlertStoreFake {}\nextension LiveCloudKitAlertStoreFake {}"
            + "\nextension LivePairingRecordDatabases {}"
        #expect(Self.liveClassFailures(sender + near).isEmpty)
        let commented = Self.mutate(sources, file) {
            LidGuardStructureTests.wholeLineCommentsRemoved($0.replacingOccurrences(
                of: Self.pairingDatabaseHead, with: Self.pairingDatabaseHead + "\n    // a comment inside the class"))
        }
        let commentedText: String = commented.first(where: { $0.name == file })?.text ?? ""
        #expect(commentedText != sender, "vacuity: the removed comment leaves its blank line in the class")
        #expect(Self.liveClassFailures(commentedText).isEmpty)
    }

    /// F-B's canaries: G2, as planted, on the live pairing database and on
    /// the live alert store (each is caught by the pin alone and by the ban
    /// alone, and by nothing else in the alert lane's lock — the gap — but
    /// the extension ban round 2 added), the doors around it, and round 2's
    /// N8.
    @Test func theSendersContainersAreNamedOnTheirLinesAlone() throws {
        let sources = try LidGuardStructureTests.swiftSources(LidGuardStructureTests.wholeLineCommentsRemoved)
        let file = Self.cloudKitFile
        let sender = sources.first(where: { $0.name == file })?.text ?? ""
        #expect(sender.contains("private let container: CKContainer"), "vacuity: the sender is in the scan")
        #expect(Self.containerNameFailures(sender).isEmpty, "\(Self.containerNameFailures(sender))")
        let g2Read: String = "    func zz(_ i: CKRecord.ID) {\n"
            + "        (container.value(forKey: \"private\" + \"CloudDatabase\") as? CKDatabase)?.fetch(withRecordID: i) { _, _ in }\n    }\n}\n"
        let g2Pairing: String = "\nextension LivePairingRecordDatabase {\n" + g2Read
        let g2Alert: String = "\nextension LiveCloudKitAlertStore {\n" + g2Read
        let g2: [(String, [(name: String, text: String)])] = [
            ("G2, as planted: the pairing database's container read by key-value coding", Self.mutate(sources, file) { $0 + g2Pairing }),
            ("G2 on the live alert store", Self.mutate(sources, file) { $0 + g2Alert }),
        ]
        for (name, mutant) in g2 {
            let text = mutant.first(where: { $0.name == file })?.text ?? ""
            #expect(text != sender, "canary '\(name)' did not apply")
            #expect(!Self.containerSiteFailures(text).isEmpty, "canary '\(name)' was NOT caught by the container pin")
            #expect(!Self.keyValueCodingFailures(text).isEmpty, "canary '\(name)' was NOT caught by the key-value ban")
            // The alert lane's lock catches it by these two alone — and,
            // since round 2's F-C, by the extension ban (G2 extends a live
            // class); never by the body pin (no body changes).
            #expect(Self.liveClassBodyFailures(text).isEmpty, "canary '\(name)': a live class's body changed")
            #expect(Self.alertLaneWriteFailures(mutant) == Self.containerNameFailures(text) + Self.liveClassExtensionFailures(text),
                    "canary '\(name)': another rule fired")
        }
        // Round 2's N8 (the re-check's control): the private database by an
        // `NSExpression` key path, the container named — caught by the
        // container pin (as before) and by the evaluator ban alone too.
        let n8: String = "\nextension LivePairingRecordDatabase {\n    func zz() -> Any? {\n"
            + "        NSExpression(forKeyPath: \"private\" + \"CloudDatabase\").expressionValue(with: container, context: nil)\n    }\n}\n"
        let n8Text: String = sender + n8
        #expect(!Self.containerSiteFailures(n8Text).isEmpty, "N8 was NOT caught by the container pin")
        #expect(!Self.keyValueCodingFailures(n8Text).isEmpty, "N8 was NOT caught by the key-value ban")
        // N7's form of it: no container named — the pin cannot see it, the ban does.
        let n8Unnamed: String = sender + n8.replacingOccurrences(of: "container", with: "zz")
        #expect(Self.containerSiteFailures(n8Unnamed).isEmpty, "vacuity: N8 with no container named passes the pin")
        #expect(!Self.keyValueCodingFailures(n8Unnamed).isEmpty, "N8 with no container named was NOT caught by the key-value ban")
        let handedOut: String = "\nextension LivePairingRecordDatabase { var zz: CKContainer { container } }"
        let byKeyPath: String = "\nextension LiveCloudKitAlertStore { func zz() -> Any { self[keyPath: \\.container] } }"
        let backticked: String = "\nextension LiveCloudKitAlertStore { func zz() -> Any? { container.`value`(forKey: \"zz\") } }"
        let databaseByName: String = "\nextension LivePairingRecordDatabase { func zz() -> Any? { database.value(forKeyPath: \"zz\") } }"
        let doors: [(String, [(name: String, text: String)])] = [
            ("the container handed out", Self.mutate(sources, file) { $0 + handedOut }),
            ("the container by key path", Self.mutate(sources, file) { $0 + byKeyPath }),
            ("a backticked key-value read", Self.mutate(sources, file) { $0 + backticked }),
            ("the database read by a key path string", Self.mutate(sources, file) { $0 + databaseByName }),
        ]
        for (name, mutant) in doors {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.alertLaneWriteFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Each ban bites through the lock's own engine, in every scan copy.
        let probes: [String] = ["c.value(forKey: k)", "c.setValue(v, forKeyPath: k)", "c.mutableArrayValue(forKey: k)",
                                "NSExpression(format: f)", "NSPredicate(format: f)", "NSSortDescriptor(key: k, ascending: true)",
                                "c.removeObserver(o, forKeyPath: k)", "#keyPath(C.p)", "c.addObserver(o, forKeyPath: k, context: nil)"]
        #expect(probes.count == Self.keyValueCodingBans.count)
        for (pattern, probe) in zip(Self.keyValueCodingBans, probes) {
            #expect(ApprovalRecordPathStructureTests.hits(pattern, in: probe), "'\(pattern)' does not match '\(probe)'")
        }
        let spellings: [String] = ["c.value(forKeyPath: k)", "c.value (forUndefinedKey: k)", "c.`value`(forKey: k)",
                                   "c.value/* x */(forKey: k)", "c.setValuesForKeys(d)", "c.setNilValueForKey(k)",
                                   "c.mutableOrderedSetValue(forKey: k)", "c.dictionaryWithValues(forKeys: k)"]
        for spelling in spellings {
            #expect(!Self.keyValueCodingFailures(spelling).isEmpty, "'\(spelling)' was NOT caught")
        }
        // Over-match controls: words that only contain the pinned or banned
        // ones.
        let near: String = "\nlet containerName = 1, containers = 2, isContainer = 3, valueForKeyCount = 4, settings = 5, zz = d.values"
            + "\nlet zzNSExpressions = 6, predicateText = 7, forKeyPaths = 8, keyPathName = 9, addObservers = 10, sortDescriptor = 11"
        #expect(Self.containerNameFailures(sender + near).isEmpty)
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
            // S-PAIR-C1.5 (#170): the pairing database runs only what it is
            // handed — no operation of its own, no alert, no third add.
            ("the pairing database builds its own fetch", Self.mutate(sources, file) {
                $0 + "\nextension LivePairingRecordDatabase { func f(_ i: CKRecord.ID) { submit(CKFetchRecordsOperation(recordIDs: [i])) } }" }),
            ("the pairing database adds a hand-built save", Self.mutate(sources, file) {
                $0 + "\nextension LivePairingRecordDatabase { func f(_ r: CKRecord) { "
                    + "database.add(CKModifyRecordsOperation(recordsToSave: [r], recordIDsToDelete: nil)) } }" }),
            ("the alert's operation handed to the pairing database", Self.mutate(sources, file) {
                $0 + "\nextension CloudKitMessageSender { static func f(d: any PairingRecordDatabase, p: CloudKitAlertPayload) { "
                    + "d.submit(makeSaveOperation(p) { _ in }) } }" }),
            ("a third add of a handed-in operation", Self.mutate(sources, file) {
                $0 + "\nextension LivePairingRecordDatabase { func again(_ operation: CKModifyRecordsOperation) {\n"
                    + "        database.add(operation)\n    } }" }),
        ]
        // The C1.5 security review's R3 (its F5): RP3' (a read slipped inside
        // the pinned fetch submit) and RP3b (a convenience read beside it),
        // as planted, and the other convenience doors on either database.
        let fetchSubmit = "    func submit(_ operation: CKFetchRecordsOperation) {\n        " + Self.pairingCheck
            + "\n        database.add(operation)\n"
        let senderText = sources.first(where: { $0.name == file })?.text ?? ""
        #expect(senderText.contains(fetchSubmit), "vacuity: RP3' plants inside the fetch submit")
        let r3: [(String, [(name: String, text: String)])] = [
            ("RP3': a read inside the pinned submit", Self.mutate(sources, file) {
                $0.replacingOccurrences(of: fetchSubmit, with: fetchSubmit
                                        + "        database.fetch(withRecordID: CKRecord.ID(recordName: \"zz\")) { _, _ in }\n") }),
            ("RP3b: a convenience read beside it", Self.mutate(sources, file) {
                $0 + "\nextension LivePairingRecordDatabase {\n"
                    + "    func zzSecRevPeek(_ id: CKRecord.ID) async -> Bool {\n        (try? await database.record(for: id)) != nil\n    }\n}" }),
            ("records(for:)", Self.mutate(sources, file) {
                $0 + "\nextension LivePairingRecordDatabase { func zz(_ i: CKRecord.ID) async throws -> Int { "
                    + "try await database.records(for: [i]).count } }" }),
            ("allRecordZones()", Self.mutate(sources, file) {
                $0 + "\nextension LivePairingRecordDatabase { func zz() async throws -> Int { try await database.allRecordZones().count } }" }),
            ("the alert store's convenience read (pre-existing door)", Self.mutate(sources, file) {
                $0 + "\nextension LiveCloudKitAlertStore { func zz(_ i: CKRecord.ID) async throws -> CKRecord { "
                    + "try await database.record(for: i) } }" }),
            ("the database handed out", Self.mutate(sources, file) {
                $0 + "\nextension LivePairingRecordDatabase { var zz: CKDatabase { database } }" }),
            ("the database by key path", Self.mutate(sources, file) {
                $0 + "\nextension LivePairingRecordDatabase { func zz() -> Any { self[keyPath: \\.database] } }" }),
            // R2: the check dropped, bypassed, widened or named elsewhere.
            ("the check dropped from the fetch submit", Self.mutate(sources, file) {
                $0.replacingOccurrences(of: fetchSubmit, with: "    func submit(_ operation: CKFetchRecordsOperation) {\n"
                                        + "        database.add(operation)\n") }),
            ("a refusal that adds anyway", Self.mutate(sources, file) {
                $0.replacingOccurrences(of: "else { return PairingRecordGuard.refuse(operation) }", with: "else { return database.add(operation) }") }),
            ("any zone admitted", Self.mutate(sources, file) {
                $0.replacingOccurrences(of: "id.zoneID.zoneName == ApprovalWire.zoneName && ", with: "") }),
            ("any name admitted", Self.mutate(sources, file) {
                $0.replacingOccurrences(of: "\n            && PairingResponseCheck.isRecordName(id.recordName)", with: "") }),
            ("a deletion that saves admitted", Self.mutate(sources, file) {
                $0.replacingOccurrences(of: "guard operation.recordsToSave?.isEmpty ?? true, let ids", with: "guard let ids") }),
            ("many records admitted", Self.mutate(sources, file) {
                $0.replacingOccurrences(of: "guard let ids = operation.recordIDs, ids.count == 1 else",
                                        with: "guard let ids = operation.recordIDs, !ids.isEmpty else") }),
            ("a refusal that tells nothing", Self.mutate(sources, file) {
                $0.replacingOccurrences(of: "        operation.fetchRecordsResultBlock?(.failure(CKError(.invalidArguments)))\n", with: "") }),
            ("the check named elsewhere", Self.mutate(sources, "MenuStateModel.swift") { $0 + "\nlet zz = PairingRecordGuard.refuse" }),
        ]
        for (name, mutant) in mutants + r3 {
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
                + "\nlet databases = 2, databaseName = \"y\", zzPairingRecordGuards = 3"
                + LidGuardStructureTests.wholeLineCommentsRemoved(
                    "\n    /// never database.save(record), never modifyRecords, never a second add(operation)"
                        + "\n    /// never database.record(for:), never PairingRecordGuard.refuse elsewhere")
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
