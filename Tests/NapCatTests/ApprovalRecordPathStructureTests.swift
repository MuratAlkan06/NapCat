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
///    path, so no production code reaches it at all. AMENDED (deliberate,
///    #146, once S-GATE merged): the record path now holds the intake's
///    record store, so it names the intake's record-sink protocol exactly
///    once — that store's own conformance, which carries the gate's forward
///    answer in and nothing back out; the store is a record-path type, so
///    the app still builds none of it;
/// 2. the approval files hold exactly one `armed` literal, `{ false }`, in
///    the fail-dark factory;
/// 3. no Mac source builds the S0 decision type or names its signature flag
///    — nor reaches its constructor unnamed: an unapplied `.init`, the
///    metatype or an alias (security review 2, G4), or an extension of the
///    type (the security re-check, N3);
/// 4. the record path cannot reach iCloud by itself: no container, no
///    database, no account check, no CloudKit identifier off its allow-list,
///    no way to run an operation but the database seam (security review 2,
///    G1), no other file in the four targets importing CloudKit in any form
///    (G2), and nothing in the app conforms to its database seam;
/// 5. the S3 test files touch nothing live;
/// 6. the prompt record is written only through the wire;
/// 7. (#146) the record store writes the gate's forward answer exactly as
///    the intake hands it, through the one conformer of the gate's answer,
///    and a decision read for a prompt only joins its retraction;
/// 8. (#153) the record path builds one record and one operation, however
///    the construction is spelled, and every operation it builds is the
///    argument of the seam's `submit`, at a set count of call sites — so no
///    banned word has to be named for a bypass to fail.
///
/// Since #153 the constructor bans (locks 3, 7 and 8) read the cleaned
/// copies too (`LidGuardStructureTests.constructorScanCopies`: backticks
/// removed, block comments replaced by a space), in addition to the raw
/// text — never instead of it.
///
/// Each lock is a pure function over comment-stripped sources and each
/// catches planted canaries, so none can pass vacuously. Locks 3 and 4 scan
/// `uncutSources` (whole-line comments removed only) and strip trailing
/// comments themselves where they always did; since #155 neither form lets
/// a `//` inside a string literal hide a token.
struct ApprovalRecordPathStructureTests {
    typealias Sources = ApprovalChannelStructureTests.Sources

    /// The record path's one Mac file (Sources/NapCat).
    static let recordPathFile = "CloudKitApprovalRecords.swift"

    /// The four targets' sources with WHOLE-LINE comments removed only
    /// (`LidGuardStructureTests.wholeLineCommentsRemoved`): trailing comments
    /// stay in, so this form can only over-match. (Before #155, `codeOnly`
    /// cut a line at a `//` inside a string literal, security review L3; it
    /// no longer does.)
    static func uncutSources() throws -> Sources {
        try ApprovalChannelStructureTests.sources(LidGuardStructureTests.wholeLineCommentsRemoved)
    }

    /// Every match of `pattern` in `text`, as written.
    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return ["<bad pattern \(pattern)>"] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    /// The record path's own types. Outside its file, nothing names them —
    /// the record store included (#146), so the app's host cannot be handed
    /// it in this slice.
    static let recordPathTypes = ["ApprovalRecordWriter", "DecisionRecordReader", "GateApprovedPrompt",
                                  "ApprovalRecordDatabase", "DecisionRecordReading", "CloudKitApprovalRecords"]

    /// The verdict API and everything that leads to it: the seam and its
    /// host, the intake and the lifecycle it drives, the channel's verdict
    /// wire, the category gate, the S0 decision type and its signature flag,
    /// the toggle, and the armed flag. (AMENDED, #146: the intake's
    /// record-sink protocol left this list for `recordStoreConformance`.)
    static let verdictAPITokens = ["ApprovalChannel", "verdictFrame", "verdictNotification", "sendFrame",
                                   "ApprovalIntake", "ApprovalSeamHost", "ApprovalLifecycle", "ApprovalEvent",
                                   "remoteDecision", "deliverVerdict", "decide(", "ApprovalDecision",
                                   "signatureVerified", "ApprovalGate", "classify(",
                                   "RemoteApprovalsController", "Seam", "armed"]

    /// The ONE place the record path names the intake's record-sink protocol
    /// (#146): the record store's own conformance. The protocol carries the
    /// gate's forward answer and the withdrawals in, and nothing back out.
    static let recordStoreConformance = "final class CloudKitApprovalRecords: ApprovalRecordSink {"

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
        let file = text(recordPathFile, in: sources)
        if ApprovalChannelStructureTests.count("ApprovalRecordSink", in: file) != 1 || !file.contains(recordStoreConformance) {
            failures.append("the record path names the intake's record sink only as the record store's own conformance")
        }
        return failures
    }

    /// Vacuity: the record path is where the locks look for it.
    static func vacuityFailures(_ sources: Sources) -> [String] {
        let file = text(recordPathFile, in: sources)
        return ["final class ApprovalRecordWriter", "enum DecisionRecordReader", "protocol GateApprovedPrompt",
                "protocol ApprovalRecordDatabase", recordStoreConformance].filter { !file.contains($0) }
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
            // #146: the record store, wired behind the intake.
            ("the record store hands a claim to the intake", Self.mutate(withFile, Self.recordPathFile) {
                $0 + "\nextension CloudKitApprovalRecords { func f(i: ApprovalIntake, c: DecisionClaim) { i.decide(c) } }" }),
            ("the record store answers the dialog", Self.mutate(withFile, Self.recordPathFile) {
                $0 + "\nextension CloudKitApprovalRecords { func f(i: Int, r: ChannelRequestID) { "
                    + "sendFrame(i, ApprovalChannel.verdictFrame(r, .allow)) } }" }),
            ("the record store takes its own copy", Self.mutate(withFile, Self.recordPathFile) {
                $0 + "\nlet c = ApprovalGate.forwardedPreview(toolName: t, inputPreview: p)" }),
            ("a second record sink in the record path", Self.mutate(withFile, Self.recordPathFile) {
                $0 + "\nextension ApprovalRecordWriter: ApprovalRecordSink {}" }),
            ("the record store's conformance dropped", Self.mutate(withFile, Self.recordPathFile) {
                $0.replacingOccurrences(of: Self.recordStoreConformance, with: "final class CloudKitApprovalRecords {") }),
            ("the toggle's host handed the record store", Self.mutate(withFile, ApprovalChannelStructureTests.toggleFile) {
                $0.replacingOccurrences(of: "records: FailDarkApprovalRecords()",
                                        with: "records: CloudKitApprovalRecords(writer: w)") }),
            ("the host builds the record store", Self.mutate(withFile, ApprovalChannelStructureTests.hostFile) {
                $0 + "\nlet r = CloudKitApprovalRecords(writer: w)" }),
        ]
        for (name, mutant) in mutants {
            #expect(!Self.verdictReachFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // The toggle canary must really apply (its anchor is the S2 factory).
        #expect(Self.text(ApprovalChannelStructureTests.toggleFile, in: withFile).contains("records: FailDarkApprovalRecords()"),
                "vacuity: the fail-dark sink is the toggle's host's record store")
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
    ///
    /// AMENDED after security review 2 (#146, G4): `let make =
    /// ApprovalDecision.init` then `make(…, true)` names neither, so the
    /// constructor reached unnamed is banned too — an unapplied `.init`, the
    /// metatype (`ApprovalDecision.self`, the road to a generic `T.init`),
    /// and an alias of the type (`= ApprovalDecision`, then `Alias.init`).
    ///
    /// AMENDED after the security re-check (#146, N3): an extension of the
    /// type reaches the constructor as `Self.init` or a bare `.init`, naming
    /// neither, so no extension of it is allowed outside NapCatWire.
    static let indirectConstruction =
        #"\bApprovalDecision\s*\.\s*(?:init|self)\b|=\s*(?:NapCatWire\s*\.\s*)?ApprovalDecision\b"#
            + #"|\bextension\s+(?:NapCatWire\s*\.\s*)?ApprovalDecision\b"#

    /// AMENDED after the security delta check (#153, B1/B2): `` extension
    /// `ApprovalDecision` `` and `extension /* … */ ApprovalDecision` named
    /// the type in a form no pattern read, so every check also reads the
    /// cleaned copies of the file (`constructorScanCopies`) — in addition to
    /// the raw text, never instead of it.
    ///
    /// `sources`: `uncutSources()`. The original two checks read the
    /// comment-stripped code, as they always did.
    static func verdictTypeFailures(_ sources: Sources) -> [String] {
        var failures: [String] = []
        for (name, uncut) in sources where !wireFiles.contains(name) {
            let copies = LidGuardStructureTests.constructorScanCopies(uncut)
            let code = copies.map(LidGuardStructureTests.codeOnly)
            if code.contains(where: { ApprovalChannelStructureTests.constructionSpelling($0).contains("ApprovalDecision(") }) {
                failures.append("\(name) builds an ApprovalDecision — no decision is a verdict before CL-1")
            }
            if code.contains(where: { $0.contains("signatureVerified") }) {
                failures.append("\(name) names signatureVerified — no decision is a verdict before CL-1")
            }
            if copies.contains(where: { $0.range(of: indirectConstruction, options: .regularExpression) != nil }) {
                failures.append("\(name) reaches ApprovalDecision's constructor unnamed — no decision is a verdict before CL-1")
            }
        }
        return failures
    }

    /// NapCatWire declares the S0 type; it is the only place that may.
    static var wireFiles: [String] { WireContractTests.constantsFiles + WireContractTests.pureFiles }

    @Test func noMacSourceBuildsAVerdict() throws {
        let sources = try Self.uncutSources()
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
            // #155: built behind a URL, where only the comment-stripped checks see it.
            ("a verdict built behind a URL", Self.mutate(sources, ApprovalChannelStructureTests.hostFile) {
                $0 + "\nfunc f(i: ApprovalIntake) { let u = \"https://x\"; "
                    + "i.decide(ApprovalDecision(promptID: p, verdict: .allow, wireVersion: 1, signatureVerified: true)) }" }),
            // #146: a claim the record store reads is never promoted to one.
            ("the record store promotes a claim", Self.mutate(sources, Self.recordPathFile) {
                $0 + "\nextension CloudKitApprovalRecords { func f(c: DecisionClaim) -> ApprovalDecision { "
                    + "ApprovalDecision(promptID: c.promptID, verdict: c.claimedVerdict, wireVersion: 1, signatureVerified: true) } }" }),
        ]
        for (name, mutant) in mutants {
            #expect(!Self.verdictTypeFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    /// Security review 2 (#146), G4 and its siblings: the constructor reached
    /// without naming it or the flag.
    @Test func noMacSourceReachesTheVerdictConstructorUnnamed() throws {
        let sources = try Self.uncutSources()
        #expect(Self.text(ApprovalChannelStructureTests.intakeFile, in: sources).contains("func decide(_ decision: ApprovalDecision)"),
                "vacuity: the one place outside the wire that names the type, as a parameter")
        let mutants: [(String, Sources)] = [
            ("an unapplied init (G4)", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nfunc f(i: ApprovalIntake, p: PromptID) {\n    let make = ApprovalDecision.init\n"
                    + "    i.decide(make(p, .allow, 1, true))\n}" }),
            ("a module-qualified unapplied init", Self.mutate(sources, ApprovalChannelStructureTests.hostFile) {
                $0 + "\nlet make = NapCatWire.ApprovalDecision . init" }),
            ("the metatype", Self.mutate(sources, ApprovalChannelStructureTests.toggleFile) {
                $0 + "\nlet type = ApprovalDecision.self" }),
            ("an alias", Self.mutate(sources, ApprovalChannelStructureTests.intakeFile) {
                $0 + "\ntypealias Claimed = ApprovalDecision\nlet make = Claimed.init" }),
            ("an unapplied init behind a URL", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nfunc f() { let u = \"https://www.icloud.com\"; let make = ApprovalDecision.init; _ = (u, make) }" }),
            // The security re-check (#146), N3: the constructor reached from an extension.
            ("an extension's Self.init (N3)", Self.mutate(sources, ApprovalChannelStructureTests.intakeFile) {
                $0 + "\nextension ApprovalDecision {\n    static let claimed = Self.init\n}\n\n"
                    + "func n3(i: ApprovalIntake, p: PromptID) {\n    i.decide(ApprovalDecision.claimed(p, .allow, 1, true))\n}" }),
            ("a module-qualified extension", Self.mutate(sources, ApprovalChannelStructureTests.hostFile) {
                $0 + "\nextension NapCatWire . ApprovalDecision {\n    static var claimed: Any { Self.init }\n}" }),
            // The security delta check (#153): B1 and B2, as planted, then together.
            ("B1: an extension behind backticks", Self.mutate(sources, ApprovalChannelStructureTests.intakeFile) {
                $0 + "\nextension `ApprovalDecision` {\n    static let claimedB1 = Self.init\n}\n\n"
                    + "func b1(i: ApprovalIntake, p: PromptID) {\n    i.decide(ApprovalDecision.claimedB1(p, .allow, 1, true))\n}" }),
            ("B2: an extension behind a block comment", Self.mutate(sources, ApprovalChannelStructureTests.intakeFile) {
                $0 + "\nextension /* b2 */ ApprovalDecision {\n    static let claimedB2 = Self.init\n}\n\n"
                    + "func b2(i: ApprovalIntake, p: PromptID) {\n    i.decide(ApprovalDecision.claimedB2(p, .allow, 1, true))\n}" }),
            ("B1 and B2 together", Self.mutate(sources, ApprovalChannelStructureTests.intakeFile) {
                $0 + "\nextension `ApprovalDecision` {\n    static let claimedB1 = Self.init\n}\n\n"
                    + "extension /* b2 */ ApprovalDecision {\n    static let claimedB2 = Self.init\n}\n\n"
                    + "func b12(i: ApprovalIntake, p: PromptID) {\n    i.decide(ApprovalDecision.claimedB1(p, .allow, 1, true))\n"
                    + "    i.decide(ApprovalDecision.claimedB2(p, .allow, 1, true))\n}" }),
            ("a backticked unapplied init", Self.mutate(sources, "NapCatApp.swift") { $0 + "\nlet make = `ApprovalDecision`.init" }),
            ("a backticked metatype", Self.mutate(sources, ApprovalChannelStructureTests.toggleFile) {
                $0 + "\nlet type = `ApprovalDecision`.self" }),
            ("an alias behind a block comment", Self.mutate(sources, ApprovalChannelStructureTests.hostFile) {
                $0 + "\ntypealias Claimed = /* x */ ApprovalDecision\nlet make = Claimed.init" }),
            ("a string-held block-comment opener around a commented extension",
             Self.mutate(sources, ApprovalChannelStructureTests.intakeFile) {
                $0 + "\nlet a = \"/*\"\nextension /* x */ ApprovalDecision {\n    static let c = Self.init\n}\nlet b = \"*/\"" }),
            ("a bare regex before a commented extension", Self.mutate(sources, ApprovalChannelStructureTests.intakeFile) {
                $0 + "\nlet r = /\"/; let a = \"/*\"; extension /* x */ ApprovalDecision { static let c = Self.init }; let b = \"*/\"" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.verdictTypeFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match control: the intake's own parameter, an extension of a
        // type whose name only starts with the S0 type's, and the doc comment
        // that names what it rules out, pass.
        #expect(Self.verdictTypeFailures(Self.mutate(sources, "NapCatApp.swift") {
            $0 + "\nfunc f(_ d: ApprovalDecision?, _ all: [ApprovalDecision]) {}\nextension ApprovalDecisionLog {}"
                + LidGuardStructureTests.wholeLineCommentsRemoved(
                    "\n/// never ApprovalDecision.init, never = ApprovalDecision, never extension ApprovalDecision")
        }).isEmpty)
        // The construction check reads the cleaned copies too (#153): a
        // construction split by a block comment is a construction.
        let split = Self.mutate(sources, "NapCatApp.swift") {
            $0 + "\nfunc f(i: ApprovalIntake) { i.decide(ApprovalDecision/* x */(promptID: p, verdict: .allow, "
                + "wireVersion: 1, signatureVerified: true)) }"
        }
        #expect(Self.verdictTypeFailures(split).contains { $0.contains("builds an ApprovalDecision") },
                "canary 'a construction split by a block comment' was NOT caught by the construction check")
        // … and through the cleaned copies (#153): a backticked parameter
        // type, a backticked keyword, and a string holding a block comment.
        #expect(Self.verdictTypeFailures(Self.mutate(sources, "NapCatApp.swift") {
            $0 + "\nfunc f(_ d: `ApprovalDecision`?) { let `default` = 1; _ = `default` }"
                + "\nlet note = \"/* ApprovalDecision */\""
        }).isEmpty)
    }

    // MARK: - 4. The record path cannot reach iCloud by itself

    /// The record path builds records and operations, and hands an
    /// operation to its database seam. It never holds a container or a
    /// database, checks an account, queries, subscribes, or adds an
    /// operation to a database itself.
    static let iCloudTokens = ["CKContainer", "CKDatabase", "privateCloudDatabase", "publicCloudDatabase",
                               "sharedCloudDatabase", "accountStatus", "CKFetch", "CKQuery", "CKSubscription",
                               "CKSyncEngine", "SecTask", ".add(", "URLSession"]

    /// AMENDED after security review 2 (#146): the record path's CloudKit
    /// identifiers are an ALLOW-LIST, exactly the ones it uses, matched as
    /// whole words (`CKRecord` does not cover `CKRecordZone`), so any other
    /// door (`CKFetchRecordsOperation`, `CKModifyRecordZonesOperation`, …)
    /// fails by default instead of waiting for its own ban.
    static let recordPathCloudKitIdentifiers: Set<String> = [
        "CKRecord", "CKRecordZone", "CKRecordValue", "CKCurrentUserDefaultName",
        "CKModifyRecordsOperation", "CKOperation", "CKError", "CKErrorDomain",
    ]

    /// Every way to RUN an operation but the seam (security review 2, G1).
    /// The allow-list cannot stop this: a CKDatabaseOperation run with no
    /// database set targets the user's private database (Apple's
    /// `CKDatabaseOperation.database`), so the allow-listed operation is never
    /// started or run by hand, queued, added to a database, pointed at a
    /// database or a container (the writer's own `self.database` is the
    /// seam), or messaged dynamically. Whole words, so `startIndex` or
    /// `addingTimeInterval` pass. AMENDED after the security re-check (#146,
    /// N1): `start` and `main` are banned as words, dot or no dot, since an
    /// extension on the operation calls `start()` on its implicit self.
    static let operationRunPatterns = [#"\bstart\b"#, #"\bmain\b"#, #"\bOperationQueue\b"#, #"\baddOperations?\b"#,
                                       #"\.\s*add\b"#, #"(?<!\bself)\.\s*database\b"#, #"\.\s*container\b"#,
                                       #"\bperform\b"#, #"#selector\b"#, #"\bSelector\b"#, #"\bNSSelectorFromString\b"#]

    /// The two Mac files that may import CloudKit (LidGuardStructureTests
    /// owns that table for Sources/NapCat). This lock scans all four targets,
    /// so a re-export from the seam's or the channel's target cannot carry
    /// CloudKit into the app either.
    static let cloudKitFiles: Set<String> = ["CloudKitMessageSender.swift", recordPathFile]

    static let seamConformance =
        #"\b(class|struct|actor|enum|extension)\b[^{\n]*:[^{\n]*\bApprovalRecordDatabase\b"#

    /// `sources`: `uncutSources()`. The original checks read the
    /// comment-stripped code, as they always did; the security-review-2
    /// checks read the uncut text.
    static func iCloudFailures(_ sources: Sources) -> [String] {
        var failures: [String] = []
        let uncut = text(recordPathFile, in: sources)
        let file = LidGuardStructureTests.codeOnly(uncut)
        for token in iCloudTokens where file.contains(token) {
            failures.append("'\(token)' in \(recordPathFile) — the record path cannot reach iCloud by itself")
        }
        for (name, text) in sources
        where LidGuardStructureTests.codeOnly(text).range(of: seamConformance, options: .regularExpression) != nil {
            failures.append("\(name) conforms to ApprovalRecordDatabase — in this slice only test fakes may")
        }
        let named = Set(matches(#"\bCK\w*"#, in: uncut))
        for identifier in named.subtracting(recordPathCloudKitIdentifiers).sorted() {
            failures.append("'\(identifier)' in \(recordPathFile) — not on the record path's CloudKit allow-list")
        }
        for identifier in recordPathCloudKitIdentifiers.subtracting(named).sorted() {
            failures.append("'\(identifier)' is allow-listed but unused in \(recordPathFile) — the list stays exact")
        }
        for pattern in operationRunPatterns where uncut.range(of: pattern, options: .regularExpression) != nil {
            failures.append("'\(pattern)' in \(recordPathFile) — only the database seam runs an operation")
        }
        for (name, text) in sources where !cloudKitFiles.contains(name)
            && text.range(of: LidGuardStructureTests.cloudKitImport, options: .regularExpression) != nil {
            failures.append("\(name) imports CloudKit — only \(cloudKitFiles.sorted()) may, in any of the four targets")
        }
        return failures
    }

    @Test func theRecordPathCannotReachICloudByItself() throws {
        let withFile = try Self.uncutSources()
        #expect(Self.vacuityFailures(withFile).isEmpty, "\(Self.vacuityFailures(withFile))")
        #expect(Self.iCloudFailures(withFile).isEmpty, "\(Self.iCloudFailures(withFile))")
        #expect(Self.text(Self.recordPathFile, in: withFile).contains("func submit(_ operation: CKModifyRecordsOperation)"),
                "vacuity: the seam the lock looks at")
        let record = Self.recordPathFile
        let mutants: [(String, Sources)] = [
            ("a container", Self.mutate(withFile, record) {
                $0 + "\nlet c = CKContainer(identifier: ApprovalWire.containerIdentifier)" }),
            ("a database", Self.mutate(withFile, record) { $0 + "\nlet d: CKDatabase? = nil" }),
            ("an operation added directly", Self.mutate(withFile, record) { $0 + "\nfunc f() { d.add(o) }" }),
            ("a live seam in the record path", Self.mutate(withFile, record) {
                $0 + "\nfinal class LiveApprovalRecords: ApprovalRecordDatabase { func submit(_ o: Op) {} }" }),
            ("a live seam elsewhere", Self.mutate(withFile, "CloudKitMessageSender.swift") {
                $0 + "\nextension LiveCloudKitAlertStore: ApprovalRecordDatabase {}" }),
        ]
        for (name, mutant) in mutants {
            #expect(!Self.iCloudFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    /// Security review 2 (#146): G1 (an allow-listed operation run without
    /// the seam), a CloudKit door off the allow-list, and G2 (CloudKit
    /// imported by a third file, or re-exported by another target).
    @Test func nothingRunsARecordOperationButTheSeam() throws {
        let withFile = try Self.uncutSources()
        #expect(Self.text(Self.recordPathFile, in: withFile).contains("        self.database = database\n"),
                "vacuity: the writer's own seam is the one `.database` the lock lets through")
        #expect(ApprovalChannelStructureTests.directories.count == 4 && withFile.contains { $0.name == "SeamSocket.swift" },
                "vacuity: the import scan sees the seam's target")
        let record = Self.recordPathFile
        let mutants: [(String, Sources)] = [
            ("the operation started (G1)", Self.mutate(withFile, record) {
                $0 + "\nextension ApprovalRecordWriter {\n    static func go(_ r: CKRecord) {\n"
                    + "        makeOperation(saving: [r], deleting: []) { _ in }.start()\n    }\n}" }),
            ("the operation queued (G1)", Self.mutate(withFile, record) {
                $0 + "\nfunc f(o: CKModifyRecordsOperation) { OperationQueue().addOperation(o) }" }),
            ("a queue reached without its name", Self.mutate(withFile, record) {
                $0 + "\nfunc f(q: Q, o: CKOperation) { q.addOperations([o], waitUntilFinished: false) }" }),
            ("the operation run by hand", Self.mutate(withFile, record) { $0 + "\nfunc f(o: CKOperation) { o . main() }" }),
            ("an unapplied start", Self.mutate(withFile, record) { $0 + "\nfunc f(o: CKOperation) { let run = o.start; run() }" }),
            ("a start behind a URL", Self.mutate(withFile, record) {
                $0 + "\nfunc f(o: CKOperation) { let u = \"https://www.icloud.com\"; o.start(); _ = u }" }),
            ("the operation pointed at a database", Self.mutate(withFile, record) {
                $0 + "\nfunc f(o: CKModifyRecordsOperation, d: Db) { o.database = d }" }),
            ("the configuration handed a container", Self.mutate(withFile, record) {
                $0 + "\nfunc f(c: CKOperation.Configuration) { c.container = .default() }" }),
            ("the operation messaged dynamically", Self.mutate(withFile, record) {
                $0 + "\nfunc f(o: CKOperation) { o.perform(NSSelectorFromString(\"start\")) }" }),
            // The security re-check (#146), N1: started on the operation's implicit self.
            ("the operation started on its implicit self (N1)", Self.mutate(withFile, record) {
                $0 + "\nextension CKModifyRecordsOperation {\n    func go() { start() }\n}\n\n"
                    + "extension ApprovalRecordWriter {\n    static func n1(_ r: CKRecord) {\n"
                    + "        makeOperation(saving: [r], deleting: []) { _ in }.go()\n    }\n}" }),
            ("the operation run by hand on its implicit self", Self.mutate(withFile, record) {
                $0 + "\nextension CKOperation {\n    func go() { main() }\n}" }),
            // … and a CloudKit door off the allow-list.
            ("a zone operation", Self.mutate(withFile, record) {
                $0 + "\nlet z = CKModifyRecordZonesOperation(recordZonesToSave: [], recordZoneIDsToDelete: nil)" }),
            ("a fetch operation", Self.mutate(withFile, record) { $0 + "\nlet f = CKFetchRecordsOperation(recordIDs: [])" }),
            ("a share", Self.mutate(withFile, record) { $0 + "\nlet s: CKShare? = nil" }),
            ("an allow-listed identifier dropped", Self.mutate(withFile, record) {
                $0.replacingOccurrences(of: "ownerName: CKCurrentUserDefaultName", with: "ownerName: \"__defaultOwner__\"") }),
            // G2: CloudKit imported by a third file, or re-exported by another target.
            ("a third CloudKit file, scoped import (G2)", withFile + [("ZZFetchRecords.swift",
                "import class CloudKit.CKFetchRecordsOperation\nfunc f() { CKFetchRecordsOperation(recordIDs: []).start() }")]),
            ("CloudKit re-exported by the seam's target", Self.mutate(withFile, "SeamSocket.swift") {
                "@_exported import CloudKit\n" + $0 }),
            // The security re-check (#146), N2: a trailing comment inside the import.
            ("a third CloudKit file, trailing-comment import (N2)", withFile + [("ZZN2Fetch.swift",
                "import // fetch only\n    CloudKit\nfunc n2() { CKFetchRecordsOperation(recordIDs: []).start() }")]),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != withFile.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.iCloudFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Each run pattern compiles and bites on its own (one that did not
        // compile would match nothing, silently).
        let probes = ["o.start()", "o.main()", "OperationQueue.current", "q.addOperation(o)", "db.add(o)", "o.database = d",
                      "c.container = k", "o.perform(s)", "#selector(Operation.start)", "Selector((\"start\"))",
                      "NSSelectorFromString(\"start\")"]
        #expect(probes.count == Self.operationRunPatterns.count)
        for (pattern, probe) in zip(Self.operationRunPatterns, probes) {
            #expect(probe.range(of: pattern, options: .regularExpression) != nil, "'\(pattern)' does not match '\(probe)'")
        }
        // Over-match controls: whole words only (`startIndex`, `addingTimeInterval`,
        // `CKRecord.ID`), and a whole-line comment naming what it rules out.
        #expect(Self.iCloudFailures(Self.mutate(withFile, record) {
            $0 + "\nfunc f(s: String, d: Date, r: CKRecord.ID) -> Bool { s.startIndex == s.endIndex && d.addingTimeInterval(1) > d }"
                + LidGuardStructureTests.wholeLineCommentsRemoved("\n    // never .start() it, never OperationQueue, never import class CloudKit.CKShare")
        }).isEmpty)
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

    // MARK: - 7. The record store writes the gate's answer as it is handed (#146)

    /// The record store is the one road from the gate to the writer (the
    /// behaviour is ApprovalRecordRoutingTests'; this pins what examples
    /// cannot): `GateApprovedPrompt` has ONE conformer anywhere, private to
    /// the record path, built once — in the store's `save`, from exactly the
    /// tool and the copy the intake handed it, never trimmed, relabelled or
    /// re-read — and the writer is reached once to write that prompt and
    /// once to retract it with the decisions read for it. A read claim only
    /// joins its own pending prompt's retraction.
    static let gateAnswerConformance = #"\b(class|struct|actor|enum|extension)\b[^{\n]*:[^{\n]*\bGateApprovedPrompt\b"#

    static func recordStoreFailures(_ sources: Sources) -> [String] {
        var failures: [String] = []
        let conformers = sources.flatMap { name, text in
            text.split(separator: "\n").filter { $0.range(of: gateAnswerConformance, options: .regularExpression) != nil }
                .map { (name, MenuPanelStructureTests.flat($0)) }
        }
        if conformers.count != 1 || conformers.first?.0 != recordPathFile
            || conformers.first?.1 != "private struct ForwardedPrompt: GateApprovedPrompt {" {
            failures.append("the gate's answer has one conformer, private to the record path: \(conformers)")
        }
        let file = text(recordPathFile, in: sources)
        let flat = MenuPanelStructureTests.flat(file)
        if ApprovalChannelStructureTests.count("ForwardedPrompt(", in: ApprovalChannelStructureTests.constructionSpelling(file)) != 1
            || !flat.contains("let prompt = ForwardedPrompt(promptID: id, toolName: tool.rawValue, inputPreview: inputPreview, "
                              + "createdAt: createdAt, ") {
            failures.append("the gate's answer is built once, in the store's save, from the tool and the copy it was handed")
        }
        if ApprovalChannelStructureTests.count("writer.write(", in: file) != 1 || !flat.contains("writer.write(prompt) { _ in }") {
            failures.append("the store writes exactly the prompt it built, once")
        }
        if ApprovalChannelStructureTests.count("writer.retract(", in: file) != 1
            || !flat.contains("let decisions = pending.removeValue(forKey: id) ?? [] "
                              + "writer.retract(id, decisions: decisions.sorted()) { _ in }") {
            failures.append("the store retracts a prompt once, with the decisions read for it")
        }
        if !flat.contains("func noteRead(_ claim: DecisionClaim) { pending[claim.promptID]?.insert(claim.recordName) }") {
            failures.append("a read claim only joins its own pending prompt's retraction")
        }
        return failures
    }

    /// `recordStoreFailures` over every cleaned copy too (#153): a backticked
    /// or comment-split second construction of the gate's answer.
    static func recordStoreFailuresInEveryCopy(_ sources: Sources) -> [String] {
        unique(LidGuardStructureTests.constructorScanCopies(sources).flatMap(recordStoreFailures))
    }

    /// `failures` without repeats, in order.
    static func unique(_ failures: [String]) -> [String] {
        var seen = Set<String>()
        return failures.filter { seen.insert($0).inserted }
    }

    @Test func theRecordStoreWritesTheGatesAnswerAsItIsHanded() throws {
        let sources = try ApprovalChannelStructureTests.sources()
        #expect(Self.recordStoreFailuresInEveryCopy(sources).isEmpty, "\(Self.recordStoreFailuresInEveryCopy(sources))")
        let file = Self.recordPathFile
        let mutants: [(String, Sources)] = [
            ("a second conformer", Self.mutate(sources, file) { $0 + "\nextension DecisionClaim: GateApprovedPrompt {}" }),
            ("a conformer in the app", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nstruct Relayed: GateApprovedPrompt { let inputPreview: String }" }),
            ("the conformer made visible", Self.mutate(sources, file) {
                $0.replacingOccurrences(of: "private struct ForwardedPrompt", with: "struct ForwardedPrompt") }),
            ("the store trims the copy", Self.mutate(sources, file) {
                $0.replacingOccurrences(of: "inputPreview: inputPreview, createdAt",
                                        with: "inputPreview: String(inputPreview.prefix(64)), createdAt") }),
            ("the store relabels the tool", Self.mutate(sources, file) {
                $0.replacingOccurrences(of: "toolName: tool.rawValue", with: "toolName: \"Bash\"") }),
            ("a second construction", Self.mutate(sources, file) {
                $0 + "\nlet p = ForwardedPrompt.init(promptID: i, toolName: t, inputPreview: raw, createdAt: c, expiresAt: e)" }),
            ("a second write", Self.mutate(sources, file) {
                $0 + "\nextension CloudKitApprovalRecords { func again(p: ForwardedPrompt) { writer.write(p) { _ in } } }" }),
            ("the retraction forgets the decisions read", Self.mutate(sources, file) {
                $0.replacingOccurrences(of: "decisions: decisions.sorted()", with: "decisions: []") }),
            ("a claim kept for a prompt never written", Self.mutate(sources, file) {
                $0.replacingOccurrences(of: "pending[claim.promptID]?.insert(", with: "pending[claim.promptID, default: []].insert(") }),
            // #153: a second construction behind backticks or a block comment.
            ("a backticked second construction", Self.mutate(sources, file) {
                $0 + "\nlet p = `ForwardedPrompt`(promptID: i, toolName: t, inputPreview: raw, createdAt: c, expiresAt: e)" }),
            ("a comment-split second construction", Self.mutate(sources, file) {
                $0 + "\nlet p = ForwardedPrompt/* x */(promptID: i, toolName: t, inputPreview: raw, createdAt: c, expiresAt: e)" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.recordStoreFailuresInEveryCopy(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: - 8. One record, one operation, and every operation goes to the seam (#153)

    /// Whether `pattern` matches in `text`. Every #153 check and its probes
    /// run through this one engine (NSRegularExpression, as `matches`):
    /// String's regex search reads some patterns differently (the security
    /// delta check's CRLF and lookahead probes).
    static func hits(_ pattern: String, in text: String) -> Bool { !matches(pattern, in: text).isEmpty }

    /// Every line holding a match of `pattern`, trimmed, with how many
    /// matches it holds. A site pin compares this to an exact allow-list, so
    /// a new site, a changed one and a vanished one all fail.
    static func siteTally(_ pattern: String, in text: String) -> [String: Int] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return ["<bad pattern \(pattern)>": 1] }
        let lineEnd: (Character) -> Bool = { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
        var tally: [String: Int] = [:]
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else {
                tally["<a match of \(pattern) off the text>", default: 0] += 1
                continue
            }
            let start = text[..<range.lowerBound].lastIndex(where: lineEnd).map { text.index(after: $0) } ?? text.startIndex
            let end = text[range.lowerBound...].firstIndex(where: lineEnd) ?? text.endIndex
            tally[text[start..<end].trimmingCharacters(in: .whitespaces), default: 0] += 1
        }
        return tally
    }

    /// A site pin: `pattern`'s sites in `text` are exactly `allowed`.
    static func siteFailures(_ pattern: String, in text: String, file: String, allowed: [String: Int],
                             rule: String) -> [String] {
        let tally = siteTally(pattern, in: text)
        if tally == allowed { return [] }
        let off = tally.filter { allowed[$0.key] != $0.value }.map { "\($0.value)× \($0.key)" }.sorted()
        let gone = allowed.filter { tally[$0.key] != $0.value }.map(\.key).sorted()
        return ["'\(pattern)' in \(file) — \(rule): off the allow-list \(off); moved or gone \(gone)"]
    }

    /// A construction of `type`, however it is applied: `T(`, `T (`,
    /// `T.init(`, `CloudKit.T(` (`T.ID(` builds another type).
    static func constructionPattern(_ type: String) -> String { #"\b"# + type + #"\s*(?:\.\s*init\b\s*)?\("# }

    /// The constructor of `type` reached with no construction to count (as
    /// lock 3's for the S0 type): an unapplied `.init`, the metatype (the
    /// road to a generic `T.init`), an alias, an extension (its `Self.init`
    /// or bare `.init`), a subclass, or a generic parameter bound to it. A
    /// member type (`T.ID`) is another type.
    static func indirectConstructionPattern(_ type: String) -> String {
        let named = #"(?:CloudKit\s*\.\s*)?"# + type + #"\b(?!\s*\.\s*[A-Z])"#
        return [#"\b"# + type + #"\s*\.\s*(?:init\b(?!\s*\()|self\b|Type\b)"#,
                #"\btypealias\b[^\n]*\b"# + named,
                #"\bextension\s+"# + named,
                #"\b(?:class|actor)\s+(?!func\b|var\b|let\b)\w+[^{\n]*:[^{\n]*\b"# + named,
                #"<[^>\n]*\b\w+\s*:\s*"# + named,
                #"\bwhere\b[^{\n]*\b"# + named].joined(separator: "|")
    }

    /// An implicit `.init(` (`let r: CKRecord = .init(…)`, `[.init(…)]`,
    /// `return .init(…)`): what it builds is not in the text, so the CloudKit
    /// files spell every construction (none uses one today).
    static let implicitInit =
        #"(?<![\w)\]>\s])\s*\.\s*init\b|\b(?:return|in|throw|try|await|else|case|where|is|as|some|any)\s+\.\s*init\b"#

    /// A CloudKit file builds each type in `sites` once, however the
    /// construction is spelled (#153; the security re-check's L6:
    /// `CKRecord.init(` slipped past a count of `CKRecord(recordType:`): in
    /// the raw text the one construction sits on its pinned line; in every
    /// scan copy the type is built once and never reached unnamed; and no
    /// implicit `.init(` appears at all.
    static func constructionFailures(_ text: String, file: String, sites: [String: String]) -> [String] {
        var failures: [String] = []
        let copies = LidGuardStructureTests.constructorScanCopies(text)
        for (type, line) in sites.sorted(by: { $0.key < $1.key }) {
            failures += siteFailures(constructionPattern(type), in: text, file: file, allowed: [line: 1],
                                     rule: "the one \(type) is built at its one site")
            for copy in copies {
                let built = matches(constructionPattern(type), in: copy).count
                if built != 1 { failures.append("\(file) builds \(type) \(built) time(s) in a scan copy — exactly once") }
                if hits(indirectConstructionPattern(type), in: copy) {
                    failures.append("\(file) reaches \(type)'s constructor unnamed (an unapplied init, the metatype, "
                                    + "an alias, an extension, a subclass or a bound generic)")
                }
            }
        }
        if copies.contains(where: { hits(implicitInit, in: $0) }) {
            failures.append("\(file) has an implicit .init( — the CloudKit files spell every construction")
        }
        return unique(failures)
    }

    /// The record path's one record and one operation.
    static let recordPathConstructions = [
        "CKRecord": "let record = CKRecord(recordType: ApprovalWire.RecordType.prompt.rawValue,",
        "CKModifyRecordsOperation": "let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: doomed)",
    ]

    @Test func theRecordPathBuildsOneRecordAndOneOperation() throws {
        let file = Self.text(Self.recordPathFile, in: try Self.uncutSources())
        let failures = Self.constructionFailures(file, file: Self.recordPathFile, sites: Self.recordPathConstructions)
        #expect(failures.isEmpty, "\(failures)")
        let built = Self.recordPathConstructions["CKRecord"] ?? ""
        let mutants: [(String, String)] = [
            // The security re-check (#146), L6, as planted.
            ("L6: a second record, init-spelled", file + "\nextension ApprovalRecordWriter {\n"
                + "    static func secondRecord(_ id: PromptID) -> CKRecord {\n"
                + "        CKRecord.init(recordType: ApprovalWire.RecordType.prompt.rawValue, recordID: promptRecordID(id))\n    }\n}"),
            ("a second record, spaced", file + "\nlet r = CKRecord (recordType: \"PromptDecision\", recordID: i)"),
            ("a backticked second record", file + "\nlet r = `CKRecord`(recordType: \"PromptDecision\", recordID: i)"),
            ("a comment-split second operation", file + "\nlet o = CKModifyRecordsOperation/* x */(recordsToSave: [], recordIDsToDelete: nil)"),
            ("a module-qualified second operation", file + "\nlet o = CloudKit.CKModifyRecordsOperation(recordsToSave: [], recordIDsToDelete: nil)"),
            ("an unapplied record init", file + "\nlet make = CKRecord.init"),
            ("the operation's metatype", file + "\nlet t = CKModifyRecordsOperation.self"),
            ("a backticked metatype", file + "\nlet t = `CKRecord`.self"),
            ("the record's metatype type", file + "\nfunc f(_ t: CKRecord.Type) {}"),
            ("an aliased operation", file + "\ntypealias Op = CKModifyRecordsOperation\nlet o = Op(recordsToSave: [], recordIDsToDelete: nil)"),
            ("an alias behind a block comment", file + "\ntypealias R = /* x */ CKRecord"),
            ("an extension's Self(", file + "\nextension CKRecord {\n    static func spare() -> CKRecord { Self(recordType: \"X\") }\n}"),
            ("a backticked extension", file + "\nextension `CKModifyRecordsOperation` {\n    static var spare: Any { Self.init }\n}"),
            ("a subclass", file + "\nfinal class SpareRecord: CKRecord {}\nlet r = SpareRecord(recordType: \"X\")"),
            ("a bound generic", file + "\nfunc spare<R: CKRecord>(_: R.Type) -> R { R(recordType: \"X\") }"),
            ("a where-bound generic", file + "\nfunc spare<R>(_: R.Type) -> R where R: CKRecord { R(recordType: \"X\") }"),
            ("an implicit init in the operation's records", file.replacingOccurrences(
                of: "recordsToSave: records,", with: "recordsToSave: records + [.init(recordType: \"PromptRequest\")],")),
            ("an implicit init returned", file + "\nfunc spare() -> CKRecord {\n    return .init(recordType: \"X\")\n}"),
            ("an implicit init behind try?", file + "\nfunc spare() throws -> CKRecord { try? .init(coder: c) ?? r }"),
            ("the one record moved", file.replacingOccurrences(of: built, with: "let record = CKRecord.init(recordType: "
                + "ApprovalWire.RecordType.prompt.rawValue,")),
        ]
        for (name, mutant) in mutants {
            #expect(mutant != file, "canary '\(name)' did not apply")
            #expect(!Self.constructionFailures(mutant, file: Self.recordPathFile, sites: Self.recordPathConstructions).isEmpty,
                    "canary '\(name)' was NOT caught")
        }
        // Each pattern compiles and bites through the lock's own engine (one
        // that did not compile would match nothing, silently).
        for (pattern, probe) in [(Self.constructionPattern("CKRecord"), "CKRecord . init (recordType: t)"),
                                 (Self.indirectConstructionPattern("CKRecord"), "let m = CKRecord.init"),
                                 (Self.indirectConstructionPattern("CKRecord"), "extension CloudKit.CKRecord {"),
                                 (Self.implicitInit, "let r: CKRecord =\n    .init(recordType: t)"),
                                 (Self.implicitInit, "{ r in .init(recordType: r) }")] {
            #expect(Self.hits(pattern, in: probe), "'\(pattern)' does not match '\(probe)'")
        }
        // Over-match controls: record IDs and zone IDs (other types), the
        // record as a parameter, an array, a result or a return type, an
        // explicit `Date.init`, an implicit member that is no init, an
        // extension of a member type, and a whole-line comment.
        #expect(Self.constructionFailures(file + "\nfunc f(r: CKRecord, rs: [CKRecord], res: Result<CKRecord, any Error>) "
            + "-> CKRecord.ID { CKRecord.ID(recordName: \"x\", zoneID: .default) }\nlet now: () -> Date = Date.init"
            + "\nlet z = CKRecordZone.ID(zoneName: \"z\")\nextension CKRecord.ID {}\nfinal class Box: @unchecked Sendable {}"
            + "\nlet initial = [1].first\nstatic func make(_ id: CKRecord.ID) -> CKRecord? { nil }"
            + LidGuardStructureTests.wholeLineCommentsRemoved("\n    /// never CKRecord.init(…), never typealias R = CKRecord"),
            file: Self.recordPathFile, sites: Self.recordPathConstructions).isEmpty)
    }

    /// The security delta check (#153), X1: `makeOperation(…).go()`, with
    /// `go` an extension in ANOTHER file that calls `start()`, named no word
    /// lock 4 bans in the record path, and every suite passed. So the
    /// operation is pinned by where it goes, the way the phone pins its
    /// writer, not by what is banned: built once (lock 8's construction
    /// check), in `makeOperation`, which only configures it and returns it;
    /// the factory named nowhere in the four targets but its declaration and
    /// the writer's two `database.submit(Self.makeOperation(…` calls, each on
    /// its pinned line; the seam's `submit` named only by its requirement and
    /// those two calls; and the operation type named only by the
    /// requirement, the factory's return type and the construction.
    static let factorySites = [
        "static func makeOperation(saving records: [CKRecord], deleting doomed: [CKRecord.ID],": 1,
        "database.submit(Self.makeOperation(saving: [record], deleting: []) { outcome in": 1,
        "database.submit(Self.makeOperation(saving: [], deleting: doomed) { outcome in": 1,
    ]
    static let submitSites = [
        "func submit(_ operation: CKModifyRecordsOperation)": 1,
        "database.submit(Self.makeOperation(saving: [record], deleting: []) { outcome in": 1,
        "database.submit(Self.makeOperation(saving: [], deleting: doomed) { outcome in": 1,
    ]
    /// Every line naming `operation`: the seam's parameter, then the factory
    /// building, configuring and returning its operation.
    static let operationSites = [
        "func submit(_ operation: CKModifyRecordsOperation)": 1,
        "let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: doomed)": 1,
        "operation.savePolicy = .ifServerRecordUnchanged": 1,
        "operation.isAtomic = true": 1,
        "operation.configuration = configuration": 1,
        "operation.perRecordSaveBlock = { _, result in results.note(result.map { _ in () }, deleting: false) }": 1,
        "operation.perRecordDeleteBlock = { _, result in results.note(result, deleting: true) }": 1,
        "operation.modifyRecordsResultBlock = { batch in completion(results.outcome(batch: batch)) }": 1,
        "return operation": 1,
    ]
    static let operationTypeSites = [
        "func submit(_ operation: CKModifyRecordsOperation)": 1,
        "-> CKModifyRecordsOperation {": 1,
        "let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: doomed)": 1,
    ]

    /// `sources`: `uncutSources()`.
    static func seamFlowFailures(_ sources: Sources) -> [String] {
        let file = text(recordPathFile, in: sources)
        var failures = siteFailures(#"\bmakeOperation\b"#, in: file, file: recordPathFile, allowed: factorySites,
                                    rule: "the operation factory is reached only by the writer's two submits")
        for (name, text) in sources where name != recordPathFile && hits(#"\bmakeOperation\b"#, in: text) {
            failures.append("'makeOperation' in \(name) — only the record path's writer reaches the operation factory")
        }
        failures += siteFailures(#"\bsubmit\b"#, in: file, file: recordPathFile, allowed: submitSites,
                                 rule: "the seam is named only by its requirement and the writer's two submits")
        failures += siteFailures(#"\boperation\b"#, in: file, file: recordPathFile, allowed: operationSites,
                                 rule: "the factory builds, configures and returns its operation, nothing else")
        failures += siteFailures(#"\bCKModifyRecordsOperation\b"#, in: file, file: recordPathFile, allowed: operationTypeSites,
                                 rule: "the operation type is named by the seam, the factory and the one construction")
        return failures
    }

    @Test func everyOperationTheRecordPathBuildsGoesToTheSeam() throws {
        let sources = try Self.uncutSources()
        #expect(Self.seamFlowFailures(sources).isEmpty, "\(Self.seamFlowFailures(sources))")
        let record = Self.recordPathFile
        let written = "saving: [record], deleting: []"
        let returned = "        return operation\n"
        #expect(Self.text(record, in: sources).contains(returned), "vacuity: the factory's return is the anchor")
        let mutants: [(String, Sources)] = [
            // The security delta check (#153), X1, as planted: both files.
            ("X1: the operation run by an extension in another file", Self.mutate(Self.mutate(sources, record) {
                $0 + "\nextension ApprovalRecordWriter {\n    static func x1(_ r: CKRecord) {\n"
                    + "        makeOperation(saving: [r], deleting: []) { _ in }.go()\n    }\n}"
            }, "NapCatApp.swift") { $0 + "\nextension Operation {\n    func go() { start() }\n}" }),
            ("the factory's own operation run by a runner elsewhere", Self.mutate(sources, record) {
                $0.replacingOccurrences(of: returned, with: "        operation.go()\n" + returned) }),
            ("the factory's operation handed out", Self.mutate(sources, record) {
                $0.replacingOccurrences(of: returned, with: "        Spare.last = operation\n" + returned) }),
            ("the operation pointed at a database", Self.mutate(sources, record) {
                $0.replacingOccurrences(of: returned, with: "        operation.database = spare\n" + returned) }),
            ("the writer keeps the operation", Self.mutate(sources, record) {
                $0.replacingOccurrences(of: "database.submit(Self.makeOperation(" + written,
                                        with: "let kept = Self.makeOperation(" + written) }),
            ("a second record written with the first", Self.mutate(sources, record) {
                $0.replacingOccurrences(of: written, with: "saving: [record, spare], deleting: []") }),
            ("an unapplied factory", Self.mutate(sources, record) { $0 + "\nlet make = ApprovalRecordWriter.makeOperation" }),
            ("the factory reached from another file", Self.mutate(sources, ApprovalChannelStructureTests.intakeFile) {
                $0 + "\nfunc f(r: R) { _ = W.makeOperation(saving: [r], deleting: []) { _ in } }" }),
            ("a default submit that runs it", Self.mutate(sources, record) {
                $0 + "\nextension ApprovalRecordDatabase {\n    func submit(_ o: CKModifyRecordsOperation) { o.go() }\n}" }),
            ("a second submit", Self.mutate(sources, record) { $0 + "\nfunc f(d: any ApprovalRecordDatabase, o: Op) { d.submit(o) }" }),
            ("the operation type extended, no banned word", Self.mutate(sources, record) {
                $0 + "\nextension CKModifyRecordsOperation {\n    func go() { spare() }\n}" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.seamFlowFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: other words (`operations`, `Operation`,
        // `submitted`), and a whole-line comment naming what it rules out.
        #expect(Self.seamFlowFailures(Self.mutate(sources, record) {
            $0 + "\nfunc f(_ operations: [Int], submitted: Bool) -> Operation? { nil }"
                + LidGuardStructureTests.wholeLineCommentsRemoved("\n    /// never makeOperation(…).go(), never a second submit(operation)")
        }).isEmpty)
    }

    // MARK: - 5. The S3 tests touch nothing live

    /// The S3 Mac test files that run anything (this file only reads sources).
    static let s3TestFiles = ["ApprovalRecordFakes.swift", "ApprovalRecordWriterTests.swift", "DecisionRecordReaderTests.swift",
                              "ApprovalRecordRoutingTests.swift"]

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
