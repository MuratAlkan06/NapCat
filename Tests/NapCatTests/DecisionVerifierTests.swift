// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import CryptoKit
import NapCatWire
import Testing
@testable import NapCat

/// F4 slice S-PAIR-A (#161): the decision verifier over SOFTWARE keys (CI
/// runs it; no Secure Enclave). The phone's half is played the way S-PAIR-B
/// will do it: build the canonical message with the shared builder over the
/// copy it displayed, sign it with its key. A decision verifies only when
/// the paired key signed exactly what the Mac rebuilds; every other claim is
/// refused with its own closed code, the first failure winning.
struct DecisionVerifierTests {
    static let promptID = PromptID(high: 0x0123_4567_89ab_cdef, low: 0x0123_4567_89ab_cdef)!
    static let otherPromptID = PromptID(high: 0x8f14_e45f_ceea_167a, low: 0x5a36_dedd_4bea_2543)!
    static let decidedAt = 1_763_942_400
    static let copy = ForwardedCopy(promptID: promptID, toolName: "Bash", inputPreview: "{\"command\":\"git status\"}",
                                    projectLabel: "NapCat")

    /// The paired phone (a software key standing in for the Secure Enclave).
    static let phone = P256.Signing.PrivateKey()

    /// What the phone does for one answer: the digest of the copy it shows,
    /// the six signed lines, the signature's raw 64 bytes.
    static func signed(_ verdict: ApprovalWire.Verdict = .allow, promptID: PromptID = promptID, decidedAt: Int = decidedAt,
                       shown: ForwardedCopy = copy, wireVersion: Int = ApprovalWire.wireVersion,
                       by key: P256.Signing.PrivateKey = phone) throws -> DecisionEvidence {
        let digest = SHA256.hash(data: ApprovalSigning.shownDigestInput(toolName: shown.toolName, inputPreview: shown.inputPreview,
                                                                        projectLabel: shown.projectLabel))
        let message = try #require(ApprovalSigning.decisionMessage(wireVersion: wireVersion, promptID: promptID, verdict: verdict,
                                                                   decidedAt: decidedAt, shownDigest: Array(digest)))
        return DecisionEvidence(wireVersion: wireVersion, promptID: promptID.hex, verdict: verdict.rawValue,
                                decidedAt: Date(timeIntervalSince1970: TimeInterval(decidedAt)),
                                signature: try key.signature(for: message).rawRepresentation)
    }

    static func evidence(_ base: DecisionEvidence, wireVersion: Int? = nil, promptID: String? = nil, verdict: String? = nil,
                         decidedAt: Date? = nil, signature: Data? = nil) -> DecisionEvidence {
        DecisionEvidence(wireVersion: wireVersion ?? base.wireVersion, promptID: promptID ?? base.promptID,
                         verdict: verdict ?? base.verdict, decidedAt: decidedAt ?? base.decidedAt,
                         signature: signature ?? base.signature)
    }

    static func verification(_ evidence: DecisionEvidence, copy: ForwardedCopy? = copy,
                             key: P256.Signing.PublicKey? = phone.publicKey) -> DecisionVerification {
        DecisionVerifier.verification(of: evidence, copy: copy, pairedKey: key)
    }

    static func reason(_ result: DecisionVerification) -> DecisionUnverifiedReason? {
        if case .unverified(let reason) = result { return reason }
        return nil
    }

    static func decision(_ result: DecisionVerification) -> ApprovalDecision? {
        if case .verified(let decision) = result { return decision }
        return nil
    }

    /// S-PAIR-C2: the paired-phone slot over an in-memory item (never the
    /// keychain), holding `key`'s public half when one is given. #247: and
    /// over `unpairs`, an outstanding-Unpair record over an in-memory medium
    /// (never the approvals folder).
    static func slot(_ items: FakeTopicStore = FakeTopicStore(), unpairs: UnpairRecord = UnpairRecord(medium: FakeTopicStore()),
                     paired key: P256.Signing.PrivateKey? = phone) throws -> PairedKeyStore {
        let keys = PairedKeyStore(items: items, unpairs: unpairs)
        if let key {
            let paired: PairedPhone = try #require(PairedPhone(publicKey: Array(key.publicKey.x963Representation),
                                                               pairedAt: Date(timeIntervalSince1970: 1_800_000_000)))
            #expect(keys.commit(paired))
        }
        return keys
    }

    // MARK: - What verifies

    @Test(arguments: ApprovalWire.Verdict.allCases)
    func thePairedPhonesSignatureVerifies(_ verdict: ApprovalWire.Verdict) throws {
        let result = Self.verification(try Self.signed(verdict))
        guard case .verified(let decision) = result else {
            Issue.record("a decision the paired key signed must verify: \(result)")
            return
        }
        #expect(decision.promptID == Self.promptID && decision.verdict == verdict)
        #expect(decision.wireVersion == ApprovalWire.wireVersion && decision.signatureVerified)
    }

    /// The text the gate may forward, and the hostile rows the vectors pin:
    /// what the Mac stored is what the phone signs, so it verifies.
    @Test func everyCopyVerifiesWhenThePhoneSignedItsOwnBytes() throws {
        let previews = ["{\"file_path\":\"/Users/me/Cafe\u{301}.md\"}", "{\"file_path\":\"/Users/me/Caf\u{E9}.md\"}",
                        "a\u{301}\u{323}", "line1\r\nline2", "x\u{2028}y\u{2029}z", "echo \u{1F469}\u{200D}\u{1F4BB}",
                        "git  status\t\u{A0}", "", String(repeating: "x", count: ApprovalGate.maxPreviewBytes)]
        for preview in previews {
            let copy = ForwardedCopy(promptID: Self.promptID, toolName: "Read", inputPreview: preview, projectLabel: "Cafe\u{301}")
            let result = Self.verification(try Self.signed(shown: copy), copy: copy)
            #expect(Self.reason(result) == nil, "\(preview.debugDescription.prefix(40)): \(result)")
        }
    }

    @Test func theDecisionTimesBoundsVerify() throws {
        for seconds in [0, 1, Int(DecisionVerifier.latestDecidedAt)] {
            #expect(Self.reason(Self.verification(try Self.signed(decidedAt: seconds))) == nil, "decided at \(seconds)")
        }
    }

    /// The phone may sign the bytes (CryptoKit hashes them with SHA-256) or
    /// their SHA-256 digest: the same signature either way.
    @Test func aSignatureOverTheDigestFormVerifiesToo() throws {
        let base = try Self.signed()
        let digest = SHA256.hash(data: ApprovalSigning.shownDigestInput(toolName: Self.copy.toolName,
                                                                        inputPreview: Self.copy.inputPreview,
                                                                        projectLabel: Self.copy.projectLabel))
        let message = try #require(ApprovalSigning.decisionMessage(wireVersion: 1, promptID: Self.promptID, verdict: .allow,
                                                                   decidedAt: Self.decidedAt, shownDigest: Array(digest)))
        let overDigest = try Self.phone.signature(for: SHA256.hash(data: message)).rawRepresentation
        #expect(Self.reason(Self.verification(Self.evidence(base, signature: overDigest))) == nil)
    }

    // MARK: - Every tampered field fails with its own code

    @Test func withoutAPairedKeyNothingVerifies() throws {
        #expect(Self.verification(try Self.signed(), key: nil) == .unverified(.noPairedKey))
    }

    @Test func theVerdictMustBeExactlyAllowOrDeny() throws {
        let base = try Self.signed()
        for verdict in ["", "ALLOW", "Allow", "allow ", " allow", "allow\n", "allow\u{301}", "maybe", "allowed", "deny,allow"] {
            #expect(Self.verification(Self.evidence(base, verdict: verdict)) == .unverified(.unknownVerdict), "'\(verdict)'")
        }
        // A known verdict the phone did not sign: the signature covers it.
        #expect(Self.verification(Self.evidence(base, verdict: "deny")) == .unverified(.signatureInvalid))
    }

    @Test func theDecisionTimeMustBeAWholeSecondInRange() throws {
        let base = try Self.signed()
        let signed = TimeInterval(Self.decidedAt)
        for fraction in [0.5, 0.001, 0.999, -0.25] {
            #expect(Self.verification(Self.evidence(base, decidedAt: Date(timeIntervalSince1970: signed + fraction)))
                    == .unverified(.fractionalDecidedAt), "+\(fraction)")
        }
        for seconds in [-1, -0.5, .infinity, -.infinity, .nan, DecisionVerifier.latestDecidedAt + 2] {
            #expect(Self.verification(Self.evidence(base, decidedAt: Date(timeIntervalSince1970: seconds)))
                    == .unverified(.decidedAtOutOfRange), "\(seconds)")
        }
        // Another whole second: the signature covers it.
        #expect(Self.verification(Self.evidence(base, decidedAt: Date(timeIntervalSince1970: signed + 1)))
                == .unverified(.signatureInvalid))
    }

    @Test func theSignatureMustBeExactly64Bytes() throws {
        let base = try Self.signed()
        for count in [0, 1, 32, 63, 65, 70, 72, 128] {
            let resized = Data((Array(base.signature) + Array(repeating: 0x30, count: 128)).prefix(count))
            #expect(Self.verification(Self.evidence(base, signature: resized)) == .unverified(.signatureLength), "\(count) bytes")
        }
        // The DER form of the very same signature is not the raw form.
        let der = try P256.Signing.ECDSASignature(rawRepresentation: base.signature).derRepresentation
        #expect(Self.verification(Self.evidence(base, signature: der)) == .unverified(.signatureLength))
        // 64 bytes that are not this decision's signature.
        var flipped = Array(base.signature)
        flipped[40] ^= 0x01
        for wrong in [Data(flipped), Data(count: 64), Data(repeating: 0xff, count: 64)] {
            #expect(Self.verification(Self.evidence(base, signature: wrong)) == .unverified(.signatureInvalid))
        }
    }

    @Test func theWireVersionMustBeTheWires() throws {
        let base = try Self.signed()
        for version in [0, 2, -1, Int.max] {
            #expect(Self.verification(Self.evidence(base, wireVersion: version)) == .unverified(.wrongWireVersion), "v\(version)")
        }
    }

    @Test func thePromptIDHasOneSpelling() throws {
        let base = try Self.signed()
        let hex = Self.promptID.hex
        // Typed element by element: the mixed String/Substring `+` overloads in a
        // single array literal exceed the macos-15 compiler's type-check budget.
        let uppercased: String = hex.uppercased()
        let short: String = String(hex.dropLast())
        let long: String = hex + "0"
        let zeros: String = String(repeating: "0", count: 32)
        let padded: String = " " + String(hex.dropFirst())
        let misdigit: String = String(hex.dropLast()) + "g"
        let prefixed: String = "0x" + String(hex.dropFirst(2))
        let spellings: [String] = [uppercased, short, long, zeros, padded, misdigit, prefixed, ""]
        for spelled in spellings {
            #expect(Self.verification(Self.evidence(base, promptID: spelled)) == .unverified(.malformedPromptID), "'\(spelled)'")
        }
        // Another real prompt, with the Mac's copy of it: the signature binds the prompt.
        let other = ForwardedCopy(promptID: Self.otherPromptID, toolName: Self.copy.toolName,
                                  inputPreview: Self.copy.inputPreview, projectLabel: Self.copy.projectLabel)
        #expect(Self.verification(Self.evidence(base, promptID: Self.otherPromptID.hex), copy: other) == .unverified(.signatureInvalid))
    }

    @Test func theMacMustHoldItsOwnCopyOfThePrompt() throws {
        let base = try Self.signed()
        #expect(Self.verification(base, copy: nil) == .unverified(.noForwardedCopy))
        let another = ForwardedCopy(promptID: Self.otherPromptID, toolName: Self.copy.toolName,
                                    inputPreview: Self.copy.inputPreview, projectLabel: Self.copy.projectLabel)
        #expect(Self.verification(base, copy: another) == .unverified(.noForwardedCopy))
    }

    /// What-you-see-is-what-you-sign: a prompt record rewritten before the
    /// phone read it (or any field the Mac holds otherwise) never verifies.
    @Test func aPromptThePhoneSawOtherwiseIsRefused() throws {
        let shown = [ForwardedCopy(promptID: Self.promptID, toolName: "Read", inputPreview: Self.copy.inputPreview,
                                   projectLabel: Self.copy.projectLabel),
                     ForwardedCopy(promptID: Self.promptID, toolName: Self.copy.toolName,
                                   inputPreview: "{\"command\":\"git status \"}", projectLabel: Self.copy.projectLabel),
                     ForwardedCopy(promptID: Self.promptID, toolName: Self.copy.toolName, inputPreview: Self.copy.inputPreview,
                                   projectLabel: "NapCat2"),
                     ForwardedCopy(promptID: Self.promptID, toolName: Self.copy.toolName, inputPreview: Self.copy.inputPreview + "\n",
                                   projectLabel: Self.copy.projectLabel)]
        for copy in shown {
            #expect(Self.verification(try Self.signed(shown: copy)) == .unverified(.signatureInvalid),
                    "the phone showed \(copy.inputPreview.debugDescription) / \(copy.projectLabel)")
        }
    }

    /// The digest is over the bytes the phone DECODED, never its display: a
    /// phone that hashed the preview as drawn (whitespace as visible marks)
    /// would never match, so such a decision is refused, never counted.
    @Test func aDigestOfTheDisplayedFormNeverVerifies() throws {
        let copy = ForwardedCopy(promptID: Self.promptID, toolName: "Bash", inputPreview: "git  status\t\n", projectLabel: "Nap Cat")
        let drawn = ForwardedCopy(promptID: Self.promptID, toolName: "Bash", inputPreview: "git\u{B7}\u{B7}status\u{2192}\u{21B5}",
                                  projectLabel: "Nap\u{B7}Cat")
        #expect(Self.verification(try Self.signed(shown: drawn), copy: copy) == .unverified(.signatureInvalid))
        #expect(Self.reason(Self.verification(try Self.signed(shown: copy), copy: copy)) == nil, "vacuity: the decoded form verifies")
    }

    @Test func aSignatureFromAnotherKeyIsRefused() throws {
        let stranger = P256.Signing.PrivateKey()
        #expect(Self.verification(try Self.signed(by: stranger)) == .unverified(.signatureInvalid))
        // … and the stranger's own key does not make the phone's signature its own.
        #expect(Self.verification(try Self.signed(), key: stranger.publicKey) == .unverified(.signatureInvalid))
    }

    // MARK: - Domain separation

    /// A signature the paired key made over any other message — the pairing
    /// proof above all, which the same key signs during the ceremony — never
    /// verifies as a decision.
    @Test func nothingElseThePhoneSignsIsADecision() throws {
        let base = try Self.signed()
        let publicKey = Array(Self.phone.publicKey.x963Representation)
        let nonce = [UInt8](repeating: 0x5a, count: ApprovalSigning.pairingNonceByteCount)
        let decision = try #require(DecisionVerifier.message(
            DecisionVerifier.Claimed(wireVersion: 1, promptID: Self.promptID, verdict: .allow, decidedAt: Self.decidedAt),
            shown: Self.copy))
        let replyDomain = Array("napcat-reply-v1".utf8) + decision.drop { $0 != 0x0a }
        let others: [(String, [UInt8])] = [
            ("the pairing proof", try #require(ApprovalSigning.pairingProofMessage(nonce: nonce, publicKey: publicKey))),
            ("the pairing confirmation", try #require(ApprovalSigning.pairingConfirmationMessage(wireVersion: 1, publicKey: publicKey))),
            ("the shown-digest input", ApprovalSigning.shownDigestInput(toolName: Self.copy.toolName, inputPreview: Self.copy.inputPreview,
                                                                        projectLabel: Self.copy.projectLabel)),
            ("the record-name input", try #require(ApprovalSigning.pairingRecordNameInput(nonce: nonce))),
            ("the decision's lines under another domain", replyDomain),
            ("the decision without its domain line", Array(decision.drop { $0 != 0x0a }.dropFirst())),
        ]
        for (name, message) in others {
            let signature = try Self.phone.signature(for: message).rawRepresentation
            #expect(Self.verification(Self.evidence(base, signature: signature)) == .unverified(.signatureInvalid), "\(name)")
        }
        #expect(Self.reason(Self.verification(Self.evidence(base, signature: try Self.phone.signature(for: decision).rawRepresentation)))
                == nil, "vacuity: the decision message itself verifies")
    }

    // MARK: - The shown-digest mismatch (diagnostic only)

    /// The paired key signed this very decision, but over the copy in the
    /// other normalization form (the record's text changed form on its way):
    /// refused, with its own code, both ways round.
    @Test func aCopyInAnotherNormalizationFormIsAShownDigestMismatch() throws {
        let nfd = ForwardedCopy(promptID: Self.promptID, toolName: "Read",
                                inputPreview: "{\"file_path\":\"/Users/me/Cafe\u{301}.md\"}", projectLabel: "Cafe\u{301}")
        let nfc = ForwardedCopy(promptID: Self.promptID, toolName: "Read",
                                inputPreview: "{\"file_path\":\"/Users/me/Caf\u{E9}.md\"}", projectLabel: "Caf\u{E9}")
        #expect(Self.verification(try Self.signed(shown: nfc), copy: nfd) == .unverified(.shownDigestMismatch))
        #expect(Self.verification(try Self.signed(shown: nfd), copy: nfc) == .unverified(.shownDigestMismatch))
        let unordered = ForwardedCopy(promptID: Self.promptID, toolName: "Bash", inputPreview: "a\u{301}\u{323}", projectLabel: "q")
        let ordered = ForwardedCopy(promptID: Self.promptID, toolName: "Bash", inputPreview: "a\u{323}\u{301}", projectLabel: "q")
        #expect(Self.verification(try Self.signed(shown: ordered), copy: unordered) == .unverified(.shownDigestMismatch))
        // Never a false label: other text, another key, or another verdict over that form.
        #expect(Self.verification(try Self.signed(shown: nfc, by: P256.Signing.PrivateKey()), copy: nfd) == .unverified(.signatureInvalid))
        #expect(Self.verification(Self.evidence(try Self.signed(shown: nfc), verdict: "deny"), copy: nfd) == .unverified(.signatureInvalid))
        let ascii = ForwardedCopy(promptID: Self.promptID, toolName: "Bash", inputPreview: "ls", projectLabel: "p")
        #expect(Self.verification(try Self.signed(shown: ascii), copy: Self.copy) == .unverified(.signatureInvalid))
    }

    // MARK: - Order: the first failure wins

    /// A claim wrong in every way at once, made right one field at a time:
    /// each step reports the next check in the fixed order.
    @Test func theFirstFailureWins() throws {
        let good = try Self.signed()
        var evidence = Self.evidence(good, wireVersion: 2, promptID: Self.promptID.hex.uppercased(), verdict: "maybe",
                                     decidedAt: Date(timeIntervalSince1970: TimeInterval(Self.decidedAt) + 0.5),
                                     signature: good.signature.prefix(63))
        var key: P256.Signing.PublicKey?
        var copy: ForwardedCopy?
        var seen: [DecisionUnverifiedReason] = []
        let fixes: [() -> Void] = [
            { key = Self.phone.publicKey },
            { evidence = Self.evidence(evidence, verdict: good.verdict) },
            { evidence = Self.evidence(evidence, decidedAt: good.decidedAt) },
            { evidence = Self.evidence(evidence, signature: Data(count: 64)) },
            { evidence = Self.evidence(evidence, wireVersion: good.wireVersion) },
            { evidence = Self.evidence(evidence, promptID: good.promptID) },
            { copy = Self.copy },
            { evidence = Self.evidence(evidence, signature: good.signature) },
        ]
        for fix in fixes {
            if let reason = Self.reason(DecisionVerifier.verification(of: evidence, copy: copy, pairedKey: key)) { seen.append(reason) }
            fix()
        }
        #expect(seen == [.noPairedKey, .unknownVerdict, .fractionalDecidedAt, .signatureLength, .wrongWireVersion,
                         .malformedPromptID, .noForwardedCopy, .signatureInvalid])
        #expect(Self.reason(DecisionVerifier.verification(of: evidence, copy: copy, pairedKey: key)) == nil, "all fixed: it verifies")
    }

    // MARK: - The audit (closed vocabulary)

    @Test func theReasonsAreAClosedVocabulary() {
        #expect(DecisionUnverifiedReason.allCases.map(\.rawValue)
            == ["noPairedKey", "unknownVerdict", "decidedAtOutOfRange", "fractionalDecidedAt", "signatureLength", "wrongWireVersion",
                "malformedPromptID", "noForwardedCopy", "signatureInvalid", "shownDigestMismatch"])
        for reason in DecisionUnverifiedReason.allCases {
            #expect(DecisionVerifierAudit(promptID: nil, reason: reason).code == "decision.unverified." + reason.rawValue)
            #expect(DecisionVerifierAudit(promptID: Self.promptID, reason: reason).code
                    == "prompt=0123456789abcdef0123456789abcdef decision.unverified." + reason.rawValue)
        }
    }

    /// A refusal is dropped and audited once, by its code, and nothing of the
    /// prompt's text, the key or the signature reaches the line; a verified
    /// decision is handed back and audits nothing here (the lifecycle logs
    /// what it does with it).
    @Test func aRefusalIsDroppedAndAuditedOnly() throws {
        let secret = ForwardedCopy(promptID: Self.promptID, toolName: "Bash", inputPreview: "{\"command\":\"SECRET-PREVIEW\"}",
                                   projectLabel: "SECRET-LABEL")
        var lines: [String] = []
        let keys = try Self.slot()
        let refused = try Self.signed(shown: Self.copy)
        #expect(DecisionVerifier.verify(refused, copy: secret, keys: keys) { lines.append($0.code) } == .unverified(.signatureInvalid))
        #expect(lines == ["prompt=0123456789abcdef0123456789abcdef decision.unverified.signatureInvalid"])
        #expect(DecisionVerifier.verify(Self.evidence(refused, promptID: "NOT-AN-ID"), copy: secret, keys: keys) {
            lines.append($0.code)
        } == .unverified(.malformedPromptID))
        #expect(lines.last == "decision.unverified.malformedPromptID")
        let signature = refused.signature.map { String(format: "%02x", $0) }.joined()
        for line in lines {
            for leak in ["SECRET", "Bash", String(signature.prefix(16)), "NOT-AN-ID"] where line.contains(leak) {
                Issue.record("'\(leak)' reached the audit line \(line)")
            }
        }
        lines.removeAll()
        let decision = Self.decision(DecisionVerifier.verify(try Self.signed(shown: secret), copy: secret, keys: keys) {
            lines.append($0.code)
        })
        #expect(decision?.promptID == Self.promptID && decision?.verdict == .allow && decision?.signatureVerified == true)
        #expect(lines.isEmpty)
    }

    // MARK: - The paired key is read at each verification (S-PAIR-C2)

    /// The verifier reads the slot once per verification and keeps nothing:
    /// an Unpair between two verifications makes the second refuse, and a
    /// new pairing's key is the only one the next verification trusts.
    @Test func anUnpairBetweenTwoVerificationsMakesTheSecondRefuse() throws {
        let items = FakeTopicStore()
        let unpairs = UnpairRecord(medium: FakeTopicStore())
        let keys = try Self.slot(items, unpairs: unpairs)
        let evidence = try Self.signed()
        var lines: [String] = []
        let reads = items.readCount
        #expect(Self.decision(DecisionVerifier.verify(evidence, copy: Self.copy, keys: keys) { lines.append($0.code) }) != nil)
        #expect(items.readCount == reads + 1, "the slot is read at the verification")
        #expect(keys.unpair())
        let unpaired = items.readCount
        #expect(DecisionVerifier.verify(evidence, copy: Self.copy, keys: keys) { lines.append($0.code) } == .unverified(.noPairedKey))
        #expect(items.readCount == unpaired + 1, "and read again at the next one")
        #expect(lines == ["prompt=\(Self.promptID.hex) decision.unverified.noPairedKey"])
        // A new pairing: the old key's signature no longer verifies, the new one's does.
        let newPhone = P256.Signing.PrivateKey()
        let repaired = try Self.slot(items, unpairs: unpairs, paired: newPhone)
        #expect(DecisionVerifier.verify(evidence, copy: Self.copy, keys: repaired) { _ in } == .unverified(.signatureInvalid))
        #expect(DecisionVerifier.verify(evidence, copy: Self.copy, keys: keys) { _ in } == .unverified(.signatureInvalid),
                "every handle on the slot reads the slot")
        #expect(Self.decision(DecisionVerifier.verify(try Self.signed(by: newPhone), copy: Self.copy, keys: keys) { _ in }) != nil)
    }

    /// No pairing, a keychain that refuses, or a stored text this build does
    /// not read: no key, so nothing verifies, and the code says so first.
    @Test func aSlotWithNoReadablePairingVerifiesNothing() throws {
        let evidence = try Self.signed()
        let unread = FakeTopicStore()
        unread.setReadAnswer(.failed(status: -25308))
        let none = UnpairRecord(medium: FakeTopicStore())
        let slots: [(String, PairedKeyStore)] = [
            ("never paired", try Self.slot(paired: nil)),
            ("the keychain refused", PairedKeyStore(items: unread, unpairs: none)),
            ("a stored text not this build's", PairedKeyStore(items: FakeTopicStore("napcat-paired-v1\nkey:04\n"), unpairs: none)),
        ]
        for (name, keys) in slots {
            #expect(DecisionVerifier.verify(evidence, copy: Self.copy, keys: keys) { _ in } == .unverified(.noPairedKey), "\(name)")
        }
    }

    // MARK: - #247: an outstanding Unpair binds the verifier's read

    /// The owner asked Unpair to remove the key and the keychain refused:
    /// a decision that key signed, exactly right, does not verify — now, and
    /// after a relaunch (a fresh slot and record over the same two fakes).
    /// Once a deletion goes through the record is gone, and a NEW pairing's
    /// key verifies as any pairing's does.
    @Test func aKeyUnderAnOutstandingUnpairVerifiesNothingAcrossARelaunch() throws {
        let items = FakeTopicStore()
        let medium = FakeTopicStore()
        let keys = try Self.slot(items, unpairs: UnpairRecord(medium: medium))
        let evidence = try Self.signed()
        #expect(Self.decision(DecisionVerifier.verify(evidence, copy: Self.copy, keys: keys) { _ in }) != nil, "vacuity: it verifies")
        items.setFailDeletes(true)
        #expect(!keys.unpair())
        #expect(items.storedValue != nil && medium.storedValue != nil, "vacuity: the key and the record are both stored")
        var lines: [String] = []
        #expect(DecisionVerifier.verify(evidence, copy: Self.copy, keys: keys) { lines.append($0.code) } == .unverified(.noPairedKey))
        #expect(lines == ["prompt=\(Self.promptID.hex) decision.unverified.noPairedKey"])

        let relaunched = PairedKeyStore(items: items, unpairs: UnpairRecord(medium: medium))
        #expect(DecisionVerifier.verify(evidence, copy: Self.copy, keys: relaunched) { _ in } == .unverified(.noPairedKey),
                "a relaunch keeps the refusal")
        items.setFailDeletes(false)
        #expect(relaunched.unpair())
        #expect(items.storedValue == nil && medium.storedValue == nil, "the key, then the record")

        let newPhone = P256.Signing.PrivateKey()
        let repaired = try Self.slot(items, unpairs: UnpairRecord(medium: medium), paired: newPhone)
        #expect(Self.decision(DecisionVerifier.verify(try Self.signed(by: newPhone), copy: Self.copy, keys: repaired) { _ in }) != nil,
                "the new pairing's key verifies")
        #expect(DecisionVerifier.verify(evidence, copy: Self.copy, keys: repaired) { _ in } == .unverified(.signatureInvalid))
    }

    /// Fail-closed: a record that cannot be read — the read refused, a
    /// text not the record's form, or the item's digest garbled — holds
    /// whatever key the slot holds, even when no Unpair ever ran; and a
    /// record the disk would not write still holds for this run.
    @Test func aRecordThatCannotBeReadOrWrittenRefuses() throws {
        let evidence = try Self.signed()
        let item: String = "item:"
        let unreadable: [(String, TopicStoreRead)] = [
            ("the read refused", .failed(status: 13)),
            ("another form", .found("not a record")),
            ("a short digest", .found(UnpairRecord.header + "\n" + item + "abcd\n")),
            ("an uppercase digest", .found(UnpairRecord.header + "\n" + item + String(repeating: "A", count: 64) + "\n")),
        ]
        for (name, found) in unreadable {
            // The key is paired first (a key written ends any record), then
            // the record turns up as it is.
            let medium = FakeTopicStore()
            let keys = try Self.slot(unpairs: UnpairRecord(medium: medium))
            #expect(Self.decision(DecisionVerifier.verify(evidence, copy: Self.copy, keys: keys) { _ in }) != nil, "\(name): vacuity")
            medium.setReadAnswer(found)
            #expect(DecisionVerifier.verify(evidence, copy: Self.copy, keys: keys) { _ in } == .unverified(.noPairedKey), "\(name)")
        }

        let items = FakeTopicStore()
        let medium = FakeTopicStore()
        let keys = try Self.slot(items, unpairs: UnpairRecord(medium: medium))
        medium.setFailWrites(true)
        items.setFailDeletes(true)
        #expect(!keys.unpair())
        #expect(medium.storedValue == nil, "vacuity: the disk refused the record")
        #expect(DecisionVerifier.verify(evidence, copy: Self.copy, keys: keys) { _ in } == .unverified(.noPairedKey),
                "this run keeps the record the disk refused")
    }

    // MARK: - The lifecycle keeps its own checks

    /// The verifier counts nothing itself: a verified decision goes to the
    /// prompt's lifecycle, which still discards a duplicate and judges the
    /// TTL on the Mac's clock, as it always did.
    @Test func duplicatesAndTheTTLStayTheLifecycles() throws {
        let decision = try #require(Self.decision(DecisionVerifier.verify(try Self.signed(), copy: Self.copy, keys: try Self.slot()) { _ in }))
        var (lifecycle, _) = ApprovalLifecycle.open(id: Self.promptID, classification: .forward(.bash), armed: true, now: 0)
        _ = lifecycle.apply(.saveAccepted, now: 1)
        #expect(lifecycle.apply(.remoteDecision(decision), now: 2).effects.contains(.deliverVerdict(.allow)))
        #expect(lifecycle.apply(.remoteDecision(decision), now: 3).audit == [.ignored(.alreadyResolved)])
        var (late, _) = ApprovalLifecycle.open(id: Self.promptID, classification: .forward(.bash), armed: true, now: 0)
        _ = late.apply(.saveAccepted, now: 1)
        let expired = late.apply(.remoteDecision(decision), now: ApprovalWire.promptTimeToLiveSeconds)
        #expect(!expired.effects.contains(.deliverVerdict(.allow)) && expired.audit.contains(.ignored(.expired)))
    }
}
