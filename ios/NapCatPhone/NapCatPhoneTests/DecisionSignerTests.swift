import CryptoKit
import Foundation
import NapCatWire
@testable import NapCatPhone
import Testing

/// What the Mac does with a decision, rebuilt here from the wire alone (the
/// phone cannot link the Mac's `DecisionVerifier`; this is its message and
/// its check, line for line): the canonical decision message over the
/// Mac's OWN copy of the prompt's three fields, and ECDSA P-256 over
/// SHA-256 of it.
enum MacCheck {
    static func message(_ verdict: ApprovalWire.Verdict, promptID: PromptID, decidedAt: Int, toolName: String,
                        inputPreview: String, projectLabel: String) -> [UInt8]? {
        let shown = SHA256.hash(data: ApprovalSigning.shownDigestInput(toolName: toolName, inputPreview: inputPreview,
                                                                       projectLabel: projectLabel))
        return ApprovalSigning.decisionMessage(wireVersion: ApprovalWire.wireVersion, promptID: promptID, verdict: verdict,
                                               decidedAt: decidedAt, shownDigest: Array(shown))
    }

    /// Whether the Mac, holding `copy` as it wrote it, would count
    /// `decision` as signed by `publicKey`.
    static func verifies(_ decision: PhoneDecision, copy: PendingRequest, publicKey: [UInt8]) -> Bool {
        let seconds = decision.decidedAt.timeIntervalSince1970
        guard seconds == seconds.rounded(.down), decision.promptID == copy.id,
              let message = message(decision.verdict, promptID: decision.promptID, decidedAt: Int(seconds),
                                    toolName: copy.toolName, inputPreview: copy.inputPreview, projectLabel: copy.projectLabel)
        else { return false }
        return SignatureCheck.verifies(decision.signature, over: message, by: publicKey)
    }
}

/// The decision signer (F4 slice S-PAIR-B, CL-1): the phone signs the
/// canonical message over the prompt's fields AS RECEIVED, in whole
/// seconds, with the committed key and one match; and the locks that keep
/// it the one place that does.
@MainActor
@Suite struct DecisionSignerTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A request whose fields hold what a display would change: spaces, a
    /// tab, a line break, a decomposed é (NFD) and a non-ASCII label.
    static let tricky = PendingRequest(id: RequestFixtures.id(0x51), toolName: "Write",
                                       inputPreview: "{\"file_path\":\"/tmp/cafe\u{0301}.txt\",\"content\":\"a b\tc\nd\"}",
                                       projectLabel: "naïve", createdAt: now, expiresAt: now.addingTimeInterval(600))!

    /// A paired software keyring and its public key.
    static func paired() -> (keys: PhoneKeyringTests.World, publicKey: [UInt8]) {
        let keys = PhoneKeyringTests.World()
        let publicKey = keys.keyring.makeProvisional() ?? []
        _ = keys.keyring.commitProvisional()
        return (keys, publicKey)
    }

    // MARK: The message

    /// The six pinned lines, with the digest of the fields as received.
    @Test(arguments: ApprovalWire.Verdict.allCases)
    func theMessageIsTheWiresSixLines(_ verdict: ApprovalWire.Verdict) throws {
        let request = Self.tricky
        let message = try #require(DecisionSigner.message(verdict, for: request, decidedAt: Self.now))
        let shown = SHA256.hash(data: ApprovalSigning.shownDigestInput(toolName: request.toolName, inputPreview: request.inputPreview,
                                                                       projectLabel: request.projectLabel))
        let expected = "napcat-decision-v1\nwire:1\nprompt:\(request.id.hex)\nverdict:\(verdict.rawValue)\n"
            + "decided:1800000000\nshown:\(ApprovalSigning.lowercaseHex(Array(shown)))\n"
        #expect(message == Array(expected.utf8))
        #expect(DecisionSigner.shownDigest(of: request) == Array(shown))
    }

    /// A time that is not a whole second from 1970 has no line.
    @Test func onlyAWholeSecondHasALine() {
        #expect(DecisionSigner.message(.allow, for: Self.tricky, decidedAt: Self.now.addingTimeInterval(0.5)) == nil)
        #expect(DecisionSigner.message(.allow, for: Self.tricky, decidedAt: Date(timeIntervalSince1970: -1)) == nil)
        #expect(DecisionSigner.wholeSecond(Self.now.addingTimeInterval(0.999)) == Self.now)
        #expect(DecisionSigner.wholeSecond(Self.now) == Self.now)
    }

    /// The decision value refuses what the wire cannot carry.
    @Test func aDecisionHoldsAWholeSecondAndSixtyFourBytes() {
        let id = RequestFixtures.id(1)
        let good = Data(repeating: 7, count: 64)
        #expect(PhoneDecision(promptID: id, verdict: .deny, decidedAt: Self.now, signature: good) != nil)
        #expect(PhoneDecision(promptID: id, verdict: .deny, decidedAt: Self.now.addingTimeInterval(0.25), signature: good) == nil)
        #expect(PhoneDecision(promptID: id, verdict: .deny, decidedAt: Date(timeIntervalSince1970: -1), signature: good) == nil)
        for count in [0, 63, 65, 72] {
            #expect(PhoneDecision(promptID: id, verdict: .deny, decidedAt: Self.now, signature: Data(count: count)) == nil)
        }
    }

    // MARK: The signature

    /// The Mac counts it: the paired key signed exactly this decision over
    /// the Mac's own copy of the fields, Allow and Deny alike.
    @Test(arguments: ApprovalWire.Verdict.allCases)
    func theMacCountsTheSignedDecision(_ verdict: ApprovalWire.Verdict) throws {
        let (keys, publicKey) = Self.paired()
        let outcome = DecisionSigner.sign(verdict, for: Self.tricky, at: Self.now.addingTimeInterval(0.7), with: keys.keyring,
                                          match: TestMatch())
        guard case .signed(let decision) = outcome else {
            Issue.record("not signed: \(outcome)")
            return
        }
        #expect(decision.promptID == Self.tricky.id && decision.verdict == verdict)
        #expect(decision.decidedAt == Self.now, "whole seconds, rounded down")
        #expect(decision.signature.count == 64)
        #expect(MacCheck.verifies(decision, copy: Self.tricky, publicKey: publicKey))
    }

    /// What-you-see-is-what-you-sign holds only over the RECEIVED bytes: the
    /// same decision does not verify over the screen's drawing of the input
    /// (whitespace marks), over the fields in another normalization form,
    /// or for another verdict, prompt or second.
    @Test func itSignsTheFieldsAsReceivedNotAsDrawn() throws {
        let (keys, publicKey) = Self.paired()
        guard case .signed(let decision) = DecisionSigner.sign(.allow, for: Self.tricky, at: Self.now, with: keys.keyring,
                                                               match: TestMatch()) else {
            Issue.record("not signed")
            return
        }
        let drawn = VisibleWhitespace.segments(Self.tricky.inputPreview).map(\.shown).joined()
        let others: [(String, PendingRequest)] = [
            ("the drawn input", Self.copy(inputPreview: drawn)),
            ("the input in NFC", Self.copy(inputPreview: Self.tricky.inputPreview.precomposedStringWithCanonicalMapping)),
            ("the label in NFD", Self.copy(projectLabel: Self.tricky.projectLabel.decomposedStringWithCanonicalMapping)),
            ("trimmed", Self.copy(inputPreview: Self.tricky.inputPreview.replacingOccurrences(of: "\t", with: " "))),
        ]
        for (name, copy) in others {
            #expect(Array(copy.inputPreview.utf8) != Array(Self.tricky.inputPreview.utf8)
                    || Array(copy.projectLabel.utf8) != Array(Self.tricky.projectLabel.utf8), "\(name) changed nothing")
            #expect(!MacCheck.verifies(decision, copy: copy, publicKey: publicKey), "\(name) verified")
        }
        #expect(MacCheck.verifies(decision, copy: Self.tricky, publicKey: publicKey))
        let deny = try #require(PhoneDecision(promptID: decision.promptID, verdict: .deny, decidedAt: decision.decidedAt,
                                              signature: decision.signature))
        #expect(!MacCheck.verifies(deny, copy: Self.tricky, publicKey: publicKey), "the verdict is signed")
        let later = try #require(PhoneDecision(promptID: decision.promptID, verdict: .allow, decidedAt: decision.decidedAt.addingTimeInterval(1),
                                               signature: decision.signature))
        #expect(!MacCheck.verifies(later, copy: Self.tricky, publicKey: publicKey), "the second is signed")
    }

    static func copy(inputPreview: String? = nil, projectLabel: String? = nil) -> PendingRequest {
        PendingRequest(id: tricky.id, toolName: tricky.toolName, inputPreview: inputPreview ?? tricky.inputPreview,
                       projectLabel: projectLabel ?? tricky.projectLabel, createdAt: tricky.createdAt, expiresAt: tricky.expiresAt)!
    }

    /// Another key's signature never passes for the paired one's.
    @Test func onlyThePairedKeysSignatureCounts() {
        let (keys, _) = Self.paired()
        let (_, stranger) = Self.paired()
        guard case .signed(let decision) = DecisionSigner.sign(.deny, for: Self.tricky, at: Self.now, with: keys.keyring,
                                                               match: TestMatch()) else {
            Issue.record("not signed")
            return
        }
        #expect(!MacCheck.verifies(decision, copy: Self.tricky, publicKey: stranger))
    }

    /// What the keyring says passes through, and the match is spent on
    /// every path.
    @Test func whatTheKeyringSaysPassesThrough() throws {
        let unpaired = PhoneKeyringTests.World()
        let match = TestMatch()
        #expect(DecisionSigner.sign(.allow, for: Self.tricky, at: Self.now, with: unpaired.keyring, match: match) == .unpaired)
        #expect(!match.isValid)
        let (keys, _) = Self.paired()
        keys.enclave.forced = .notAuthorized
        #expect(DecisionSigner.sign(.allow, for: Self.tricky, at: Self.now, with: keys.keyring, match: TestMatch()) == .notSigned)
        keys.enclave.forced = nil
        keys.enclave.killed = [try #require(keys.committed()).keyData]
        keys.enrolled = PhoneKeyringTests.after
        #expect(DecisionSigner.sign(.allow, for: Self.tricky, at: Self.now, with: keys.keyring, match: TestMatch()) == .selfUnpaired)
        let spent = TestMatch()
        spent.invalidate()
        let (fresh, _) = Self.paired()
        #expect(DecisionSigner.sign(.allow, for: Self.tricky, at: Self.now, with: fresh.keyring, match: spent) == .notSigned,
                "a spent match signs nothing")
    }

    /// A time before 1970 signs nothing, and still spends the match.
    @Test func aTimeWithNoLineSignsNothing() {
        let (keys, _) = Self.paired()
        let match = TestMatch()
        #expect(DecisionSigner.sign(.allow, for: Self.tricky, at: Date(timeIntervalSince1970: -5), with: keys.keyring,
                                    match: match) == .notSigned)
        #expect(!match.isValid)
        #expect(keys.enclave.signed.isEmpty)
    }

    // MARK: The lock: one signer, over the fields as received

    typealias Source = CloudKitStructureTests.Source
    static let appDir = CloudKitStructureTests.appDir
    static let signerFile = "\(appDir)/Model/DecisionSigner.swift"
    static let inboxFile = "\(appDir)/Model/RequestInbox.swift"
    static let digestInput = "Array(SHA256.hash(data: ApprovalSigning.shownDigestInput(toolName: request.toolName, "
        + "inputPreview: request.inputPreview, projectLabel: request.projectLabel)))"
    /// Anything that changes text or draws it: never between the record's
    /// fields and the digest.
    static let displayTokens = ["VisibleWhitespace", "PhoneLine", "AttributedString", "Text(", "precomposed", "decomposed",
                                "replacingOccurrences", "trimmingCharacters", "lowercased", "uppercased", "folding(",
                                "applyingTransform", "description", "inputDrawing", "InputDrawing"]

    /// The decision message, the shown digest and the decision value are
    /// built in the signer only; the digest is over the request's three
    /// fields as they are, and the signer names nothing that draws or
    /// changes text; the committed key signs only there; and the inbox's
    /// one write sends what the signer signed, after the window's re-check.
    static func signerFailures(_ app: [Source]) -> [String] {
        var failures: [String] = []
        for (path, text) in app {
            let code = RecordPathStructureTests.constructionSpelling(CloudKitStructureTests.codeOnly(text))
            let here = path == signerFile
            for (token, count) in [("ApprovalSigning.decisionMessage(", 1), ("ApprovalSigning.shownDigestInput(", 1),
                                   ("PhoneDecision(", 1), ("keyring.sign(", 1)]
            where CloudKitStructureTests.occurrences(of: token, in: code) != (here ? count : 0) {
                failures.append("'\(token)' in \(path) — only the decision signer, once")
            }
        }
        let signer = CloudKitStructureTests.codeOnly(app.first { $0.path == signerFile }?.text ?? "")
        if !SettingsReachabilityTests.flat(signer).contains(digestInput) {
            failures.append("the shown digest must be taken over the request's three fields as received")
        }
        for token in displayTokens where signer.contains(token) {
            failures.append("'\(token)' in the signer — the digest is over the fields as received, never a drawn form")
        }
        let inbox = SettingsReachabilityTests.flat(app.first { $0.path == inboxFile }?.text ?? "")
        let order = ["guard phase(of: id)?.isPending == true, let request = entries[id]?.request else {",
                     "let signing = DecisionSigner.sign(verdict, for: request, at: clock(), with: keyring, match: match)",
                     "guard case .signed(let decision) = signing else {", "let outcome = await writer.write(decision)"]
        var cursor = inbox.startIndex
        for step in order {
            guard let found = inbox.range(of: step, range: cursor..<inbox.endIndex) else {
                failures.append("the inbox's write lost '\(step)', or it moved out of order")
                break
            }
            cursor = found.upperBound
        }
        return failures
    }

    @Test func oneSignerSignsTheFieldsAsReceived() throws {
        let app = try CloudKitStructureTests.swiftFiles(under: Self.appDir)
        #expect(app.contains { $0.path == Self.signerFile }, "vacuity: the signer is where the lock looks")
        #expect(Self.signerFailures(app).isEmpty, "\(Self.signerFailures(app))")
        func mutate(_ path: String, _ transform: (String) -> String) -> [Source] {
            app.map { $0.path == path ? ($0.path, transform($0.text)) : $0 }
        }
        let mutants: [(String, [Source])] = [
            ("the digest over the drawn input", mutate(Self.signerFile) {
                $0.replacingOccurrences(of: "inputPreview: request.inputPreview,",
                                        with: "inputPreview: VisibleWhitespace.segments(request.inputPreview).map(\\.shown).joined(),") }),
            ("the digest over a normalized label", mutate(Self.signerFile) {
                $0.replacingOccurrences(of: "projectLabel: request.projectLabel)",
                                        with: "projectLabel: request.projectLabel.precomposedStringWithCanonicalMapping)") }),
            ("a second message builder", mutate(Self.inboxFile) {
                $0 + "\nlet spare = ApprovalSigning.decisionMessage(wireVersion: 1, promptID: p, verdict: .allow, decidedAt: 0, shownDigest: d)" }),
            ("an unsigned decision built elsewhere", mutate(Self.inboxFile) {
                $0 + "\nlet spare = PhoneDecision.init(promptID: p, verdict: .deny, decidedAt: d, signature: s)" }),
            ("the key used elsewhere", mutate(Self.inboxFile) { $0 + "\nfunc spare() { _ = keyring.sign(m, match: x) }" }),
            ("the write before the signature", mutate(Self.inboxFile) {
                $0.replacingOccurrences(of: "let outcome = await writer.write(decision)", with: "let outcome = await writer.write(spare)") }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.signerFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }
}
