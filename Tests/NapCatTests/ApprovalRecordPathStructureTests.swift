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
///    type (the security re-check, N3). AMENDED (deliberate, S-PAIR-A,
///    #161): the decision verifier is the one exception, building it once,
///    verified, after its signature check, and naming nothing of the
///    verdict API, the Secure Enclave, the keychain or CloudKit; nothing
///    names the verifier yet, and only the S0 type's own file is exempt;
/// 4. the record path cannot reach iCloud by itself: no container, no
///    database, no account check, no CloudKit identifier off its allow-list,
///    no way to run an operation but the database seam (security review 2,
///    G1), no other file in the four targets importing CloudKit in any form
///    (G2; since #241 the other three targets' files are matched by path,
///    so none passes under a sanctioned name), and nothing in the app
///    conforms to its database seam;
/// 5. the S3 test files touch nothing live;
/// 6. the prompt record is written only through the wire;
/// 7. (#146) the record store writes the gate's forward answer exactly as
///    the intake hands it, through the one conformer of the gate's answer,
///    and a decision read for a prompt only joins its retraction;
/// 8. (#153) the record path builds one record and one operation, however
///    the construction is spelled, and every operation it builds is the
///    argument of the seam's `submit`, at a set count of call sites — so no
///    banned word has to be named for a bypass to fail;
/// 9. (#161, the S-PAIR-A security review) the verifier's cryptography
///    means what it says: nothing re-declares or extends what its check is
///    spelled in, every unsafe-memory site and every line naming the S0 type
///    is pinned, the signature check is one adjacent block, the verifier's
///    top level is exactly its types, and no Mac source signs; (S-PAIR-C2)
///    and the paired key is read from the slot at each verification;
/// 10. (#170, S-PAIR-C1.5, the live pairing transport) the pairing record is
///    reached by its ID alone, through its one source and its one live
///    database, and a fetch is found only from a record actually read.
///    Locks 4 and 8 are AMENDED with it, deliberately: the CloudKit allow-list
///    widens by `CKFetchRecordsOperation` alone, and the seam-flow pins gain
///    the pairing source's fetch and its deletion (the record path's own
///    factory, saving nothing).
///
/// AMENDED for S-PAIR-C2 (#181), deliberately: the verifier is wired. Lock 3
/// now pins every line naming a verifier type outside its file (the record
/// store builds its two inputs, the intake makes its one call), lock 9b's
/// S0-type sites shrink to the verifier's (the intake takes the verifier's
/// result alone), and lock 9f is new: the paired key is read from the slot
/// at each verification, and kept nowhere.
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

    /// `uncutSources()`'s files and form, Sources/NapCat named by file name
    /// and the other three targets by path
    /// (`ApprovalChannelStructureTests.pathSources`, #244), so no file
    /// outside Sources/NapCat matches a pinned name.
    static func uncutPathSources() throws -> Sources {
        try ApprovalChannelStructureTests.pathSources(LidGuardStructureTests.wholeLineCommentsRemoved)
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
    /// AMENDED for S-PAIR-A (#161), deliberately: signed decisions exist, so
    /// the door has ONE key, the decision verifier. It builds the S0 type
    /// exactly once in every scan copy, naming the flag once (that
    /// construction's label), and the unnamed roads stay shut there too.
    /// Re-tightened in the same step (`verifierFailures`): that construction
    /// sits on its pinned line, verified, after the length check, the one
    /// parse and the signature check, in that order; the verifier names
    /// nothing of the verdict API, the Secure Enclave, biometrics, the
    /// keychain or CloudKit; and nothing names the verifier, since no reader,
    /// intake or lifecycle is handed one in this slice (S-PAIR-C2 wires it).
    /// Only the S0 type's own file is exempt from the scan now: every other
    /// NapCatWire file, the canonical-bytes file included, is read like any
    /// other source. (S-PAIR-C2 wired it: the verifier's types are named at
    /// pinned sites, `wiredVerifierSites`.)
    static let verifierFile = "DecisionVerifier.swift"

    /// The S0 type's own file, the one source the scan skips.
    static let declaringFile = "ApprovalStateMachine.swift"

    /// `sources`: `uncutSources()`. The original two checks read the
    /// comment-stripped code, as they always did.
    static func verdictTypeFailures(_ sources: Sources) -> [String] {
        var failures: [String] = []
        for (name, uncut) in sources where name != declaringFile {
            let allowed = name == verifierFile ? 1 : 0
            let copies = LidGuardStructureTests.constructorScanCopies(uncut)
            let code = copies.map(LidGuardStructureTests.codeOnly)
            if code.contains(where: {
                ApprovalChannelStructureTests.count("ApprovalDecision(", in: ApprovalChannelStructureTests.constructionSpelling($0)) != allowed
            }) {
                failures.append("\(name) builds an ApprovalDecision — only the decision verifier does, exactly once")
            }
            if code.contains(where: { ApprovalChannelStructureTests.count("signatureVerified", in: $0) != allowed }) {
                failures.append("\(name) names signatureVerified — only the decision verifier's one construction does")
            }
            if copies.contains(where: { $0.range(of: indirectConstruction, options: .regularExpression) != nil }) {
                failures.append("\(name) reaches ApprovalDecision's constructor unnamed — no decision is a verdict before CL-1")
            }
        }
        return failures + verifierFailures(sources)
    }

    /// The verifier's one construction, as written.
    static let verifiedConstruction = "return .verified(ApprovalDecision(promptID: promptID, verdict: verdict, "
        + "wireVersion: evidence.wireVersion, signatureVerified: true))"

    /// In the verifier, in this order: the length check before any
    /// cryptography, the signature's one parse, the signature check, then
    /// the construction.
    static let verifierOrder = ["guard evidence.signature.count == ApprovalSigning.signatureByteCount else {",
                                "P256.Signing.ECDSASignature(rawRepresentation: evidence.signature)",
                                "guard pairedKey.isValidSignature(signature, for: SHA256.hash(data: message)) else {",
                                verifiedConstruction]

    /// What the verifier never names: the verdict API (lock 1's list, but
    /// the type it builds), and anything beyond a software public key — the
    /// Secure Enclave, biometrics, the keychain and CloudKit. (The keychain
    /// token is split so this file never names a Security item call itself.)
    static let verifierBannedTokens = verdictAPITokens.filter { $0 != "ApprovalDecision" && $0 != "signatureVerified" }
        + ["SecureEnclave", "LocalAuthentication", "LAContext", "SecAccessControl", "Sec" + "Item", "SecKey", "kSec", "CloudKit"]

    /// The verifier's own types, matched as whole words.
    static let verifierTypes = ["DecisionVerifier", "DecisionEvidence", "ForwardedCopy", "DecisionVerification",
                                "DecisionUnverifiedReason", "DecisionVerifierAudit", "DecisionVerifierLog"]

    /// AMENDED for S-PAIR-C2 (#181), deliberately: the verifier is wired, so
    /// "nothing outside its file names its types" became an exact list of
    /// where they are named — every line, file by file. The record store
    /// builds the verifier's two inputs (a claim's evidence, its own copy of
    /// the prompt), once each, and hands them on; the intake takes them and
    /// the slot, makes the one call to the verifier and takes its result.
    /// Nothing else names a verifier type: no other file builds an input,
    /// verifies, or holds a result.
    static let wiredVerifierSites: [String: [String: Int]] = [
        ApprovalChannelStructureTests.intakeFile: [
            "func receiveDecision(_ evidence: DecisionEvidence, copy: ForwardedCopy?, keys: PairedKeyStore,": 2,
            "refusals: (DecisionVerifierAudit) -> Void = DecisionVerifierLog.record) {": 2,
            wiredCall: 1,
            "func decide(_ verification: DecisionVerification) {": 1,
        ],
        recordPathFile: [
            "private var copies: [PromptID: ForwardedCopy] = [:]": 1,
            "copies[id] = ForwardedCopy(promptID: id, toolName: prompt.toolName, inputPreview: prompt.inputPreview,": 1,
            "-> (evidence: DecisionEvidence, copy: ForwardedCopy?)? {": 2,
            "var evidence: DecisionEvidence {": 1,
            "DecisionEvidence(wireVersion: ApprovalWire.wireVersion, promptID: promptID.hex, verdict: claimedVerdict.rawValue,": 1,
        ],
    ]

    /// The one wired call (S-PAIR-C2): the intake's `decide`, handed the
    /// verifier's result for the slot as it is now.
    static let wiredCall: String = "decide(DecisionVerifier.verify(evidence, copy: copy, keys: keys, audit: refusals))"

    /// Inside the verifier: its own copy rebuilt in another normalization
    /// form (the diagnostic) is its one construction of an input.
    static let verifierInputSites: [String: Int] = [
        "let other = ForwardedCopy(promptID: copy.promptID, toolName: form(copy.toolName), inputPreview: form(copy.inputPreview),": 1,
    ]

    /// `sources`: `uncutSources()`.
    static func verifierFailures(_ sources: Sources) -> [String] {
        let uncut = text(verifierFile, in: sources)
        let code = LidGuardStructureTests.codeOnly(uncut)
        guard code.contains("enum DecisionVerifier {") else {
            return ["'enum DecisionVerifier {' not found in \(verifierFile) — the verifier lock would be vacuous"]
        }
        var failures = siteFailures(constructionPattern("ApprovalDecision"), in: uncut, file: verifierFile,
                                    allowed: [verifiedConstruction: 1],
                                    rule: "the verifier builds the S0 type once, verified, on its pinned line")
        let spelled = ApprovalChannelStructureTests.constructionSpelling(code)
        if ApprovalChannelStructureTests.count("ECDSASignature(", in: spelled) != 1 {
            failures.append("the verifier parses a signature in exactly one place")
        }
        var cursor = code.startIndex
        for step in verifierOrder {
            guard ApprovalChannelStructureTests.count(step, in: code) == 1,
                  let found = code.range(of: step, range: cursor..<code.endIndex) else {
                failures.append("the verifier checks the length, parses the signature once, checks it, then builds "
                                + "the decision, in that order: '\(step)' is missing, doubled or out of order")
                break
            }
            cursor = found.upperBound
        }
        for token in verifierBannedTokens where code.contains(token) {
            failures.append("'\(token)' in \(verifierFile) — the verifier answers nothing and holds a software public key only")
        }
        if hits(#"\bCK[A-Z]\w*"#, in: code) {
            failures.append("a CloudKit identifier in \(verifierFile) — the verifier reads no record")
        }
        let typePattern = #"\b(?:"# + verifierTypes.joined(separator: "|") + #")\b"#
        for (name, text) in sources where name != verifierFile {
            for copy in LidGuardStructureTests.constructorScanCopies(LidGuardStructureTests.codeOnly(text)) {
                failures += siteFailures(typePattern, in: copy, file: name, allowed: wiredVerifierSites[name] ?? [:],
                                         rule: "the verifier's types are named only where the store builds its inputs and the "
                                             + "intake calls it (S-PAIR-C2)")
            }
        }
        for copy in LidGuardStructureTests.constructorScanCopies(uncut) {
            failures += siteFailures(constructionPattern("ForwardedCopy") + "|" + constructionPattern("DecisionEvidence"),
                                     in: copy, file: verifierFile, allowed: verifierInputSites,
                                     rule: "the verifier builds no input but its own copy in another normalization form")
        }
        return unique(failures)
    }

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
            // Security spot-check H9: a bare regex after `switch` holding a
            // quote, then the URL, then the verdict; and its multi-line form,
            // the verdict in a `//`-led interpolation line.
            ("H9a: a verdict built behind a URL after a bare regex", Self.mutate(sources, ApprovalChannelStructureTests.hostFile) {
                $0 + "\nfunc h9(i: ApprovalIntake) { switch /\"/ { default: let u = \"https://x\"; "
                    + "i.decide(ApprovalDecision(promptID: p, verdict: .allow, wireVersion: 1, signatureVerified: true)) } }" }),
            ("H9, multi-line: a verdict in a //-led interpolation line", Self.mutate(sources, ApprovalChannelStructureTests.hostFile) {
                $0 + LidGuardStructureTests.wholeLineCommentsRemoved("\nfunc h9m(i: ApprovalIntake) -> String {\n"
                    + "    switch /\"\"\"/ { default: break }\n    let s = \"\"\"\n"
                    + "    // \\(i.decide(ApprovalDecision(promptID: p, verdict: .allow, wireVersion: 1, signatureVerified: true)))\n"
                    + "    \"\"\"\n    switch /\"\"\"/ { default: break }\n    return s\n}") }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.verdictTypeFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    /// Security review 2 (#146), G4 and its siblings: the constructor reached
    /// without naming it or the flag.
    @Test func noMacSourceReachesTheVerdictConstructorUnnamed() throws {
        let sources = try Self.uncutSources()
        #expect(Self.text(Self.verifierFile, in: sources).contains("case verified(ApprovalDecision)"),
                "vacuity: outside the wire the type is named as the verifier's payload (S-PAIR-C2: the intake takes its result)")
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
            // Security spot-check H9b, as planted (R-H9-B2): the regex follows
            // `switch`, so its quote must not open a string.
            ("H9b: a bare regex after switch before a commented extension", Self.mutate(sources, ApprovalChannelStructureTests.intakeFile) {
                $0 + "\nfunc h9b() { switch /\"/ { default: break } }; extension /* x */ ApprovalDecision { static let h9claim = Self.init }\n\n"
                    + "func h9use(i: ApprovalIntake, p: PromptID) {\n    i.decide(ApprovalDecision.h9claim(p, .allow, 1, true))\n}" }),
            ("H9, multi-line: a regex holding \"\"\" before a commented extension",
             Self.mutate(sources, ApprovalChannelStructureTests.intakeFile) {
                $0 + "\nfunc h9m() -> String {\n    switch /\"\"\"/ { default: break }\n    return \"\"\"\n    \"\"\"\n}\n"
                    + "extension /* x */ ApprovalDecision { static let h9claimM = Self.init }" }),
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

    /// S-PAIR-A (#161): the amendment's one exception, re-tightened. Each
    /// canary is one way the exception could widen: a second builder (in
    /// the app, a new file or a NapCatWire file), the verifier reaching the
    /// verdict API or anything beyond a software public key, its one
    /// construction moved, doubled or loosened, the unnamed roads opened in
    /// a third file or in the verifier itself, or the verifier wired ahead
    /// of its slice.
    @Test func onlyTheDecisionVerifierBuildsADecision() throws {
        let sources = try Self.uncutSources()
        #expect(Self.verdictTypeFailures(sources).isEmpty, "\(Self.verdictTypeFailures(sources))")
        let verifier = Self.verifierFile
        let file = Self.text(verifier, in: sources)
        let built = "        " + Self.verifiedConstruction + "\n"
        let checked = "        guard pairedKey.isValidSignature(signature, for: SHA256.hash(data: message)) else {\n"
        let length = "        guard evidence.signature.count == ApprovalSigning.signatureByteCount else { return .unverified(.signatureLength) }\n"
        let diagnosed = "if pairedKey.isValidSignature(signature, for: SHA256.hash(data: message)) { return true }"
        for anchor in [built, checked, length, diagnosed] {
            #expect(file.contains(anchor), "vacuity: '\(anchor.trimmingCharacters(in: .whitespacesAndNewlines))' is the anchor")
        }
        let decision = "ApprovalDecision(promptID: p, verdict: .allow, wireVersion: 1, signatureVerified: true)"
        let mutants: [(String, Sources)] = [
            // A second file building the type.
            ("the app builds one", Self.mutate(sources, "NapCatApp.swift") { $0 + "\nlet d = " + decision }),
            ("a new file builds one", sources + [("ZZSecondVerifier.swift",
                "import NapCatWire\nfunc verifyAgain(p: PromptID) -> ApprovalDecision { " + decision + " }")]),
            ("the canonical-bytes file builds one", Self.mutate(sources, "ApprovalSigning.swift") { $0 + "\nlet d = " + decision }),
            ("another wire file extends the type", Self.mutate(sources, "ApprovalWire.swift") {
                $0 + "\nextension ApprovalDecision {\n    static let claimed = Self.init\n}" }),
            // The verifier naming the verdict API.
            ("the verifier feeds the intake", Self.mutate(sources, verifier) {
                $0 + "\nfunc f(i: ApprovalIntake, d: ApprovalDecision) { i.decide(d) }" }),
            ("the verifier answers the dialog", Self.mutate(sources, verifier) {
                $0 + "\nfunc f(c: Int, r: ChannelRequestID) { sendFrame(c, ApprovalChannel.verdictFrame(r, .allow)) }" }),
            ("the verifier drives a lifecycle", Self.mutate(sources, verifier) {
                $0 + "\nfunc f(l: inout ApprovalLifecycle, d: ApprovalDecision) { _ = l.apply(.remoteDecision(d), now: 0) }" }),
            ("the verifier classifies", Self.mutate(sources, verifier) {
                $0 + "\nlet c = ApprovalGate.classify(toolName: t, inputPreview: p, secrets: [])" }),
            ("the verifier arms", Self.mutate(sources, verifier) { $0 + "\nlet armed = true" }),
            // … or holding more than a software public key.
            ("the verifier names the enclave", Self.mutate(sources, verifier) {
                $0 + "\nlet k = try? SecureEnclave.P256.Signing.PrivateKey()" }),
            ("the verifier asks for a match", Self.mutate(sources, verifier) { "import LocalAuthentication\n" + $0 + "\nlet c = LAContext()" }),
            ("the verifier reads the keychain", Self.mutate(sources, verifier) { $0 + "\nlet s = Sec" + "ItemCopyMatching(q, &r)" }),
            ("the verifier reads a record", Self.mutate(sources, verifier) { $0 + "\nfunc f(r: CKRecord) {}" }),
            // The one construction moved, doubled or loosened.
            ("a second construction in the verifier", Self.mutate(sources, verifier) {
                $0.replacingOccurrences(of: diagnosed, with: "if pairedKey.isValidSignature(signature, for: SHA256.hash(data: message)) { "
                    + "_ = ApprovalDecision(promptID: claimed.promptID, verdict: claimed.verdict, wireVersion: 1, "
                    + "signatureVerified: true); return true }") }),
            ("the flag from a variable", Self.mutate(sources, verifier) {
                $0.replacingOccurrences(of: "signatureVerified: true))", with: "signatureVerified: ok))") }),
            ("built before the signature check", Self.mutate(sources, verifier) {
                $0.replacingOccurrences(of: built, with: "").replacingOccurrences(of: checked, with: built + checked) }),
            ("the length checked after the parse", Self.mutate(sources, verifier) {
                $0.replacingOccurrences(of: length, with: "").replacingOccurrences(of: checked, with: length + checked) }),
            ("the length check dropped", Self.mutate(sources, verifier) { $0.replacingOccurrences(of: length, with: "") }),
            ("a second parse", Self.mutate(sources, verifier) {
                $0.replacingOccurrences(of: length, with: "        _ = try? P256.Signing.ECDSASignature(derRepresentation: evidence.signature)\n"
                    + length) }),
            // The unnamed roads, in a third file and in the verifier itself.
            ("an unapplied init in a third file", Self.mutate(sources, "MenuStateModel.swift") { $0 + "\nlet make = ApprovalDecision.init" }),
            ("an extension in a third file", Self.mutate(sources, "LidGuardController.swift") {
                $0 + "\nextension ApprovalDecision {\n    static let claimed = Self.init\n}" }),
            ("an unapplied init in the verifier", Self.mutate(sources, verifier) { $0 + "\nlet make = ApprovalDecision.init" }),
            ("a backticked extension in the verifier", Self.mutate(sources, verifier) {
                $0 + "\nextension `ApprovalDecision` {\n    static let claimed = Self.init\n}" }),
            ("an alias in the verifier", Self.mutate(sources, verifier) { $0 + "\ntypealias Verified = /* x */ ApprovalDecision" }),
            // Named off its pinned sites (S-PAIR-C2: wired, at those sites alone).
            ("the intake verifies a second time", Self.mutate(sources, ApprovalChannelStructureTests.intakeFile) {
                $0 + "\nfunc f(e: DecisionEvidence, k: PairedKeyStore) { _ = DecisionVerifier.verify(e, copy: nil, keys: k) }" }),
            ("the record store keeps a second copy", Self.mutate(sources, Self.recordPathFile) { $0 + "\nlet c: ForwardedCopy? = nil" }),
            ("the app holds a verification", Self.mutate(sources, "NapCatApp.swift") { $0 + "\nvar last: DecisionVerification?" }),
            ("the host verifies", Self.mutate(sources, ApprovalChannelStructureTests.hostFile) {
                $0 + "\nfunc zz(e: DecisionEvidence, k: PairedKeyStore) -> Any { DecisionVerifier.verify(e, copy: nil, keys: k) }" }),
            ("the record store builds a second evidence", Self.mutate(sources, Self.recordPathFile) {
                $0.replacingOccurrences(of: "        return (claim.evidence, copies[claim.promptID])",
                                        with: "        return (DecisionEvidence(wireVersion: 1, promptID: claim.promptID.hex, verdict: \"allow\", "
                                            + "decidedAt: claim.decidedAt, signature: claim.signature), copies[claim.promptID])") }),
            ("the wired call moved", Self.mutate(sources, ApprovalChannelStructureTests.intakeFile) {
                $0.replacingOccurrences(of: Self.wiredCall, with: "decide(DecisionVerifier.verify(evidence, copy: copy, keys: keys))") }),
            ("the verifier builds an evidence", Self.mutate(sources, verifier) {
                $0.replacingOccurrences(of: "    static let latestDecidedAt: TimeInterval = 9_007_199_254_740_992\n",
                                        with: "    static let latestDecidedAt: TimeInterval = 9_007_199_254_740_992\n    static let zz = "
                                            + "DecisionEvidence.init(wireVersion: 1, promptID: \"\", verdict: \"\", decidedAt: .now, signature: Data())\n") }),
            ("a backticked result held elsewhere", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nvar zz: `DecisionVerification`? = nil" }),
            // The verifier gone: the lock must not pass vacuously.
            ("the verifier renamed away", Self.mutate(sources, verifier) {
                $0.replacingOccurrences(of: "enum DecisionVerifier {", with: "enum Verifier {") }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.verdictTypeFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: a whole-line comment naming the verifier and
        // its copy, names that only start like its types, the S0 type as the
        // verifier's payload and parameter, and a trailing comment in the
        // verifier naming what it never reaches.
        #expect(Self.verdictTypeFailures(Self.mutate(Self.mutate(sources, "NapCatApp.swift") {
            $0 + LidGuardStructureTests.wholeLineCommentsRemoved("\n/// S-PAIR-C2 hands the DecisionVerifier a ForwardedCopy")
                + "\nstruct DecisionVerifierLogo {}\nlet forwardedCopyCount = 0"
        }, verifier) {
            $0 + "\nfunc spare(_ d: ApprovalDecision?) -> [ApprovalDecision] { [] } // never ApprovalIntake, never LAContext"
        }).isEmpty)
    }

    // MARK: - 9. The verifier's cryptography means what it says (S-PAIR-A security review)

    /// The S-PAIR-A security review (#161) planted backdoors that left every
    /// lock above green, the verifier's pinned lines kept or the file
    /// untouched: a CryptoKit overload in another file outranking the
    /// verifier's pinned call (P2'), a verified decision forged by
    /// `unsafeBitCast` with no construction and no flag named, or no type
    /// name at all (P1, P1'), the verifier exported through aliases declared
    /// in its file (P3), its key minted in its own scope (L2), and its pinned
    /// guard made dead while a live OR verified (L3). So the locks below pin
    /// what the check MEANS, not the names a plant avoided:
    ///
    /// a. nothing in the four targets DECLARES what the check and the
    ///    canonical bytes are reached by (`isValidSignature`, `hash`,
    ///    `decisionMessage`, `shownDigestInput`) outside its home, and
    ///    nothing extends the crypto types or, outside its own file, the
    ///    canonical-bytes enum — directly or through an alias;
    /// b. every unsafe-memory site, and every line naming the S0 type outside
    ///    its declaring file, is pinned to today's exact list;
    /// c. the signature check is one adjacent block — the guard, its refusal,
    ///    its brace, the construction — and its diagnostic is declared once
    ///    and called only from that refusal;
    /// d. the verifier's top level is exactly its imports and its seven types,
    ///    and it holds no `typealias` and no `extension` at all;
    /// e. no Mac source holds a private key or signs.
    ///
    /// Every check reads `uncutSources()` through #158's three copies (raw,
    /// backticks removed, cleaned); a comment between two tokens a pattern
    /// joins is read as the whitespace it is (`gap`).
    static let gap = #"(?:\s|//[^\n]*|/\*[\s\S]*?\*/)"#

    /// The security review's compiled plants, verbatim (each compiled into
    /// the suite and bit: a garbage signature verified, a forged decision
    /// came out verified, the verifier ran from another file).
    static let plantShadow = """
        import CryptoKit

        // REVIEWER PLANT P2' (conditional): a non-generic overload that outranks
        // CryptoKit's generic check at the verifier's pinned call, honest for every
        // signature but one magic pattern. The verifier file is untouched.
        extension P256.Signing.PublicKey {
            func isValidSignature(_ signature: P256.Signing.ECDSASignature, for digest: SHA256Digest) -> Bool {
                signature.rawRepresentation.allSatisfy { $0 == 0x01 } || zzReal(signature, digest)
            }
            private func zzReal<D: Digest>(_ signature: P256.Signing.ECDSASignature, _ digest: D) -> Bool {
                isValidSignature(signature, for: digest)
            }
        }

        """
    static let plantForgeHead = """
        import NapCatWire

        // REVIEWER PLANT P1: a verified S0 decision with no construction, no flag
        // label and no `ApprovalDecision.self` / `.init` spelling.
        func zzForgedDecision(_ id: PromptID) -> ApprovalDecision? {
            unsafeBitCast((id, ApprovalWire.Verdict.allow, ApprovalWire.wireVersion, true), to: ApprovalDecision?.self)
        }


        """
    static let plantForgeTail = """
        // REVIEWER PLANT P1' (no S0 type name at all): the type is inferred from the
        // intake's own parameter.
        func zzForge<T>(_ parts: (PromptID, ApprovalWire.Verdict, Int, Bool)) -> T { unsafeBitCast(parts, to: T.self) }

        extension ApprovalIntake {
            func zzDecide(_ id: PromptID) { decide(zzForge((id, .allow, ApprovalWire.wireVersion, true))) }
        }

        """
    static let plantWiring = """
        import NapCatWire

        // REVIEWER PLANT P3: the verifier reached from outside its file through
        // aliases declared inside it.
        func zzWired(_ reading: SignedReading) -> ApprovalDecision? {
            SignatureCheck.verify(reading, copy: nil, pairedKey: nil)
        }

        """
    /// P3's half in the verifier: the two aliases appended to it.
    static let plantAliases = "\ntypealias SignatureCheck = DecisionVerifier\ntypealias SignedReading = DecisionEvidence\n"

    /// `sources` plus a new file, read as `uncutSources()` reads a file.
    static func adding(_ sources: Sources, _ name: String, _ text: String) -> Sources {
        sources + [(name, LidGuardStructureTests.wholeLineCommentsRemoved(text))]
    }

    // MARK: 9a. Nothing re-declares or extends what the check is spelled in

    /// What the verifier's check and the canonical bytes are reached by, and
    /// the one file that may declare each (nil: none in the four targets —
    /// CryptoKit's own). A declaration anywhere else is an overload that may
    /// outrank the pinned call, as P2' did, whatever type it extends.
    static let checkNames: [(name: String, home: String?)] = [
        ("isValidSignature", nil), ("hash", nil),
        ("decisionMessage", signingPath), ("shownDigestInput", signingPath),
    ]

    /// The CryptoKit types the check is spelled in (none has a home in the
    /// four targets), and the canonical-bytes enum, extended only in its own
    /// file — named by its path (#244: by its file name alone, read before,
    /// a file under its name in another target could declare the canonical
    /// builders and extend the enum).
    static let cryptoTypes = ["P256", "SHA256", "SHA256Digest", "Digest", "HMAC", "SymmetricKey"]
    static let signingPath = "Sources/NapCatWire/ApprovalSigning.swift"

    /// A declaration of `name`, however the gap after its keyword is spelled.
    static func declarationPattern(_ name: String) -> String {
        #"\b(?:func|var|let|case)"# + gap + "+" + name + #"\b"#
    }

    /// An extension of one of `types` (named anywhere in its header, so a
    /// module prefix, a member type or a `where Self ==` all count), or an
    /// alias of one, the road to `extension Alias`: named on its line, or
    /// first after its `=` and a gap that runs onto the next line.
    static func extensionPatterns(_ types: [String]) -> [String] {
        let type = "(?:" + types.joined(separator: "|") + ")"
        let aliased = #"\btypealias\b[^=\n{}]*="# + gap + #"*(?:\("# + gap + #"*)?(?:\w+"# + gap + #"*\."# + gap + "*)?"
            + type + #"\b"#
        return [#"\bextension\b[^{]*?\b"# + type + #"\b"#, #"\btypealias\b[^\n]*\b"# + type + #"\b"#, aliased]
    }

    /// `sources`: `uncutPathSources()` (#244).
    static func cryptoMeaningFailures(_ sources: Sources) -> [String] {
        var failures: [String] = []
        let extended: [(types: [String], home: String?)] = [(cryptoTypes, nil), (["ApprovalSigning"], signingPath)]
        for (name, uncut) in sources {
            for copy in LidGuardStructureTests.constructorScanCopies(uncut) {
                for (declared, home) in checkNames {
                    let found = matches(declarationPattern(declared), in: copy).count
                    if home == name, found != 1 {
                        failures.append("'\(declared)' declared \(found) time(s) in \(name) — exactly once, in its home")
                    } else if home != name, found != 0 {
                        failures.append("'\(declared)' declared in \(name) — only \(home ?? "CryptoKit") declares it, "
                                        + "so no overload outranks the verifier's call")
                    }
                }
                for (types, home) in extended where home != name {
                    for pattern in extensionPatterns(types) where hits(pattern, in: copy) {
                        failures.append("\(types) extended or aliased in \(name) — only \(home ?? "CryptoKit") "
                                        + "defines what they mean")
                    }
                }
            }
        }
        return unique(failures)
    }

    @Test func nothingRedefinesWhatTheVerifiersCheckIsSpelledIn() throws {
        let sources = try Self.uncutPathSources()
        #expect(Self.cryptoMeaningFailures(sources).isEmpty, "\(Self.cryptoMeaningFailures(sources))")
        let verifier = Self.verifierFile
        let checked = "guard pairedKey.isValidSignature(signature, for: SHA256.hash(data: message)) else {"
        #expect(Self.text(verifier, in: sources).contains(checked), "vacuity: the verifier calls the check the lock protects")
        let check = "func isValidSignature(_ s: P256.Signing.ECDSASignature, for d: SHA256Digest) -> Bool { true }"
        let mutants: [(String, Sources)] = [
            // The security review's P2', compiled, as planted.
            ("P2': a conditional overload in a new file", Self.adding(sources, "ZZPlantShadow.swift", Self.plantShadow)),
            // … and its lexical twin (L6), as planted.
            ("L6: a crypto overload shadow in another file", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nextension P256.Signing.PublicKey { func isValidSignature(_ s: P256.Signing.ECDSASignature, "
                    + "for d: SHA256Digest) -> Bool { true } }" }),
            // Protocol-extension variants (each compiled and bit in a scratch
            // probe): the overload on a protocol the key is made to conform
            // to, and a non-generic `hash` on CryptoKit's HashFunction — a
            // type no extension ban names, so only the declaration ban sees it.
            ("a protocol extension the key conforms to", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nprotocol ZZChecks {}\nextension P256.Signing.PublicKey: ZZChecks {}\nextension ZZChecks {\n    "
                    + check + "\n}" }),
            ("its overload alone, on the protocol", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nprotocol ZZChecks {}\nextension ZZChecks {\n    " + check + "\n}" }),
            ("its conformance alone, in a third file", Self.mutate(sources, "LidGuardController.swift") {
                $0 + "\nextension P256.Signing.PublicKey: ZZChecks {}" }),
            ("a non-generic hash on HashFunction", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nextension HashFunction {\n    static func hash(data: [UInt8]) -> Digest { Self.hash(data: Data([0x42])) }\n}" }),
            // Declarations elsewhere, however spelled.
            ("a free check in the verifier", Self.mutate(sources, verifier) { $0 + "\n" + check }),
            ("a backticked declaration", Self.mutate(sources, "NapCatApp.swift") { $0 + "\nfunc `isValidSignature`() {}" }),
            ("a declaration split by a comment", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nstatic func // x\n    hash(data: [UInt8]) -> [UInt8] { [] }" }),
            ("a declaration behind a block comment", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nfunc /* x */ hash<D>(_ d: D) -> Int { 0 }" }),
            ("the canonical bytes rebuilt in the verifier", Self.mutate(sources, verifier) {
                $0 + "\nfunc decisionMessage(wireVersion: Int, promptID: PromptID) -> [UInt8]? { nil }" }),
            ("the shown digest's input redeclared in the app", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nlet shownDigestInput: (String, String, String) -> [UInt8] = { _, _, _ in [] }" }),
            ("a second canonical builder in its home", Self.mutate(sources, Self.signingPath) {
                $0 + "\nextension ApprovalSigning {\n    static func decisionMessage(_ any: Int) -> [UInt8]? { nil }\n}" }),
            ("the home's builder renamed away", Self.mutate(sources, Self.signingPath) {
                $0.replacingOccurrences(of: "public static func shownDigestInput(", with: "public static func shownInput(") }),
            // Extensions of each type, however the header is spelled.
            ("a module-qualified digest extension", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nextension CryptoKit.SHA256Digest: @retroactive ExpressibleByIntegerLiteral {}" }),
            ("the hash function extended", Self.mutate(sources, "NapCatApp.swift") { $0 + "\nextension SHA256 { static let zz = 1 }" }),
            ("the digest protocol extended", Self.mutate(sources, "NapCatApp.swift") { $0 + "\nextension `Digest` { var zz: Int { 0 } }" }),
            ("a constrained MAC", Self.mutate(sources, "NapCatApp.swift") { $0 + "\nextension HMAC where H == SHA256 {}" }),
            ("a symmetric key behind a block comment", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nextension /* x */ SymmetricKey {}" }),
            ("a where Self == header split by a comment", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nextension ZZChecks // x\n    where Self == P256.Signing.ECDSASignature {}" }),
            ("the canonical bytes extended elsewhere", Self.mutate(sources, verifier) {
                $0 + "\nextension NapCatWire.ApprovalSigning {}" }),
            ("an alias, then its extension", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\ntypealias ZZKey = P256.Signing.PublicKey\nextension ZZKey {}" }),
            ("an alias split after its =", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\ntypealias ZZSigning = // x\n    (NapCatWire.ApprovalSigning)" }),
            ("the canonical bytes aliased elsewhere", Self.mutate(sources, verifier) { $0 + "\ntypealias Bytes = ApprovalSigning" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.cryptoMeaningFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: CALLS to the check, the hash and the builders
        // (the verifier's own, and a test's), names that only contain the
        // banned ones, an extension of the canonical bytes in its own file,
        // extensions of other types, and a whole-line comment naming them.
        #expect(Self.cryptoMeaningFailures(Self.mutate(Self.mutate(sources, "NapCatApp.swift") {
            $0 + "\nlet ok = key.isValidSignature(sig, for: SHA256.hash(data: message))\nlet hashed = SHA256.hash(data: d)"
                + "\nlet m = ApprovalSigning.decisionMessage(wireVersion: 1, promptID: p, verdict: .allow, decidedAt: 1, shownDigest: s)"
                + "\nfunc rehash() {}\nlet hashValue = 0\nvar isValidSignatureCount = 0\nextension DigestBox {}\nextension HMACRecord {}"
                + "\nextension ApprovalSigningVectors {}\nextension SHA256Holder {}"
                + LidGuardStructureTests.wholeLineCommentsRemoved(
                    "\n/// never func isValidSignature, never extension P256, never typealias K = SHA256Digest")
        }, Self.signingPath) { $0 + "\nextension ApprovalSigning {}" }).isEmpty)
        // #244: the canonical bytes' home is the NapCatWire file, by path. A
        // file under its name in each other target that declares each builder
        // once and extends the enum, or holds the home's own text, is named,
        // by its path.
        let home = Self.text(Self.signingPath, in: sources)
        #expect(home.contains("public static func decisionMessage(") && home.contains("public static func shownDigestInput("),
                "vacuity: the home is read, by path, and declares both builders")
        let builders = "extension ApprovalSigning {\n    static func decisionMessage(zz: Int) -> [UInt8]? { nil }\n"
            + "    static func shownDigestInput(zz: Int) -> [UInt8] { [] }\n}\n"
        let namesakes = ApprovalChannelStructureTests.namesakes(of: Self.signingPath)
        #expect(namesakes.count == 3, "vacuity: a namesake in each other target")
        for path in namesakes {
            for (kind, text) in [("the builders and an extension", builders), ("the home's twin", home)] {
                let mutant = ApprovalChannelStructureTests.inserting(sources, path, text)
                let failures = Self.cryptoMeaningFailures(mutant)
                let declared: String = "'decisionMessage' declared in \(path) — only \(Self.signingPath) declares it, "
                    + "so no overload outranks the verifier's call"
                #expect(mutant.count == sources.count + 1, "canary '\(kind)' at \(path) did not apply")
                #expect(failures.contains(declared) && ApprovalChannelStructureTests.names(failures, path),
                        "canary '\(kind)' at \(path) was NOT named by the check-name lock: \(failures)")
            }
        }
        // Each pattern compiles and bites through the lock's own engine.
        let probes: [(String, String)] = [
            (Self.declarationPattern("hash"), "static func\n    hash(data: D)"),
            (Self.declarationPattern("isValidSignature"), "var /* x */ isValidSignature: Bool"),
            (Self.extensionPatterns(Self.cryptoTypes)[0], "extension ZZ\n    where Self == P256.Signing.PublicKey {"),
            (Self.extensionPatterns(Self.cryptoTypes)[1], "typealias D = SHA256Digest"),
            (Self.extensionPatterns(Self.cryptoTypes)[2], "typealias K<T> = /* x */\n    ( CryptoKit . HMAC<T>)"),
        ]
        for (pattern, probe) in probes {
            #expect(Self.hits(pattern, in: probe), "'\(pattern)' does not match '\(probe)'")
        }
    }

    // MARK: 9b. Unsafe memory and the S0 type's name, pinned

    /// The unsafe-memory operations a decision is forged with without a
    /// construction (P1, P1', L1a–c): a bit cast, and every pointer
    /// rebinding or typed load. Whole words (a member access or a call for
    /// `load`), so `payload`, `reload()` and `isLoaded` pass.
    static let unsafeMemoryPattern =
        #"\b(?:unsafeBitCast|bindMemory|assumingMemoryBound|withMemoryRebound|initializeMemory)\b"#
            + #"|\.\s*load(?:Unaligned)?\b|\bload(?:Unaligned)?\s*\("#

    /// Today's unsafe-memory sites in the four targets, exactly: the lock
    /// function's `dlsym` cast, and the seam's two `sockaddr` rebindings.
    static let unsafeMemorySites: [String: [String: Int]] = [
        "ScreenLockController.swift": ["return unsafeBitCast(symbol, to: LockFunction.self)": 1],
        ApprovalChannelStructureTests.seamFile: ["$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {": 2],
    ]

    /// Every line naming the S0 type outside its declaring file, exactly:
    /// the verifier's payload and its one construction. A forge that names
    /// the type (P1, L1a–c) adds a line. AMENDED for S-PAIR-C2 (#181),
    /// deliberately: the intake's parameter and the verifier's optional
    /// return left the list — the intake takes the verifier's result alone,
    /// and `verify` returns that result.
    static let decisionTokenSites: [String: [String: Int]] = [
        verifierFile: ["case verified(ApprovalDecision)": 1, verifiedConstruction: 1],
    ]

    /// `sources`: `uncutSources()`.
    static func pinnedSiteFailures(_ sources: Sources) -> [String] {
        var failures: [String] = []
        for (name, uncut) in sources {
            for copy in LidGuardStructureTests.constructorScanCopies(uncut) {
                failures += siteFailures(unsafeMemoryPattern, in: copy, file: name, allowed: unsafeMemorySites[name] ?? [:],
                                         rule: "unsafe memory stays at today's sites — a decision is never forged from bytes")
                if name != declaringFile {
                    failures += siteFailures(#"\bApprovalDecision\b"#, in: copy, file: name,
                                             allowed: decisionTokenSites[name] ?? [:],
                                             rule: "the S0 type is named only at today's sites outside its own file")
                }
            }
        }
        return unique(failures)
    }

    @Test func unsafeMemoryAndTheDecisionTypesNameStayAtTodaysSites() throws {
        let sources = try Self.uncutSources()
        #expect(Self.pinnedSiteFailures(sources).isEmpty, "\(Self.pinnedSiteFailures(sources))")
        let lock = "ScreenLockController.swift"
        let seam = ApprovalChannelStructureTests.seamFile
        let rebound = "$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {"
        #expect(ApprovalChannelStructureTests.count(rebound, in: Self.text(seam, in: sources)) == 2, "vacuity: the seam's two sites")
        let forgeTail: String = "import NapCatWire\n\n" + Self.plantForgeTail
        let mutants: [(String, Sources)] = [
            // The security review's P1 and P1', compiled, as planted (one file).
            ("P1 and P1': the forge, as planted", Self.adding(sources, "ZZPlantForge.swift", Self.plantForgeHead + Self.plantForgeTail)),
            ("P1': a type-inferred forge, no S0 name at all", Self.adding(sources, "ZZPlantForge.swift", forgeTail)),
            // The review's lexical plants, as planted.
            ("L1a: a bit cast to Optional<T>.self", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nfunc zz(_ id: PromptID) -> ApprovalDecision? { unsafeBitCast((id, ApprovalWire.Verdict.allow, 1, true), "
                    + "to: Optional<ApprovalDecision>.self) }" }),
            ("L1b: a bit cast to (T).self", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nlet zz = unsafeBitCast((p, ApprovalWire.Verdict.allow, 1, true), to: (ApprovalDecision).self)" }),
            ("L1c: a pointer load", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nfunc zz(_ t: inout (PromptID, ApprovalWire.Verdict, Int, Bool)) -> ApprovalDecision { withUnsafePointer(to: &t) "
                    + "{ UnsafeRawPointer($0).load(as: [ApprovalDecision].Element.self) } }" }),
            // Each operation, with no S0 name: only the unsafe-memory pin sees it.
            ("a generic offset load", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nfunc zz<T>(_ r: UnsafeRawPointer) -> T { r.load(fromByteOffset: 0, as: T.self) }" }),
            ("an unaligned load", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nfunc zz<T>(_ r: UnsafeRawBufferPointer) -> T { r . loadUnaligned(as: T.self) }" }),
            ("a bound pointer", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nfunc zz<T>(_ r: UnsafeMutableRawPointer) -> T { r.bindMemory(to: T.self, capacity: 1).pointee }" }),
            ("an assumed binding", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nfunc zz<T>(_ r: UnsafeRawPointer) -> T { r.assumingMemoryBound(to: T.self).pointee }" }),
            ("initialized memory", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nfunc zz<T>(_ r: UnsafeMutableRawPointer, _ v: T) { _ = r.initializeMemory(as: T.self, repeating: v, count: 1) }" }),
            ("an unapplied bit cast", Self.mutate(sources, "NapCatApp.swift") { $0 + "\nlet zzCast: (Int, Int.Type) -> Int = unsafeBitCast" }),
            ("a third rebinding in the seam", Self.mutate(sources, seam) { $0 + "\nfunc zz(_ p: UnsafeMutablePointer<Int>) { "
                + "p.withMemoryRebound(to: UInt.self, capacity: 1) { _ in } }" }),
            ("a second cast beside the pinned one", Self.mutate(sources, lock) { $0 + "\nlet zz = unsafeBitCast(0, to: UInt.self)" }),
            ("a pinned site gone", Self.mutate(sources, lock) {
                $0.replacingOccurrences(of: "return unsafeBitCast(symbol, to: LockFunction.self)", with: "return nil") }),
            ("one of the seam's two sites respelled", Self.mutate(sources, seam) {
                $0.replacingOccurrences(of: rebound, with: "$0.withMemoryRebound(to: sockaddr.self, capacity: 2) {",
                                        range: $0.range(of: rebound)) }),
            // The S0 type named on a new line, however spelled.
            ("the type as a parameter in a third file", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nfunc zz(_ d: ApprovalDecision) {}" }),
            ("the type module-qualified and backticked", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nvar zz: NapCatWire.`ApprovalDecision`?" }),
            ("a second line in the verifier", Self.mutate(sources, Self.verifierFile) {
                $0 + "\nenum ZZLast { static var decision: ApprovalDecision? }" }),
            ("a second line in the intake", Self.mutate(sources, ApprovalChannelStructureTests.intakeFile) {
                $0 + "\nfunc zz(_ all: [ApprovalDecision]) {}" }),
            ("a wire file names it", Self.mutate(sources, "ApprovalWire.swift") { $0 + "\nlet zz: ApprovalDecision? = nil" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.pinnedSiteFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: words that only contain the banned ones, the
        // S0 type's longer-named neighbours, other safe pointer uses, and a
        // whole-line comment naming them.
        #expect(Self.pinnedSiteFailures(Self.mutate(sources, "NapCatApp.swift") {
            $0 + "\nlet payload = 1\nfunc reload() {}\nlet isLoaded = true\nfunc download(_ u: URL) {}\nlet loadFactor = 0.5"
                + "\nstruct ApprovalDecisionLog {}\nlet approvalDecisions = 0\nlet n = withUnsafeBytes(of: 1) { $0.count }"
                + LidGuardStructureTests.wholeLineCommentsRemoved(
                    "\n/// never unsafeBitCast(…, to: ApprovalDecision?.self), never p.load(as:)")
        }).isEmpty)
        // The pattern bites through the lock's own engine, every operation.
        for probe in ["unsafeBitCast(x, to: T.self)", "p.bindMemory(to: T.self, capacity: 1)", "p.assumingMemoryBound(to: T.self)",
                      "$0.withMemoryRebound(to: T.self, capacity: 1)", "p.initializeMemory(as: T.self, to: v)",
                      "p.load(as: T.self)", "p.load(fromByteOffset: 8, as: T.self)", "p.loadUnaligned(as: T.self)", "load (as: T.self)"] {
            #expect(Self.hits(Self.unsafeMemoryPattern, in: probe), "the unsafe-memory pattern does not match '\(probe)'")
        }
    }

    // MARK: 9c. The signature check is one adjacent block

    /// The guard, its refusal, its closing brace and the construction, on
    /// adjacent lines, once: nothing runs between the check and the decision,
    /// and nothing can leave the guard pinned but dead (L3).
    static let signatureCheckBlock = [
        "        guard pairedKey.isValidSignature(signature, for: SHA256.hash(data: message)) else {",
        "            return .unverified(signedAnotherForm(claimed, of: copy, signature, pairedKey) ? .shownDigestMismatch : .signatureInvalid)",
        "        }",
        "        " + verifiedConstruction,
    ].joined(separator: "\n") + "\n"

    /// The diagnostic's two sites in the four targets: its declaration, and
    /// its one call, in the refusal (its answer only names the refusal).
    static let diagnosticSites = [
        "return .unverified(signedAnotherForm(claimed, of: copy, signature, pairedKey) ? .shownDigestMismatch : .signatureInvalid)": 1,
        "static func signedAnotherForm(_ claimed: Claimed, of copy: ForwardedCopy, _ signature: P256.Signing.ECDSASignature,": 1,
    ]

    /// `sources`: `uncutSources()`.
    static func signatureBlockFailures(_ sources: Sources) -> [String] {
        guard sources.contains(where: { $0.name == verifierFile }) else {
            return ["\(verifierFile) not found — the signature-block lock would be vacuous"]
        }
        var failures: [String] = []
        for (name, uncut) in sources {
            for copy in LidGuardStructureTests.constructorScanCopies(uncut) {
                failures += siteFailures(#"\bsignedAnotherForm\b"#, in: copy, file: name,
                                         allowed: name == verifierFile ? diagnosticSites : [:],
                                         rule: "the diagnostic is declared once and called only from the signature check's refusal")
                if name == verifierFile, ApprovalChannelStructureTests.count(signatureCheckBlock, in: copy) != 1 {
                    failures.append("the signature check is one adjacent block in \(verifierFile) — the guard, its refusal, "
                                    + "its brace, then the construction — exactly once")
                }
            }
        }
        return unique(failures)
    }

    @Test func theSignatureCheckIsOneAdjacentBlock() throws {
        let sources = try Self.uncutSources()
        #expect(Self.signatureBlockFailures(sources).isEmpty, "\(Self.signatureBlockFailures(sources))")
        let verifier = Self.verifierFile
        let checked = "        guard pairedKey.isValidSignature(signature, for: SHA256.hash(data: message)) else {\n"
        let built = "        " + Self.verifiedConstruction + "\n"
        let refused = "            return .unverified(signedAnotherForm(claimed, of: copy, signature, pairedKey) ? "
            + ".shownDigestMismatch : .signatureInvalid)\n        }\n"
        #expect(checked + refused + built == Self.signatureCheckBlock, "vacuity: the block is the review's anchors, adjacent")
        let mutants: [(String, Sources)] = [
            // The security review's L3, as planted.
            ("L3: a dead pinned guard, a live OR", Self.mutate(sources, verifier) {
                $0.replacingOccurrences(of: checked + refused + built, with: "        _ = { () -> Bool in\n" + checked
                    + "            return false\n        }\n        return true }\n"
                    + "        if pairedKey.isValidSignature(signature, for: SHA256.hash(data: message)) || "
                    + "signedAnotherForm(claimed, of: copy, signature, pairedKey) {\n" + built + "        }\n"
                    + "        return .unverified(.signatureInvalid)\n") }),
            // The whole block kept, but dead: a live OR after it.
            ("the block kept whole inside a dead closure", Self.mutate(sources, verifier) {
                $0.replacingOccurrences(of: checked + refused + built, with: "        _ = { () -> DecisionVerification in\n"
                    + checked + refused + built + "        }\n        guard signedAnotherForm(claimed, of: copy, signature, pairedKey) "
                    + "else { return .unverified(.signatureInvalid) }\n") }),
            ("a statement between the brace and the construction", Self.mutate(sources, verifier) {
                $0.replacingOccurrences(of: refused + built, with: refused + "        _ = signature\n" + built) }),
            ("the refusal reworded", Self.mutate(sources, verifier) {
                $0.replacingOccurrences(of: "? .shownDigestMismatch : .signatureInvalid)", with: "? .signatureInvalid : .signatureInvalid)") }),
            ("the guard and the refusal on one line", Self.mutate(sources, verifier) {
                $0.replacingOccurrences(of: "else {\n            return .unverified(signedAnotherForm",
                                        with: "else { return .unverified(signedAnotherForm") }),
            ("the diagnostic called twice", Self.mutate(sources, verifier) {
                $0.replacingOccurrences(of: built, with: "        _ = signedAnotherForm(claimed, of: copy, signature, pairedKey)\n" + built) }),
            ("an unapplied diagnostic", Self.mutate(sources, verifier) { $0 + "\nlet zzDiagnose = DecisionVerifier.signedAnotherForm" }),
            ("the diagnostic reached from another file", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nlet zz = signedAnotherForm" }),
            ("the block gone", Self.mutate(sources, verifier) { $0.replacingOccurrences(of: checked, with: "") }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.signatureBlockFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: a name that only starts like the diagnostic's,
        // and a whole-line comment naming it.
        #expect(Self.signatureBlockFailures(Self.mutate(sources, "NapCatApp.swift") {
            $0 + "\nlet signedAnotherFormCount = 0"
                + LidGuardStructureTests.wholeLineCommentsRemoved("\n/// never signedAnotherForm(…) outside the verifier's refusal")
        }).isEmpty)
    }

    // MARK: 9d. The verifier's top level is exactly its types

    /// The verifier's top level as `topLevel` reads it: its four imports and
    /// its seven types, each body elided.
    static let verifierTopLevel = [
        "import CryptoKit", "import Foundation", "import NapCatWire", "import os",
        "struct DecisionEvidence: Sendable { }", "struct ForwardedCopy: Sendable { }",
        "enum DecisionUnverifiedReason: String, CaseIterable, Sendable { }", "enum DecisionVerification: Equatable, Sendable { }",
        "struct DecisionVerifierAudit: Equatable, Sendable { }", "enum DecisionVerifier { }", "enum DecisionVerifierLog { }",
    ].joined(separator: " ")

    /// `text`'s top level, read through `lexemes`: every comment and literal
    /// read as a space, every brace-delimited body elided to `{ }`, and the
    /// whitespace flattened.
    static func topLevel(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        let kinds = LidGuardStructureTests.lexemes(scalars)
        var top = String.UnicodeScalarView()
        var depth = 0
        for index in scalars.indices {
            let scalar = scalars[index]
            if kinds[index] != .code {
                if depth == 0 { top.append(" ") }
            } else if scalar == "{" {
                if depth == 0 { top.append(contentsOf: " { ".unicodeScalars) }
                depth += 1
            } else if scalar == "}" {
                depth = max(depth - 1, 0)
                if depth == 0 { top.append(contentsOf: " } ".unicodeScalars) }
            } else if depth == 0 {
                top.append(scalar)
            }
        }
        return MenuPanelStructureTests.flat(String(top))
    }

    /// `sources`: `uncutSources()`.
    static func verifierTopLevelFailures(_ sources: Sources) -> [String] {
        let uncut = text(verifierFile, in: sources)
        var failures: [String] = []
        let top = topLevel(uncut)
        if top != verifierTopLevel {
            failures.append("\(verifierFile)'s top level is exactly its imports and its seven types — read '\(top)'")
        }
        for copy in LidGuardStructureTests.constructorScanCopies(uncut) where hits(#"\b(?:typealias|extension)\b"#, in: copy) {
            failures.append("a typealias or an extension in \(verifierFile) — nothing re-exports the verifier or what it builds")
        }
        return unique(failures)
    }

    @Test func theVerifiersTopLevelIsExactlyItsTypes() throws {
        let sources = try Self.uncutSources()
        #expect(Self.verifierTopLevelFailures(sources).isEmpty, "\(Self.verifierTopLevelFailures(sources))")
        let verifier = Self.verifierFile
        let mutants: [(String, Sources)] = [
            // The security review's P3, compiled, as planted (both files).
            ("P3: aliases in the verifier, wired from a new file", Self.adding(Self.mutate(sources, verifier) {
                $0 + Self.plantAliases }, "ZZPlantWiring.swift", Self.plantWiring)),
            // … and its lexical twins, L4 and L5, as planted.
            ("L4: an alias export, the intake decides", Self.mutate(Self.mutate(sources, verifier) {
                $0 + "\ntypealias SignatureCheck = DecisionVerifier\ntypealias SignedReading = DecisionEvidence" },
                ApprovalChannelStructureTests.intakeFile) {
                $0 + "\nextension ApprovalIntake { func zz(_ r: SignedReading) { if let d = SignatureCheck.verify(r, copy: nil, "
                    + "pairedKey: nil) { decide(d) } } }" }),
            ("L5: an extension export on PromptID", Self.mutate(Self.mutate(sources, verifier) {
                $0 + "\nextension PromptID { func zzChecked(_ e: DecisionEvidence) -> ApprovalDecision? { "
                    + "DecisionVerifier.verify(e, copy: nil, pairedKey: nil) } }" }, "MenuStateModel.swift") {
                $0 + "\nlet zzd = PromptID(high: 1, low: 1)?.zzChecked(e)" }),
            // Other top-level roads out.
            ("a top-level function", Self.mutate(sources, verifier) {
                $0 + "\nfunc zzExport(_ e: DecisionEvidence) -> Any? { DecisionVerifier.verify(e, copy: nil, pairedKey: nil) }" }),
            ("a top-level closure", Self.mutate(sources, verifier) { $0 + "\nlet zzVerify = DecisionVerifier.verify" }),
            ("an eighth type", Self.mutate(sources, verifier) { $0 + "\nstruct ZZRelay { static let check = DecisionVerifier.self }" }),
            ("a conditional alias", Self.mutate(sources, verifier) { $0 + "\n#if DEBUG\ntypealias Check = DecisionVerifier\n#endif" }),
            ("a nested alias", Self.mutate(sources, verifier) {
                $0.replacingOccurrences(of: "enum DecisionVerifierLog {\n",
                                        with: "enum DecisionVerifierLog {\n    typealias V = DecisionVerifier\n") }),
            ("a backticked alias", Self.mutate(sources, verifier) { $0 + "\ntypealias `Check` = DecisionVerifier" }),
            ("an alias behind a block comment", Self.mutate(sources, verifier) { $0 + "\ntypealias /* x */ Check = DecisionVerifier" }),
            ("a conformance added", Self.mutate(sources, verifier) {
                $0.replacingOccurrences(of: "struct ForwardedCopy: Sendable {", with: "struct ForwardedCopy: Sendable, Hashable {") }),
            ("a type renamed", Self.mutate(sources, verifier) {
                $0.replacingOccurrences(of: "enum DecisionVerifierLog {", with: "enum DecisionLog {") }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.verifierTopLevelFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: members, literals and trailing comments that
        // hold braces or the banned words inside a type, a whole-line comment
        // at the top level, and names that only contain the banned words.
        #expect(Self.verifierTopLevelFailures(Self.mutate(sources, verifier) {
            $0.replacingOccurrences(of: "enum DecisionVerifierLog {\n", with: "enum DecisionVerifierLog {\n"
                + "    static let braces = \"} {\" // a }\n    static let extensionCount = 0\n    static let aliasName = \"x\"\n")
                + LidGuardStructureTests.wholeLineCommentsRemoved("\n// never typealias, never extension, never func zz() {}")
        }).isEmpty)
    }

    // MARK: 9e. No Mac source signs

    /// A private key of any kind (CryptoKit's or the enclave's), and a
    /// signing call, however the gap before its label is spelled. The Mac
    /// verifies with the paired phone's public key only; the tests sign.
    static let signingPatterns = ["PrivateKey", #"\bsignature"# + gap + #"*\("# + gap + #"*for\b"#]

    /// `sources`: `uncutSources()`.
    static func signingFailures(_ sources: Sources) -> [String] {
        var failures: [String] = []
        for (name, uncut) in sources {
            for copy in LidGuardStructureTests.constructorScanCopies(uncut) {
                for pattern in signingPatterns where hits(pattern, in: copy) {
                    failures.append("'\(pattern)' in \(name) — the Mac verifies only: it holds no private key and signs nothing")
                }
            }
        }
        return unique(failures)
    }

    @Test func noMacSourceHoldsAPrivateKeyOrSigns() throws {
        let sources = try Self.uncutSources()
        #expect(Self.signingFailures(sources).isEmpty, "\(Self.signingFailures(sources))")
        let verifier = Self.verifierFile
        let checked = "        guard pairedKey.isValidSignature(signature, for: SHA256.hash(data: message)) else {\n"
        let built = "        " + Self.verifiedConstruction + "\n"
        let refused = "            return .unverified(signedAnotherForm(claimed, of: copy, signature, pairedKey) ? "
            + ".shownDigestMismatch : .signatureInvalid)\n        }\n"
        let mutants: [(String, Sources)] = [
            // The security review's L2, as planted: the verifier mints its own
            // software key in a do-scope and checks against it.
            ("L2: the verifier mints its own key", Self.mutate(sources, verifier) {
                $0.replacingOccurrences(of: checked + refused + built,
                    with: "        do {\n        let minted = P256.Signing.PrivateKey()\n        let pairedKey = minted.publicKey\n"
                        + "        let signature = try! minted.signature(for: SHA256.hash(data: message))\n"
                        + checked + "            return .unverified(.signatureInvalid)\n        }\n" + built + "        }\n") }),
            ("an enclave key in the app", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nlet zz = try? SecureEnclave.P256.Signing.PrivateKey()" }),
            ("another curve's key in a wire file", Self.mutate(sources, "ApprovalWire.swift") {
                $0 + "\nlet zz: Curve25519.Signing.PrivateKey? = nil" }),
            ("a signing call, backticked", Self.mutate(sources, "NapCatApp.swift") { $0 + "\nlet s = try k.`signature`(for: d)" }),
            ("a signing call behind a block comment", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nlet s = try k.signature /* x */ (for: d)" }),
            ("a signing call split by a comment", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nlet s = try k.signature( // x\n    for: d)" }),
            ("an unapplied signing call", Self.mutate(sources, "NapCatApp.swift") { $0 + "\nlet sign = k.signature(for:)" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.signingFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: the verifier's own parse and check, a public
        // key, names that only contain the banned words, and a whole-line
        // comment naming them. (The test files, which sign, are not read.)
        #expect(Self.text(verifier, in: sources).contains("pairedKey.isValidSignature(signature, for:"),
                "vacuity: the verifier's own check names `signature, for:` and passes")
        #expect(Self.signingFailures(Self.mutate(sources, "NapCatApp.swift") {
            $0 + "\nlet signature = try? P256.Signing.ECDSASignature(rawRepresentation: s)\nlet k: P256.Signing.PublicKey? = nil"
                + "\nfunc signatures(for d: Int) {}\nlet privateKeyCount = 0\nlet ok = k?.isValidSignature(signature!, for: d)"
                + LidGuardStructureTests.wholeLineCommentsRemoved("\n/// never a PrivateKey, never signature(for:)")
        }).isEmpty)
    }

    // MARK: 9f. The paired key is read at each verification, and kept nowhere (S-PAIR-C2)

    /// S-PAIR-C2 (#181): the verifier obtains the paired key through the
    /// slot's `read()` alone, at the moment of each verification, so no key
    /// outlives an Unpair (`DecisionVerifierTests` shows it by example). The
    /// behaviour cannot show that nothing else feeds the checks, so, in every
    /// scan copy of `uncutSources()`:
    /// - in the verifier, the slot is named at its entry and read once, on
    ///   the line that turns the paired phone's bytes into the key; those
    ///   bytes are read on the next line alone; and the key is named where
    ///   it is read, handed to the checks and checked — no reading handed in
    ///   (a C1 security review probe's shape), no key kept;
    /// - the checks (`verification(of:copy:pairedKey:)`, which take a key)
    ///   are reached from that entry alone: outside the verifier nothing
    ///   names `pairedKey` or reaches the checks by name;
    /// - the intake hands the slot on untouched, at its one call;
    /// - a P-256 public key is named at today's sites only, in the four
    ///   targets: the slot's validation, the ceremony's proof check and the
    ///   verifier's own — so no file can make or hold another.
    static let slotRead: String = "let pairedKey: P256.Signing.PublicKey? = switch keys.read() {"
    static let keyFromSlot: String = "case .paired(let phone): try? P256.Signing.PublicKey(x963Representation: phone.publicKey)"
    static let verifierEntry: String = "static func verify(_ evidence: DecisionEvidence, copy: ForwardedCopy?, keys: PairedKeyStore,"
    static let checksCall: String = "let verification = verification(of: evidence, copy: copy, pairedKey: pairedKey)"
    static let verifierKeySites: [(pattern: String, allowed: [String: Int], rule: String)] = [
        (#"\bkeys\b"#, [verifierEntry: 1, slotRead: 1], "the verifier's entry takes the slot and reads it, once"),
        (#"\bread\b"#, [slotRead: 1], "the verifier reads the slot at one site, at each verification"),
        (#"\bpublicKey\b"#, [keyFromSlot: 1], "the key is the paired phone's bytes as the slot holds them now"),
        (#"\bpairedKey\b"#, [slotRead: 1, checksCall: 2, "pairedKey: P256.Signing.PublicKey?) -> DecisionVerification {": 1,
                              "guard let pairedKey else { return .unverified(.noPairedKey) }": 1,
                              "guard pairedKey.isValidSignature(signature, for: SHA256.hash(data: message)) else {": 1,
                              "return .unverified(signedAnotherForm(claimed, of: copy, signature, pairedKey) ? .shownDigestMismatch : .signatureInvalid)": 1,
                              "_ pairedKey: P256.Signing.PublicKey) -> Bool {": 1,
                              "if pairedKey.isValidSignature(signature, for: SHA256.hash(data: message)) { return true }": 1],
         "the key read now is handed to the checks and checked, and named nowhere else"),
        (#"\bverification\b"#, ["static func verification(of evidence: DecisionEvidence, copy: ForwardedCopy?,": 1, checksCall: 2,
                                 "if case .unverified(let reason) = verification {": 1, "return verification": 1],
         "the checks are reached from the verifier's entry alone"),
    ]
    /// The intake's `keys`: taken at its decision entry, handed to the verifier.
    static let intakeKeySites: [String: Int] = ["func receiveDecision(_ evidence: DecisionEvidence, copy: ForwardedCopy?, keys: PairedKeyStore,": 1,
                                 wiredCall: 2]
    /// Every line naming a public key type in the four targets.
    static let publicKeySites: [String: [String: Int]] = [
        verifierFile: [slotRead: 1, keyFromSlot: 1, "pairedKey: P256.Signing.PublicKey?) -> DecisionVerification {": 1,
                       "_ pairedKey: P256.Signing.PublicKey) -> Bool {": 1],
        PairingStructureTests.slotFile: ["(try? P256.Signing.PublicKey(x963Representation: publicKey)) != nil,": 1],
        PairingStructureTests.ceremonyFile: ["let key = try? P256.Signing.PublicKey(x963Representation: response.publicKey),": 1],
    ]

    /// `sources`: `uncutSources()`.
    static func keyReadFailures(_ sources: Sources) -> [String] {
        guard text(verifierFile, in: sources).contains(slotRead) else {
            return ["'\(slotRead)' not found in \(verifierFile) — the key-read lock would be vacuous"]
        }
        var failures: [String] = []
        for (name, uncut) in sources {
            for copy in LidGuardStructureTests.constructorScanCopies(uncut) {
                if name == verifierFile {
                    for (pattern, allowed, rule) in verifierKeySites {
                        failures += siteFailures(pattern, in: copy, file: name, allowed: allowed, rule: rule)
                    }
                } else {
                    failures += siteFailures(#"\bpairedKey\b|\.\s*verification\b|\bverification\s*\("#, in: copy, file: name,
                                             allowed: [:], rule: "nothing outside the verifier hands its checks a key")
                }
                if name == ApprovalChannelStructureTests.intakeFile {
                    failures += siteFailures(#"\bkeys\b"#, in: copy, file: name, allowed: intakeKeySites,
                                             rule: "the intake hands the slot to the verifier untouched, at its one call")
                }
                failures += siteFailures(#"\bPublicKey\b"#, in: copy, file: name, allowed: publicKeySites[name] ?? [:],
                                         rule: "a public key is named at today's sites only — none is made or kept elsewhere")
            }
        }
        return unique(failures)
    }

    @Test func thePairedKeyIsReadAtEachVerificationAndKeptNowhere() throws {
        let sources = try Self.uncutSources()
        #expect(Self.keyReadFailures(sources).isEmpty, "\(Self.keyReadFailures(sources))")
        let verifier = Self.verifierFile
        let head: String = "enum DecisionVerifier {\n"
        let read: String = "        " + Self.slotRead + "\n"
        #expect(Self.text(verifier, in: sources).contains(head) && Self.text(verifier, in: sources).contains(read),
                "vacuity: the verifier's body and its one read are where the canaries plant")
        let mutants: [(String, Sources)] = [
            // A C1 security review probe, as planted, and in the verifier's body.
            ("the verifier reads the slot through PairedPhoneRead, as the probe planted it", Self.mutate(sources, verifier) {
                $0 + "\nextension DecisionVerifier { static func zz(_ r: PairedPhoneRead) -> [UInt8]? { "
                    + "if case .paired(let p) = r { return p.publicKey }; return nil } }" }),
            ("the same read in the verifier's body", Self.mutate(sources, verifier) {
                $0.replacingOccurrences(of: head, with: head + "    static func zz(_ r: PairedPhoneRead) -> [UInt8]? { "
                    + "if case .paired(let p) = r { return p.publicKey }; return nil }\n") }),
            // A reading handed in, not taken at the verification.
            ("the entry handed a reading", Self.mutate(sources, verifier) {
                $0.replacingOccurrences(of: "switch keys.read() {", with: "switch reading {") }),
            ("the slot read twice", Self.mutate(sources, verifier) {
                $0.replacingOccurrences(of: read, with: "        _ = keys.read()\n" + read) }),
            // A key kept, or another key handed to the checks.
            ("a key kept across verifications", Self.mutate(sources, verifier) {
                $0.replacingOccurrences(of: head, with: head + "    nonisolated(unsafe) static var zzLast: P256.Signing.PublicKey?\n") }),
            ("the checks handed a kept key", Self.mutate(sources, verifier) {
                $0.replacingOccurrences(of: Self.checksCall, with: "let verification = verification(of: evidence, copy: copy, "
                                        + "pairedKey: pairedKey ?? zzLast)") }),
            ("the checks reached from the intake", Self.mutate(sources, ApprovalChannelStructureTests.intakeFile) {
                $0 + "\nfunc zz(e: DecisionEvidence, k: P256.Signing.PublicKey) -> Any { "
                    + "DecisionVerifier.verification(of: e, copy: nil, pairedKey: k) }" }),
            ("the checks reached unapplied", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nlet zz = DecisionVerifier . verification" }),
            ("a key made from the pairing's bytes elsewhere", Self.mutate(sources, "PairingController.swift") {
                $0 + "\nfunc zz(_ b: [UInt8]) -> Any? { try? P256.Signing.PublicKey(x963Representation: b) }" }),
            ("a key held by the host", Self.mutate(sources, ApprovalChannelStructureTests.hostFile) {
                $0 + "\nlet zz: P256.Signing.PublicKey? = nil" }),
            ("the intake keeps the slot", Self.mutate(sources, ApprovalChannelStructureTests.intakeFile) {
                $0.replacingOccurrences(of: "        " + Self.wiredCall, with: "        Self.zzKeys = keys\n        " + Self.wiredCall) }),
            ("a backticked key in a wire file", Self.mutate(sources, "ApprovalWire.swift") {
                $0 + "\nlet zz: P256.Signing.`PublicKey`? = nil" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.keyReadFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: names that only contain the pinned words
        // (`readCount`, `keysSorted`, `publicKeyByteCount`, `verificationTimeout`,
        // `.verificationFailed`), a key type's longer-named neighbour, and a
        // whole-line comment naming them.
        #expect(Self.keyReadFailures(Self.mutate(Self.mutate(sources, verifier) {
            $0.replacingOccurrences(of: head, with: head + "    static let readCount = 0, keysSorted = 1, publicKeyByteCount = 2\n")
        }, "MenuStateModel.swift") {
            $0 + "\nlet verificationTimeout = 1\nlet f = Outcome.verificationFailed\nstruct PublicKeyRow {}"
                + LidGuardStructureTests.wholeLineCommentsRemoved("\n/// never pairedKey: k, never DecisionVerifier.verification(of:)")
        }).isEmpty)
    }

    // MARK: - 4. The record path cannot reach iCloud by itself

    /// The record path builds records and operations, and hands an
    /// operation to its database seam. It never holds a container or a
    /// database, checks an account, queries, subscribes, or adds an
    /// operation to a database itself.
    ///
    /// AMENDED (S-PAIR-C1.5, #170 — deliberate): `CKFetch` left this list for
    /// the allow-list below, which now holds exactly one fetch door,
    /// `CKFetchRecordsOperation` (the pairing record, by ID); every other
    /// `CKFetch…` operation is off the allow-list and fails as before.
    static let iCloudTokens = ["CKContainer", "CKDatabase", "privateCloudDatabase", "publicCloudDatabase",
                               "sharedCloudDatabase", "accountStatus", "CKQuery", "CKSubscription",
                               "CKSyncEngine", "SecTask", ".add(", "URLSession"]

    /// AMENDED after security review 2 (#146): the record path's CloudKit
    /// identifiers are an ALLOW-LIST, exactly the ones it uses, matched as
    /// whole words (`CKRecord` does not cover `CKRecordZone`), so any other
    /// door (`CKFetchRecordZonesOperation`, `CKModifyRecordZonesOperation`, …)
    /// fails by default instead of waiting for its own ban. AMENDED
    /// (S-PAIR-C1.5, #170): widened by exactly what the pairing record's fetch
    /// needs — `CKFetchRecordsOperation` (one record, by its ID); lock 10 pins
    /// where it is built and where it goes.
    static let recordPathCloudKitIdentifiers: Set<String> = [
        "CKRecord", "CKRecordZone", "CKRecordValue", "CKCurrentUserDefaultName",
        "CKModifyRecordsOperation", "CKOperation", "CKError", "CKErrorDomain", "CKFetchRecordsOperation",
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

    /// The two Mac files that may import CloudKit, both in Sources/NapCat
    /// (LidGuardStructureTests owns that table for Sources/NapCat). This lock
    /// scans all four targets, so a re-export from the seam's or the
    /// channel's target cannot carry CloudKit into the app either. Since #241
    /// it reads them as `iCloudSources()` names them, the other three
    /// targets' files by path, so a file there under one of these two names
    /// is not one of them.
    ///
    /// What it sees (`LidGuardStructureTests.cloudKitImport`): an import
    /// declaration of the module in any form, with an attribute
    /// (`@preconcurrency`, `@_exported`, `@testable`) or an access level,
    /// scoped (`import struct CloudKit.CKRecord`), backticked, split over
    /// lines or with a comment inside, and one inside an `#if` block
    /// whatever its condition. What it cannot see: iCloud reached with no
    /// CloudKit import. A `canImport(CloudKit)` condition alone imports
    /// nothing and is not matched. A module from outside the four targets
    /// that re-exported CloudKit, or another framework's iCloud API (Core
    /// Data's CloudKit container, Foundation's ubiquitous key-value store),
    /// reaches iCloud without one, and this lock does not look for either.
    /// A class looked up by name at run time is the lookup ban's
    /// (`PairingStructureTests.objcLookupFailures`).
    static let cloudKitFiles: Set<String> = ["CloudKitMessageSender.swift", recordPathFile]

    /// Lock 4's sources (#241): the files and the form of `uncutSources()`
    /// (whole-line comments removed), Sources/NapCat named by file name and
    /// the other three Mac targets by path from the repository root
    /// (`LidGuardStructureTests.otherTargetSources`, as the URL-loading lock
    /// reads them since #236), so no file outside Sources/NapCat can match a
    /// name in `cloudKitFiles`.
    static func iCloudSources() throws -> Sources {
        try LidGuardStructureTests.swiftSources(LidGuardStructureTests.wholeLineCommentsRemoved)
            + LidGuardStructureTests.otherTargetSources(LidGuardStructureTests.wholeLineCommentsRemoved)
    }

    static let seamConformance =
        #"\b(class|struct|actor|enum|extension)\b[^{\n]*:[^{\n]*\bApprovalRecordDatabase\b"#

    /// `sources`: `iCloudSources()` (#241: `uncutSources()`, read before,
    /// names the other three targets' files by file name alone, so one there
    /// under a sanctioned name passed the import check). The original checks
    /// read the comment-stripped code, as they always did; the
    /// security-review-2 checks read the uncut text.
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
            failures.append("\(name) imports CloudKit — only \(cloudKitFiles.sorted()) in Sources/NapCat may, in any of the four targets")
        }
        return failures
    }

    @Test func theRecordPathCannotReachICloudByItself() throws {
        let withFile = try Self.iCloudSources()
        #expect(Self.vacuityFailures(withFile).isEmpty, "\(Self.vacuityFailures(withFile))")
        #expect(Self.iCloudFailures(withFile).isEmpty, "\(Self.iCloudFailures(withFile))")
        #expect(Self.text(Self.recordPathFile, in: withFile).contains("func submit(_ operation: CKModifyRecordsOperation)"),
                "vacuity: the seam the lock looks at")
        // #241: all four Mac targets are read, in `uncutSources()`'s form,
        // the other three by path (vacuity: each of them holds a file the
        // scan sees), and the two sanctioned names are the two Sources/NapCat
        // files that import CloudKit.
        let bare = try Self.uncutSources()
        #expect(withFile.map { $0.text } == bare.map { $0.text }
                && withFile.map { $0.name.split(separator: "/").last.map(String.init) ?? "" } == bare.map { $0.name },
                "vacuity: lock 4 reads every file of the four targets, as uncutSources() reads it")
        let others = LidGuardStructureTests.networkingOtherTargets
        #expect(ApprovalChannelStructureTests.directories.count == 4 && others.count == 3, "the four Mac targets")
        #expect(Set(withFile.filter { $0.name.contains("/") }.map { $0.name.split(separator: "/").dropLast().joined(separator: "/") })
                == Set(others), "vacuity: every other Mac target is read, each file named by its path")
        #expect(Self.cloudKitFiles.count == 2, "the allow-list is explicit: two names")
        for file in Self.cloudKitFiles.sorted() {
            #expect(Self.text(file, in: withFile).range(of: LidGuardStructureTests.cloudKitImport, options: .regularExpression) != nil,
                    "vacuity: \(file) is in Sources/NapCat and imports CloudKit")
        }
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
    /// imported by a third file, or re-exported by another target). #241:
    /// G2 in each other target, whose files are matched by path, under an
    /// ordinary name or a sanctioned one.
    @Test func nothingRunsARecordOperationButTheSeam() throws {
        let withFile = try Self.iCloudSources()
        #expect(Self.text(Self.recordPathFile, in: withFile).contains("        self.database = database\n"),
                "vacuity: the writer's own seam is the one `.database` the lock lets through")
        #expect(ApprovalChannelStructureTests.directories.count == 4
                && withFile.contains { $0.name == "Sources/NapCatSeam/SeamSocket.swift" },
                "vacuity: the import scan sees the seam's target, by path")
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
            // S-PAIR-C1.5 (#170): the one fetch door allowed is the record
            // fetch by ID (a second one is lock 8's); every other is off-list.
            ("a zone-changes fetch", Self.mutate(withFile, record) {
                $0 + "\nlet f = CKFetchRecordZoneChangesOperation(recordZoneIDs: [], configurationsByRecordZoneID: nil)" }),
            ("a database-changes fetch", Self.mutate(withFile, record) {
                $0 + "\nlet f = CKFetchDatabaseChangesOperation(previousServerChangeToken: nil)" }),
            ("a query", Self.mutate(withFile, record) { $0 + "\nlet q = CKQueryOperation(query: q)" }),
            ("a share", Self.mutate(withFile, record) { $0 + "\nlet s: CKShare? = nil" }),
            ("an allow-listed identifier dropped", Self.mutate(withFile, record) {
                $0.replacingOccurrences(of: "ownerName: CKCurrentUserDefaultName", with: "ownerName: \"__defaultOwner__\"") }),
            // G2: CloudKit imported by a third file, or re-exported by another target.
            ("a third CloudKit file, scoped import (G2)", withFile + [("ZZFetchRecords.swift",
                "import class CloudKit.CKFetchRecordsOperation\nfunc f() { CKFetchRecordsOperation(recordIDs: []).start() }")]),
            ("CloudKit re-exported by the seam's target", Self.mutate(withFile, "Sources/NapCatSeam/SeamSocket.swift") {
                "@_exported import CloudKit\n" + $0 }),
            // The security re-check (#146), N2: a trailing comment inside the import.
            ("a third CloudKit file, trailing-comment import (N2)", withFile + [("ZZN2Fetch.swift",
                "import // fetch only\n    CloudKit\nfunc n2() { CKFetchRecordsOperation(recordIDs: []).start() }")]),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != withFile.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.iCloudFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // #241: a CloudKit import at the top of a file of each other target,
        // in the forms the matcher sees; a new file there; and a file under
        // each sanctioned name in each other target. The import check itself
        // names each, by its path.
        func atTop(_ path: String, _ line: String) -> (String, Sources) { (path, Self.mutate(withFile, path) { line + $0 }) }
        func added(_ path: String, _ text: String) -> (String, Sources) { (path, withFile + [(name: path, text: text)]) }
        let forms: [(String, Sources)] = [
            atTop("Sources/NapCatSeam/SeamSocket.swift", "import CloudKit\n"),
            atTop("Sources/NapCatChannel/ChannelServer.swift", "@preconcurrency import CloudKit\n"),
            atTop("Sources/NapCatChannel/ChannelRelay.swift", "@_exported import CloudKit\n"),
            atTop("Sources/NapCatWire/ApprovalWire.swift", "import struct CloudKit.CKRecord\n"),
            atTop("Sources/NapCatWire/AlertWire.swift", "#if canImport(CloudKit)\nimport CloudKit\n#endif\n"),
            added("Sources/NapCatChannel/ChannelRecords.swift", "import CloudKit\nlet zz: CKRecord? = nil\n"),
        ]
        let sanctionedNames: [(String, Sources)] = Self.cloudKitFiles.sorted().flatMap { file -> [(String, Sources)] in
            LidGuardStructureTests.networkingOtherTargets.map { added($0 + "/" + file, "import CloudKit\n") }
        }
        #expect(sanctionedNames.count == 6, "vacuity: two sanctioned names, in each of three other targets")
        for (path, mutant) in forms + sanctionedNames {
            #expect(mutant.map { $0.text } != withFile.map { $0.text }, "canary at \(path) did not apply")
            #expect(Self.iCloudFailures(mutant).contains { $0.hasPrefix(path + " imports CloudKit") },
                    "canary at \(path) was NOT caught by the import check")
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

    /// The record path's one record and one operation — and (S-PAIR-C1.5,
    /// #170) the pairing record's one fetch.
    static let recordPathConstructions = [
        "CKRecord": "let record = CKRecord(recordType: ApprovalWire.RecordType.prompt.rawValue,",
        "CKModifyRecordsOperation": "let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: doomed)",
        "CKFetchRecordsOperation": fetchConstruction,
    ]
    static let fetchConstruction = "let operation = CKFetchRecordsOperation(recordIDs: [recordID(recordName)])"

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
            // S-PAIR-C1.5 (#170): the pairing record's one fetch, however spelled.
            ("a second fetch", file + "\nlet f = CKFetchRecordsOperation(recordIDs: [])"),
            ("a second fetch, init-spelled", file + "\nlet f = CKFetchRecordsOperation.init(recordIDs: [])"),
            ("the fetch's metatype", file + "\nlet t = CKFetchRecordsOperation.self"),
            ("a fetch by implicit init", file + "\nfunc spare() -> CKFetchRecordsOperation {\n    return .init(recordIDs: [])\n}"),
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
    ///
    /// AMENDED (S-PAIR-C1.5, #170 — deliberate): the pairing record's source
    /// is the factory's third caller (its deletion: that one record, nothing
    /// saved) and the pairing database's seam the second set of `submit`s.
    /// The seams' modify requirements are spelled alike, so that line counts
    /// twice. The fetch factory (`makeFetchOperation`) is pinned the same way:
    /// declared once, reached by the source's one fetch submit, its operation
    /// built once (lock 8's construction check), configured and returned.
    static let pairingDeleteSubmit = "database.submit(ApprovalRecordWriter.makeOperation(saving: [], deleting: [Self.recordID(recordName)]) { outcome in"
    static let pairingFetchSubmit = "database.submit(Self.makeFetchOperation(recordName: recordName) { continuation.resume(returning: $0) })"
    static let fetchFactoryHead = "static func makeFetchOperation(recordName: String, completion: @escaping @Sendable (PairingFetch) -> Void)"
    static let factorySites = [
        "static func makeOperation(saving records: [CKRecord], deleting doomed: [CKRecord.ID],": 1,
        "database.submit(Self.makeOperation(saving: [record], deleting: []) { outcome in": 1,
        "database.submit(Self.makeOperation(saving: [], deleting: doomed) { outcome in": 1,
        pairingDeleteSubmit: 1,
    ]
    static let submitSites = [
        "func submit(_ operation: CKModifyRecordsOperation)": 2,
        "func submit(_ operation: CKFetchRecordsOperation)": 1,
        "database.submit(Self.makeOperation(saving: [record], deleting: []) { outcome in": 1,
        "database.submit(Self.makeOperation(saving: [], deleting: doomed) { outcome in": 1,
        pairingDeleteSubmit: 1,
        pairingFetchSubmit: 1,
    ]
    /// Every line naming `operation`: the seams' parameters, then each
    /// factory building, configuring and returning its operation.
    static let operationSites = [
        "func submit(_ operation: CKModifyRecordsOperation)": 2,
        "func submit(_ operation: CKFetchRecordsOperation)": 1,
        "let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: doomed)": 1,
        "operation.savePolicy = .ifServerRecordUnchanged": 1,
        "operation.isAtomic = true": 1,
        "operation.configuration = configuration": 2,
        "operation.perRecordSaveBlock = { _, result in results.note(result.map { _ in () }, deleting: false) }": 1,
        "operation.perRecordDeleteBlock = { _, result in results.note(result, deleting: true) }": 1,
        "operation.modifyRecordsResultBlock = { batch in completion(results.outcome(batch: batch)) }": 1,
        fetchConstruction: 1,
        "operation.perRecordResultBlock = { _, result in fetched.note(result) }": 1,
        "operation.fetchRecordsResultBlock = { batch in": 1,
        "return operation": 2,
    ]
    static let operationTypeSites = [
        "func submit(_ operation: CKModifyRecordsOperation)": 2,
        "-> CKModifyRecordsOperation {": 1,
        "let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: doomed)": 1,
    ]
    static let fetchTypeSites = [
        "func submit(_ operation: CKFetchRecordsOperation)": 1,
        "-> CKFetchRecordsOperation {": 1,
        fetchConstruction: 1,
    ]
    static let fetchFactorySites = [fetchFactoryHead: 1, pairingFetchSubmit: 1]

    /// `sources`: `uncutSources()`.
    static func seamFlowFailures(_ sources: Sources) -> [String] {
        let file = text(recordPathFile, in: sources)
        var failures = siteFailures(#"\bmakeOperation\b"#, in: file, file: recordPathFile, allowed: factorySites,
                                    rule: "the operation factory is reached only by the writer's two submits and the pairing deletion")
        for factory in ["makeOperation", "makeFetchOperation"] {
            for (name, text) in sources where name != recordPathFile && hits(#"\b"# + factory + #"\b"#, in: text) {
                failures.append("'\(factory)' in \(name) — only the record path reaches its operation factories")
            }
        }
        failures += siteFailures(#"\bmakeFetchOperation\b"#, in: file, file: recordPathFile, allowed: fetchFactorySites,
                                 rule: "the fetch factory is reached only by the pairing source's one fetch")
        failures += siteFailures(#"\bsubmit\b"#, in: file, file: recordPathFile, allowed: submitSites,
                                 rule: "the seams are named only by their requirements, the writer's two submits and the pairing source's two")
        failures += siteFailures(#"\boperation\b"#, in: file, file: recordPathFile, allowed: operationSites,
                                 rule: "each factory builds, configures and returns its operation, nothing else")
        failures += siteFailures(#"\bCKModifyRecordsOperation\b"#, in: file, file: recordPathFile, allowed: operationTypeSites,
                                 rule: "the operation type is named by the seams, the factory and the one construction")
        failures += siteFailures(#"\bCKFetchRecordsOperation\b"#, in: file, file: recordPathFile, allowed: fetchTypeSites,
                                 rule: "the fetch operation's type is named by its seam, its factory and its one construction")
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
            // Security spot-check H9, as planted (R-H9-X1b): a regex holding
            // `"""` after `switch`, read as a division, swapped string and
            // code, so the runner's `//`-led interpolation line read as a
            // whole-line comment; a second such regex restored the parity.
            ("H9: the operation run from a //-led interpolation line", Self.mutate(Self.mutate(sources, record) {
                $0 + LidGuardStructureTests.wholeLineCommentsRemoved("\nextension ApprovalRecordWriter {\n"
                    + "    static func h9x(_ r: CKRecord) -> String {\n        switch /\"\"\"/ { default: break }\n        let s = \"\"\"\n"
                    + "        // \\(kickOff(makeOperation(saving: [r], deleting: []) { _ in }))\n        \"\"\"\n"
                    + "        switch /\"\"\"/ { default: break }\n        return s\n    }\n}\n")
            }, "CompositeMessageSender.swift") { $0 + "\nfunc kickOff<O: Operation>(_ o: O) { o.start() }\n" }),
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

    // MARK: - 10. The pairing record is reached by its ID alone, through its one source (S-PAIR-C1.5)

    /// The live pairing transport (#170): what the behaviour tests show by
    /// example (`CloudKitPairingRecordsTests`), pinned so no other road
    /// exists.
    /// - ONE `PairingRecordSource` conformer in the four targets, on its
    ///   declaration's exact line in the record path (the C1 stub
    ///   `NoPairingRecords` is gone, named nowhere), built once, by the
    ///   controller's wiring; ONE `PairingRecordDatabase` conformer, the live
    ///   database, on its exact line in the container's file. Every line
    ///   naming either type is pinned, so nothing else holds the live
    ///   database or reaches the source (a typed implicit init, an unapplied
    ///   one, an alias or an extension all name the type; `type(of:)` is
    ///   banned app-wide by PairingStructureTests lock 6; no `Self(` in the
    ///   record path).
    /// - The source's fetch and delete, whole: the name's shape first, then
    ///   the fetch by `makeFetchOperation` alone, and a deletion of that one
    ///   record that saves nothing.
    /// - The fetch, whole: one record ID — the approvals zone and the name
    ///   (`recordID`, whole), no query — and its outcome from `fetchOutcome`.
    /// - The closed mapping, whole: `found` only from a record actually read,
    ///   read with the same name; `nothing` only for `unknownItem`; anything
    ///   else `unreachable`. The record path's one `.found` and its one
    ///   `expectedName:` read are those lines.
    static let sourceDeclaration = "final class CloudKitPairingRecords: PairingRecordSource, @unchecked Sendable {"
    static let liveDatabaseDeclaration = "private final class LivePairingRecordDatabase: PairingRecordDatabase, @unchecked Sendable {"
    static let senderFile = "CloudKitMessageSender.swift"
    static let pairingWiring = "source: CloudKitPairingRecords(database: { CloudKitMessageSender.makeLivePairingDatabase() }), keys: keys,"

    /// An adoption of `name` however it is declared: a type, an extension or
    /// a refining protocol naming it in its clause, over any number of lines,
    /// or a typealias of it — one declaration at a time (`oneDeclaration`,
    /// the phone's: a clause never runs into the next declaration, so a
    /// typealias above a stored property of the seam's type is not read as
    /// an alias of it).
    static func adoptionPattern(_ name: String) -> String {
        let word = #"\b"# + name + #"\b"#
        return #"\b(?:class|struct|actor|enum|extension|protocol)\b"# + oneDeclaration + ":" + oneDeclaration + word
            + #"|\btypealias\b"# + oneDeclaration + "=" + oneDeclaration + word
    }
    static let oneDeclaration = #"(?:(?!\b(?:typealias|protocol|struct|class|actor|enum|extension|func|var|let)\b)[^{};])*?"#

    static let sourceWordSites: [String: [String: Int]] = [
        recordPathFile: [sourceDeclaration: 1,
                         "return CloudKitPairingRecords.fetchOutcome(recordName: recordName, record: record, batch: batch)": 1],
        "PairingController.swift": [pairingWiring: 1],
    ]
    static let databaseWordSites: [String: [String: Int]] = [
        recordPathFile: ["protocol PairingRecordDatabase: AnyObject, Sendable {": 1,
                         "private let makeDatabase: @Sendable () -> (any PairingRecordDatabase)?": 1,
                         "private var live: (any PairingRecordDatabase)?": 1,
                         "init(database: @escaping @Sendable () -> (any PairingRecordDatabase)?) {": 1,
                         "private func resolvedDatabase() -> (any PairingRecordDatabase)? {": 1],
        senderFile: ["static func makeLivePairingDatabase() -> (any PairingRecordDatabase)? {": 1, liveDatabaseDeclaration: 1],
    ]

    static let fetchBody = "guard PairingResponseCheck.isRecordName(recordName), let database = resolvedDatabase() else { return .unreachable } "
        + "return await withCheckedContinuation { continuation in " + pairingFetchSubmit + " }"
    static let deleteBody = "guard PairingResponseCheck.isRecordName(recordName), let database = resolvedDatabase() else { return false } "
        + "return await withCheckedContinuation { continuation in " + pairingDeleteSubmit
        + " continuation.resume(returning: outcome == .confirmed) }) }"
    static let recordIDBody = "CKRecord.ID(recordName: recordName, zoneID: ApprovalRecordWriter.zoneID)"
    static let fetchFactoryBody = "-> CKFetchRecordsOperation { " + fetchConstruction
        + " let configuration = CKOperation.Configuration() configuration.qualityOfService = .userInitiated"
        + " configuration.isLongLived = false configuration.timeoutIntervalForRequest = LidGuardTuning.requestTimeout"
        + " configuration.timeoutIntervalForResource = LidGuardTuning.requestTimeout operation.configuration = configuration"
        + " let fetched = FetchedRecord() operation.perRecordResultBlock = { _, result in fetched.note(result) }"
        + " operation.fetchRecordsResultBlock = { batch in guard let outcome = fetched.finish(recordName: recordName, batch: batch)"
        + " else { return } completion(outcome) } return operation"
    static let foundLine = "return .found(PairingResponseReader.reading(of: read, expectedName: recordName))"
    static let outcomeBody = "switch record { case .success(let read)?: " + foundLine
        + " case .failure(let error)?: return isMissing(error) ? .nothing : .unreachable"
        + " case nil: if case .failure(let error) = batch, isMissing(error) { return .nothing } return .unreachable }"
    static let missingBody = "ApprovalRecordWriter.isGone(CloudKitMessageSender.recordLevelError(error as NSError))"
    static let bodies: [(head: String, body: String, rule: String)] = [
        ("func fetch(recordName: String) async -> PairingFetch {", fetchBody,
         "the fetch checks the name's shape, then fetches by the one factory"),
        ("func delete(recordName: String) async -> Bool {", deleteBody,
         "the deletion checks the name's shape, then deletes that one record and saves nothing"),
        ("static func recordID(_ recordName: String) -> CKRecord.ID {", recordIDBody,
         "the pairing record's ID is the approvals zone and the derived name"),
        (fetchFactoryHead, fetchFactoryBody, "the fetch asks for one record by its ID, and reports the closed mapping"),
        ("static func fetchOutcome(recordName: String, record: Result<CKRecord, any Error>?,",
         "batch: Result<Void, any Error>) -> PairingFetch { " + outcomeBody,
         "found only from a record read, read with the name asked for; nothing only for unknownItem; else unreachable"),
        ("static func isMissing(_ error: any Error) -> Bool {", missingBody, "missing means unknownItem, alone or as the one item"),
    ]

    /// `sources`: `uncutSources()`.
    static func pairingTransportFailures(_ sources: Sources) -> [String] {
        let file = text(recordPathFile, in: sources)
        guard file.contains(sourceDeclaration), text(senderFile, in: sources).contains(liveDatabaseDeclaration) else {
            return ["the pairing source or its live database is missing — the pairing transport lock would be vacuous"]
        }
        var failures: [String] = []
        for (name, text) in sources {
            let copies = LidGuardStructureTests.constructorScanCopies(text)
            for (seam, allowed) in [("PairingRecordSource", name == recordPathFile ? [sourceDeclaration: 1] : [:]),
                                    ("PairingRecordDatabase", name == senderFile ? [liveDatabaseDeclaration: 1] : [:])] {
                for copy in copies where siteTally(adoptionPattern(seam), in: copy) != allowed {
                    failures.append("\(name) adopts \(seam) off its pin: \(siteTally(adoptionPattern(seam), in: copy))")
                }
            }
            if hits(#"\bNoPairingRecords\b"#, in: text) {
                failures.append("'NoPairingRecords' in \(name) — the C1 stub is gone; the live source is the one conformer")
            }
        }
        failures += PairingStructureTests.appSiteFailures(#"\bCloudKitPairingRecords\b"#, in: sources, allowed: sourceWordSites,
                                                          rule: "the pairing source is declared once and built once, by the controller's wiring")
        failures += PairingStructureTests.appSiteFailures(#"\bPairingRecordDatabase\b"#, in: sources, allowed: databaseWordSites,
                                                          rule: "the live pairing database is held by the pairing source alone")
        for copy in LidGuardStructureTests.constructorScanCopies(file) where hits(#"\bSelf\s*(?:\(|\.\s*init\b)"#, in: copy) {
            failures.append("the record path builds through Self( or Self.init — it spells every construction")
        }
        for (head, body, rule) in bodies {
            guard let found = PhoneTransportStructureTests.body(after: head, in: file) else {
                failures.append("'\(head)' not found in \(recordPathFile) — \(rule)")
                continue
            }
            if MenuPanelStructureTests.flat(found) != body { failures.append("\(rule) — exactly as pinned") }
        }
        failures += siteFailures(#"\.\s*found\b"#, in: file, file: recordPathFile, allowed: [foundLine: 1],
                                 rule: "a fetch is found only from a record actually read")
        failures += PairingStructureTests.appSiteFailures(#"\bexpectedName\b"#, in: sources, allowed: [recordPathFile: [
            "static func reading(of record: CKRecord, expectedName: String) -> PairingResponseReading {": 1,
            "guard record.recordID.recordName == expectedName else { return .malformed(.wrongRecordName) }": 1, foundLine: 1]],
            rule: "a pairing record is read once, with the very name it was fetched by")
        return unique(failures)
    }

    @Test func thePairingRecordIsReachedByItsIDAloneThroughItsOneSource() throws {
        let sources = try Self.uncutSources()
        #expect(Self.pairingTransportFailures(sources).isEmpty, "\(Self.pairingTransportFailures(sources))")
        let record = Self.recordPathFile
        let sender = Self.senderFile
        let mutants: [(String, Sources)] = [
            // The mapping and the name: a record read with the name it carries,
            // a query, another zone, a found from nothing, an error read as
            // nothing, a shape check skipped.
            ("read with the name the record carries", Self.mutate(sources, record) {
                $0.replacingOccurrences(of: "expectedName: recordName))", with: "expectedName: read.recordID.recordName))") }),
            ("a fetch by query", Self.mutate(sources, record) {
                $0.replacingOccurrences(of: Self.fetchConstruction, with: "let operation = CKFetchRecordsOperation(recordIDs: spareIDs)") }),
            ("the record in the default zone", Self.mutate(sources, record) {
                $0.replacingOccurrences(of: Self.recordIDBody, with: "CKRecord.ID(recordName: recordName, zoneID: .default)") }),
            ("found from no record", Self.mutate(sources, record) {
                $0.replacingOccurrences(of: "if case .failure(let error) = batch, isMissing(error) { return .nothing }\n            return .unreachable",
                                        with: "return .found(.malformed(.missingField))") }),
            ("every error read as nothing", Self.mutate(sources, record) {
                $0.replacingOccurrences(of: "return isMissing(error) ? .nothing : .unreachable", with: "return .nothing") }),
            ("the shape check skipped", Self.mutate(sources, record) {
                $0.replacingOccurrences(of: "guard PairingResponseCheck.isRecordName(recordName), let database = resolvedDatabase() else { return false }",
                                        with: "guard let database = resolvedDatabase() else { return false }") }),
            ("a deletion that saves", Self.mutate(sources, record) {
                $0.replacingOccurrences(of: "makeOperation(saving: [], deleting: [Self.recordID(recordName)])",
                                        with: "makeOperation(saving: spare, deleting: [Self.recordID(recordName)])") }),
            ("missing widened", Self.mutate(sources, record) {
                $0.replacingOccurrences(of: Self.missingBody, with: "true") }),
            ("a second read of a pairing record", Self.mutate(sources, "PairingCeremony.swift") {
                $0 + "\nfunc spare(r: CKRecord) -> Any { PairingResponseReader.reading(of: r, expectedName: \"x\") }" }),
            // The conformers and their holders.
            ("NoPairingRecords back, beside the live source", Self.mutate(sources, "PairingController.swift") {
                $0 + "\nfinal class NoPairingRecords: PairingRecordSource {\n    func fetch(recordName: String) async -> PairingFetch { .nothing }\n"
                    + "    func delete(recordName: String) async -> Bool { true }\n}" }),
            ("the stub named only", Self.mutate(sources, "MenuStateModel.swift") { $0 + "\nlet zz = NoPairingRecords.self" }),
            ("a second source, its conformance on the next line", Self.mutate(sources, record) {
                $0 + "\nfinal class SpareRecords:\n    PairingRecordSource {}" }),
            ("a source by extension", Self.mutate(sources, "MenuStateModel.swift") { $0 + "\nextension MenuStateModel: PairingRecordSource {}" }),
            ("a refining protocol", Self.mutate(sources, "PairingCeremony.swift") { $0 + "\nprotocol SpareSource: PairingRecordSource {}" }),
            ("an alias of the database seam", Self.mutate(sources, sender) { $0 + "\ntypealias SpareDatabase = PairingRecordDatabase" }),
            ("a second live database", Self.mutate(sources, sender) {
                $0 + "\nprivate final class SpareDatabase: PairingRecordDatabase, @unchecked Sendable {}" }),
            ("the live database held elsewhere", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nlet zz: (any PairingRecordDatabase)? = nil" }),
            ("a second source built", Self.mutate(sources, "NapCatApp.swift") { $0 + "\nlet zz = CloudKitPairingRecords(database: { nil })" }),
            ("a second source by typed implicit init", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nlet zz: CloudKitPairingRecords = .init(database: { nil })" }),
            ("the source's unapplied init", Self.mutate(sources, "MenuStateModel.swift") { $0 + "\nlet zz = CloudKitPairingRecords.init" }),
            ("a second source through Self(", Self.mutate(sources, record) {
                $0.replacingOccurrences(of: "    static func recordID(_ recordName: String) -> CKRecord.ID {\n",
                                        with: "    static let spare = Self(database: { nil })\n"
                                            + "    static func recordID(_ recordName: String) -> CKRecord.ID {\n") }),
            ("a backticked second source", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nlet zz = `CloudKitPairingRecords`(database: { nil })" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.pairingTransportFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: the seam's own declaration and a protocol
        // extension of it adopt nothing; words that only contain the pinned
        // ones; `Self.` members; and a whole-line comment.
        #expect(Self.pairingTransportFailures(Self.mutate(sources, "MenuStateModel.swift") {
            $0 + "\nextension PairingRecordSource where Self: AnyObject {}"
                + "\nlet spareCloudKitPairingRecordsCount = 1, foundation = 2, expectedNames = 3"
                + LidGuardStructureTests.wholeLineCommentsRemoved("\n/// never NoPairingRecords(), never CloudKitPairingRecords(database:)")
        }).isEmpty)
        for probe in ["final class X:\n    PairingRecordSource {", "typealias S = Sendable &\n    PairingRecordSource"] {
            #expect(Self.hits(Self.adoptionPattern("PairingRecordSource"), in: probe), "missed '\(probe)'")
        }
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
