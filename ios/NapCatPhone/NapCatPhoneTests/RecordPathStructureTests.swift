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
/// 4. Allow writes only after a biometric match it asked for itself, Deny
///    never asks, and both write through one site that re-checks the window
///    first (CL-3);
/// 5. the decision record is built once, only through the wire's keys and
///    encryption table, and carries no signature before pairing.
///
/// Each lock is a pure function over comment-stripped sources, and each
/// catches planted canaries, so none can pass vacuously.
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
                        "let e = ApprovalEvent.remoteDecision(d)"] {
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
    static let seamConformance =
        #"\b(class|struct|actor|enum|extension)\b[^{\n]*:[^{\n]*\bCloudKitApprovalDatabase\b"#

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

    @Test func noAppSourceBuildsALiveDecisionWriter() throws {
        let app = try Self.app()
        #expect(Self.liveWriterFailures(app).isEmpty, "\(Self.liveWriterFailures(app))")
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
        ]
        for (name, mutant) in mutants {
            #expect(!Self.liveWriterFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: 3. The S3 tests touch nothing live

    static let testsDir = CloudKitStructureTests.testsDir
    /// The S3 test files that run anything (this file only reads sources).
    static let s3TestFiles = ["ApprovalRecordFakes.swift", "RequestInboxTests.swift", "CloudKitRequestRecordTests.swift",
                              "RequestAnsweringTests.swift", "PendingRequestScreenTests.swift",
                              "CloudKitDecisionWriterTests.swift", "VisibleWhitespaceTests.swift"]

    /// A container, a live database or source, the real defaults, the
    /// notification center and the real biometric prompt.
    static let liveTokens = ["CKContainer", "privateCloudDatabase", "makeLive(", "UserDefaults.standard",
                             "UNUserNotificationCenter", "LAContext", "LocalAuthenticationGate(", "SystemNotificationGate("]

    static func liveFailures(_ tests: [Source]) -> [String] {
        tests.flatMap { path, text in
            let code = CloudKitStructureTests.codeOnly(text)
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
                        "let n = UNUserNotificationCenter.current()"] {
            let mutant = tests.map { ($0.path, $0.text + "\n" + planted) }
            #expect(!Self.liveFailures(mutant).isEmpty, "canary '\(planted)' was NOT caught")
        }
    }

    // MARK: 4. Allow needs the match; one write site re-checks the window

    static let inboxFile = "\(appDir)/Model/RequestInbox.swift"

    /// In the inbox: Allow opens on the answerable check, asks the gate,
    /// returns unless matched, and only then sends; Deny opens on the same
    /// check and never names the gate; the gate is asked in one place and
    /// the writer reached in one place, `send`, whose first act is to
    /// re-check that the request is still pending.
    static func allowPathFailures(_ inbox: String) -> [String] {
        let code = CloudKitStructureTests.codeOnly(inbox)
        var failures: [String] = []
        guard let allow = CloudKitStructureTests.body(after: "func allow(_ id: PromptID) async {", in: code),
              let deny = CloudKitStructureTests.body(after: "func deny(_ id: PromptID) async {", in: code),
              let send = CloudKitStructureTests.body(after: "private func send(_ verdict: ApprovalWire.Verdict, for id: PromptID) async {",
                                                     in: code) else {
            return ["allow, deny or send moved (the lock would be vacuous)"]
        }
        let allowSteps = ["guard isAnswerable(id) else { return }", "let match = await biometrics.confirm(reason: Self.allowReason)",
                          "guard match == .confirmed else {", "await send(.allow, for: id)"]
        var cursor = allow.startIndex
        for step in allowSteps {
            guard let found = allow.range(of: step, range: cursor..<allow.endIndex) else {
                failures.append("Allow lost '\(step)', or it moved out of order")
                break
            }
            cursor = found.upperBound
        }
        let denyFlat = SettingsReachabilityTests.flat(deny)
        if !denyFlat.hasPrefix("guard isAnswerable(id) else { return } await send(.deny, for: id)") {
            failures.append("Deny must open on the answerable check, then send")
        }
        if deny.contains("biometrics") { failures.append("Deny never asks for a match") }
        let sendFlat = SettingsReachabilityTests.flat(send)
        if !sendFlat.hasPrefix("tick() guard phase(of: id)?.isPending == true else {") {
            failures.append("send must re-check that the request is still pending before anything else")
        }
        for (token, count) in [("biometrics.confirm(", 1), ("writer.write(", 1), ("send(.allow", 1), ("send(.deny", 1)]
        where CloudKitStructureTests.occurrences(of: token, in: code) != count {
            failures.append("'\(token)' must appear exactly \(count) time(s) in the inbox")
        }
        if !send.contains("writer.write(") { failures.append("the one write must be in send") }
        return failures
    }

    @Test func allowNeedsTheMatchAndOneSiteWrites() throws {
        let inbox = try #require(try Self.app().first { $0.path == Self.inboxFile }).text
        #expect(Self.allowPathFailures(inbox).isEmpty, "\(Self.allowPathFailures(inbox))")
        let mutants: [(String, String)] = [
            ("Allow without the match", inbox.replacingOccurrences(
                of: "        guard match == .confirmed else {\n            entries[id]?.answer = .notConfirmed\n            return\n        }\n",
                with: "")),
            ("Allow sends before asking", inbox.replacingOccurrences(
                of: "        entries[id]?.answer = .confirming\n",
                with: "        entries[id]?.answer = .confirming\n        await send(.allow, for: id)\n")),
            ("Allow ignores the match", inbox.replacingOccurrences(of: "guard match == .confirmed else {",
                                                                   with: "guard match == match else {")),
            ("Deny skips the check", inbox.replacingOccurrences(
                of: "    func deny(_ id: PromptID) async {\n        guard isAnswerable(id) else { return }\n",
                with: "    func deny(_ id: PromptID) async {\n")),
            ("send skips the re-check", inbox.replacingOccurrences(
                of: "        tick()\n        guard phase(of: id)?.isPending == true else {\n            entries[id]?.answer = .none\n            return\n        }\n        entries[id]?.answer = .sending(verdict)",
                with: "        entries[id]?.answer = .sending(verdict)")),
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
    /// from the wire's own table, and no signature before pairing (CL-1).
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
        if !flat.contains("case .signature: return nil") {
            failures.append("a decision carries no signature before pairing (CL-1)")
        }
        return failures
    }

    @Test func theDecisionRecordIsWrittenOnlyThroughTheWire() throws {
        let file = try #require(try Self.app().first { $0.path == Self.cloudKitFile }).text
        #expect(Self.decisionSchemaFailures(file).isEmpty, "\(Self.decisionSchemaFailures(file))")
        let mutants: [(String, String)] = [
            ("a signature written", file.replacingOccurrences(of: "case .signature: return nil",
                                                              with: "case .signature: return Data([1]) as NSData")),
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
}
