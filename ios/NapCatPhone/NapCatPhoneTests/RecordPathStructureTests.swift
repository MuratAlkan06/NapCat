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
///    and fakes only, so no CloudKit operation of this path can run;
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
    /// AMENDED (#166): a clause on any number of lines, a refining protocol
    /// or a typealias (the one-line scan missed all three).
    static let seamConformance = CloudKitStructureTests.adoptionPattern("CloudKitApprovalDatabase")

    static func liveWriterFailures(_ app: [Source]) -> [String] {
        var failures: [String] = []
        for (path, text) in app {
            let code = CloudKitStructureTests.codeOnly(text)
            if constructionSpelling(code).contains(writerType + "(") {
                failures.append("\(path) builds the CloudKit decision writer — in this slice only tests may")
            }
            if code.range(of: seamConformance, options: .regularExpression) != nil {
                failures.append("\(path) conforms to CloudKitApprovalDatabase — in this slice only test fakes may")
            }
        }
        return failures
    }

    /// `liveWriterFailures` over every cleaned copy too (#153): a backticked
    /// or comment-split construction of the writer is a construction. And
    /// (#166) no implicit `.init(` in the app: it could build the writer
    /// unnamed.
    static func liveWriterFailuresInEveryCopy(_ app: [Source]) -> [String] {
        CloudKitStructureTests.unique(CloudKitStructureTests.constructorScanCopies(app).flatMap(liveWriterFailures)
            + implicitInitFailures(app, rule: "the CloudKit decision writer is built by no app source, by name or not"))
    }

    @Test func noAppSourceBuildsALiveDecisionWriter() throws {
        let app = try Self.app()
        #expect(Self.liveWriterFailuresInEveryCopy(app).isEmpty, "\(Self.liveWriterFailuresInEveryCopy(app))")
        let cloudKit = CloudKitStructureTests.codeOnly(app.first { $0.path == Self.cloudKitFile }?.text ?? "")
        for declaration in ["struct CloudKitDecisionWriter: DecisionWriter", "protocol CloudKitApprovalDatabase: Sendable",
                            "func submit(_ operation: CKModifyRecordsOperation)"] {
            #expect(cloudKit.contains(declaration), "vacuity: '\(declaration)' is what the lock looks for")
        }
        let feed = "\(Self.appDir)/Model/AlertFeed.swift"
        let mutants: [(String, [Source])] = [
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
    static let s3TestFiles = ["ApprovalRecordFakes.swift", "RequestInboxTests.swift", "CloudKitRequestRecordTests.swift",
                              "RequestAnsweringTests.swift", "PendingRequestScreenTests.swift",
                              "CloudKitDecisionWriterTests.swift", "VisibleWhitespaceTests.swift"]

    /// A container, a live database or source, the real defaults, the
    /// notification center and the real biometric prompt. AMENDED (#166):
    /// and since S-PAIR-B the live key parts (`SigningKeyStructureTests`'
    /// tokens: the enclave, the keychain, a context, the live bindings) and
    /// the launch factories that build them (the inbox's, by name or as an
    /// implicit member).
    static let liveTokens = ["CKContainer", "privateCloudDatabase", "makeLive(", "UserDefaults.standard",
                             "UNUserNotificationCenter", "SystemNotificationGate(", "RequestInbox.make", ".make(options:"]
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
                        "let make = RequestInbox.make", "let i: RequestInbox = .make(options: o, now: n)"] {
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
    static func allowPathFailures(_ inbox: String) -> [String] {
        let code = CloudKitStructureTests.codeOnly(inbox)
        var failures: [String] = []
        guard let allow = CloudKitStructureTests.body(after: "func allow(_ id: PromptID) async {", in: code),
              let deny = CloudKitStructureTests.body(after: "func deny(_ id: PromptID) async {", in: code),
              let confirm = CloudKitStructureTests.body(
                after: "private func confirmAndSend(_ verdict: ApprovalWire.Verdict, for id: PromptID) async {", in: code),
              let send = CloudKitStructureTests.body(
                after: "private func send(_ verdict: ApprovalWire.Verdict, for id: PromptID, match: any BiometricMatch) async {",
                in: code) else {
            return ["allow, deny, confirmAndSend or send moved (the lock would be vacuous)"]
        }
        for (name, body, verdict) in [("Allow", allow, "allow"), ("Deny", deny, "deny")]
        where SettingsReachabilityTests.flat(body) != "guard isAnswerable(id) else { return } await confirmAndSend(.\(verdict), for: id)" {
            failures.append("\(name) must open on the answerable check, then ask for its match (confirmAndSend), nothing else")
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
        for (token, count) in [("biometrics.confirm(", 1), ("writer.write(", 1), ("confirmAndSend(.allow", 1),
                               ("confirmAndSend(.deny", 1), ("await send(", 1), ("match.invalidate()", 1)]
        where CloudKitStructureTests.occurrences(of: token, in: code) != count {
            failures.append("'\(token)' must appear exactly \(count) time(s) in the inbox")
        }
        if !send.contains("writer.write(") { failures.append("the one write must be in send") }
        return failures
    }

    @Test func everyAnswerNeedsTheMatchAndOneSiteWrites() throws {
        let inbox = try #require(try Self.app().first { $0.path == Self.inboxFile }).text
        #expect(Self.allowPathFailures(inbox).isEmpty, "\(Self.allowPathFailures(inbox))")
        let ask = "        guard case .confirmed(let match) = await biometrics.confirm(reason: Self.reason(for: verdict)) else {\n"
        let mutants: [(String, String)] = [
            ("Deny skips the match", inbox.replacingOccurrences(
                of: "        guard isAnswerable(id) else { return }\n        await confirmAndSend(.deny, for: id)\n",
                with: "        guard isAnswerable(id) else { return }\n        await send(.deny, for: id, match: Spare())\n")),
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
                of: "    func deny(_ id: PromptID) async {\n        guard isAnswerable(id) else { return }\n",
                with: "    func deny(_ id: PromptID) async {\n")),
            ("send skips the re-check", inbox.replacingOccurrences(
                of: "        tick()\n        guard phase(of: id)?.isPending == true, let request = entries[id]?.request else {\n",
                with: "        guard let request = entries[id]?.request else {\n")),
            ("the match outlives its answer", inbox.replacingOccurrences(of: "        defer { match.invalidate() }\n", with: "")),
            ("a second write site", inbox + "\nextension RequestInbox { func f() async { _ = await writer.write(d) } }"),
        ]
        for (name, mutant) in mutants {
            #expect(mutant != inbox, "canary '\(name)' did not apply")
            #expect(!Self.allowPathFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
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
        if CloudKitStructureTests.occurrences(of: "CKRecord(recordType:", in: code) != 1 {
            failures.append("a decision record must be constructed in exactly one place (makeDecisionRecord)")
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
    /// or `main`, no queue, no database `add`, no dynamic message (whole
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
    static let operationRunPatterns = [#"\bstart\b"#, #"\bmain\b"#, #"\bOperationQueue\b"#, #"\baddOperations?\b"#,
                                       #"\.\s*add\b"#, #"\bperform\b"#, #"#selector\b"#, #"\bSelector\b"#,
                                       #"\bNSSelectorFromString\b"#]

    /// AMENDED after the security delta check (#153, X1: an operation run by
    /// an extension in ANOTHER file names no banned word here): the
    /// operation is pinned by where it goes. Every line of the CloudKit file
    /// naming `operation` is the seam's parameter or the factory building,
    /// configuring and returning it; the operation type is named only there
    /// and by the one construction; and `submit` only by the seam and the
    /// writer.
    static let decisionOperation = "let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)"
    static let seamRequirement = "func submit(_ operation: CKModifyRecordsOperation)"
    static let operationSites: [(pattern: String, sites: [String: Int], rule: String)] = [
        (#"\boperation\b"#, [seamRequirement: 1, decisionOperation: 1, "operation.savePolicy = .ifServerRecordUnchanged": 1,
                             "operation.isAtomic = true": 1, "operation.configuration = configuration": 1,
                             "operation.perRecordSaveBlock = { _, result in saved.note(result.map { _ in () }) }": 1,
                             "operation.modifyRecordsResultBlock = { batch in": 1, "return operation": 1],
         "the factory builds, configures and returns its operation, nothing else"),
        (#"\bCKModifyRecordsOperation\b"#, [seamRequirement: 1, ") -> CKModifyRecordsOperation {": 1, decisionOperation: 1],
         "the operation type is named by the seam, the factory and the one construction"),
        (#"\bsubmit\b"#, [seamRequirement: 1, "database.submit(CloudKitAlertSource.makeDecisionSaveOperation(record) "
                          + "{ continuation.resume(returning: $0) })": 1],
         "the seam is named only by its requirement and the writer"),
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
        let probes = ["o.start()", "o.main()", "OperationQueue.current", "q.addOperation(o)", "db.add(o)", "o.perform(s)",
                      "#selector(Operation.start)", "Selector((\"start\"))", "NSSelectorFromString(\"start\")"]
        #expect(probes.count == Self.operationRunPatterns.count)
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
    static let implicitInit =
        #"(?<![\w)\]>\s])\s*\.\s*init\b|\b(?:return|in|throw|try|await|else|case|where|is|as|some|any)\s+\.\s*init\b"#

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

    /// The CloudKit file's one record (the decision), one operation (its
    /// save) and one subscription (the alert lane's push).
    static let constructions = [
        "CKRecord": "let record = CKRecord(recordType: ApprovalWire.RecordType.decision.rawValue,",
        "CKModifyRecordsOperation": decisionOperation,
        "CKQuerySubscription": "let subscription = CKQuerySubscription(",
    ]

    /// The security re-check's L6 (`CKRecord.init(` slipped past a count of
    /// `CKRecord(recordType:`): in the raw text each construction sits on
    /// its pinned line; in every scan copy each type is built once and never
    /// reached unnamed; and no implicit `.init(` appears at all.
    static func constructionFailures(_ app: [Source]) -> [String] {
        let file = CloudKitStructureTests.wholeLineCommentsRemoved(app.first { $0.path == cloudKitFile }?.text ?? "")
        var failures: [String] = []
        let copies = CloudKitStructureTests.constructorScanCopies(file)
        for (type, line) in constructions.sorted(by: { $0.key < $1.key }) {
            failures += CloudKitStructureTests.siteFailures(constructionPattern(type), in: file, file: cloudKitFile,
                                                            allowed: [line: 1], rule: "the one \(type) is built at its one site")
            for copy in copies {
                let built = CloudKitStructureTests.matches(constructionPattern(type), in: copy).count
                if built != 1 { failures.append("\(cloudKitFile) builds \(type) \(built) time(s) in a scan copy — exactly once") }
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
}
