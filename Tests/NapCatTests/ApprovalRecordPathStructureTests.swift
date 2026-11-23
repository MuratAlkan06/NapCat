// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing

/// F4 slice S3: the fail-dark locks over the Mac's half of the CloudKit
/// record path (the PromptRequest writer and the PromptDecision reader).
/// Design: design/remote-approvals.md.
///
/// In this slice the record path exists, and is exercised by tests and fakes
/// only. Signed decisions (CL-1) arrive in a later slice, so nothing may
/// treat a decision record as a verdict, and the Mac stays never armed:
///
/// 1. the record path names nothing of the verdict API (the seam, the
///    intake, the lifecycle, the channel's verdict wire, the gate, the S0
///    decision type) — and nothing outside the record path names the record
///    path, so no production code reaches it at all;
/// 2. the approval files hold exactly one `armed` literal, `{ false }`, in
///    the fail-dark factory;
/// 3. no Mac source builds the S0 decision type or names its signature flag;
/// 4. the record path cannot reach iCloud by itself: no container, no
///    database, no account check, and nothing in the app conforms to its
///    database seam;
/// 5. the S3 test files touch nothing live.
///
/// Each lock is a pure function over comment-stripped sources and each
/// catches planted canaries, so none can pass vacuously.
struct ApprovalRecordPathStructureTests {
    typealias Sources = ApprovalChannelStructureTests.Sources

    /// The record path's one Mac file (Sources/NapCat).
    static let recordPathFile = "CloudKitApprovalRecords.swift"

    /// The record path's own types. Outside its file, nothing names them.
    static let recordPathTypes = ["ApprovalRecordWriter", "DecisionRecordReader", "GateApprovedPrompt",
                                  "ApprovalRecordDatabase", "DecisionRecordReading"]

    /// The verdict API and everything that leads to it: the seam and its
    /// host, the intake and the lifecycle it drives, the channel's verdict
    /// wire, the category gate, the S0 decision type and its signature flag,
    /// the toggle, and the armed flag.
    static let verdictAPITokens = ["ApprovalChannel", "verdictFrame", "verdictNotification", "sendFrame",
                                   "ApprovalIntake", "ApprovalSeamHost", "ApprovalLifecycle", "ApprovalEvent",
                                   "remoteDecision", "deliverVerdict", "decide(", "ApprovalDecision",
                                   "signatureVerified", "ApprovalGate", "classify(", "ApprovalRecordSink",
                                   "RemoteApprovalsController", "Seam", "armed"]

    static func text(_ name: String, in sources: Sources) -> String {
        ApprovalChannelStructureTests.text(name, in: sources)
    }

    static func mutate(_ sources: Sources, _ name: String, _ transform: (String) -> String) -> Sources {
        ApprovalChannelStructureTests.mutate(sources, name, transform)
    }

    // MARK: - 1. The record path never reaches the verdict API

    static func verdictReachFailures(_ sources: Sources) -> [String] {
        var failures: [String] = []
        for (name, text) in sources where name == recordPathFile {
            for token in verdictAPITokens where text.contains(token) {
                failures.append("'\(token)' in \(name) — the record path never reaches the verdict API")
            }
        }
        for (name, text) in sources where name != recordPathFile {
            for token in recordPathTypes where text.contains(token) {
                failures.append("'\(token)' in \(name) — in this slice nothing outside the record path reaches it")
            }
        }
        return failures
    }

    /// Vacuity: the record path is where the locks look for it.
    static func vacuityFailures(_ sources: Sources) -> [String] {
        let file = text(recordPathFile, in: sources)
        return ["final class ApprovalRecordWriter", "enum DecisionRecordReader", "protocol GateApprovedPrompt",
                "protocol ApprovalRecordDatabase"].filter { !file.contains($0) }
            .map { "'\($0)' not found in \(recordPathFile) — the record-path locks would be vacuous" }
    }

    @Test func theRecordPathNeverReachesTheVerdictAPI() throws {
        let withFile = try ApprovalChannelStructureTests.sources()
        #expect(Self.vacuityFailures(withFile).isEmpty, "\(Self.vacuityFailures(withFile))")
        #expect(Self.verdictReachFailures(withFile).isEmpty, "\(Self.verdictReachFailures(withFile))")
        let mutants: [(String, Sources)] = [
            ("the writer answers the dialog", Self.mutate(withFile, Self.recordPathFile) {
                $0 + "\nfunc f(i: Int, r: ChannelRequestID) { sendFrame(i, ApprovalChannel.verdictFrame(r, .allow)) }" }),
            ("the reader feeds the intake", Self.mutate(withFile, Self.recordPathFile) {
                $0 + "\nfunc f(i: ApprovalIntake, d: X) { i.decide(d) }" }),
            ("the reader builds a verdict", Self.mutate(withFile, Self.recordPathFile) {
                $0 + "\nlet d = ApprovalDecision(promptID: p, verdict: .allow, wireVersion: 1, signatureVerified: true)" }),
            ("the reader drives a lifecycle", Self.mutate(withFile, Self.recordPathFile) {
                $0 + "\nfunc f(l: inout ApprovalLifecycle) { _ = l.apply(.remoteDecision(d), now: 0) }" }),
            ("the writer classifies", Self.mutate(withFile, Self.recordPathFile) {
                $0 + "\nlet c = ApprovalGate.classify(toolName: t, inputPreview: p, secrets: [])" }),
            ("the writer arms", Self.mutate(withFile, Self.recordPathFile) { $0 + "\nlet armed = true" }),
            ("the toggle reaches the writer", Self.mutate(withFile, ApprovalChannelStructureTests.toggleFile) {
                $0 + "\nlet w = ApprovalRecordWriter(database: d)" }),
            ("the intake reads decisions", Self.mutate(withFile, ApprovalChannelStructureTests.intakeFile) {
                $0 + "\nlet r = DecisionRecordReader.read(record)" }),
            ("the app builds the writer", Self.mutate(withFile, "NapCatApp.swift") {
                $0 + "\nlet w = ApprovalRecordWriter(database: d)" }),
        ]
        for (name, mutant) in mutants {
            #expect(!Self.verdictReachFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: - 2. Armed stays false

    /// The approval files on the Mac (the S1/S2 ones and the record path).
    static let approvalFiles = [ApprovalChannelStructureTests.intakeFile, ApprovalChannelStructureTests.hostFile,
                                ApprovalChannelStructureTests.toggleFile, "RemoteApprovalsPolicy.swift", recordPathFile]

    /// What may follow `armed:` in them: a declaration, a pass-through, a
    /// read, or the fail-dark factory's one literal.
    static let armedForms = ["@escaping () -> Bool", "() -> Bool", "armed()", "armed,", "armed)", "{ false }"]

    static func armedFailures(_ sources: Sources) -> [String] {
        var failures: [String] = []
        var literals: [String] = []
        for (name, text) in sources where approvalFiles.contains(name) {
            let flat = MenuPanelStructureTests.flat(text)
            var cursor = flat.startIndex
            while let found = flat.range(of: "armed:", range: cursor..<flat.endIndex) {
                cursor = found.upperBound
                let rest = flat[found.upperBound...].drop { $0 == " " }
                guard let form = armedForms.first(where: { rest.hasPrefix($0) }) else {
                    failures.append("'armed:\(rest.prefix(24))' in \(name) — the approval files are never armed")
                    continue
                }
                if form == "{ false }" { literals.append(name) }
            }
            if flat.contains("armed = true") {
                failures.append("\(name) sets armed — the approval files are never armed")
            }
        }
        if literals != [ApprovalChannelStructureTests.toggleFile] {
            failures.append("'armed: { false }' at \(literals) — expected exactly once, in the fail-dark factory")
        }
        return failures
    }

    @Test func armedStaysFalse() throws {
        let sources = try ApprovalChannelStructureTests.sources()
        #expect(Self.armedFailures(sources).isEmpty, "\(Self.armedFailures(sources))")
        let toggle = ApprovalChannelStructureTests.toggleFile
        let mutants: [(String, Sources)] = [
            ("armed", Self.mutate(sources, toggle) { $0.replacingOccurrences(of: "armed: { false }", with: "armed: { true }") }),
            ("armed by the switch", Self.mutate(sources, toggle) {
                $0.replacingOccurrences(of: "armed: { false }", with: "armed: { state.enabled }") }),
            ("the literal dropped", Self.mutate(sources, toggle) {
                $0.replacingOccurrences(of: "armed: { false }", with: "armed: armed") }),
            ("a lifecycle opened armed", Self.mutate(sources, ApprovalChannelStructureTests.intakeFile) {
                $0.replacingOccurrences(of: "armed: armed(), now: now()", with: "armed: true, now: now()") }),
            ("a second never-armed host", Self.mutate(sources, ApprovalChannelStructureTests.hostFile) {
                $0 + "\nlet i = ApprovalIntake(armed: { false }, secrets: s)" }),
        ]
        for (name, mutant) in mutants {
            #expect(!Self.armedFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: - 3. No decision is a verdict on the Mac

    /// Until signed decisions exist (CL-1), no Mac source builds the S0
    /// decision type (however the construction is spelled) or names its
    /// signature flag: the one door to a verdict stays shut.
    static func verdictTypeFailures(_ sources: Sources) -> [String] {
        var failures: [String] = []
        for (name, text) in sources where !wireFiles.contains(name) {
            let spelled = ApprovalChannelStructureTests.constructionSpelling(text)
            if spelled.contains("ApprovalDecision(") {
                failures.append("\(name) builds an ApprovalDecision — no decision is a verdict before CL-1")
            }
            if text.contains("signatureVerified") {
                failures.append("\(name) names signatureVerified — no decision is a verdict before CL-1")
            }
        }
        return failures
    }

    /// NapCatWire declares the S0 type; it is the only place that may.
    static var wireFiles: [String] { WireContractTests.constantsFiles + WireContractTests.pureFiles }

    @Test func noMacSourceBuildsAVerdict() throws {
        let sources = try ApprovalChannelStructureTests.sources()
        #expect(Self.verdictTypeFailures(sources).isEmpty, "\(Self.verdictTypeFailures(sources))")
        #expect(Self.text("ApprovalStateMachine.swift", in: sources).contains("signatureVerified"),
                "vacuity: the S0 type is where the lock looks for it")
        let mutants: [(String, Sources)] = [
            ("the intake builds one", Self.mutate(sources, ApprovalChannelStructureTests.intakeFile) {
                $0 + "\nlet d = ApprovalDecision(promptID: p, verdict: .allow, wireVersion: 1, signatureVerified: true)" }),
            ("the init spelling", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nlet d = ApprovalDecision.init(promptID: p, verdict: .deny, wireVersion: 1, signatureVerified: true)" }),
            ("the flag named", Self.mutate(sources, ApprovalChannelStructureTests.hostFile) {
                $0 + "\nlet v = decision.signatureVerified" }),
        ]
        for (name, mutant) in mutants {
            #expect(!Self.verdictTypeFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: - 4. The record path cannot reach iCloud by itself

    /// The record path builds records and operations, and hands an
    /// operation to its database seam. It never holds a container or a
    /// database, checks an account, queries, subscribes, or adds an
    /// operation to a database itself.
    static let iCloudTokens = ["CKContainer", "CKDatabase", "privateCloudDatabase", "publicCloudDatabase",
                               "sharedCloudDatabase", "accountStatus", "CKFetch", "CKQuery", "CKSubscription",
                               "CKSyncEngine", "SecTask", ".add(", "URLSession"]

    static let seamConformance =
        #"\b(class|struct|actor|enum|extension)\b[^{\n]*:[^{\n]*\bApprovalRecordDatabase\b"#

    static func iCloudFailures(_ sources: Sources) -> [String] {
        var failures: [String] = []
        let file = text(recordPathFile, in: sources)
        for token in iCloudTokens where file.contains(token) {
            failures.append("'\(token)' in \(recordPathFile) — the record path cannot reach iCloud by itself")
        }
        for (name, text) in sources where text.range(of: seamConformance, options: .regularExpression) != nil {
            failures.append("\(name) conforms to ApprovalRecordDatabase — in this slice only test fakes may")
        }
        return failures
    }

    @Test func theRecordPathCannotReachICloudByItself() throws {
        let withFile = try ApprovalChannelStructureTests.sources()
        #expect(Self.vacuityFailures(withFile).isEmpty, "\(Self.vacuityFailures(withFile))")
        #expect(Self.iCloudFailures(withFile).isEmpty, "\(Self.iCloudFailures(withFile))")
        #expect(Self.text(Self.recordPathFile, in: withFile).contains("func submit(_ operation: CKModifyRecordsOperation)"),
                "vacuity: the seam the lock looks at")
        let mutants: [(String, Sources)] = [
            ("a container", Self.mutate(withFile, Self.recordPathFile) {
                $0 + "\nlet c = CKContainer(identifier: ApprovalWire.containerIdentifier)" }),
            ("a database", Self.mutate(withFile, Self.recordPathFile) { $0 + "\nlet d: CKDatabase? = nil" }),
            ("an operation added directly", Self.mutate(withFile, Self.recordPathFile) { $0 + "\nfunc f() { d.add(o) }" }),
            ("a live seam in the record path", Self.mutate(withFile, Self.recordPathFile) {
                $0 + "\nfinal class LiveApprovalRecords: ApprovalRecordDatabase { func submit(_ o: Op) {} }" }),
            ("a live seam elsewhere", Self.mutate(withFile, "CloudKitMessageSender.swift") {
                $0 + "\nextension LiveCloudKitAlertStore: ApprovalRecordDatabase {}" }),
        ]
        for (name, mutant) in mutants {
            #expect(!Self.iCloudFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: - 6. The prompt record is written only through the wire

    /// As the alert lane's record (PhoneTransportSchemaTests): ONE record
    /// construction, every key an `ApprovalWire` field (no literal key, no
    /// bulk setter, no asset or reference), and the encrypted-or-clear choice
    /// read from the wire's own table.
    static func schemaFailures(_ file: String) -> [String] {
        var failures: [String] = []
        if ApprovalChannelStructureTests.count("CKRecord(recordType:", in: file) != 1 {
            failures.append("a prompt record must be constructed in exactly one place (makePromptRecord)")
        }
        for token in ["setValuesForKeys", "setObject(", "setValue(", "CKAsset", "CKRecord.Reference"] where file.contains(token) {
            failures.append("'\(token)' — record fields are written only through the ApprovalWire field keys")
        }
        // A string literal as a key, on any receiver (`r["note"] = …`).
        if file.range(of: #"\[\s*"[^"]*"\s*\]\s*="#, options: .regularExpression) != nil {
            failures.append("a literal key — record fields are written only through the ApprovalWire field keys")
        }
        let shape = "for field in ApprovalWire.PromptField.allCases { let value = promptValue(field, of: prompt) "
            + "if ApprovalWire.encryptedPromptFields.contains(field) { record.encryptedValues[field.rawValue] = value } "
            + "else { record[field.rawValue] = value } }"
        if !MenuPanelStructureTests.flat(file).contains(shape) {
            failures.append("the prompt record's fields must be every wire field, encrypted as the wire's table says")
        }
        return failures
    }

    @Test func thePromptRecordIsWrittenOnlyThroughTheWire() throws {
        let file = Self.text(Self.recordPathFile, in: try ApprovalChannelStructureTests.sources())
        #expect(Self.schemaFailures(file).isEmpty, "\(Self.schemaFailures(file))")
        let anchor = "            } else {\n                record[field.rawValue] = value\n            }"
        #expect(file.contains(anchor), "vacuity: the clear-field write is the anchor")
        let mutants: [(String, String)] = [
            ("a literal key", file.replacingOccurrences(of: anchor, with: anchor + "\n            record[\"sessionId\"] = \"x\" as NSString")),
            ("an encrypted side channel", file.replacingOccurrences(of: anchor, with: anchor + "\n            record.encryptedValues[\"cwd\"] = v")),
            ("everything in the clear", file.replacingOccurrences(of: "if ApprovalWire.encryptedPromptFields.contains(field) {",
                                                                  with: "if false {")),
            ("a second record", file + "\nlet r = CKRecord(recordType: \"PromptRequest\", recordID: i)"),
            ("a bulk setter", file + "\nfunc f(r: CKRecord) { r.setValuesForKeys([:]) }"),
            ("a literal key on another receiver", file + "\nfunc f(r: CKRecord) { r[\"note\"] = \"x\" as NSString }"),
        ]
        for (name, mutant) in mutants {
            #expect(mutant != file, "canary '\(name)' did not apply")
            #expect(!Self.schemaFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: - 5. The S3 tests touch nothing live

    /// The S3 Mac test files that run anything (this file only reads sources).
    static let s3TestFiles = ["ApprovalRecordFakes.swift", "ApprovalRecordWriterTests.swift", "DecisionRecordReaderTests.swift"]

    /// S2's list (defaults, keychain, the real home, processes, the probe,
    /// the toggle's production factory), plus CloudKit's live doors.
    static let liveTokens = RemoteApprovalsStructureTests.liveTokens
        + ["CKContainer", "privateCloudDatabase", "makeLiveStore", "CloudKitEntitlementProbe", "accountStatus("]

    static func liveFailures(_ tests: Sources) -> [String] {
        tests.flatMap { name, text in
            liveTokens.filter { text.contains($0) }.map { "'\($0)' in \(name) — S3 tests touch nothing live" }
        }
    }

    @Test func theS3TestsTouchNothingLive() throws {
        let directory = LidGuardStructureTests.repoRoot().appendingPathComponent("Tests/NapCatTests")
        let tests: Sources = try Self.s3TestFiles.map {
            ($0, LidGuardStructureTests.codeOnly(try String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8)))
        }
        #expect(tests.allSatisfy { !$0.text.isEmpty }, "vacuity: every listed file was read")
        #expect(Self.liveFailures(tests).isEmpty, "\(Self.liveFailures(tests))")
        for planted in ["let c = CKContainer(identifier: i)", "let d = UserDefaults.standard",
                        "let s = CloudKitMessageSender.makeLiveStore()", "let k = KeychainTopicStore." + "login" + "Keychain",
                        "let db = container.privateCloudDatabase"] {
            let mutant = tests.map { ($0.name, $0.text + "\n" + planted) }
            #expect(!Self.liveFailures(mutant).isEmpty, "canary '\(planted)' was NOT caught")
        }
    }
}
