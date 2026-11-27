import Foundation
import Testing

/// F4 slice S3: the phone's fail-dark locks over the record path (pending
/// requests in, decisions out). Design: design/remote-approvals.md.
///
/// Signed decisions (CL-1, pairing) arrive in a later slice, so in this one:
///
/// 1. the phone has no verdict machinery at all: it never builds the S0
///    decision type, never names its signature flag, and names nothing of
///    the Mac's lifecycle, intake, channel or gate. A decision the phone
///    writes is a request to the Mac, never a verdict;
/// 2. the CloudKit decision writer is built by no app source, and nothing in
///    the app conforms to its database seam: decisions are written by tests
///    and fakes only, so no CloudKit operation of this path can run
///    (AMENDED in S-PAIR-C1.6: the seam has one app conformer, the live
///    approvals database, which runs the pairing response's save alone, and
///    the pairing writer is built once, at the live wiring site);
/// 3. the S3 test files touch nothing live;
/// 4. Allow and Deny alike write only after a biometric match asked for
///    for that one answer (AMENDED in S-PAIR-B by the owner's uniform-signing
///    ruling: Deny asks too, every answer being signed), the match ends in
///    the one write site, and that site re-checks the window first (CL-3);
/// 5. the decision record is built once, only through the wire's keys and
///    encryption table, and (AMENDED in S-PAIR-B) carries the decision's own
///    signature, from the decision the signer built;
/// 6. (security review 2) the decision's record and its save operation are
///    each reached once, in `CloudKitDecisionWriter.write`, which hands the
///    operation to the seam, and nothing in the CloudKit file runs an
///    operation itself (#153: and the factory only configures and returns
///    its operation, pinned by its lines, not by banned words);
/// 7. (#153) the CloudKit file builds one record, one operation and one
///    subscription, however the construction is spelled.
///
/// Since #153 the constructor bans (locks 2 and 7) read the cleaned copies
/// too (`CloudKitStructureTests.constructorScanCopies`: backticks removed,
/// block comments replaced by a space), in addition to the raw text.
///
/// AMENDED (#166, the S-PAIR-B security review): every lock that counts a
/// construction, here and in the signing suites, also bans an implicit
/// `.init(` anywhere in the app (`implicitInitFailures`), and lock 2's seam
/// conformance reads a clause over any number of lines, a refining
/// protocol and a typealias (`CloudKitStructureTests.adoptionPattern`).
/// Lock 3's live tokens take in the signing suite's and the launch
/// factories that build them.
///
/// AMENDED (#168, the PR #167 review's lock-shape follow-ups): an implicit
/// `.init` after an operator and a space reads as implicit (the G9 shape);
/// lock 2 collects the database seam's other names; lock 4 pins the inbox's
/// `send`, `write` and `confirm` by NAME, not by a receiver's spelling, pins
/// every `confirmed` in the app, and bans reflection (`Mirror`); and two
/// app-wide locks join: 8, the guarded types' constructors are never reached
/// unnamed (no `Self(`, no operator declaration), and 9, no unsafe-memory
/// API (the Mac's lock 9b families).
///
/// AMENDED (S-PAIR-C1.5, #170, the live pairing transport): the CloudKit
/// file gains the pairing response's writer. Lock 2 builds it by no app
/// source either (and lock 8 never unnamed); lock 5 counts its record and a
/// twin of lock 5 pins its fields; lock 6 counts its create-only operation
/// beside the decision's; the new lock 6b pins its factory whole, its one
/// write, its outcome table, and bans every name for the record a conflict
/// hands back; lock 7 pins each record and operation construction's line.
///
/// AMENDED (S-PAIR-C1.6, #172, the phone goes live): lock 2's seam gets its
/// one app conformer, the live approvals database (its declaration's exact
/// line), and the pairing writer its one construction, at the live wiring
/// site, with the live names pinned app-wide; lock 3's live tokens take in
/// the two new factories; lock 6 admits the conformer's lines and pins its
/// database `add`; the new lock 6c pins the conformer and its check whole;
/// the new lock 6d pins the approvals zone's lookup and its one creation
/// (create only) whole, and lock 7 counts their constructions; lock 8
/// guards the conformer and the live pairing. The decision writer is still
/// built by no app source.
///
/// AMENDED (#194, the phone receives prompts, still unsent): the live
/// approvals database is built once, by the live inbox's factory, and
/// shared by the live pairing and the new live prompt source (lock 2 pins
/// both names, and the prompt source joins lock 8's guarded types); its
/// admit list grows to a decision's create-only save, the prompts' one
/// snapshot read and the prompt subscription's lookup, save and removal by
/// its one ID, each behind its own check, the conformer and every check
/// pinned whole (locks 6 and 6c); the new lock 6e pins the prompt path's
/// operations, their result holder and the prompt source whole, each
/// factory used once; lock 7 counts their constructions. The decision
/// writer is still built by no app source, and the live inbox writes
/// through the unsent writer (`SigningKeyStructureTests` lock 6): nothing
/// arms.
///
/// Each lock is a pure function over comment-stripped sources, and each
/// catches planted canaries, so none can pass vacuously. Lock 6 strips
/// whole-line comments only (trailing comments stay in, so it can only
/// over-match); since #155 neither stripper lets a `//` inside a string
/// literal hide a token.
@Suite struct RecordPathStructureTests {
    typealias Source = CloudKitStructureTests.Source

    static let appDir = CloudKitStructureTests.appDir
    static let cloudKitFile = CloudKitStructureTests.cloudKitFile

    static func app() throws -> [Source] {
        try CloudKitStructureTests.swiftFiles(under: appDir)
    }

    static func mutate(_ sources: [Source], _ path: String, _ transform: (String) -> String) -> [Source] {
        sources.map { $0.path == path ? ($0.path, transform($0.text)) : $0 }
    }

    /// A construction however it is spelled: `T.init(` and `T (` read as `T(`.
    static func constructionSpelling(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*\.\s*init\s*\("#, with: "(", options: .regularExpression)
            .replacingOccurrences(of: #"([A-Za-z0-9_])\s+\("#, with: "$1(", options: .regularExpression)
    }

    // MARK: 1. The phone has no verdict machinery

    static let verdictTokens = ["ApprovalDecision", "signatureVerified", "ApprovalLifecycle", "ApprovalEvent",
                                "remoteDecision", "deliverVerdict", "ApprovalIntake", "ApprovalChannel",
                                "verdictFrame", "ApprovalGate"]

    static func verdictFailures(_ app: [Source]) -> [String] {
        app.flatMap { path, text in
            let code = CloudKitStructureTests.codeOnly(text)
            return verdictTokens.filter { code.contains($0) }
                .map { "'\($0)' in \(path) — the phone writes requests to the Mac, never verdicts" }
        }
    }

    @Test func thePhoneHasNoVerdictMachinery() throws {
        let app = try Self.app()
        #expect(app.contains { $0.path == Self.cloudKitFile }, "vacuity: the scan sees the app")
        #expect(Self.verdictFailures(app).isEmpty, "\(Self.verdictFailures(app))")
        for planted in ["let d = ApprovalDecision(promptID: p, verdict: .allow, wireVersion: 1, signatureVerified: true)",
                        "let ok = decision.signatureVerified",
                        "var l = ApprovalLifecycle.open(id: i, classification: c, armed: true, now: 0)",
                        "let e = ApprovalEvent.remoteDecision(d)",
                        // #155: a URL in a string literal no longer hides the rest of its line.
                        "let u = \"https://x\"; let ok = decision.signatureVerified"] {
            let mutant = Self.mutate(app, Self.cloudKitFile) { $0 + "\n" + planted }
            #expect(!Self.verdictFailures(mutant).isEmpty, "canary '\(planted)' was NOT caught")
        }
        // A comment may name what it rules out.
        #expect(Self.verdictFailures(Self.mutate(app, Self.cloudKitFile) {
            $0 + "\n// never an ApprovalDecision here\n"
        }).isEmpty)
    }

    // MARK: 2. No live decision writer

    static let writerType = "CloudKitDecisionWriter"
    /// AMENDED (S-PAIR-C1.5, #170): the pairing response's CloudKit writer
    /// joins it, under the same rule — built by no app source in this slice
    /// (by name or not: the implicit-init ban below, lock 8's unnamed
    /// constructions and dynamic types), over the same unconformed seam.
    /// (S-PAIR-C1.6 builds it once, at the live wiring site: see below.)
    static let pairingWriterType = "CloudKitPairingResponseWriter"
    /// AMENDED (#166): a clause on any number of lines, a refining protocol
    /// or a typealias (the one-line scan missed all three).
    static let seamConformance = CloudKitStructureTests.adoptionPattern("CloudKitApprovalDatabase")

    /// AMENDED (S-PAIR-C1.6, #172, the phone goes live): the seam has ONE
    /// app conformer, the live approvals database, adopting it on its
    /// declaration's exact line; the pairing writer is built ONCE, at the
    /// live wiring site (`LivePairing.make`); and each live type — the
    /// database, the pairing writer — and the database's factory are named
    /// on their pinned lines alone, app-wide (a word, so an unapplied
    /// reference, a metatype or a shadow is a site too). The decision writer
    /// is still built by no app source: nothing arms.
    static let livePairingFile = "\(appDir)/Live/LivePairing.swift"
    static let liveDatabaseAdoption = "private struct LiveCloudKitApprovalDatabase: CloudKitApprovalDatabase {"
    static let pairingWriterConstruction = "writer = CloudKitPairingResponseWriter(database: database)"
    static let liveNameSites: [(word: String, sites: [String: Int])] = [
        ("LiveCloudKitApprovalDatabase", CloudKitStructureTests.appSites([
            "Live/CloudKitAlertSource.swift": [liveDatabaseAdoption: 1, "return LiveCloudKitApprovalDatabase(container: container)": 1]])),
        ("CloudKitPairingResponseWriter", CloudKitStructureTests.appSites([
            "Live/CloudKitAlertSource.swift": ["struct CloudKitPairingResponseWriter: PairingResponseWriter {": 1],
            "Live/LivePairing.swift": [pairingWriterConstruction: 1]])),
        // AMENDED (#194): built once, by the live inbox's factory, which
        // shares it with the live pairing and the live prompt source.
        ("makeLiveApprovalDatabase", CloudKitStructureTests.appSites([
            "Live/CloudKitAlertSource.swift": ["static func makeLiveApprovalDatabase() -> (any CloudKitApprovalDatabase)? {": 1],
            "Model/RequestInbox.swift": ["let database = CloudKitAlertSource.makeLiveApprovalDatabase()": 1]])),
        ("LivePromptSource", CloudKitStructureTests.appSites([
            "Live/LivePromptSource.swift": ["struct LivePromptSource: PromptSource {": 1],
            "Model/RequestInbox.swift": [livePromptSourceConstruction: 1]])),
    ]
    static let livePromptSourceConstruction = "prompts: database.map { LivePromptSource(database: $0) })"

    static func liveWriterFailures(_ app: [Source]) -> [String] {
        var failures: [String] = []
        var pairingWriters: [String: Int] = [:]
        var adoptions: [String: Int] = [:]
        for (path, text) in app {
            let code = CloudKitStructureTests.codeOnly(text)
            if constructionSpelling(code).contains(writerType + "(") {
                failures.append("\(path) builds the CloudKit decision writer — no app source may: nothing arms")
            }
            let built = CloudKitStructureTests.occurrences(of: pairingWriterType + "(", in: constructionSpelling(code))
            if built > 0 { pairingWriters[path] = built }
            for (line, count) in CloudKitStructureTests.siteTally(seamConformance, in: code) {
                adoptions["\(path): \(line)", default: 0] += count
            }
        }
        if pairingWriters != [livePairingFile: 1] {
            failures.append("the CloudKit pairing writer is built once, at the live wiring site: found \(pairingWriters)")
        }
        if adoptions != ["\(cloudKitFile): \(liveDatabaseAdoption)": 1] {
            failures.append("CloudKitApprovalDatabase has one app conformer, the live approvals database, on its pinned line: "
                            + "found \(adoptions.sorted { $0.key < $1.key })")
        }
        let stripped = app.map { ($0.path, CloudKitStructureTests.codeOnly($0.text)) }
        for (word, sites) in liveNameSites {
            failures += CloudKitStructureTests.appSiteFailures(#"\b"# + word + #"\b"#, in: stripped, allowed: sites,
                                                               rule: "'\(word)' is named on its pinned lines alone")
        }
        return failures
    }

    /// `liveWriterFailures` over every cleaned copy too (#153): a backticked
    /// or comment-split construction of the writer is a construction. And
    /// (#166) no implicit `.init(` in the app: it could build the writer
    /// unnamed.
    ///
    /// AMENDED (#168): every other name for the seam (a typealias or a
    /// refining protocol, in any file, Fixtures/ included) is itself an
    /// adoption no app source may make.
    static func liveWriterFailuresInEveryCopy(_ app: [Source]) -> [String] {
        let aliases = CloudKitStructureTests.seamNames("CloudKitApprovalDatabase", in: app).subtracting(["CloudKitApprovalDatabase"])
        return CloudKitStructureTests.unique(CloudKitStructureTests.constructorScanCopies(app).flatMap(liveWriterFailures)
            + implicitInitFailures(app, rule: "the CloudKit decision writer is built by no app source, by name or not")
            + aliases.sorted().map { "\($0) is another name for CloudKitApprovalDatabase — no app source may adopt the seam" })
    }

    @Test func noAppSourceBuildsALiveDecisionWriter() throws {
        let app = try Self.app()
        #expect(Self.liveWriterFailuresInEveryCopy(app).isEmpty, "\(Self.liveWriterFailuresInEveryCopy(app))")
        let cloudKit = CloudKitStructureTests.codeOnly(app.first { $0.path == Self.cloudKitFile }?.text ?? "")
        for declaration in ["struct CloudKitDecisionWriter: DecisionWriter", "protocol CloudKitApprovalDatabase: Sendable",
                            "func submit(_ operation: CKModifyRecordsOperation)",
                            "struct CloudKitPairingResponseWriter: PairingResponseWriter", Self.liveDatabaseAdoption] {
            #expect(cloudKit.contains(declaration), "vacuity: '\(declaration)' is what the lock looks for")
        }
        let feed = "\(Self.appDir)/Model/AlertFeed.swift"
        let fixturePairing = "\(Self.appDir)/Fixtures/FixturePairing.swift"
        let wiring = Self.livePairingFile
        let mutants: [(String, [Source])] = [
            // S-PAIR-C1.6 (#172): the writer's one construction, the one live
            // conformer and the live names, each held to its pinned line.
            ("a second pairing writer at the wiring site", Self.mutate(app, wiring) {
                $0.replacingOccurrences(of: "writer = UnsentPairingWriter()", with: "writer = CloudKitPairingResponseWriter(database: spare)") }),
            ("the pairing writer over another database", Self.mutate(app, wiring) {
                $0.replacingOccurrences(of: Self.pairingWriterConstruction, with: "writer = CloudKitPairingResponseWriter(database: SpareDatabase())") }),
            ("the live database named in another file", Self.mutate(app, feed) { $0 + "\nlet spare: Any = LiveCloudKitApprovalDatabase.self" }),
            ("the live database's factory called elsewhere", Self.mutate(app, feed) {
                $0 + "\nlet spare = CloudKitAlertSource.makeLiveApprovalDatabase()" }),
            ("the live database's factory unapplied", Self.mutate(app, feed) { $0 + "\nlet spare = CloudKitAlertSource.makeLiveApprovalDatabase" }),
            ("the live database's clause on the next line", Self.mutate(app, Self.cloudKitFile) {
                $0.replacingOccurrences(of: Self.liveDatabaseAdoption,
                                        with: "private struct LiveCloudKitApprovalDatabase:\n    CloudKitApprovalDatabase {") }),
            ("a second live database in the CloudKit file", Self.mutate(app, Self.cloudKitFile) {
                $0 + "\nprivate struct SpareApprovalDatabase: CloudKitApprovalDatabase { func submit(_ o: CKModifyRecordsOperation) {} }" }),
            ("the pairing writer named in a backticked shadow", Self.mutate(app, feed) {
                $0 + "\nenum Spare { static func `CloudKitPairingResponseWriter`() {} }" }),
            // #194: the live database built a second time, by the live
            // pairing again; a second prompt source; the decision writer
            // built over the shared database (nothing arms).
            ("the live pairing builds its own database again", Self.mutate(app, wiring) {
                $0.replacingOccurrences(of: "        if let database {\n",
                                        with: "        if let database = CloudKitAlertSource.makeLiveApprovalDatabase() {\n") }),
            ("a second prompt source", Self.mutate(app, feed) { $0 + "\nlet spare = LivePromptSource(database: d)" }),
            ("the live inbox armed over the shared database", Self.mutate(app, "\(Self.appDir)/Model/RequestInbox.swift") {
                $0.replacingOccurrences(of: "return RequestInbox(writer: UnsentDecisionWriter(),",
                                        with: "return RequestInbox(writer: CloudKitDecisionWriter(database: database!),") }),
            // S-PAIR-C1.5 (#170): the pairing writer built by an app source,
            // however spelled — a fixture included (a fixture launch writes
            // to a fixture).
            ("the pairing writer built by the fixture", Self.mutate(app, fixturePairing) {
                $0 + "\nfunc spare(d: any CloudKitApprovalDatabase) -> any PairingResponseWriter { CloudKitPairingResponseWriter(database: d) }" }),
            ("the pairing writer, init-spelled", Self.mutate(app, feed) { $0 + "\nlet w = CloudKitPairingResponseWriter.init(database: d)" }),
            ("the pairing writer by typed implicit init", Self.mutate(app, feed) {
                $0 + "\nlet w: CloudKitPairingResponseWriter = .init(database: d)" }),
            ("a backticked pairing writer", Self.mutate(app, feed) { $0 + "\nlet w = `CloudKitPairingResponseWriter`(database: d)" }),
            ("a comment-split pairing writer", Self.mutate(app, Self.cloudKitFile) {
                $0 + "\nlet w = CloudKitPairingResponseWriter/* x */(database: d)" }),
            ("the feed builds it", Self.mutate(app, feed) { $0 + "\nlet w = CloudKitDecisionWriter(database: d)" }),
            ("the init spelling", Self.mutate(app, feed) { $0 + "\nlet w = CloudKitDecisionWriter.init(database: d)" }),
            ("a spaced call", Self.mutate(app, Self.cloudKitFile) { $0 + "\nlet w = CloudKitDecisionWriter (database: d)" }),
            ("a live database", Self.mutate(app, Self.cloudKitFile) {
                $0 + "\nprivate struct LiveApprovalDatabase: CloudKitApprovalDatabase { func submit(_ o: Op) {} }" }),
            ("the alert database made live for it", Self.mutate(app, Self.cloudKitFile) {
                $0 + "\nextension LiveCloudKitAlertDatabase: Sendable, CloudKitApprovalDatabase {}" }),
            // #153: behind backticks or a block comment.
            ("a backticked writer", Self.mutate(app, feed) { $0 + "\nlet w = `CloudKitDecisionWriter`(database: d)" }),
            ("a comment-split writer", Self.mutate(app, feed) { $0 + "\nlet w = CloudKitDecisionWriter/* x */(database: d)" }),
            // #166: by a typed implicit init (the security review's B6/B9/B10
            // shape), and a seam conformance on the next line, through a
            // refining protocol, or through a typealias (B11-B13's shapes).
            ("a writer by typed implicit init", Self.mutate(app, feed) {
                $0 + "\nlet w: CloudKitDecisionWriter = .init(database: d)" }),
            ("a live database, its conformance on the next line", Self.mutate(app, Self.cloudKitFile) {
                $0 + "\nprivate struct LiveApprovalDatabase:\n    CloudKitApprovalDatabase { func submit(_ o: Op) {} }" }),
            ("a live database through a refining protocol", Self.mutate(app, feed) {
                $0 + "\nprotocol SpareDatabase: CloudKitApprovalDatabase {}\nstruct LiveApprovalDatabase: SpareDatabase { func submit(_ o: Op) {} }" }),
            ("a live database through a typealias", Self.mutate(app, feed) {
                $0 + "\ntypealias SpareDatabase = CloudKitApprovalDatabase\nstruct LiveApprovalDatabase: SpareDatabase { func submit(_ o: Op) {} }" }),
            ("a seam conformance behind a block comment holding a brace", Self.mutate(app, feed) {
                $0 + "\nstruct LiveApprovalDatabase /* { */: CloudKitApprovalDatabase { func submit(_ o: Op) {} }" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.liveWriterFailuresInEveryCopy(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: the seam as a parameter, a doc comment naming
        // a conformance, and inits that name what they build (a delegating
        // `self.init(`, `super.init(`, an unapplied `Date.init`).
        #expect(Self.liveWriterFailuresInEveryCopy(Self.mutate(app, feed) {
            $0 + "\n/// never struct X: CloudKitApprovalDatabase, never let w: CloudKitDecisionWriter = .init(database: d)"
                + "\nfunc spare(d: any CloudKitApprovalDatabase) -> Bool { true }"
        }).isEmpty)
        #expect(Self.implicitInitFailures([("x", "init(a: Int) { self.init(b: a) }\nsuper.init()\nlet now: () -> Date = Date.init")],
                                          rule: "").isEmpty)
    }

    // MARK: 3. The S3 tests touch nothing live

    static let testsDir = CloudKitStructureTests.testsDir
    /// The S3 test files that run anything (this file only reads sources).
    /// AMENDED (#194): and the prompt path's (fakes and real operations only).
    static let s3TestFiles = ["ApprovalRecordFakes.swift", "RequestInboxTests.swift", "CloudKitRequestRecordTests.swift",
                              "RequestAnsweringTests.swift", "PendingRequestScreenTests.swift",
                              "CloudKitDecisionWriterTests.swift", "VisibleWhitespaceTests.swift",
                              "CloudKitPairingWriterTests.swift", "CloudKitPromptSourceTests.swift"]

    /// A container, a live database or source, the real defaults, the
    /// notification center and the real biometric prompt. AMENDED (#166):
    /// and since S-PAIR-B the live key parts (`SigningKeyStructureTests`'
    /// tokens: the enclave, the keychain, a context, the live bindings) and
    /// the launch factories that build them (the inbox's, by name or as an
    /// implicit member).
    /// AMENDED (S-PAIR-C1.6, #172): and the live approvals database's
    /// factory and the live pairing's.
    static let liveTokens = ["CKContainer", "privateCloudDatabase", "makeLive(", "UserDefaults.standard",
                             "UNUserNotificationCenter", "SystemNotificationGate(", "RequestInbox.make", ".make(options:",
                             "makeLiveApprovalDatabase", "LivePairing.make"]
        + SigningKeyStructureTests.liveTokens

    /// Read in its construction spelling (#166), as the signing suites'
    /// scans are: `T.init(` and `T (` read as `T(`.
    static func liveFailures(_ tests: [Source]) -> [String] {
        tests.flatMap { path, text in
            let code = constructionSpelling(CloudKitStructureTests.codeOnly(text))
            return liveTokens.filter { code.contains($0) }.map { "'\($0)' in \(path) — S3 tests touch nothing live" }
        }
    }

    static func s3Tests() throws -> [Source] {
        let all = try CloudKitStructureTests.swiftFiles(under: testsDir)
        return s3TestFiles.map { name in
            let path = "\(testsDir)/\(name)"
            return (path, all.first { $0.path == path }?.text ?? "")
        }
    }

    @Test func theS3TestsTouchNothingLive() throws {
        let tests = try Self.s3Tests()
        #expect(tests.allSatisfy { !$0.text.isEmpty }, "vacuity: every listed file was read")
        #expect(Self.liveFailures(tests).isEmpty, "\(Self.liveFailures(tests))")
        // The container constructor is split: no test spells it (CloudKitStructureTests).
        for planted in ["let c = " + "CKContainer" + "(identifier: i)", "let d = UserDefaults.standard",
                        "let g = LAContext()", "let s = CloudKitAlertSource.makeLive()",
                        "let n = UNUserNotificationCenter.current()",
                        // #166: the live key parts and the factories that build them.
                        "let k = try SecureEnclave.P256.Signing.PrivateKey()", "_ = SecItemCopyMatching(q, &r)",
                        "let s = KeychainSigningKeyStore.phoneKeychain", "let s = KeychainSigningKeyStore(calls: .securityFramework)",
                        "let e = SecureEnclaveSigner()", "let e = SecureEnclaveSigner.init()", "let e = SecureEnclaveSigner ()",
                        "let m = LocalAuthenticationMatch(c)", "let n = LocalAuthenticationEnrollment.init()",
                        "let g = LocalAuthenticationGate.init()", "let i = RequestInbox.make(options: o, now: n)",
                        "let make = RequestInbox.make", "let i: RequestInbox = .make(options: o, now: n)",
                        "let d = CloudKitAlertSource.makeLiveApprovalDatabase()", "let p = LivePairing.make(keyring: k, biometrics: g)"] {
            let mutant = tests.map { ($0.path, $0.text + "\n" + planted) }
            #expect(!Self.liveFailures(mutant).isEmpty, "canary '\(planted)' was NOT caught")
        }
        // A whole-line comment may name what the tests never touch.
        #expect(Self.liveFailures(tests.map { ($0.path, $0.text + "\n/// never RequestInbox.make(options:now:), never SecureEnclaveSigner()") })
            .isEmpty)
    }

    // MARK: 4. Every answer needs its match; one write site re-checks the window

    static let inboxFile = "\(appDir)/Model/RequestInbox.swift"

    /// In the inbox (AMENDED in S-PAIR-B, the owner's uniform-signing
    /// ruling): Allow and Deny each open on the answerable check and go to
    /// `confirmAndSend` and nowhere else; it asks the gate for a match for
    /// that answer, in that answer's words, returns unless it got one, and
    /// only then sends with it. The gate is asked in one place and the
    /// writer reached in one place, `send`, whose first acts are to end the
    /// match on every path out and to re-check that the request is still
    /// pending. (S-PAIR-B: the signature sits between that re-check and the
    /// write; `DecisionSignerTests` pins the order. AMENDED in the S-PAIR-B
    /// design review: the answer waiting for its match names its own
    /// verdict, `.confirming(verdict)`, so the screen says which answer the
    /// match will sign.)
    ///
    /// AMENDED (#154): the answerable check names the answer, and is pinned
    /// whole: it asks the request's status whether THAT answer is on offer,
    /// with the answer iCloud left unconfirmed folded in, so once one is,
    /// the other answer asks for no match. That answer is set in one place,
    /// after the write, and never cleared; the signed decision is named only
    /// where the signer hands it over and where it is written, so no
    /// signature outlives its write (a resend is signed afresh).
    /// AMENDED (the #154 security spot-check): and so is the signer's
    /// outcome that holds it (`signing`): bound, unwrapped, and read for
    /// the unsigned note, nothing else, so neither can be kept across the
    /// unconfirmed state without a new site.
    static func allowPathFailures(_ inbox: String) -> [String] {
        let code = CloudKitStructureTests.codeOnly(inbox)
        var failures: [String] = []
        guard let allow = CloudKitStructureTests.body(after: "func allow(_ id: PromptID) async {", in: code),
              let deny = CloudKitStructureTests.body(after: "func deny(_ id: PromptID) async {", in: code),
              let answerable = CloudKitStructureTests.body(after: answerableHead, in: code),
              let confirm = CloudKitStructureTests.body(
                after: "private func confirmAndSend(_ verdict: ApprovalWire.Verdict, for id: PromptID) async {", in: code),
              let send = CloudKitStructureTests.body(
                after: "private func send(_ verdict: ApprovalWire.Verdict, for id: PromptID, match: any BiometricMatch) async {",
                in: code) else {
            return ["allow, deny, isAnswerable, confirmAndSend or send moved (the lock would be vacuous)"]
        }
        for (name, body, verdict) in [("Allow", allow, "allow"), ("Deny", deny, "deny")]
        where SettingsReachabilityTests.flat(body)
            != "guard isAnswerable(id, with: .\(verdict)) else { return } await confirmAndSend(.\(verdict), for: id)" {
            failures.append("\(name) must open on the answerable check for itself, then ask for its match (confirmAndSend), nothing else")
        }
        if SettingsReachabilityTests.flat(answerable) != answerableBody {
            failures.append("isAnswerable must ask the status, with the unconfirmed answer folded in, whether that answer is on offer")
        }
        let confirmBody = "entries[id]?.answer = .confirming(verdict) "
            + "guard case .confirmed(let match) = await biometrics.confirm(reason: Self.reason(for: verdict)) else { "
            + "entries[id]?.answer = .notConfirmed return } await send(verdict, for: id, match: match)"
        if SettingsReachabilityTests.flat(confirm) != confirmBody {
            failures.append("confirmAndSend must ask for the match, return without one, and only then send with it")
        }
        let sendFlat = SettingsReachabilityTests.flat(send)
        if !sendFlat.hasPrefix("defer { match.invalidate() } tick() "
                               + "guard phase(of: id)?.isPending == true, let request = entries[id]?.request else {") {
            failures.append("send must end the match on every path and re-check that the request is still pending first")
        }
        for (token, count) in [("confirmAndSend(.allow", 1), ("confirmAndSend(.deny", 1), ("match.invalidate()", 1)]
        where CloudKitStructureTests.occurrences(of: token, in: code) != count {
            failures.append("'\(token)' must appear exactly \(count) time(s) in the inbox")
        }
        if !send.contains("writer.write(") { failures.append("the one write must be in send") }
        // AMENDED (#168, the PR #167 review's (b)): `send`, `write` and
        // `confirm` pinned by NAME — every line naming one, whatever its
        // receiver — so `let g = biometrics; g.confirm(…)` or `let f = send;
        // await f(…)` is a new site, not an uncounted spelling.
        let named = Self.literalsEmptied(code)
        for (word, sites) in inboxNameSites {
            failures += CloudKitStructureTests.siteFailures(#"\b"# + word + #"\b"#, in: named, file: inboxFile, allowed: sites,
                                                            rule: "the inbox reaches '\(word)' at its pinned sites only")
        }
        return failures
    }

    /// Every one-line string literal (plain or raw) emptied (the twin of
    /// `PairingCeremonyTests.literalsEmptied`, which is main-actor bound).
    static func literalsEmptied(_ code: String) -> String {
        code.replacingOccurrences(of: ##"#"(?:[^"\n]|"(?!#))*"#|"(?:[^"\\\n]|\\.)*""##, with: "\"\"", options: .regularExpression)
    }

    /// The answerable check (#154), whole.
    /// AMENDED (#194 polish, security I1): it opens on the read-only fact,
    /// so a read-only inbox asks for no match and signs nothing.
    static let answerableHead: String = "private func isAnswerable(_ id: PromptID, with verdict: ApprovalWire.Verdict) -> Bool {"
    static let answerableBody: String = "if isReadOnly { return false } tick() refreshKeyHealth() if case .unpaired = keyHealth { return false } "
        + "guard let entry = entries[id], phase(of: id)?.isPending == true else { return false } "
        + "let status: RequestStatus = RequestStatus(phase: .pending(until: entry.answerableUntil), answer: entry.answer, "
        + "mayHaveLanded: entry.mayHaveLanded) return status.answers.contains(verdict)"

    /// Every line of the inbox naming `send`, `write` or `confirm` (string
    /// literals emptied: the reasons' words are copy, not calls).
    /// AMENDED (#154): and `mayHaveLanded` (declared, read by the status and
    /// the answerable check, set once after an unconfirmed write, never
    /// cleared) and `decision` (bound from the signer, written, nothing
    /// else: no decision is kept for a resend).
    /// AMENDED (the #154 security spot-check): and `signing`, the signer's
    /// outcome holding that decision (bound once, unwrapped once, read once
    /// for the unsigned note): kept anywhere, it names no `decision`.
    static let inboxNameSites: [(String, [String: Int])] = [
        ("send", ["await send(verdict, for: id, match: match)": 1,
                  "private func send(_ verdict: ApprovalWire.Verdict, for id: PromptID, match: any BiometricMatch) async {": 1]),
        ("write", ["let outcome = await writer.write(decision)": 1]),
        ("confirm", ["guard case .confirmed(let match) = await biometrics.confirm(reason: Self.reason(for: verdict)) else {": 1]),
        ("mayHaveLanded", ["var mayHaveLanded: ApprovalWire.Verdict?": 1,
                           "return RequestStatus(phase: phase, answer: entry.answer, mayHaveLanded: entry.mayHaveLanded)": 2,
                           "mayHaveLanded: entry.mayHaveLanded)": 2,
                           "if outcome == .unconfirmed { entries[id]?.mayHaveLanded = verdict }": 1]),
        ("decision", ["guard case .signed(let decision) = signing else {": 1, "let outcome = await writer.write(decision)": 1]),
        ("signing", ["let signing = DecisionSigner.sign(verdict, for: request, at: clock(), with: keyring, match: match)": 1,
                     "guard case .signed(let decision) = signing else {": 1,
                     "entries[id]?.answer = signing == .notSigned ? .unsigned : .none": 1]),
    ]

    /// Every `confirmed` in the app (#168, (b)): the result's case, the
    /// gate's one hand-on, and the two places a match is taken from it —
    /// the inbox's answer and the ceremony's proof. Literals emptied.
    static let confirmedSites = CloudKitStructureTests.appSites([
        "Model/BiometricGate.swift": ["case confirmed(any BiometricMatch)": 1],
        "Live/LocalAuthenticationGate.swift": ["return .confirmed(LocalAuthenticationMatch(context))": 1],
        "Model/RequestInbox.swift": ["guard case .confirmed(let match) = await biometrics.confirm(reason: Self.reason(for: verdict)) else {": 1],
        "Model/PairingCeremony.swift": ["guard case .confirmed(let match) = await biometrics.confirm(reason: Self.reason) else {": 1],
    ])

    /// A match taken from a confirmation anywhere new, or reflection (which
    /// reads a value's stored parts with no name in sight), app-wide.
    /// AMENDED (S-PAIR-C1.6, #172): but for one redaction's own childless
    /// mirror, the scanned pairing code's, on its exact line: it hides the
    /// code from `dump` and every other `Mirror`-based reading, and reads
    /// nothing itself.
    static let redactionMirror = CloudKitStructureTests.appSites([
        "Live/QRScanner.swift": ["var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }": 2],
    ])

    static func confirmationFailures(_ app: [Source]) -> [String] {
        let code = app.map { ($0.path, Self.literalsEmptied(CloudKitStructureTests.codeOnly($0.text))) }
        var failures = CloudKitStructureTests.appSiteFailures(#"\bconfirmed\b"#, in: code, allowed: confirmedSites,
                                                              rule: "a confirmation is taken at its pinned sites only")
        failures += CloudKitStructureTests.appSiteFailures(#"\bMirror\b"#, in: code, allowed: redactionMirror,
                                                           rule: "nothing reflects a value (Mirror) but the scanned code's childless redaction — "
                                                            + "nothing reads a match's or a decision's parts unnamed")
        return failures
    }

    @Test func everyAnswerIsReachedByNameAlone() throws {
        let app = try Self.app()
        #expect(Self.confirmationFailures(app).isEmpty, "\(Self.confirmationFailures(app))")
        let inbox = Self.inboxFile
        let plant = "\nextension RequestInbox {\n    func reviewerSecondRoute(_ id: PromptID) async {\n        let g = biometrics\n"
            + "        guard case .confirmed(let m) = await g.confirm(reason: \"Unlock NapCat\") else { return }\n"
            + "        let f = send\n        await f(.allow, id, m)\n    }\n}"
        let g5 = Self.mutate(app, inbox) { $0 + plant }
        let g5Inbox = try #require(g5.first { $0.path == inbox }).text
        #expect(!Self.allowPathFailures(g5Inbox).isEmpty, "canary 'G5: a renamed confirm and an unapplied send' was NOT caught by lock 4")
        #expect(!Self.confirmationFailures(g5).isEmpty, "canary 'G5' was NOT caught app-wide")
        let mutants: [(String, [Source])] = [
            ("a confirmation taken in the keyring", Self.mutate(app, "\(Self.appDir)/Model/PhoneKeyring.swift") {
                $0 + "\nfunc spare(r: BiometricResult) -> Bool { if case .confirmed = r { return true }; return false }" }),
            ("a confirmation built in a fixture", Self.mutate(app, "\(Self.appDir)/Fixtures/FixtureRequests.swift") {
                $0 + "\nfunc spare(m: any BiometricMatch) -> BiometricResult { .confirmed(m) }" }),
            ("a match read by reflection", Self.mutate(app, inbox) {
                $0 + "\nfunc spare(m: any BiometricMatch) -> Int { Mirror(reflecting: m).children.count }" }),
            // S-PAIR-C1.6 (#172): the one redaction mirror, held to its line.
            ("the redaction's mirror given its code", Self.mutate(app, "\(Self.appDir)/Live/QRScanner.swift") {
                $0.replacingOccurrences(of: "Mirror(self, children: [], displayStyle: .struct)",
                                        with: "Mirror(self, children: [\"payload\": payload], displayStyle: .struct)") }),
            ("a second mirror beside the redaction's", Self.mutate(app, "\(Self.appDir)/Live/QRScanner.swift") {
                $0 + "\nfunc spare(c: ScannedCode) -> Int { Mirror(reflecting: c).children.count }" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.confirmationFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        for (name, plant) in [("an unapplied write", "\nextension RequestInbox { func spare() { let w = writer.write } }"),
                              ("a confirm on a renamed gate", "\nextension RequestInbox { func spare() async { _ = await gate.confirm(reason: r) } }")] {
            let inboxText = try #require(Self.mutate(app, inbox) { $0 + plant }.first { $0.path == inbox }).text
            #expect(!Self.allowPathFailures(inboxText).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: words that only contain the pinned ones, the
        // reasons' copy, and a whole-line comment.
        #expect(Self.confirmationFailures(Self.mutate(app, inbox) {
            $0 + "\nlet notConfirmed = 1, unconfirmed = 2, sendCount = 3, Mirrored = 4\nlet copy = \"confirmed by Mirror\""
                + "\n/// never g.confirm, never Mirror(reflecting:)"
        }).isEmpty)
        let inboxText = try #require(app.first { $0.path == inbox }).text
        #expect(Self.allowPathFailures(inboxText + "\nlet sender = 1, rewrite = 2, confirmation = \"send it\"").isEmpty)
    }

    @Test func everyAnswerNeedsTheMatchAndOneSiteWrites() throws {
        let inbox = try #require(try Self.app().first { $0.path == Self.inboxFile }).text
        #expect(Self.allowPathFailures(inbox).isEmpty, "\(Self.allowPathFailures(inbox))")
        let ask = "        guard case .confirmed(let match) = await biometrics.confirm(reason: Self.reason(for: verdict)) else {\n"
        let mutants: [(String, String)] = [
            ("Deny skips the match", inbox.replacingOccurrences(
                of: "        guard isAnswerable(id, with: .deny) else { return }\n        await confirmAndSend(.deny, for: id)\n",
                with: "        guard isAnswerable(id, with: .deny) else { return }\n        await send(.deny, for: id, match: Spare())\n")),
            ("Allow skips the match", inbox.replacingOccurrences(
                of: "await confirmAndSend(.allow, for: id)", with: "await send(.allow, for: id, match: Spare())")),
            ("the match ignored", inbox.replacingOccurrences(of: ask, with: "        _ = await biometrics.confirm(reason: Self.reason(for: verdict))\n"
                                                             + "        guard let match = Optional(Spare()) else {\n")),
            ("sends before asking", inbox.replacingOccurrences(
                of: "        entries[id]?.answer = .confirming(verdict)\n",
                with: "        entries[id]?.answer = .confirming(verdict)\n        await send(verdict, for: id, match: Spare())\n")),
            ("the wait names Allow for every answer", inbox.replacingOccurrences(
                of: "entries[id]?.answer = .confirming(verdict)", with: "entries[id]?.answer = .confirming(.allow)")),
            ("Deny asks in Allow's words", inbox.replacingOccurrences(of: "Self.reason(for: verdict)", with: "Self.allowReason")),
            ("Deny skips the check", inbox.replacingOccurrences(
                of: "    func deny(_ id: PromptID) async {\n        guard isAnswerable(id, with: .deny) else { return }\n",
                with: "    func deny(_ id: PromptID) async {\n")),
            ("send skips the re-check", inbox.replacingOccurrences(
                of: "        tick()\n        guard phase(of: id)?.isPending == true, let request = entries[id]?.request else {\n",
                with: "        guard let request = entries[id]?.request else {\n")),
            ("the match outlives its answer", inbox.replacingOccurrences(of: "        defer { match.invalidate() }\n", with: "")),
            ("a second write site", inbox + "\nextension RequestInbox { func f() async { _ = await writer.write(d) } }"),
            // #154: the answerable check names its answer and asks the status
            // with the unconfirmed answer folded in; that answer is set once
            // and never cleared; no signed decision is kept.
            ("Deny checked as Allow", inbox.replacingOccurrences(
                of: "guard isAnswerable(id, with: .deny)", with: "guard isAnswerable(id, with: .allow)")),
            ("the check ignores the answer", inbox.replacingOccurrences(
                of: "return status.answers.contains(verdict)", with: "return status.isAnswerable")),
            ("the check forgets the unconfirmed answer", inbox.replacingOccurrences(
                of: "mayHaveLanded: entry.mayHaveLanded)\n        return status.answers.contains(verdict)",
                with: "mayHaveLanded: nil)\n        return status.answers.contains(verdict)")),
            ("an unpaired phone asks for a match", inbox.replacingOccurrences(
                of: "        refreshKeyHealth()\n        if case .unpaired = keyHealth { return false }\n        guard let entry",
                with: "        refreshKeyHealth()\n        guard let entry")),
            // #194 polish (security I1): a read-only inbox refuses first.
            ("a read-only inbox asks for a match", inbox.replacingOccurrences(
                of: "        if isReadOnly { return false }\n        tick()\n", with: "        tick()\n")),
            ("the unconfirmed answer never kept", inbox.replacingOccurrences(
                of: "        if outcome == .unconfirmed { entries[id]?.mayHaveLanded = verdict }\n", with: "")),
            ("the restriction lifted after a failed resend", inbox.replacingOccurrences(
                of: "        case .failed: .unsent(verdict)\n",
                with: "        case .failed: .unsent(verdict); entries[id]?.mayHaveLanded = nil\n")),
            ("the signed decision kept for a resend", inbox.replacingOccurrences(
                of: "        entries[id]?.answer = .sending(verdict)\n",
                with: "        entries[id]?.answer = .sending(verdict)\n        entries[id]?.lastSigned = decision\n")),
        ]
        for (name, mutant) in mutants {
            #expect(mutant != inbox, "canary '\(name)' did not apply")
            #expect(!Self.allowPathFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // The #154 security spot-check: the signer's outcome kept in the
        // entry names no `decision`, so the `signing` pin alone sees it.
        let kept: String = inbox.replacingOccurrences(
            of: "        entries[id]?.answer = .sending(verdict)\n",
            with: "        entries[id]?.answer = .sending(verdict)\n        entries[id]?.kept = signing\n")
        let caught: [String] = Self.allowPathFailures(kept)
        #expect(kept != inbox, "canary 'the signed outcome kept in the entry' did not apply")
        #expect(caught.count == 1 && caught.allSatisfy { $0.hasPrefix(#"'\bsigning\b' in "#) },
                "canary 'the signed outcome kept in the entry' must be caught by the signing pin alone: \(caught)")
        // Over-match control: words that only contain it, and its copy.
        #expect(Self.allowPathFailures(inbox + "\nlet signings = 1, cosigning = 2, copy = \"signing\"").isEmpty)
    }

    // MARK: 5. The decision record is written only through the wire

    /// As the Mac's records: ONE record construction in the receiver (the
    /// decision), every key an `ApprovalWire` field (no literal key, no bulk
    /// setter, no asset or reference), the encrypted-or-clear choice read
    /// from the wire's own table, and (AMENDED in S-PAIR-B, CL-1) the
    /// signature written is the decision's own, which only the signer
    /// builds (`PhoneDecision` holds exactly 64 bytes).
    static func decisionSchemaFailures(_ file: String) -> [String] {
        let code = CloudKitStructureTests.codeOnly(file)
        var failures: [String] = []
        // AMENDED (S-PAIR-C1.5, #170): two records, each built in one place —
        // the decision and the pairing response (lock 7 pins each line).
        if CloudKitStructureTests.occurrences(of: "CKRecord(recordType:", in: code) != 2 {
            failures.append("a decision record and a pairing response must each be constructed in exactly one place "
                            + "(makeDecisionRecord, makePairingResponseRecord)")
        }
        for token in ["setValuesForKeys", "setObject(", "setValue(", "CKAsset", "CKRecord.Reference"] where code.contains(token) {
            failures.append("'\(token)' — decision fields are written only through the ApprovalWire field keys")
        }
        // A string literal as a key, on any receiver (`r["note"] = …`).
        if code.range(of: #"\[\s*"[^"]*"\s*\]\s*="#, options: .regularExpression) != nil {
            failures.append("a literal key — decision fields are written only through the ApprovalWire field keys")
        }
        let flat = SettingsReachabilityTests.flat(code)
        let shape = "for field in ApprovalWire.DecisionField.allCases { guard let value = decisionValue(field, of: decision) "
            + "else { continue } if ApprovalWire.encryptedDecisionFields.contains(field) { "
            + "record.encryptedValues[field.rawValue] = value } else { record[field.rawValue] = value } }"
        if !flat.contains(shape) {
            failures.append("the decision's fields must be the wire's, encrypted as the wire's table says")
        }
        if !flat.contains("case .signature: return decision.signature as NSData") {
            failures.append("a decision carries its own signature, as the signer made it (CL-1)")
        }
        return failures
    }

    @Test func theDecisionRecordIsWrittenOnlyThroughTheWire() throws {
        let file = try #require(try Self.app().first { $0.path == Self.cloudKitFile }).text
        #expect(Self.decisionSchemaFailures(file).isEmpty, "\(Self.decisionSchemaFailures(file))")
        let mutants: [(String, String)] = [
            ("the signature left out", file.replacingOccurrences(of: "case .signature: return decision.signature as NSData",
                                                                 with: "case .signature: return nil")),
            ("a signature made up", file.replacingOccurrences(of: "case .signature: return decision.signature as NSData",
                                                              with: "case .signature: return Data(count: 64) as NSData")),
            ("everything in the clear", file.replacingOccurrences(of: "if ApprovalWire.encryptedDecisionFields.contains(field) {",
                                                                  with: "if false {")),
            ("a literal key", file + "\nfunc f(r: CKRecord) { r[\"note\"] = \"x\" as NSString }"),
            ("a second record", file + "\nlet r = CKRecord(recordType: \"PromptDecision\", recordID: i)"),
        ]
        for (name, mutant) in mutants {
            #expect(mutant != file, "canary '\(name)' did not apply")
            #expect(!Self.decisionSchemaFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    /// S-PAIR-C1.5 (#170): the pairing response is written only through the
    /// wire, as the decision is — every `ApprovalWire.PairingResponseField`,
    /// encrypted exactly as `encryptedPairingResponseFields` says (every
    /// field but the version), each value the response's own, in the
    /// approvals zone under the response's own record name.
    static let pairingRecordShape = "let record = CKRecord(recordType: ApprovalWire.RecordType.pairingResponse.rawValue, "
        + "recordID: pairingResponseRecordID(response)) for field in ApprovalWire.PairingResponseField.allCases { "
        + "let value = pairingResponseValue(field, of: response) if ApprovalWire.encryptedPairingResponseFields.contains(field) { "
        + "record.encryptedValues[field.rawValue] = value } else { record[field.rawValue] = value } } return record"
    static let pairingValues = ["case .wireVersion: return response.wireVersion as NSNumber",
                                "case .publicKey: return response.publicKey as NSData",
                                "case .confirmation: return response.confirmation as NSData",
                                "case .proof: return response.proof as NSData"]
    static let pairingRecordID = "CKRecord.ID(recordName: response.recordName, zoneID: approvalsZoneID)"

    static func pairingSchemaFailures(_ file: String) -> [String] {
        let flat = SettingsReachabilityTests.flat(CloudKitStructureTests.codeOnly(file))
        var failures: [String] = []
        if !flat.contains(pairingRecordShape) {
            failures.append("the pairing response's fields must be the wire's, encrypted as the wire's table says")
        }
        for value in pairingValues where CloudKitStructureTests.occurrences(of: value, in: flat) != 1 {
            failures.append("the pairing response carries its own value, once: '\(value)'")
        }
        if CloudKitStructureTests.occurrences(of: pairingRecordID, in: flat) != 1 {
            failures.append("the pairing response is named by its own record name, in the approvals zone")
        }
        return failures
    }

    @Test func thePairingResponseIsWrittenOnlyThroughTheWire() throws {
        let file = try #require(try Self.app().first { $0.path == Self.cloudKitFile }).text
        #expect(Self.pairingSchemaFailures(file).isEmpty, "\(Self.pairingSchemaFailures(file))")
        let mutants: [(String, String)] = [
            ("everything in the clear", file.replacingOccurrences(of: "if ApprovalWire.encryptedPairingResponseFields.contains(field) {",
                                                                  with: "if false {")),
            ("a proof made up", file.replacingOccurrences(of: "case .proof: return response.proof as NSData",
                                                          with: "case .proof: return Data(count: 64) as NSData")),
            ("the key from elsewhere", file.replacingOccurrences(of: "case .publicKey: return response.publicKey as NSData",
                                                                 with: "case .publicKey: return spareKey as NSData")),
            ("the default zone", file.replacingOccurrences(of: Self.pairingRecordID,
                                                           with: "CKRecord.ID(recordName: response.recordName, zoneID: .default)")),
            ("a name of its own", file.replacingOccurrences(of: Self.pairingRecordID,
                                                            with: "CKRecord.ID(recordName: UUID().uuidString, zoneID: approvalsZoneID)")),
            ("a field skipped", file.replacingOccurrences(of: "            let value = pairingResponseValue(field, of: response)\n",
                                                          with: "            guard field != .proof else { continue }\n"
                                                              + "            let value = pairingResponseValue(field, of: response)\n")),
        ]
        for (name, mutant) in mutants {
            #expect(mutant != file, "canary '\(name)' did not apply")
            #expect(!Self.pairingSchemaFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: 6. The decision operation runs only through the seam

    /// A record operation run with no database set targets the user's
    /// private database (Apple's `CKDatabaseOperation.database`), so the
    /// operation must never run outside the seam (security review 2: P1
    /// started it outside the writer, P2 added it to the live alert
    /// database). The two factories are counted as whole words across the
    /// app (an unapplied `let make = …makeDecisionSaveOperation` counts):
    /// each is declared once and used once, in the writer's `write`, whose
    /// body is exactly "build the record, hand its operation to the seam".
    /// And nothing in the CloudKit file runs an operation itself: no `start`
    /// or `main`, no queue, no database `add` (since S-PAIR-C1.6 but the live
    /// approvals database's, on its pinned lines), no dynamic message (whole
    /// words, so `addingTimeInterval` passes). AMENDED after the security
    /// re-check (N1): `start` and `main` are banned as words, dot or no dot,
    /// since an extension on the operation calls `start()` on its implicit
    /// self.
    static let decisionFactories = ["makeDecisionRecord", "makeDecisionSaveOperation"]
    static let writerHead = "struct CloudKitDecisionWriter: DecisionWriter {"
    static let writeHead = "func write(_ decision: PhoneDecision) async -> DecisionWriteOutcome {"
    static let writeBody = "let record = CloudKitAlertSource.makeDecisionRecord(decision) "
        + "return await withCheckedContinuation { continuation in "
        + "database.submit(CloudKitAlertSource.makeDecisionSaveOperation(record) { continuation.resume(returning: $0) }) }"
    /// AMENDED (S-PAIR-C1.6, #172): a database `.add` is no longer banned
    /// outright: the live approvals database adds what it admits, on its
    /// pinned lines (`liveAddSites`), and nowhere else.
    static let operationRunPatterns = [#"\bstart\b"#, #"\bmain\b"#, #"\bOperationQueue\b"#, #"\baddOperations?\b"#,
                                       #"\bperform\b"#, #"#selector\b"#, #"\bSelector\b"#, #"\bNSSelectorFromString\b"#]
    static let liveAddSites = CloudKitStructureTests.approvalsAddSites

    /// AMENDED after the security delta check (#153, X1: an operation run by
    /// an extension in ANOTHER file names no banned word here): the
    /// operation is pinned by where it goes. Every line of the CloudKit file
    /// naming `operation` is the seam's parameter or the factory building,
    /// configuring and returning it; the operation type is named only there
    /// and by the one construction; and `submit` only by the seam and the
    /// writer.
    static let decisionOperation = "let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)"
    static let seamRequirement = "func submit(_ operation: CKModifyRecordsOperation)"
    /// AMENDED (S-PAIR-C1.5, #170): the pairing response's factory builds
    /// the same create-only operation, line for line (its body is pinned
    /// whole by `pairingRunFailures`), so each line counts twice; its writer
    /// is the seam's one other caller.
    static let pairingSubmit = "database.submit(CloudKitAlertSource.makePairingResponseSaveOperation(record) "
        + "{ continuation.resume(returning: $0) })"
    /// AMENDED (S-PAIR-C1.6, #172): the seam's one app conformer, the live
    /// approvals database, receives the operation, checks it
    /// (`isPairingResponseCreation`, whose lines read it) and adds it — each
    /// line pinned here, and the conformer and the check pinned whole by
    /// `liveDatabaseFailures`.
    static let liveSubmitHead = "func submit(_ operation: CKModifyRecordsOperation) {"
    static let checkHead = "static func isPairingResponseCreation(_ operation: CKModifyRecordsOperation) -> Bool {"
    /// AMENDED (#194): and the decision's check, the pairing's twin in its
    /// first lines.
    static let decisionCheckHead = "static func isDecisionCreation(_ operation: CKModifyRecordsOperation) -> Bool {"
    static let checkOperationLines: [String: Int] = [
        checkHead: 1, decisionCheckHead: 1,
        "guard operation.savePolicy == .ifServerRecordUnchanged, operation.recordIDsToDelete?.isEmpty ?? true,": 4,
        "let records = operation.recordsToSave, records.count == 1, let record = records.first,": 2,
    ]
    /// AMENDED (#194): the live database admits a decision's creation too.
    static let liveAdmit = "guard CloudKitAlertSource.isPairingResponseCreation(operation) || CloudKitAlertSource.isDecisionCreation(operation) else {"
    static let liveOperationLines: [String: Int] = [
        liveSubmitHead: 1, liveAdmit: 2,
        "operation.modifyRecordsResultBlock?(.failure(CKError(.invalidArguments)))": 1,
        "database.add(CloudKitAlertSource.makeApprovalsZoneCreation { database.add(operation) })": 1,
        "database.add(operation)": 1,
    ]
    /// #194: the seam's three new requirements and their live conformances.
    static let promptSeamLines: [String] = ["func submit(_ snapshot: CKFetchRecordZoneChangesOperation)",
                                            "func submit(_ lookup: CKFetchSubscriptionsOperation)",
                                            "func submit(_ change: CKModifySubscriptionsOperation)"]
    static let promptSubmitSites: [String: Int] = {
        var sites: [String: Int] = [:]
        for line in promptSeamLines {
            sites[line] = 1
            sites[line + " {"] = 1
        }
        return sites
    }()
    static let submitSites: [String: Int] = {
        var sites: [String: Int] = [seamRequirement: 1, pairingSubmit: 1, liveSubmitHead: 1,
                                    "database.submit(CloudKitAlertSource.makeDecisionSaveOperation(record) "
                                        + "{ continuation.resume(returning: $0) })": 1]
        sites.merge(promptSubmitSites) { $0 + $1 }
        return sites
    }()
    static let factoryOperationLines: [String: Int] = [
        seamRequirement: 1, decisionOperation: 2, "operation.savePolicy = .ifServerRecordUnchanged": 2,
        "operation.isAtomic = true": 2, "operation.configuration = configuration": 2,
        "operation.perRecordSaveBlock = { _, result in saved.note(result.map { _ in () }) }": 2,
        "operation.modifyRecordsResultBlock = { batch in": 2, "return operation": 2,
    ]
    static let operationLines: [String: Int] = {
        var lines = factoryOperationLines
        lines.merge(checkOperationLines) { $0 + $1 }
        lines.merge(liveOperationLines) { $0 + $1 }
        return lines
    }()
    static let operationSites: [(pattern: String, sites: [String: Int], rule: String)] = [
        (#"\boperation\b"#, operationLines,
         "the two factories build, configure and return their operations; the live database checks and adds one; nothing else"),
        (#"\bCKModifyRecordsOperation\b"#, [seamRequirement: 1, ") -> CKModifyRecordsOperation {": 2, decisionOperation: 2,
                                            liveSubmitHead: 1, checkHead: 1, decisionCheckHead: 1],
         "the operation type is named by the seam, its conformer, the two checks, the two factories and their constructions"),
        (#"\bsubmit\b"#, submitSites,
         "the seam is named only by its requirements, its one conformer and the two writers (#194: and the prompt source, lock 6e)"),
        (#"\.\s*add\b"#, liveAddSites, "an operation is added to a database by the live approvals database alone, on its pinned lines"),
    ]

    static func decisionRunFailures(_ app: [Source]) -> [String] {
        let uncut = app.map { (path: $0.path, text: CloudKitStructureTests.wholeLineCommentsRemoved($0.text)) }
        let file = uncut.first { $0.path == cloudKitFile }?.text ?? ""
        guard let writer = CloudKitStructureTests.body(after: writerHead, in: file),
              let write = CloudKitStructureTests.body(after: writeHead, in: writer) else {
            return ["CloudKitDecisionWriter.write moved (the lock would be vacuous)"]
        }
        var failures: [String] = []
        for factory in decisionFactories {
            let word = #"\b"# + factory + #"\b"#
            let total = uncut.reduce(0) { $0 + CloudKitStructureTests.matchCount(word, in: $1.text) }
            let declared = CloudKitStructureTests.occurrences(of: "static func \(factory)(", in: file)
            if declared != 1 || total != 2 || CloudKitStructureTests.matchCount(word, in: write) != 1 {
                failures.append("'\(factory)' must be declared once and reached once, in CloudKitDecisionWriter.write "
                                + "(\(declared) declaration(s), \(total) mention(s) in the app)")
            }
        }
        if SettingsReachabilityTests.flat(write) != writeBody {
            failures.append("CloudKitDecisionWriter.write builds the record and hands its operation to the seam, nothing else")
        }
        for pattern in operationRunPatterns where file.range(of: pattern, options: .regularExpression) != nil {
            failures.append("'\(pattern)' in \(cloudKitFile) — only the seam runs a decision's operation")
        }
        for (pattern, sites, rule) in operationSites {
            failures += CloudKitStructureTests.siteFailures(pattern, in: file, file: cloudKitFile, allowed: sites, rule: rule)
        }
        return failures
    }

    @Test func theDecisionOperationRunsOnlyThroughTheSeam() throws {
        let app = try Self.app()
        #expect(Self.decisionRunFailures(app).isEmpty, "\(Self.decisionRunFailures(app))")
        let probes = ["o.start()", "o.main()", "OperationQueue.current", "q.addOperation(o)", "o.perform(s)",
                      "#selector(Operation.start)", "Selector((\"start\"))", "NSSelectorFromString(\"start\")"]
        #expect(probes.count == Self.operationRunPatterns.count)
        #expect("db.add(o)".range(of: #"\.\s*add\b"#, options: .regularExpression) != nil, "the add pin reads a database add")
        for (pattern, probe) in zip(Self.operationRunPatterns, probes) {
            #expect(probe.range(of: pattern, options: .regularExpression) != nil, "'\(pattern)' does not match '\(probe)'")
        }
        let ck = Self.cloudKitFile
        let inbox = Self.inboxFile
        let submit = "database.submit(CloudKitAlertSource.makeDecisionSaveOperation(record) { continuation.resume(returning: $0) })"
        let mutants: [(String, [Source])] = [
            ("P1: started outside the writer", Self.mutate(app, ck) {
                $0 + "\nextension CloudKitAlertSource {\n    static func p1(_ d: PhoneDecision) {\n"
                    + "        makeDecisionSaveOperation(makeDecisionRecord(d)) { _ in }.start()\n    }\n}" }),
            ("P1 from another file", Self.mutate(app, inbox) {
                $0 + "\nfunc p1(_ d: PhoneDecision) { CloudKitAlertSource.makeDecisionSaveOperation("
                    + "CloudKitAlertSource.makeDecisionRecord(d)) { _ in }.start() }" }),
            ("P2: added to the live alert database", Self.mutate(app, ck) {
                $0 + "\nextension LiveCloudKitAlertDatabase {\n    func p2(_ d: PhoneDecision) {\n"
                    + "        container.privateCloudDatabase.add(CloudKitAlertSource.makeDecisionSaveOperation("
                    + "CloudKitAlertSource.makeDecisionRecord(d)) { _ in })\n    }\n}" }),
            ("P2 with an operation handed in", Self.mutate(app, ck) {
                $0 + "\nextension LiveCloudKitAlertDatabase { func p2(_ o: CKModifyRecordsOperation) { "
                    + "container.privateCloudDatabase.add(o) } }" }),
            ("an unapplied factory", Self.mutate(app, "\(Self.appDir)/Model/AlertFeed.swift") {
                $0 + "\nlet make = CloudKitAlertSource.makeDecisionSaveOperation" }),
            ("a second record for the writer", Self.mutate(app, ck) {
                $0 + "\nfunc f(d: PhoneDecision) -> CKRecord { CloudKitAlertSource.makeDecisionRecord(d) }" }),
            ("the writer starts its own operation", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: submit, with: "CloudKitAlertSource.makeDecisionSaveOperation(record) "
                                        + "{ continuation.resume(returning: $0) }.start()") }),
            ("the writer queues it", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "database.submit(", with: "OperationQueue.main.addOperation(") }),
            ("a start behind a URL", Self.mutate(app, ck) {
                $0 + "\nfunc f(o: CKOperation) { let u = \"https://www.icloud.com\"; o.start(); _ = u }" }),
            ("an operation run by hand", Self.mutate(app, ck) { $0 + "\nfunc f(o: CKOperation) { o.main() }" }),
            ("an operation messaged dynamically", Self.mutate(app, ck) {
                $0 + "\nfunc f(o: CKOperation) { o.perform(NSSelectorFromString(\"start\")) }" }),
            // The security re-check (N1): started on the operation's implicit self.
            ("an operation started on its implicit self (N1)", Self.mutate(app, ck) {
                $0 + "\nextension CKModifyRecordsOperation {\n    func go() { start() }\n}" }),
            ("an operation run by hand on its implicit self", Self.mutate(app, ck) {
                $0 + "\nextension CKOperation {\n    func go() { main() }\n}" }),
            // The security delta check (#153), X1's shape on the phone: the
            // factory's own operation run by a runner in another file.
            ("X1: the factory's operation run by an extension in another file", Self.mutate(Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "        return operation\n", with: "        operation.go()\n        return operation\n")
            }, "\(Self.appDir)/Model/AlertFeed.swift") { $0 + "\nextension Operation {\n    func go() { start() }\n}" }),
            ("the factory's operation handed out", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "        return operation\n", with: "        Spare.last = operation\n        return operation\n") }),
            ("the operation type extended, no banned word", Self.mutate(app, ck) {
                $0 + "\nextension CKModifyRecordsOperation {\n    func go() { spare() }\n}" }),
            ("a second submit", Self.mutate(app, ck) { $0 + "\nfunc f(d: any CloudKitApprovalDatabase, o: Op) { d.submit(o) }" }),
            // S-PAIR-C1.6 (#172): the live approvals database adds what it
            // admits on its pinned line only — a second add there, an add
            // past its check, and the decision's operation handed to it.
            ("a second add in the live approvals database", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "                database.add(operation)\n",
                                        with: "                database.add(operation)\n                database.add(spare)\n") }),
            ("an add before the check", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "        " + Self.liveAdmit + "\n",
                                        with: "        container.privateCloudDatabase.add(operation)\n        " + Self.liveAdmit + "\n") }),
            // #194: the prompt path's operations — one added past no check, a
            // second seam requirement, a submit of a prompt read from the
            // CloudKit file itself.
            ("a prompt read added before its check", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "        guard CloudKitAlertSource.isPromptSnapshot(snapshot) else {\n",
                                        with: "        container.privateCloudDatabase.add(snapshot)\n"
                                            + "        guard CloudKitAlertSource.isPromptSnapshot(snapshot) else {\n") }),
            ("a second requirement of the seam", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "    func submit(_ change: CKModifySubscriptionsOperation)\n}",
                                        with: "    func submit(_ change: CKModifySubscriptionsOperation)\n    func submit(_ query: CKQueryOperation)\n}") }),
            ("a prompt read submitted from the CloudKit file", Self.mutate(app, ck) {
                $0 + "\nfunc spare(_ db: any CloudKitApprovalDatabase) { db.submit(CloudKitAlertSource.makePromptSnapshot { _ in }) }" }),
            ("the save added before the zone", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "        let database = container.privateCloudDatabase\n",
                                        with: "        let database = container.privateCloudDatabase\n        database.add(operation)\n") }),
            ("the decision's operation submitted to the live database", Self.mutate(app, ck) {
                $0 + "\nfunc spare(_ d: PhoneDecision, _ db: any CloudKitApprovalDatabase) {\n"
                    + "    db.submit(CloudKitAlertSource.makeDecisionSaveOperation(CloudKitAlertSource.makeDecisionRecord(d)) { _ in })\n}" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.decisionRunFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: a whole-line comment may name the factories,
        // and `addingTimeInterval` or the feed's own `start()` elsewhere pass.
        #expect(Self.decisionRunFailures(Self.mutate(app, ck) {
            $0 + "\n/// never makeDecisionSaveOperation(…).start() outside the writer\n"
                + "func f(d: Date) -> Date { d.addingTimeInterval(1) }"
        }).isEmpty)
        #expect(app.contains { $0.text.contains("await feed.start()") }, "vacuity: a legitimate start() lives outside the CloudKit file")
    }

    // MARK: 6b. The pairing response is created only through the seam (S-PAIR-C1.5, #170)

    /// The pairing response's record and its save are each reached once, in
    /// `CloudKitPairingResponseWriter.write`, whose body is exactly "build
    /// the record, hand its operation to the seam" (the ceremony's one write
    /// stays the ceremony's: `PairingCeremonyTests`). The save is CREATE
    /// ONLY, its factory pinned whole: a new record under
    /// `.ifServerRecordUnchanged`, so a response saved already is refused,
    /// never overwritten; the saved record is dropped unread; the outcome is
    /// the decision's table, case for case. And nothing in the CloudKit file
    /// names what a conflict hands back — the record the server holds and
    /// its relatives — so an existing response is never read or adopted.
    static let pairingFactories = ["makePairingResponseRecord", "makePairingResponseSaveOperation"]
    static let pairingWriterHead = "struct CloudKitPairingResponseWriter: PairingResponseWriter {"
    static let pairingWriteHead = "func write(_ response: PairingResponse) async -> PairingWriteOutcome {"
    static let pairingWriteBody = "let record = CloudKitAlertSource.makePairingResponseRecord(response) "
        + "return await withCheckedContinuation { continuation in " + pairingSubmit + " }"
    static let pairingSaveHead = "static func makePairingResponseSaveOperation("
    static let pairingSaveBody = "_ record: CKRecord, completion: @escaping @Sendable (PairingWriteOutcome) -> Void ) "
        + "-> CKModifyRecordsOperation { " + decisionOperation + " operation.savePolicy = .ifServerRecordUnchanged "
        + "operation.isAtomic = true let configuration = CKOperation.Configuration() "
        + "configuration.qualityOfService = .userInitiated configuration.timeoutIntervalForRequest = 30 "
        + "configuration.timeoutIntervalForResource = 60 operation.configuration = configuration "
        + "let saved = CreatedRecordResult() operation.perRecordSaveBlock = { _, result in saved.note(result.map { _ in () }) } "
        + "operation.modifyRecordsResultBlock = { batch in guard let outcome = saved.finish(batch: batch).map(pairingOutcome) "
        + "else { return } if outcome != .saved { logger.error(\"pairing response not saved "
        + "(\\(outcome.rawValue, privacy: .public))\") } completion(outcome) } return operation"
    static let pairingOutcomeHead = "static func pairingOutcome(_ outcome: DecisionWriteOutcome) -> PairingWriteOutcome {"
    static let pairingOutcomeBody = "switch outcome { case .saved: return .saved case .alreadyAnswered: return .alreadyAnswered "
        + "case .failed: return .failed case .unconfirmed: return .unconfirmed }"
    /// Each helper word, and every line of the CloudKit file naming it.
    static let pairingHelperSites: [(String, [String: Int])] = [
        ("pairingOutcome", [pairingOutcomeHead: 1,
                            "guard let outcome = saved.finish(batch: batch).map(pairingOutcome) else { return }": 1]),
        ("pairingResponseValue", ["static func pairingResponseValue(_ field: ApprovalWire.PairingResponseField, of response: "
                                  + "PairingResponse) -> CKRecordValue {": 1,
                                  "let value = pairingResponseValue(field, of: response)": 1]),
        ("pairingResponseRecordID", ["static func pairingResponseRecordID(_ response: PairingResponse) -> CKRecord.ID {": 1,
                                     "recordID: pairingResponseRecordID(response))": 1]),
    ]
    /// What a conflict hands back, by any name the CloudKit file could read
    /// it under (`CKError`'s members and the user-info keys).
    static let serverRecordReads = #"\b(?:serverRecord|clientRecord|ancestorRecord)\b|\bCKRecordChangedError\w*"#

    static func pairingRunFailures(_ app: [Source]) -> [String] {
        let uncut = app.map { (path: $0.path, text: CloudKitStructureTests.wholeLineCommentsRemoved($0.text)) }
        let file = uncut.first { $0.path == cloudKitFile }?.text ?? ""
        guard let writer = CloudKitStructureTests.body(after: pairingWriterHead, in: file),
              let write = CloudKitStructureTests.body(after: pairingWriteHead, in: writer),
              let save = CloudKitStructureTests.body(after: pairingSaveHead, in: file),
              let outcome = CloudKitStructureTests.body(after: pairingOutcomeHead, in: file) else {
            return ["CloudKitPairingResponseWriter.write, its factory or its outcome moved (the lock would be vacuous)"]
        }
        var failures: [String] = []
        for factory in pairingFactories {
            let word = #"\b"# + factory + #"\b"#
            let total = uncut.reduce(0) { $0 + CloudKitStructureTests.matchCount(word, in: $1.text) }
            let declared = CloudKitStructureTests.occurrences(of: "static func \(factory)(", in: file)
            if declared != 1 || total != 2 || CloudKitStructureTests.matchCount(word, in: write) != 1 {
                failures.append("'\(factory)' must be declared once and reached once, in CloudKitPairingResponseWriter.write "
                                + "(\(declared) declaration(s), \(total) mention(s) in the app)")
            }
        }
        if SettingsReachabilityTests.flat(write) != pairingWriteBody {
            failures.append("CloudKitPairingResponseWriter.write builds the record and hands its operation to the seam, nothing else")
        }
        if SettingsReachabilityTests.flat(save) != pairingSaveBody {
            failures.append("the pairing response's save is create-only and drops the saved record unread — exactly as pinned")
        }
        if SettingsReachabilityTests.flat(outcome) != pairingOutcomeBody {
            failures.append("the pairing response's outcome is the decision's table, case for case — exactly as pinned")
        }
        for (word, sites) in pairingHelperSites {
            failures += CloudKitStructureTests.siteFailures(#"\b"# + word + #"\b"#, in: file, file: cloudKitFile, allowed: sites,
                                                            rule: "'\(word)' is declared once and used once")
            for (path, text) in uncut where path != cloudKitFile && CloudKitStructureTests.hits(#"\b"# + word + #"\b"#, in: text) {
                failures.append("'\(word)' in \(path) — only the CloudKit file builds the pairing response")
            }
        }
        if CloudKitStructureTests.hits(serverRecordReads, in: file) {
            failures.append("\(cloudKitFile) names what a conflict hands back — an existing response is never read or adopted")
        }
        return failures
    }

    @Test func thePairingResponseIsCreatedOnlyThroughTheSeam() throws {
        let app = try Self.app()
        #expect(Self.pairingRunFailures(app).isEmpty, "\(Self.pairingRunFailures(app))")
        let ck = Self.cloudKitFile
        let block = "operation.perRecordSaveBlock = { _, result in saved.note(result.map { _ in () }) }\n"
            + "        operation.modifyRecordsResultBlock = { batch in\n"
            + "            guard let outcome = saved.finish(batch: batch).map(pairingOutcome) else { return }"
        #expect(try #require(app.first { $0.path == ck }).text.contains(block), "vacuity: the pairing save's callbacks are the anchor")
        let mutants: [(String, [Source])] = [
            ("the server's response adopted on a conflict", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: block, with: block.replacingOccurrences(
                    of: "saved.note(result.map { _ in () })",
                    with: "saved.note(result.map { _ in () }.flatMapError { (($0 as? CKError)?.serverRecord != nil) ? .success(()) : .failure($0) })")) }),
            ("the server's record read through the user info", Self.mutate(app, ck) {
                $0 + "\nfunc spare(e: NSError) -> Any? { e.userInfo[CKRecordChangedErrorServerRecordKey] }" }),
            ("an overwrite", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: Self.decisionOperation + "\n        operation.savePolicy = .ifServerRecordUnchanged\n"
                                            + "        operation.isAtomic = true\n        let configuration = CKOperation.Configuration()\n"
                                            + "        configuration.qualityOfService = .userInitiated\n        configuration.timeoutIntervalForRequest = 30\n"
                                            + "        configuration.timeoutIntervalForResource = 60\n        operation.configuration = configuration\n"
                                            + "        let saved = CreatedRecordResult()\n        operation.perRecordSaveBlock = { _, result in saved.note(result.map { _ in () }) }\n"
                                            + "        operation.modifyRecordsResultBlock = { batch in\n            guard let outcome = saved.finish(batch: batch).map(pairingOutcome)",
                                        with: Self.decisionOperation + "\n        operation.savePolicy = .allKeys\n"
                                            + "        operation.isAtomic = true\n        let configuration = CKOperation.Configuration()\n"
                                            + "        configuration.qualityOfService = .userInitiated\n        configuration.timeoutIntervalForRequest = 30\n"
                                            + "        configuration.timeoutIntervalForResource = 60\n        operation.configuration = configuration\n"
                                            + "        let saved = CreatedRecordResult()\n        operation.perRecordSaveBlock = { _, result in saved.note(result.map { _ in () }) }\n"
                                            + "        operation.modifyRecordsResultBlock = { batch in\n            guard let outcome = saved.finish(batch: batch).map(pairingOutcome)") }),
            ("a conflict read as saved", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "case .alreadyAnswered: return .alreadyAnswered", with: "case .alreadyAnswered: return .saved") }),
            ("a second pairing write", Self.mutate(app, ck) {
                $0 + "\nextension CloudKitPairingResponseWriter {\n    func again(_ r: CKRecord) {\n"
                    + "        database.submit(CloudKitAlertSource.makePairingResponseSaveOperation(r) { _ in })\n    }\n}" }),
            ("the writer writes twice", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: Self.pairingSubmit, with: Self.pairingSubmit + "\n            " + Self.pairingSubmit) }),
            ("an unapplied pairing factory elsewhere", Self.mutate(app, "\(Self.appDir)/Model/PairingCeremony.swift") {
                $0 + "\nlet spareMake = CloudKitAlertSource.makePairingResponseRecord" }),
            ("a second record for the pairing writer", Self.mutate(app, ck) {
                $0 + "\nfunc spare(r: PairingResponse) -> CKRecord { CloudKitAlertSource.makePairingResponseRecord(r) }" }),
            ("the outcome taken elsewhere", Self.mutate(app, ck) {
                $0 + "\nfunc spare(o: DecisionWriteOutcome) -> PairingWriteOutcome { CloudKitAlertSource.pairingOutcome(o) }" }),
            ("a value read twice", Self.mutate(app, ck) {
                $0 + "\nfunc spare(r: PairingResponse) -> CKRecordValue { CloudKitAlertSource.pairingResponseValue(.proof, of: r) }" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.pairingRunFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: the conflict's own code (`serverRecordChanged`)
        // and words that only contain a banned one, and a whole-line comment.
        #expect(Self.pairingRunFailures(Self.mutate(app, ck) {
            $0 + "\nlet spareServerRecords = 1, isServerRecordChanged = CKError.Code.serverRecordChanged"
                + "\n/// never error.serverRecord, never userInfo[CKRecordChangedErrorServerRecordKey]\n"
        }).isEmpty)
    }

    // MARK: 6c. The live approvals database runs the pairing's save alone (S-PAIR-C1.6, #172)

    /// The seam's one app conformer, pinned WHOLE (a line pin does not hold
    /// the line after it: the C1.5 delta re-check's F-C): its one stored
    /// property, the container, and its `submit`, which checks the
    /// operation, refuses anything else by telling the operation's own
    /// result block `invalidArguments` (never adding it), and adds what it
    /// admits. The check is pinned whole too, and named only by its
    /// declaration and that guard. An extension of the conformer is lock 8's
    /// (a guarded type); its name and its factory's are lock 2's.
    ///
    /// AMENDED (#194): the admit list, whole. A record save is admitted as
    /// the pairing response's or a decision's creation; the prompts'
    /// snapshot, the prompt subscription's lookup and its change each by
    /// their own check, each refused unrun on its own result block, each
    /// added on its one line. Every check is pinned whole and named only by
    /// its declaration and its guard.
    static let liveDatabaseBody = "let container: CKContainer " + liveSubmitHead + " " + liveAdmit + " "
        + "operation.modifyRecordsResultBlock?(.failure(CKError(.invalidArguments))) return } "
        + "let database = container.privateCloudDatabase "
        + "database.add(CloudKitAlertSource.makeApprovalsZoneLookup { missing in if missing { "
        + "database.add(CloudKitAlertSource.makeApprovalsZoneCreation { database.add(operation) }) "
        + "} else { database.add(operation) } }) } "
        + "func submit(_ snapshot: CKFetchRecordZoneChangesOperation) { guard CloudKitAlertSource.isPromptSnapshot(snapshot) else { "
        + "snapshot.fetchRecordZoneChangesResultBlock?(.failure(CKError(.invalidArguments))) return } "
        + CloudKitStructureTests.promptReadAdd + " } "
        + "func submit(_ lookup: CKFetchSubscriptionsOperation) { guard CloudKitAlertSource.isPromptSubscriptionLookup(lookup) else { "
        + "lookup.fetchSubscriptionsResultBlock?(.failure(CKError(.invalidArguments))) return } "
        + CloudKitStructureTests.promptLookupAdd + " } "
        + "func submit(_ change: CKModifySubscriptionsOperation) { guard CloudKitAlertSource.isPromptSubscriptionChange(change) else { "
        + "change.modifySubscriptionsResultBlock?(.failure(CKError(.invalidArguments))) return } "
        + CloudKitStructureTests.promptChangeAdd + " }"
    static let checkBody = "guard operation.savePolicy == .ifServerRecordUnchanged, operation.recordIDsToDelete?.isEmpty ?? true, "
        + "let records = operation.recordsToSave, records.count == 1, let record = records.first, "
        + "record.recordType == ApprovalWire.RecordType.pairingResponse.rawValue, record.recordChangeTag == nil, "
        + "record.recordID.zoneID == approvalsZoneID else { return false } let hex = Set(\"0123456789abcdef\".utf8) "
        + "let name = record.recordID.recordName.utf8 "
        + "return name.count == ApprovalSigning.recordNameHexDigits && name.allSatisfy(hex.contains)"
    static let checkSites = CloudKitStructureTests.appSites([
        "Live/CloudKitAlertSource.swift": [checkHead: 1, liveAdmit: 1]])
    /// #194: the admit list's other checks, each whole, each named by its
    /// declaration and the live database's guard alone (the subscription's
    /// shape by the change's check).
    static let decisionCheckBody: String = "guard operation.savePolicy == .ifServerRecordUnchanged, operation.recordIDsToDelete?.isEmpty ?? true, "
        + "let records = operation.recordsToSave, records.count == 1, let record = records.first, "
        + "record.recordType == ApprovalWire.RecordType.decision.rawValue, record.recordChangeTag == nil, "
        + "record.recordID.zoneID == approvalsZoneID, "
        + "let promptHex = record.encryptedValues[ApprovalWire.DecisionField.promptID.rawValue] as? String, "
        + "let promptID = PromptID(hex: promptHex) else { return false } "
        + "return record.recordID.recordName == ApprovalWire.decisionRecordName(for: promptID)"
    static let snapshotCheckHead: String = "static func isPromptSnapshot(_ snapshot: CKFetchRecordZoneChangesOperation) -> Bool {"
    static let snapshotCheckBody: String = "guard snapshot.recordZoneIDs == [approvalsZoneID], snapshot.fetchAllChanges, "
        + "let zones = snapshot.configurationsByRecordZoneID, zones.count == 1, let zone = zones[approvalsZoneID], "
        + "zone.previousServerChangeToken == nil, let keys = zone.desiredKeys else { return false } "
        + "return keys.count == promptKeys.count && Set(keys) == Set(promptKeys)"
    static let lookupCheckHead: String = "static func isPromptSubscriptionLookup(_ lookup: CKFetchSubscriptionsOperation) -> Bool {"
    static let lookupCheckBody: String = "lookup.subscriptionIDs == [ApprovalWire.promptSubscriptionID]"
    static let changeCheckHead: String = "static func isPromptSubscriptionChange(_ change: CKModifySubscriptionsOperation) -> Bool {"
    static let changeCheckBody: String = "let saved: [CKSubscription] = change.subscriptionsToSave ?? [] "
        + "let removed: [CKSubscription.ID] = change.subscriptionIDsToDelete ?? [] "
        + "if removed.isEmpty { return saved.count == 1 && saved.allSatisfy(isPromptSubscription) } "
        + "return saved.isEmpty && removed == [ApprovalWire.promptSubscriptionID]"
    static let shapeCheckHead: String = "static func isPromptSubscription(_ subscription: CKSubscription) -> Bool {"
    static let shapeCheckBody: String = "guard let query = subscription as? CKQuerySubscription, let info = query.notificationInfo, "
        + "query.subscriptionID == ApprovalWire.promptSubscriptionID, "
        + "query.recordType == ApprovalWire.RecordType.prompt.rawValue, query.zoneID == approvalsZoneID, "
        + "query.querySubscriptionOptions == [.firesOnRecordCreation], "
        + "query.predicate.predicateFormat == \"TRUEPREDICATE\" else { return false } "
        + "guard info.title == notificationTitle, info.alertBody == promptNotificationBody, "
        + "info.soundName == notificationSound, info.alertLocalizationKey == nil, "
        + "info.desiredKeys?.isEmpty ?? true, info.alertLocalizationArgs?.isEmpty ?? true, "
        + "info.titleLocalizationArgs?.isEmpty ?? true, info.subtitleLocalizationArgs?.isEmpty ?? true else { return false } "
        + "return info.category == nil && info.collapseIDKey == nil && !info.shouldSendContentAvailable "
        + "&& !info.shouldSendMutableContent"
    static let promptChecks: [(head: String, body: String, what: String)] = [
        (decisionCheckHead, decisionCheckBody, "a decision's create-only save alone"),
        (snapshotCheckHead, snapshotCheckBody, "the approvals zone read from the start for the prompt's six fields alone"),
        (lookupCheckHead, lookupCheckBody, "the prompt subscription looked up by its one ID alone"),
        (changeCheckHead, changeCheckBody, "the prompt subscription saved as made, or deleted, by its one ID alone"),
        (shapeCheckHead, shapeCheckBody, "the prompt subscription's own shape alone: fixed words, no record field"),
    ]
    static let promptCheckSites: [(word: String, sites: [String: Int])] = [
        ("isDecisionCreation", CloudKitStructureTests.appSites(["Live/CloudKitAlertSource.swift": [decisionCheckHead: 1, liveAdmit: 1]])),
        ("isPromptSnapshot", CloudKitStructureTests.appSites(["Live/CloudKitAlertSource.swift": [
            snapshotCheckHead: 1, "guard CloudKitAlertSource.isPromptSnapshot(snapshot) else {": 1]])),
        ("isPromptSubscriptionLookup", CloudKitStructureTests.appSites(["Live/CloudKitAlertSource.swift": [
            lookupCheckHead: 1, "guard CloudKitAlertSource.isPromptSubscriptionLookup(lookup) else {": 1]])),
        ("isPromptSubscriptionChange", CloudKitStructureTests.appSites(["Live/CloudKitAlertSource.swift": [
            changeCheckHead: 1, "guard CloudKitAlertSource.isPromptSubscriptionChange(change) else {": 1]])),
        ("isPromptSubscription", CloudKitStructureTests.appSites(["Live/CloudKitAlertSource.swift": [
            shapeCheckHead: 1, "if removed.isEmpty { return saved.count == 1 && saved.allSatisfy(isPromptSubscription) }": 1,
            promptLookupItemLine: 1]])),
    ]

    static func liveDatabaseFailures(_ app: [Source]) -> [String] {
        let file = CloudKitStructureTests.codeOnly(app.first { $0.path == cloudKitFile }?.text ?? "")
        guard let database = CloudKitStructureTests.body(after: liveDatabaseAdoption, in: file),
              let check = CloudKitStructureTests.body(after: checkHead, in: file) else {
            return ["the live approvals database or its check moved (the lock would be vacuous)"]
        }
        var failures: [String] = []
        if SettingsReachabilityTests.flat(database) != liveDatabaseBody {
            failures.append("the live approvals database checks what it is handed, refuses the rest unrun and adds what it admits — "
                            + "exactly as pinned")
        }
        if SettingsReachabilityTests.flat(check) != checkBody {
            failures.append("the live database's check admits the pairing response's create-only save alone — exactly as pinned")
        }
        failures += CloudKitStructureTests.appSiteFailures(#"\bisPairingResponseCreation\b"#,
                                                           in: app.map { ($0.path, CloudKitStructureTests.codeOnly($0.text)) },
                                                           allowed: checkSites, rule: "the check is declared once and used by the live database alone")
        for (head, pinned, what) in promptChecks {
            guard let body = CloudKitStructureTests.body(after: head, in: file) else {
                failures.append("'\(head)' moved (the lock would be vacuous)")
                continue
            }
            if SettingsReachabilityTests.flat(body) != pinned {
                failures.append("the live database's check admits \(what) — exactly as pinned")
            }
        }
        let stripped: [Source] = app.map { ($0.path, CloudKitStructureTests.codeOnly($0.text)) }
        for (word, sites) in promptCheckSites {
            failures += CloudKitStructureTests.appSiteFailures(#"\b"# + word + #"\b"#, in: stripped, allowed: sites,
                                                               rule: "'\(word)' is declared once and used by its one guard alone")
        }
        return failures
    }

    @Test func theLiveApprovalsDatabaseRunsThePairingSaveAlone() throws {
        let app = try Self.app()
        #expect(Self.liveDatabaseFailures(app).isEmpty, "\(Self.liveDatabaseFailures(app))")
        let ck = Self.cloudKitFile
        let admit = "        " + Self.liveAdmit + "\n"
        let mutants: [(String, [Source])] = [
            ("the check skipped", Self.mutate(app, ck) { $0.replacingOccurrences(of: admit, with: "        guard true else {\n") }),
            // #194: the admit list — a check dropped from the guard, each new
            // operation's check skipped, a refusal added after all or left
            // hanging, and each check widened.
            ("the decision admitted by the pairing's check alone", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: Self.liveAdmit, with: "guard CloudKitAlertSource.isDecisionCreation(operation) || true else {") }),
            ("any read admitted", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "guard CloudKitAlertSource.isPromptSnapshot(snapshot) else {", with: "guard true else {") }),
            ("any lookup admitted", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "guard CloudKitAlertSource.isPromptSubscriptionLookup(lookup) else {", with: "guard true else {") }),
            ("any change admitted", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "guard CloudKitAlertSource.isPromptSubscriptionChange(change) else {",
                                        with: "guard !CloudKitAlertSource.isPromptSubscriptionChange(change) || true else {") }),
            ("a refused read added after all", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "            snapshot.fetchRecordZoneChangesResultBlock?(.failure(CKError(.invalidArguments)))\n",
                                        with: "            container.privateCloudDatabase.add(snapshot)\n") }),
            ("a refused change left hanging", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "            change.modifySubscriptionsResultBlock?(.failure(CKError(.invalidArguments)))\n", with: "") }),
            ("a decision named for any prompt", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "return record.recordID.recordName == ApprovalWire.decisionRecordName(for: promptID)",
                                        with: "return !record.recordID.recordName.isEmpty") }),
            ("a decision in any zone", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "              record.recordID.zoneID == approvalsZoneID,\n              let promptHex",
                                        with: "              let promptHex") }),
            ("a read of every field", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "zone.previousServerChangeToken == nil, let keys = zone.desiredKeys else { return false }",
                                        with: "zone.previousServerChangeToken == nil else { return true }\n        let keys = promptKeys") }),
            ("a read from a change token", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "zone.previousServerChangeToken == nil, let keys", with: "let keys") }),
            ("a read of any zone", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "guard snapshot.recordZoneIDs == [approvalsZoneID], snapshot.fetchAllChanges,",
                                        with: "guard snapshot.fetchAllChanges,") }),
            ("every subscription looked up", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "lookup.subscriptionIDs == [ApprovalWire.promptSubscriptionID]",
                                        with: "lookup.subscriptionIDs?.contains(ApprovalWire.promptSubscriptionID) ?? true") }),
            ("any subscription deleted", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "return saved.isEmpty && removed == [ApprovalWire.promptSubscriptionID]",
                                        with: "return saved.isEmpty") }),
            ("a subscription saved whatever its shape", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "saved.count == 1 && saved.allSatisfy(isPromptSubscription)", with: "saved.count == 1") }),
            ("a record field in the push admitted", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "              info.desiredKeys?.isEmpty ?? true, info.alertLocalizationArgs?.isEmpty ?? true,\n",
                                        with: "              info.alertLocalizationArgs?.isEmpty ?? true,\n") }),
            ("an action admitted", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "return info.category == nil && info.collapseIDKey == nil",
                                        with: "return info.collapseIDKey == nil") }),
            ("a check named elsewhere", Self.mutate(app, "\(Self.appDir)/Model/AlertFeed.swift") {
                $0 + "\nlet spare = CloudKitAlertSource.isPromptSnapshot" }),
            ("the shape's check used twice", Self.mutate(app, ck) {
                $0 + "\nfunc spare(_ s: CKSubscription) -> Bool { CloudKitAlertSource.isPromptSubscription(s) }" }),
            ("a refusal added after all", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "            operation.modifyRecordsResultBlock?(.failure(CKError(.invalidArguments)))\n",
                                        with: "            container.privateCloudDatabase.add(operation)\n") }),
            ("a refusal left hanging", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "            operation.modifyRecordsResultBlock?(.failure(CKError(.invalidArguments)))\n", with: "") }),
            ("a statement continued under the add", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "                database.add(operation)\n",
                                        with: "                database.add(operation)\n                Spare.keep(container)\n") }),
            ("the zone skipped", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "            if missing {\n", with: "            if false {\n") }),
            ("the save skipped once the zone exists", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "            } else {\n                database.add(operation)\n            }\n",
                                        with: "            }\n") }),
            ("a second stored property", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: Self.liveDatabaseAdoption + "\n    let container: CKContainer\n",
                                        with: Self.liveDatabaseAdoption + "\n    let container: CKContainer\n    let spare = Spare()\n") }),
            ("deletions admitted", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: ", operation.recordIDsToDelete?.isEmpty ?? true,", with: ",") }),
            ("an overwrite admitted", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "guard operation.savePolicy == .ifServerRecordUnchanged, ", with: "guard ") }),
            ("a decision admitted", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "record.recordType == ApprovalWire.RecordType.pairingResponse.rawValue",
                                        with: "record.recordType != ApprovalWire.RecordType.prompt.rawValue") }),
            ("a changed record admitted", Self.mutate(app, ck) { $0.replacingOccurrences(of: " record.recordChangeTag == nil,", with: "") }),
            ("any zone admitted", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "record.recordID.zoneID == approvalsZoneID else", with: "true else") }),
            ("any name admitted", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "name.allSatisfy(hex.contains)", with: "!name.isEmpty") }),
            ("the check named elsewhere", Self.mutate(app, "\(Self.appDir)/Model/AlertFeed.swift") {
                $0 + "\nlet spare = CloudKitAlertSource.isPairingResponseCreation" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.liveDatabaseFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match control: a whole-line comment naming the shapes.
        #expect(Self.liveDatabaseFailures(Self.mutate(app, ck) {
            $0 + "\n/// never isPairingResponseCreation(o) outside the live database, never container.privateCloudDatabase.add(o)\n"
                + "/// never isDecisionCreation(o), isPromptSnapshot(s) or isPromptSubscription(s) but on their pinned lines\n"
        }).isEmpty)
    }

    // MARK: 6d. The approvals zone: one lookup, one creation, create only (S-PAIR-C1.6, #172)

    /// The zone's two steps, each pinned WHOLE: the lookup fetches the
    /// approvals zone by its ID and hands on only whether it is missing;
    /// the creation saves that one zone, deletes none, and always hands on
    /// (a creation that never handed on would leave the pairing's save
    /// unrun and its writer waiting). Each factory is declared once and
    /// used once, by the live approvals database, whose body (lock 6c) runs
    /// the creation only from the lookup's missing branch. A zone is missing
    /// only on `zoneNotFound` or `userDeletedZone`, read from the zone's OWN
    /// result first (CloudKit hands the lookup's result block a success for
    /// a zone that is not there): the lookup's result holder is pinned
    /// whole, declared once and built once, by the lookup.
    static let lookupHead = "static func makeApprovalsZoneLookup(then: @escaping @Sendable (Bool) -> Void) -> CKFetchRecordZonesOperation {"
    static let lookupBody = #"let lookup = CKFetchRecordZonesOperation(recordZoneIDs: [approvalsZoneID]) "#
        + #"lookup.configuration = approvalsZoneConfiguration let found = ZoneLookupResult() "#
        + #"lookup.perRecordZoneResultBlock = { _, result in found.note(result) } "#
        + #"lookup.fetchRecordZonesResultBlock = { batch in guard let result = found.finish(batch: batch) else { return } "#
        + #"guard case .failure(let error) = result else { return then(false) } let missing = isZoneMissing(error) "#
        + #"if !missing { logger.error("approvals zone lookup failed (code \(code(of: error)))") } then(missing) } return lookup"#
    static let creationHead = "static func makeApprovalsZoneCreation(then: @escaping @Sendable () -> Void) -> CKModifyRecordZonesOperation {"
    static let creationBody = #"let creation = CKModifyRecordZonesOperation(recordZonesToSave: [CKRecordZone(zoneID: approvalsZoneID)], "#
        + #"recordZoneIDsToDelete: nil) creation.configuration = approvalsZoneConfiguration "#
        + #"creation.perRecordZoneSaveBlock = { _, result in if case .failure(let error) = result { "#
        + #"logger.error("approvals zone not created (code \(code(of: error)))") } } "#
        + #"creation.modifyRecordZonesResultBlock = { result in if case .failure(let error) = result { "#
        + #"logger.error("approvals zone not created (code \(code(of: error)))") } then() } return creation"#
    static let missingHead = "static func isZoneMissing(_ error: any Error) -> Bool {"
    static let missingBody = "let nsError = recordLevelError(error as NSError) return nsError.domain == CKErrorDomain "
        + "&& (nsError.code == CKError.Code.zoneNotFound.rawValue || nsError.code == CKError.Code.userDeletedZone.rawValue)"
    static let holderHead = "private final class ZoneLookupResult: @unchecked Sendable {"
    static let holderBody = "private let lock = NSLock() private var zoneFailure: (any Error)? private var finished = false "
        + "func note(_ result: Result<CKRecordZone, any Error>) { lock.lock() defer { lock.unlock() } "
        + "if case .failure(let error) = result, zoneFailure == nil { zoneFailure = error } } "
        + "func finish(batch: Result<Void, any Error>) -> Result<Void, any Error>? { lock.lock() defer { lock.unlock() } "
        + "guard !finished else { return nil } finished = true return zoneFailure.map { .failure($0) } ?? batch }"
    static let zoneWordSites: [(word: String, sites: [String: Int])] = [
        ("makeApprovalsZoneLookup", CloudKitStructureTests.appSites(["Live/CloudKitAlertSource.swift": [
            lookupHead: 1, "database.add(CloudKitAlertSource.makeApprovalsZoneLookup { missing in": 1]])),
        ("makeApprovalsZoneCreation", CloudKitStructureTests.appSites(["Live/CloudKitAlertSource.swift": [
            creationHead: 1, "database.add(CloudKitAlertSource.makeApprovalsZoneCreation { database.add(operation) })": 1]])),
        ("isZoneMissing", CloudKitStructureTests.appSites(["Live/CloudKitAlertSource.swift": [
            missingHead: 1, "let missing = isZoneMissing(error)": 1]])),
        ("ZoneLookupResult", CloudKitStructureTests.appSites(["Live/CloudKitAlertSource.swift": [
            holderHead: 1, "let found = ZoneLookupResult()": 1]])),
    ]

    static func zoneFailures(_ app: [Source]) -> [String] {
        let file = CloudKitStructureTests.codeOnly(app.first { $0.path == cloudKitFile }?.text ?? "")
        var failures: [String] = []
        for (head, pinned, what) in [(lookupHead, lookupBody, "the lookup"), (creationHead, creationBody, "the creation"),
                                     (missingHead, missingBody, "the missing-zone reading"),
                                     (holderHead, holderBody, "the lookup's result holder")] {
            guard let body = CloudKitStructureTests.body(after: head, in: file) else {
                failures.append("\(what) moved (the lock would be vacuous)")
                continue
            }
            if SettingsReachabilityTests.flat(body) != pinned {
                failures.append("\(what) of the approvals zone — exactly as pinned (one zone, create only, always handed on)")
            }
        }
        let stripped = app.map { ($0.path, CloudKitStructureTests.codeOnly($0.text)) }
        for (word, sites) in zoneWordSites {
            failures += CloudKitStructureTests.appSiteFailures(#"\b"# + word + #"\b"#, in: stripped, allowed: sites,
                                                               rule: "'\(word)' is declared once and used once, by the live approvals database")
        }
        return failures
    }

    @Test func theApprovalsZoneIsCreatedAtOneSiteCreateOnly() throws {
        let app = try Self.app()
        #expect(Self.zoneFailures(app).isEmpty, "\(Self.zoneFailures(app))")
        let ck = Self.cloudKitFile
        let mutants: [(String, [Source])] = [
            ("the lookup asks for another zone", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "CKFetchRecordZonesOperation(recordZoneIDs: [approvalsZoneID])",
                                        with: "CKFetchRecordZonesOperation(recordZoneIDs: [.default])") }),
            ("every lookup failure read as missing", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "let missing = isZoneMissing(error)", with: "let missing = true") }),
            ("a found zone read as missing", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "else { return then(false) }", with: "else { return then(true) }") }),
            ("the creation never hands on", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "            then()\n", with: "") }),
            ("a zone deleted", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "recordZoneIDsToDelete: nil)", with: "recordZoneIDsToDelete: [approvalsZoneID])") }),
            ("a second zone saved", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "[CKRecordZone(zoneID: approvalsZoneID)]",
                                        with: "[CKRecordZone(zoneID: approvalsZoneID), CKRecordZone(zoneName: \"spare\")]") }),
            ("unknownItem read as missing", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "nsError.code == CKError.Code.userDeletedZone.rawValue)",
                                        with: "nsError.code == CKError.Code.userDeletedZone.rawValue || nsError.code == 11)") }),
            ("the creation run twice", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "            if missing {\n",
                                        with: "            database.add(CloudKitAlertSource.makeApprovalsZoneCreation { })\n            if missing {\n") }),
            ("the creation built elsewhere", Self.mutate(app, "\(Self.appDir)/Model/AlertFeed.swift") {
                $0 + "\nlet spare = CloudKitAlertSource.makeApprovalsZoneCreation { }" }),
            ("the lookup unapplied elsewhere", Self.mutate(app, "\(Self.appDir)/Model/AlertFeed.swift") {
                $0 + "\nlet spare = CloudKitAlertSource.makeApprovalsZoneLookup" }),
            // The zone's own result: not read (the C1.6 build's first shape,
            // which never found a missing zone), read after the lookup's, or
            // a later failure kept over the first; and the holder built twice.
            ("the zone's own result never read", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "        lookup.perRecordZoneResultBlock = { _, result in found.note(result) }\n", with: "") }),
            ("the lookup's result read over the zone's", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "return zoneFailure.map { .failure($0) } ?? batch",
                                        with: "if case .failure = batch { return batch }\n        return zoneFailure.map { .failure($0) } ?? batch") }),
            ("a later zone failure kept over the first", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "result, zoneFailure == nil { zoneFailure = error }", with: "result { zoneFailure = error }") }),
            ("the lookup ending twice", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "        guard !finished else { return nil }\n        finished = true\n        return zoneFailure",
                                        with: "        finished = true\n        return zoneFailure") }),
            ("a second holder", Self.mutate(app, "\(Self.appDir)/Model/AlertFeed.swift") { $0 + "\nlet spare = ZoneLookupResult()" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.zoneFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match control: a whole-line comment naming the shapes.
        #expect(Self.zoneFailures(Self.mutate(app, ck) {
            $0 + "\n/// never makeApprovalsZoneCreation outside the live database, never isZoneMissing(e) elsewhere\n"
        }).isEmpty)
    }

    // MARK: 6e. The prompt path: its operations whole, each built and used once (#194)

    /// The prompt path (#194), each piece pinned WHOLE: the prompt subscription
    /// (fixed words under the app's title, no record field, no action, no
    /// silent wake); its lookup, which hands on found, missing or failed
    /// (missing on the server's own unknownItem, or, since the #194 security
    /// review, when what it finds under the ID is not the prompt
    /// subscription exactly as made, so the save that follows replaces it);
    /// its creation and its removal, the one ID each, the removal saving
    /// nothing; the snapshot
    /// (the approvals zone from the start, the prompt's six fields, every
    /// record read as a prompt or dropped unread, any failure failing it
    /// all); their one result holder (the first failure kept, an item's
    /// before the batch's); and the live prompt source, which looks up
    /// before it saves and saves only what is missing. Each factory is
    /// declared once and used once (by the source; the subscription by its
    /// creation), the holder built only by the four factories, and the
    /// prompt subscription's ID named on the CloudKit file's pinned lines
    /// alone. The live database's half is lock 6c's.
    static let promptSubscriptionHead: String = "static func makePromptSubscription() -> CKQuerySubscription {"
    static let promptSubscriptionBody: String = "let subscription = CKQuerySubscription( "
        + "recordType: ApprovalWire.RecordType.prompt.rawValue, predicate: NSPredicate(value: true), "
        + "subscriptionID: ApprovalWire.promptSubscriptionID, options: [.firesOnRecordCreation] ) "
        + "subscription.zoneID = approvalsZoneID let info = CKSubscription.NotificationInfo() info.title = notificationTitle "
        + "info.alertBody = promptNotificationBody info.soundName = notificationSound subscription.notificationInfo = info "
        + "return subscription"
    static let promptLookupHead: String = "static func makePromptSubscriptionLookup(then: @escaping @Sendable (SubscriptionLookup) -> Void) "
        + "-> CKFetchSubscriptionsOperation {"
    static let promptLookupLine: String = "let lookup = CKFetchSubscriptionsOperation(subscriptionIDs: [ApprovalWire.promptSubscriptionID])"
    static let promptLookupBody: String = promptLookupLine + " lookup.configuration = approvalsZoneConfiguration "
        + "let found = PromptResults() lookup.perSubscriptionResultBlock = { _, result in " + promptLookupItemLine + " } "
        + "lookup.fetchSubscriptionsResultBlock = { batch in guard let result = found.finish(batch: batch) else { return } "
        + "switch result { case .success(let read): then(read.items == 1 ? .found : .failed) "
        + "case .failure(let error) where isMissing(error): then(.missing) case .failure(let error): "
        + #"logger.error("prompt subscription check failed (code \(code(of: error)))") then(.failed) } } return lookup"#
    /// A subscription found in another shape reads as missing (#194).
    static let promptLookupItemLine: String = "found.note(item: result.flatMap { isPromptSubscription($0) ? .success(()) "
        + ": .failure(CKError(.unknownItem)) })"
    static let promptSaveHead: String = "static func makePromptSubscriptionSave(then: @escaping @Sendable (Bool) -> Void) "
        + "-> CKModifySubscriptionsOperation {"
    static let promptSaveBody: String = CloudKitStructureTests.promptSubscriptionSave + " change.configuration = approvalsZoneConfiguration "
        + "let saved = PromptResults() change.perSubscriptionSaveBlock = { _, result in saved.note(item: result.map { _ in () }) } "
        + "change.modifySubscriptionsResultBlock = { batch in guard let result = saved.finish(batch: batch) else { return } "
        + "switch result { case .success(let read): then(read.items == 1) case .failure(let error): "
        + #"logger.error("prompt subscription not created (code \(code(of: error)))") then(false) } } return change"#
    static let promptRemovalHead: String = "static func makePromptSubscriptionRemoval(then: @escaping @Sendable (Bool) -> Void) "
        + "-> CKModifySubscriptionsOperation {"
    static let promptRemovalLine: String = "let change = CKModifySubscriptionsOperation(subscriptionsToSave: nil, "
        + "subscriptionIDsToDelete: [ApprovalWire.promptSubscriptionID])"
    static let promptRemovalBody: String = promptRemovalLine + " change.configuration = approvalsZoneConfiguration "
        + "let removed = PromptResults() change.perSubscriptionDeleteBlock = { _, result in removed.note(item: result) } "
        + "change.modifySubscriptionsResultBlock = { batch in guard let result = removed.finish(batch: batch) else { return } "
        + "switch result { case .success(let read): then(read.items == 1) case .failure(let error) where isMissing(error): then(true) "
        + #"case .failure(let error): logger.error("prompt subscription not removed (code \(code(of: error)))") then(false) } } "#
        + "return change"
    static let promptSnapshotHead: String = "static func makePromptSnapshot(then: @escaping @Sendable ([PendingRequest]?) -> Void) "
        + "-> CKFetchRecordZoneChangesOperation {"
    static let promptSnapshotLine: String = "let snapshot = CKFetchRecordZoneChangesOperation(recordZoneIDs: [approvalsZoneID],"
    static let promptZoneLine: String = "let zone = CKFetchRecordZoneChangesOperation.ZoneConfiguration()"
    static let promptSnapshotBody: String = promptZoneLine + " zone.desiredKeys = promptKeys " + promptSnapshotLine
        + " configurationsByRecordZoneID: [approvalsZoneID: zone]) snapshot.configuration = approvalsZoneConfiguration "
        + "let read = PromptResults() "
        + "snapshot.recordWasChangedBlock = { _, result in read.note(record: result.map { pendingRequest(from: $0) }) } "
        + "snapshot.recordZoneFetchResultBlock = { _, result in if case .failure(let error) = result { read.note(item: .failure(error)) } } "
        + "snapshot.fetchRecordZoneChangesResultBlock = { batch in guard let result = read.finish(batch: batch) else { return } "
        + "switch result { case .success(let offered): then(offered.prompts) case .failure(let error): "
        + #"logger.error("prompt snapshot failed (code \(code(of: error)))") then(nil) } } return snapshot"#
    static let promptKeysHead: String = "static var promptKeys: [CKRecord.FieldKey] {"
    static let promptKeysBody: String = "ApprovalWire.PromptField.allCases.map(\\.rawValue)"
    static let resultsHead: String = "private final class PromptResults: @unchecked Sendable {"
    static let resultsBody: String = "private let lock = NSLock() private var items = 0 private var prompts: [PendingRequest] = [] "
        + "private var failure: (any Error)? private var finished = false "
        + "func note(item result: Result<Void, any Error>) { lock.lock() defer { lock.unlock() } switch result { "
        + "case .success: items += 1 case .failure(let error): if failure == nil { failure = error } } } "
        + "func note(record result: Result<PendingRequest?, any Error>) { lock.lock() defer { lock.unlock() } switch result { "
        + "case .success(let prompt): items += 1 if let prompt { prompts.append(prompt) } "
        + "case .failure(let error): if failure == nil { failure = error } } } "
        + "func finish(batch: Result<Void, any Error>) -> Result<(items: Int, prompts: [PendingRequest]), any Error>? { "
        + "lock.lock() defer { lock.unlock() } guard !finished else { return nil } finished = true "
        + "if let failure { return .failure(failure) } if case .failure(let error) = batch { return .failure(error) } "
        + "return .success((items, prompts)) }"
    static let promptPieces: [(head: String, body: String, what: String)] = [
        (promptSubscriptionHead, promptSubscriptionBody, "the prompt subscription: fixed words, no record field, no action"),
        (promptLookupHead, promptLookupBody, "the prompt subscription's lookup: missing on unknownItem or another shape"),
        (promptSaveHead, promptSaveBody, "the prompt subscription's creation: the one subscription, nothing deleted"),
        (promptRemovalHead, promptRemovalBody, "the prompt subscription's removal: the one ID, nothing saved"),
        (promptSnapshotHead, promptSnapshotBody, "the snapshot: the zone from the start, six fields, any failure failing it all"),
        (promptKeysHead, promptKeysBody, "the snapshot's fields: the prompt's six"),
        (resultsHead, resultsBody, "the prompt operations' result holder: the first failure kept"),
    ]
    /// The live prompt source, whole: a lookup before any save, a save only
    /// when missing, one operation per call.
    static let sourceFile: String = "\(appDir)/Live/LivePromptSource.swift"
    static let sourceHead: String = "struct LivePromptSource: PromptSource {"
    static let sourceBody: String = "let database: any CloudKitApprovalDatabase func ensureSubscription() async -> Bool { "
        + "let lookup: CloudKitAlertSource.SubscriptionLookup = await withCheckedContinuation { continuation in "
        + "database.submit(CloudKitAlertSource.makePromptSubscriptionLookup { continuation.resume(returning: $0) }) } "
        + "guard lookup == .missing else { return lookup == .found } return await withCheckedContinuation { continuation in "
        + "database.submit(CloudKitAlertSource.makePromptSubscriptionSave { continuation.resume(returning: $0) }) } } "
        + "func removeSubscription() async -> Bool { await withCheckedContinuation { continuation in "
        + "database.submit(CloudKitAlertSource.makePromptSubscriptionRemoval { continuation.resume(returning: $0) }) } } "
        + "func snapshot() async -> [PendingRequest]? { await withCheckedContinuation { continuation in "
        + "database.submit(CloudKitAlertSource.makePromptSnapshot { continuation.resume(returning: $0) }) } }"
    static let promptWordSites: [(word: String, sites: [String: Int])] = [
        ("makePromptSubscription", CloudKitStructureTests.appSites(["Live/CloudKitAlertSource.swift": [
            promptSubscriptionHead: 1, CloudKitStructureTests.promptSubscriptionSave: 1]])),
        ("makePromptSubscriptionLookup", CloudKitStructureTests.appSites([
            "Live/CloudKitAlertSource.swift": [promptLookupHead: 1],
            "Live/LivePromptSource.swift": ["database.submit(CloudKitAlertSource.makePromptSubscriptionLookup { continuation.resume(returning: $0) })": 1]])),
        ("makePromptSubscriptionSave", CloudKitStructureTests.appSites([
            "Live/CloudKitAlertSource.swift": [promptSaveHead: 1],
            "Live/LivePromptSource.swift": ["database.submit(CloudKitAlertSource.makePromptSubscriptionSave { continuation.resume(returning: $0) })": 1]])),
        ("makePromptSubscriptionRemoval", CloudKitStructureTests.appSites([
            "Live/CloudKitAlertSource.swift": [promptRemovalHead: 1],
            "Live/LivePromptSource.swift": [
                "database.submit(CloudKitAlertSource.makePromptSubscriptionRemoval { continuation.resume(returning: $0) })": 1]])),
        ("makePromptSnapshot", CloudKitStructureTests.appSites([
            "Live/CloudKitAlertSource.swift": [promptSnapshotHead: 1],
            "Live/LivePromptSource.swift": ["database.submit(CloudKitAlertSource.makePromptSnapshot { continuation.resume(returning: $0) })": 1]])),
        ("PromptResults", CloudKitStructureTests.appSites(["Live/CloudKitAlertSource.swift": [
            resultsHead: 1, "let found = PromptResults()": 1, "let saved = PromptResults()": 1, "let removed = PromptResults()": 1,
            "let read = PromptResults()": 1]])),
        ("promptKeys", CloudKitStructureTests.appSites(["Live/CloudKitAlertSource.swift": [
            promptKeysHead: 1, "zone.desiredKeys = promptKeys": 1, "return keys.count == promptKeys.count && Set(keys) == Set(promptKeys)": 2]])),
        ("promptNotificationBody", CloudKitStructureTests.appSites(["Live/CloudKitAlertSource.swift": [
            "static let promptNotificationBody = \"A permission prompt is waiting.\"": 1,
            "info.alertBody = promptNotificationBody": 1, "guard info.title == notificationTitle, info.alertBody == promptNotificationBody,": 1]])),
        ("promptSubscriptionID", CloudKitStructureTests.appSites(["Live/CloudKitAlertSource.swift": [
            "notification.subscriptionID == ApprovalWire.promptSubscriptionID,": 1, "subscriptionID: ApprovalWire.promptSubscriptionID,": 1,
            "query.subscriptionID == ApprovalWire.promptSubscriptionID,": 1, promptLookupLine: 1, promptRemovalLine: 1,
            lookupCheckBody: 1, "return saved.isEmpty && removed == [ApprovalWire.promptSubscriptionID]": 1]])),
    ]
    /// Every line of the CloudKit file naming a prompt operation's type:
    /// the seam, its conformer, the checks, the factories and their
    /// constructions, nothing else.
    static let promptTypeSites: [(String, [String: Int])] = [
        (#"\bCKFetchRecordZoneChangesOperation\b"#, [promptSnapshotHead: 1, promptZoneLine: 1, promptSnapshotLine: 1, snapshotCheckHead: 1,
                                                    promptSeamLines[0]: 1, promptSeamLines[0] + " {": 1]),
        (#"\bCKFetchSubscriptionsOperation\b"#, [promptLookupHead: 1, promptLookupLine: 1, lookupCheckHead: 1,
                                                promptSeamLines[1]: 1, promptSeamLines[1] + " {": 1]),
        (#"\bCKModifySubscriptionsOperation\b"#, [promptSaveHead: 1, promptRemovalHead: 1, CloudKitStructureTests.promptSubscriptionSave: 1,
                                                 promptRemovalLine: 1, changeCheckHead: 1, promptSeamLines[2]: 1, promptSeamLines[2] + " {": 1]),
    ]

    static func promptPathFailures(_ app: [Source]) -> [String] {
        let file = CloudKitStructureTests.codeOnly(app.first { $0.path == cloudKitFile }?.text ?? "")
        let source = CloudKitStructureTests.codeOnly(app.first { $0.path == sourceFile }?.text ?? "")
        var failures: [String] = []
        for (head, pinned, what) in promptPieces {
            guard let body = CloudKitStructureTests.body(after: head, in: file) else {
                failures.append("\(what) moved (the lock would be vacuous)")
                continue
            }
            if SettingsReachabilityTests.flat(body) != pinned {
                failures.append("\(what) — exactly as pinned")
            }
        }
        if CloudKitStructureTests.body(after: sourceHead, in: source).map(SettingsReachabilityTests.flat) != sourceBody {
            failures.append("the live prompt source looks up before it saves, saves only what is missing, one operation a call — exactly as pinned")
        }
        let stripped: [Source] = app.map { ($0.path, CloudKitStructureTests.codeOnly($0.text)) }
        for (word, sites) in promptWordSites {
            failures += CloudKitStructureTests.appSiteFailures(#"\b"# + word + #"\b"#, in: stripped, allowed: sites,
                                                               rule: "'\(word)' is declared once and used at its pinned sites alone")
        }
        let uncut = CloudKitStructureTests.wholeLineCommentsRemoved(app.first { $0.path == cloudKitFile }?.text ?? "")
        for (pattern, sites) in promptTypeSites {
            failures += CloudKitStructureTests.siteFailures(pattern, in: uncut, file: cloudKitFile, allowed: sites,
                                                            rule: "a prompt operation's type is named by the seam, its conformer, its check "
                                                                + "and its factory alone")
        }
        return failures
    }

    @Test func thePromptPathRunsItsPinnedOperationsAlone() throws {
        let app = try Self.app()
        #expect(app.contains { $0.path == Self.sourceFile }, "vacuity: the scan sees the prompt source")
        #expect(Self.promptPathFailures(app).isEmpty, "\(Self.promptPathFailures(app))")
        let ck = Self.cloudKitFile
        let source = Self.sourceFile
        let feed = "\(Self.appDir)/Model/AlertFeed.swift"
        let mutants: [(String, [Source])] = [
            // The push: a record field, the input as its words, an action, a
            // silent wake.
            ("a record field in the push", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "        info.alertBody = promptNotificationBody\n",
                                        with: "        info.alertBody = promptNotificationBody\n        info.desiredKeys = promptKeys\n") }),
            ("the input as the push's words", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "        info.alertBody = promptNotificationBody\n",
                                        with: "        info.alertLocalizationKey = \"%1$@\"\n"
                                            + "        info.alertLocalizationArgs = [ApprovalWire.PromptField.inputPreview.rawValue]\n") }),
            ("an action on the push", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "        info.soundName = notificationSound\n        subscription.notificationInfo = info\n        return subscription\n    }\n\n    /// Whether",
                                        with: "        info.soundName = notificationSound\n        info.category = \"answer\"\n"
                                            + "        subscription.notificationInfo = info\n        return subscription\n    }\n\n    /// Whether") }),
            ("every zone watched", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "        subscription.zoneID = approvalsZoneID\n", with: "") }),
            // The lookup and the save: missing read from any failure, a save
            // without a lookup, a save after a failed lookup.
            ("any lookup failure read as missing", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "case .failure(let error) where isMissing(error): then(.missing)\n",
                                        with: "case .failure: then(.missing)\n") }),
            ("an empty lookup read as found", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "then(read.items == 1 ? .found : .failed)", with: "then(.found)") }),
            // #194 security review: a subscription in another shape kept.
            ("any shape found read as found", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: Self.promptLookupItemLine, with: "found.note(item: result.map { _ in () })") }),
            ("another shape read as a failure", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: ".failure(CKError(.unknownItem)) })", with: ".failure(CKError(.serverRejectedRequest)) })") }),
            ("a save without a lookup", Self.mutate(app, source) {
                $0.replacingOccurrences(of: "        guard lookup == .missing else { return lookup == .found }\n", with: "") }),
            ("a save after a failed lookup", Self.mutate(app, source) {
                $0.replacingOccurrences(of: "guard lookup == .missing else", with: "guard lookup != .found else") }),
            ("the removal saving the subscription", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "CKModifySubscriptionsOperation(subscriptionsToSave: nil, subscriptionIDsToDelete:",
                                        with: "CKModifySubscriptionsOperation(subscriptionsToSave: [makePromptSubscription()], subscriptionIDsToDelete:") }),
            // The read: every field, a token, a record's own result ignored,
            // a partial read handed on, a later failure kept over the first.
            ("a read of every field", Self.mutate(app, ck) { $0.replacingOccurrences(of: "        zone.desiredKeys = promptKeys\n", with: "") }),
            ("a record's own result ignored", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "        snapshot.recordWasChangedBlock = { _, result in read.note(record: result.map { pendingRequest(from: $0) }) }\n",
                                        with: "        snapshot.recordWasChangedBlock = { _, result in read.note(record: .success(try? result.get().flatMap { pendingRequest(from: $0) })) }\n") }),
            ("the zone's failure ignored", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "            if case .failure(let error) = result { read.note(item: .failure(error)) }\n", with: "") }),
            ("a partial read handed on", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "        if let failure { return .failure(failure) }\n", with: "") }),
            ("a later failure kept over the first", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "if failure == nil { failure = error }", with: "failure = error") }),
            ("the holder ending twice", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "        guard !finished else { return nil }\n        finished = true\n        if let failure",
                                        with: "        finished = true\n        if let failure") }),
            // Each piece once: a factory or the holder reached elsewhere, the
            // ID on another line, a second read in the source.
            ("a factory reached elsewhere", Self.mutate(app, feed) { $0 + "\nlet spare = CloudKitAlertSource.makePromptSnapshot { _ in }" }),
            ("a factory unapplied elsewhere", Self.mutate(app, feed) { $0 + "\nlet spare = CloudKitAlertSource.makePromptSubscriptionSave" }),
            ("a second holder", Self.mutate(app, feed) { $0 + "\nlet spare = PromptResults()" }),
            ("the ID on another line", Self.mutate(app, feed) { $0 + "\nlet spare = ApprovalWire.promptSubscriptionID" }),
            ("the source reads twice", Self.mutate(app, source) {
                $0.replacingOccurrences(of: "    func snapshot() async -> [PendingRequest]? {\n",
                                        with: "    func snapshot() async -> [PendingRequest]? {\n        _ = await withCheckedContinuation { c in "
                                            + "database.submit(CloudKitAlertSource.makePromptSnapshot { c.resume(returning: $0) }) }\n") }),
            ("a prompt operation's type on a new line", Self.mutate(app, ck) {
                $0 + "\nfunc spare(_ o: CKModifySubscriptionsOperation) {}" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.promptPathFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: whole-line comments naming the pieces, and
        // words that only contain them.
        #expect(Self.promptPathFailures(Self.mutate(app, feed) {
            $0 + "\n/// never makePromptSnapshot or PromptResults() here, never ApprovalWire.promptSubscriptionID\n"
                + "let promptKeysCount = 6, spareSnapshot = 1, isPromptSnapshotted = false"
        }).isEmpty)
    }

    // MARK: 7. One record, one operation, one subscription, however spelled (#153)

    /// A construction of `type`, however it is applied: `T(`, `T (`,
    /// `T.init(`, `CloudKit.T(` (`T.ID(` builds another type). The Mac's
    /// `ApprovalRecordPathStructureTests.constructionPattern`.
    static func constructionPattern(_ type: String) -> String { #"\b"# + type + #"\s*(?:\.\s*init\b\s*)?\("# }

    /// The constructor of `type` reached with no construction to count: an
    /// unapplied `.init`, the metatype, an alias, an extension, a subclass,
    /// or a generic parameter bound to it (a member type, `T.ID`, is another
    /// type).
    static func indirectConstructionPattern(_ type: String) -> String {
        let named = #"(?:CloudKit\s*\.\s*)?"# + type + #"\b(?!\s*\.\s*[A-Z])"#
        return [#"\b"# + type + #"\s*\.\s*(?:init\b(?!\s*\()|self\b|Type\b)"#,
                #"\btypealias\b[^\n]*\b"# + named,
                #"\bextension\s+"# + named,
                #"\b(?:class|actor)\s+(?!func\b|var\b|let\b)\w+[^{\n]*:[^{\n]*\b"# + named,
                #"<[^>\n]*\b\w+\s*:\s*"# + named,
                #"\bwhere\b[^{\n]*\b"# + named].joined(separator: "|")
    }

    /// An implicit `.init(`: what it builds is not in the text, so the
    /// CloudKit file spells every construction (none uses one today).
    ///
    /// AMENDED (#168, the PR #167 review's G9): `0 ~> .init(…)` builds one
    /// through a custom operator ending in `>`, which the look-behind took
    /// for a generic's close; an operator character, a space, then `.init`
    /// is implicit too.
    static let implicitInit =
        #"(?<![\w)\]>\s])\s*\.\s*init\b|\b(?:return|in|throw|try|await|else|case|where|is|as|some|any)\s+\.\s*init\b"#
            + #"|[!%&*+\-/<=>?^|~]\s+\.\s*init\b"#

    /// AMENDED (#166, the S-PAIR-B security review's B6, B9 and B10): every
    /// lock that counts a construction bans an implicit `.init(` in EVERY
    /// app file, not only the CloudKit file. `let d: PhoneDecision? =
    /// .init(…)` builds one with no `PhoneDecision(` in the text, so no
    /// count could see it; the app spells every construction (none uses an
    /// implicit init today). Read in every constructor scan copy.
    static func implicitInitFailures(_ app: [Source], rule: String) -> [String] {
        app.compactMap { path, text in
            CloudKitStructureTests.constructorScanCopies(CloudKitStructureTests.codeOnly(text))
                .contains { CloudKitStructureTests.hits(implicitInit, in: $0) }
                ? "\(path) has an implicit .init( — \(rule); the app spells every construction" : nil
        }
    }

    /// The CloudKit file's records (the decision's and, since S-PAIR-C1.5,
    /// the pairing response's), their two save operations (one line each,
    /// the same text) and one subscription (the alert lane's push), each
    /// type with every line it is built on.
    /// AMENDED (S-PAIR-C1.6, #172): and the approvals zone's lookup, its one
    /// creation and the one zone that creation saves.
    /// AMENDED (#194): and the prompt path's — the prompt subscription (the
    /// alert one's line, twice) and each subscription's push settings, its
    /// lookup, its creation and its removal, the snapshot and its zone's
    /// configuration.
    static let constructions: [String: [String: Int]] = [
        "CKRecord": ["let record = CKRecord(recordType: ApprovalWire.RecordType.decision.rawValue,": 1,
                     "let record = CKRecord(recordType: ApprovalWire.RecordType.pairingResponse.rawValue,": 1],
        "CKModifyRecordsOperation": [decisionOperation: 2],
        "CKQuerySubscription": ["let subscription = CKQuerySubscription(": 2],
        "NotificationInfo": ["let info = CKSubscription.NotificationInfo()": 2],
        "CKFetchSubscriptionsOperation": [promptLookupLine: 1],
        "CKModifySubscriptionsOperation": [CloudKitStructureTests.promptSubscriptionSave: 1, promptRemovalLine: 1],
        "CKFetchRecordZoneChangesOperation": [promptSnapshotLine: 1],
        "ZoneConfiguration": [promptZoneLine: 1],
        "CKFetchRecordZonesOperation": ["let lookup = CKFetchRecordZonesOperation(recordZoneIDs: [approvalsZoneID])": 1],
        "CKModifyRecordZonesOperation": [CloudKitStructureTests.zoneCreationLine: 1],
        "CKRecordZone": [CloudKitStructureTests.zoneCreationLine: 1],
    ]

    /// The security re-check's L6 (`CKRecord.init(` slipped past a count of
    /// `CKRecord(recordType:`): in the raw text each construction sits on
    /// its pinned line; in every scan copy each type is built as many times
    /// as it has pinned sites and never reached unnamed; and no implicit
    /// `.init(` appears at all.
    static func constructionFailures(_ app: [Source]) -> [String] {
        let file = CloudKitStructureTests.wholeLineCommentsRemoved(app.first { $0.path == cloudKitFile }?.text ?? "")
        var failures: [String] = []
        let copies = CloudKitStructureTests.constructorScanCopies(file)
        for (type, lines) in constructions.sorted(by: { $0.key < $1.key }) {
            let expected = lines.values.reduce(0, +)
            failures += CloudKitStructureTests.siteFailures(constructionPattern(type), in: file, file: cloudKitFile,
                                                            allowed: lines, rule: "each \(type) is built at its pinned site")
            for copy in copies {
                let built = CloudKitStructureTests.matches(constructionPattern(type), in: copy).count
                if built != expected {
                    failures.append("\(cloudKitFile) builds \(type) \(built) time(s) in a scan copy — exactly \(expected)")
                }
                if CloudKitStructureTests.hits(indirectConstructionPattern(type), in: copy) {
                    failures.append("\(cloudKitFile) reaches \(type)'s constructor unnamed")
                }
            }
        }
        if copies.contains(where: { CloudKitStructureTests.hits(implicitInit, in: $0) }) {
            failures.append("\(cloudKitFile) has an implicit .init( — the CloudKit file spells every construction")
        }
        return CloudKitStructureTests.unique(failures)
    }

    @Test func theCloudKitFileBuildsEachRecordAndOperationOnce() throws {
        let app = try Self.app()
        #expect(Self.constructionFailures(app).isEmpty, "\(Self.constructionFailures(app))")
        let ck = Self.cloudKitFile
        let mutants: [(String, [Source])] = [
            // The security re-check (#146): the phone's alert-lane plant, as planted.
            ("the live database extended to save an init-spelled decision", Self.mutate(app, ck) {
                $0 + "\nextension LiveCloudKitAlertDatabase {\n    func alertLaneProbe(_ p: PromptID) async throws {\n"
                    + "        _ = try await container.privateCloudDatabase.save(CKRecord.init(recordType: "
                    + "ApprovalWire.RecordType.decision.rawValue,\n            recordID: CloudKitAlertSource.decisionRecordID(for: p)))\n    }\n}" }),
            ("a second record, spaced", Self.mutate(app, ck) { $0 + "\nlet r = CKRecord (recordType: \"PromptDecision\")" }),
            ("a backticked second record", Self.mutate(app, ck) { $0 + "\nlet r = `CKRecord`(recordType: \"PromptDecision\")" }),
            ("a comment-split second operation", Self.mutate(app, ck) {
                $0 + "\nlet o = CKModifyRecordsOperation/* x */(recordsToSave: [], recordIDsToDelete: nil)" }),
            ("a second subscription", Self.mutate(app, ck) {
                $0 + "\nlet s = CKQuerySubscription.init(recordType: \"PromptDecision\", predicate: p, options: [])" }),
            ("an unapplied record init", Self.mutate(app, ck) { $0 + "\nlet make = CKRecord.init" }),
            ("an aliased operation", Self.mutate(app, ck) {
                $0 + "\ntypealias Op = CKModifyRecordsOperation\nlet o = Op(recordsToSave: [], recordIDsToDelete: nil)" }),
            ("an extension's Self(", Self.mutate(app, ck) {
                $0 + "\nextension CKRecord {\n    static func spare() -> CKRecord { Self(recordType: \"X\") }\n}" }),
            ("a bound generic", Self.mutate(app, ck) { $0 + "\nfunc spare<R: CKRecord>(_: R.Type) -> R { R(recordType: \"X\") }" }),
            ("an implicit init in the decision's records", Self.mutate(app, ck) {
                $0.replacingOccurrences(of: "recordsToSave: [record],", with: "recordsToSave: [record, .init(recordType: \"X\")],") }),
            ("an implicit init returned", Self.mutate(app, ck) { $0 + "\nfunc spare() -> CKRecord {\n    return .init(recordType: \"X\")\n}" }),
            // #194: a second lookup, removal or read; a push setting built
            // elsewhere; an aliased read.
            ("a second lookup", Self.mutate(app, ck) { $0 + "\nlet spare = CKFetchSubscriptionsOperation(subscriptionIDs: nil)" }),
            ("a second change, init-spelled", Self.mutate(app, ck) {
                $0 + "\nlet spare = CKModifySubscriptionsOperation.init(subscriptionsToSave: nil, subscriptionIDsToDelete: nil)" }),
            ("a second read", Self.mutate(app, ck) {
                $0 + "\nlet spare = CKFetchRecordZoneChangesOperation(recordZoneIDs: [], configurationsByRecordZoneID: nil)" }),
            ("a third push setting", Self.mutate(app, ck) { $0 + "\nlet spare = CKSubscription.NotificationInfo()" }),
            ("an aliased read", Self.mutate(app, ck) {
                $0 + "\ntypealias Spare = CKFetchRecordZoneChangesOperation\nlet s = Spare(recordZoneIDs: [], configurationsByRecordZoneID: nil)" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.constructionFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        for (pattern, probe) in [(Self.constructionPattern("CKRecord"), "CKRecord . init (recordType: t)"),
                                 (Self.indirectConstructionPattern("CKRecord"), "extension CloudKit.CKRecord {"),
                                 (Self.implicitInit, "let r: CKRecord =\n    .init(recordType: t)")] {
            #expect(CloudKitStructureTests.hits(pattern, in: probe), "'\(pattern)' does not match '\(probe)'")
        }
        // Over-match controls: record and zone IDs, the record as a
        // parameter or result, an implicit member that is no init, an
        // extension of a member type, and a whole-line comment.
        #expect(Self.constructionFailures(Self.mutate(app, ck) {
            $0 + "\nfunc f(r: CKRecord, rs: [CKRecord], res: Result<CKRecord, any Error>) -> CKRecord.ID { "
                + "CKRecord.ID(recordName: \"x\", zoneID: .default) }\nextension CKRecord.ID {}\nlet now: () -> Date = Date.init"
                + "\n/// never CKRecord.init(…), never typealias R = CKRecord\n"
        }).isEmpty)
    }

    // MARK: 8. The guarded types' constructors, never reached unnamed (#168)

    /// The PR #167 review's (a): the types whose constructions the suites
    /// count. Their constructors are never reached unnamed ANYWHERE in the
    /// app — not through an unapplied `.init`, the metatype, an alias, an
    /// extension, a subclass or a bound generic (`indirectConstructionPattern`,
    /// the CloudKit file's), through `Self(` / `Self.init` (an extension's
    /// own constructor, the review's G3), or through an operator of the app's
    /// own (G9 built a decision with `0 ~> .init(…)`): no source declares an
    /// operator at all. AMENDED (the S-PAIR-C1 security review's R1): nor
    /// through a dynamic type — no source takes `type(of:)`.
    /// AMENDED (S-PAIR-C1.5, #170): and the pairing response's CloudKit
    /// writer, which lock 2 says no app source builds by name.
    /// AMENDED (S-PAIR-C1.6, #172): and the live approvals database and the
    /// live pairing, so neither is extended, aliased or reached unnamed.
    /// AMENDED (#194): and the live prompt source.
    static let guardedTypes = ["PhoneDecision", "PendingRequest", "PairingCeremony", "PhoneKeyring", "KeyFingerprint",
                               "LocalAuthenticationMatch", "CloudKitPairingResponseWriter", "LiveCloudKitApprovalDatabase",
                               "LivePairing", "LivePromptSource"]
    static let selfInit = #"\bSelf\s*(?:\(|\.\s*init\b)"#
    static let operatorDeclaration = #"\boperator\b"#
    /// AMENDED (the S-PAIR-C1 security review's R1): a value's dynamic type,
    /// taken at all. `type(of: d).init(…)` built a decision (P1) and a code
    /// (P2) with no type named; a pattern for `type(of:)` followed by
    /// `.init` would still miss `let t = type(of: d)` and a later `t.init(…)`,
    /// so the app — which takes none — takes no dynamic type anywhere.
    static let dynamicType = #"\btype\s*\(\s*of\s*:"#

    static func unnamedConstructionFailures(_ app: [Source]) -> [String] {
        var failures: [String] = []
        for (path, text) in app {
            for copy in CloudKitStructureTests.constructorScanCopies(CloudKitStructureTests.codeOnly(text)) {
                for type in guardedTypes where CloudKitStructureTests.hits(indirectConstructionPattern(type), in: copy) {
                    failures.append("\(path) reaches \(type)'s constructor unnamed")
                }
                if CloudKitStructureTests.hits(selfInit, in: copy) {
                    failures.append("\(path) builds through Self( or Self.init — the app spells every construction")
                }
                if CloudKitStructureTests.hits(operatorDeclaration, in: copy) {
                    failures.append("\(path) declares an operator — none hides what it builds")
                }
                if CloudKitStructureTests.hits(dynamicType, in: copy) {
                    failures.append("\(path) takes a dynamic type (type(of:)) — the road to a constructor with no type named")
                }
            }
        }
        return CloudKitStructureTests.unique(failures + implicitInitFailures(app, rule: "the guarded types are built by name only"))
    }

    @Test func noGuardedConstructorIsReachedUnnamed() throws {
        let app = try Self.app()
        #expect(Self.unnamedConstructionFailures(app).isEmpty, "\(Self.unnamedConstructionFailures(app))")
        let inbox = Self.inboxFile
        let keyring = "\(Self.appDir)/Model/PhoneKeyring.swift"
        // The review's plants, as planted (G3/G4 and G9), each alone.
        let g3 = "\nextension PhoneDecision {\n    static func reviewerUnsigned(_ p: PromptID) -> Self? {\n"
            + "        Self(promptID: p, verdict: .allow, decidedAt: Date(timeIntervalSince1970: 0), signature: Data(count: 64))\n    }\n}"
        let g4 = "\nextension RequestInbox {\n    func reviewerUnapplied(_ p: PromptID) -> PhoneDecision? {\n        let make = PhoneDecision.init\n"
            + "        return make(p, .allow, Date(timeIntervalSince1970: 0), Data(count: 64))\n    }\n}"
        let g9 = "\ninfix operator ~>: AdditionPrecedence\nfunc ~> (lhs: Int, rhs: PhoneDecision?) -> PhoneDecision? { rhs }\n"
            + "extension RequestInbox {\n    func reviewerOperatorInit(_ p: PromptID) -> PhoneDecision? {\n"
            + "        0 ~> .init(promptID: p, verdict: .allow, decidedAt: Date(timeIntervalSince1970: 0), signature: Data(count: 64))\n    }\n}"
        var mutants: [(String, [Source])] = [
            ("G3: Self( in an extension", Self.mutate(app, inbox) { $0 + g3 }),
            ("G4: an unapplied PhoneDecision.init", Self.mutate(app, inbox) { $0 + g4 }),
            ("G9: .init after a >-ending operator", Self.mutate(app, inbox) { $0 + g9 }),
            ("G9's .init alone", Self.mutate(app, inbox) {
                $0 + "\nfunc spare(_ p: PromptID) -> PhoneDecision? { 0 ~> .init(promptID: p) }" }),
            ("an operator declared alone", Self.mutate(app, keyring) { $0 + "\nprefix operator ^^" }),
            ("Self.init in an extension", Self.mutate(app, keyring) { $0 + "\nextension PhoneKeyring { static func spare() -> Self { Self.init() } }" }),
            // The S-PAIR-C1 security review's R1: its P1 and P2, as planted,
            // and their neighbours — the dynamic type kept and used later,
            // spaced, backticked, module-qualified, and unapplied.
            ("P1: a decision built through type(of:).init", Self.mutate(app, inbox) {
                $0 + "\nextension RequestInbox {\n    func reviewerDynamicInit(_ d: PhoneDecision, _ p: PromptID) -> PhoneDecision? {\n"
                    + "        type(of: d).init(promptID: p, verdict: .allow, decidedAt: Date(timeIntervalSince1970: 0), signature: Data(count: 64))\n    }\n}" }),
            ("P2: a fingerprint built through type(of:).init", Self.mutate(app, inbox) {
                $0 + "\nfunc reviewerCode(_ f: KeyFingerprint, _ k: [UInt8]) -> KeyFingerprint? { type(of: f).init(publicKey: k) }" }),
            ("the dynamic type kept, its init called later", Self.mutate(app, keyring) {
                $0 + "\nfunc spare(_ f: KeyFingerprint, _ k: [UInt8]) -> KeyFingerprint? {\n    let made = type(of: f)\n    return made.init(publicKey: k)\n}" }),
            ("a spaced dynamic type", Self.mutate(app, keyring) { $0 + "\nfunc spare(_ f: KeyFingerprint) -> Any { type ( of : f ) }" }),
            ("a backticked dynamic type", Self.mutate(app, keyring) { $0 + "\nfunc spare(_ f: KeyFingerprint) -> Any { `type`(of: f) }" }),
            ("a module-qualified dynamic type", Self.mutate(app, keyring) { $0 + "\nfunc spare(_ f: KeyFingerprint) -> Any { Swift.type(of: f) }" }),
            ("an unapplied type(of:)", Self.mutate(app, keyring) { $0 + "\nlet spare: (Int) -> Int.Type = type(of:)" }),
        ]
        for type in Self.guardedTypes {
            mutants += [
                ("\(type): an extension", Self.mutate(app, keyring) { $0 + "\nextension \(type) {}" }),
                ("\(type): an alias", Self.mutate(app, keyring) { $0 + "\ntypealias Spare = \(type)" }),
                ("\(type): the metatype", Self.mutate(app, keyring) { $0 + "\nlet spare = \(type).self" }),
                ("\(type): a bound generic", Self.mutate(app, keyring) { $0 + "\nfunc spare<T: \(type)>(_ t: T.Type) {}" }),
            ]
        }
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.unnamedConstructionFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: named constructions, member types, a delegating
        // `self.init(`, `Self.reason` (a member, no construction), words that
        // only contain the banned ones, and a whole-line comment.
        #expect(Self.unnamedConstructionFailures(Self.mutate(app, keyring) {
            $0 + "\nfunc spare(k: [UInt8]) -> KeyFingerprint? { KeyFingerprint(publicKey: k) }"
                + "\nfunc spare2(p: PairingCeremony.Phase, r: PendingRequest?) -> Bool { p == .scanning && r == nil }"
                + "\nlet spareCooperator = 1, Selfish = 2\nlet spareReason = PairingCeremony.reason"
                + "\n/// never Self(…), never infix operator, never PhoneDecision.init, never type(of: d).init"
        }).isEmpty)
        // R1's over-match controls: a `type` that is a name, a member or part
        // of a word, and a function whose name only ends in `Type(of:)`.
        #expect(Self.unnamedConstructionFailures(Self.mutate(app, keyring) {
            $0 + "\nlet type = 1, recordType = 2, subtype = 3, types = [4]\nfunc spare(r: SpareRecord) -> Int { r.typeCode + types.count }"
                + "\nfunc spareType(of x: Int) -> Int { x }\nlet spare3 = spareType(of: 1)"
        }).isEmpty)
        #expect(Self.unnamedConstructionFailures([("x", "init(a: Int) { self.init(b: a) }\nlet r = Self.reason")]).isEmpty)
        for probe in ["0 ~> .init(x)", "a == .init(x)", "f(x) ?? .init()"] {
            #expect(CloudKitStructureTests.hits(Self.implicitInit, in: probe), "'\(probe)' is implicit")
        }
        for probe in ["Array<Int>.init()", "Foo<T>.init(x)", "x = PhoneDecision.init(p)"] {
            #expect(!CloudKitStructureTests.hits(Self.implicitInit, in: probe), "'\(probe)' names what it builds")
        }
    }

    // MARK: 9. No unsafe memory (#168, the Mac's lock 9b families)

    /// The Mac's `unsafeMemoryPattern`: a bit cast, and every pointer
    /// rebinding or typed load. The phone app uses none, anywhere.
    static let unsafeMemoryPattern =
        #"\b(?:unsafeBitCast|bindMemory|assumingMemoryBound|withMemoryRebound|initializeMemory)\b"#
            + #"|\.\s*load(?:Unaligned)?\b|\bload(?:Unaligned)?\s*\("#

    static func unsafeMemoryFailures(_ app: [Source]) -> [String] {
        CloudKitStructureTests.unique(app.flatMap { path, text in
            CloudKitStructureTests.constructorScanCopies(CloudKitStructureTests.codeOnly(text))
                .filter { CloudKitStructureTests.hits(unsafeMemoryPattern, in: $0) }
                .map { _ in "\(path) uses unsafe memory — a decision or a key is never forged from bytes" }
        })
    }

    @Test func noAppSourceUsesUnsafeMemory() throws {
        let app = try Self.app()
        #expect(Self.unsafeMemoryFailures(app).isEmpty, "\(Self.unsafeMemoryFailures(app))")
        for plant in ["func zz(_ id: PromptID) -> PhoneDecision? { unsafeBitCast(0, to: PhoneDecision?.self) }",
                      "func zz<T>(_ r: UnsafeRawPointer) -> T { r.load(as: T.self) }",
                      "func zz<T>(_ r: UnsafeRawBufferPointer) -> T { r . loadUnaligned(as: T.self) }",
                      "func zz<T>(_ r: UnsafeMutableRawPointer) -> T { r.bindMemory(to: T.self, capacity: 1).pointee }",
                      "func zz<T>(_ r: UnsafeRawPointer) -> T { r.assumingMemoryBound(to: T.self).pointee }",
                      "func zz(_ p: UnsafeMutablePointer<Int>) { p.withMemoryRebound(to: UInt.self, capacity: 1) { _ in } }",
                      "func zz<T>(_ r: UnsafeMutableRawPointer, _ v: T) { _ = r.initializeMemory(as: T.self, repeating: v, count: 1) }",
                      "let zz: (Int, Int.Type) -> Int = `unsafeBitCast`"] {
            let mutant = Self.mutate(app, Self.inboxFile) { $0 + "\n" + plant }
            #expect(!Self.unsafeMemoryFailures(mutant).isEmpty, "canary '\(plant)' was NOT caught")
        }
        #expect(Self.unsafeMemoryFailures(Self.mutate(app, Self.inboxFile) {
            $0 + "\nlet payload = 1\nfunc reload() {}\nlet isLoaded = true\nlet n = withUnsafeBytes(of: 1) { $0.count }"
                + "\n/// never unsafeBitCast, never p.load(as:)"
        }).isEmpty)
    }
}
