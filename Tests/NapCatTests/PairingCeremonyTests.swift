// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import CryptoKit
import NapCatWire
import Testing
@testable import NapCat

/// The phone's half of a pairing, played the way S-PAIR-B's
/// `PairingCeremony.response` does it, over a SOFTWARE key (CI has no Secure
/// Enclave): the confirmation MAC keyed by the nonce, the proof signed by the
/// new key, both over the wire's own builders.
enum PhoneHalf {
    static let nonce = Array(0..<UInt8(32))
    static let otherNonce = Array(repeating: UInt8(0x5a), count: 32)

    static func response(nonce: [UInt8] = nonce, key: P256.Signing.PrivateKey = P256.Signing.PrivateKey(),
                         macNonce: [UInt8]? = nil, proofNonce: [UInt8]? = nil,
                         signer: P256.Signing.PrivateKey? = nil) throws -> PairingResponseClaim {
        let publicKey = Array(key.publicKey.x963Representation)
        let proofMessage = try #require(ApprovalSigning.pairingProofMessage(nonce: proofNonce ?? nonce, publicKey: publicKey))
        let confirmationMessage = try #require(ApprovalSigning.pairingConfirmationMessage(wireVersion: ApprovalWire.wireVersion,
                                                                                          publicKey: publicKey))
        let proof = try (signer ?? key).signature(for: SHA256.hash(data: proofMessage)).rawRepresentation
        let confirmation = HMAC<SHA256>.authenticationCode(for: confirmationMessage, using: SymmetricKey(data: macNonce ?? nonce))
        return PairingResponseClaim(publicKey: publicKey, confirmation: Array(confirmation), proof: Array(proof))
    }

    static func recordName(_ nonce: [UInt8] = nonce) -> String {
        PairingResponseCheck.recordName(nonce: nonce) ?? ""
    }

    static func fingerprint(_ response: PairingResponseClaim) -> PairingFingerprint? {
        PairingFingerprint(digest: Array(SHA256.hash(data: response.publicKey)))
    }
}

/// F4 slice S-PAIR-C1 (#168): the Mac's ceremony as a pure state machine,
/// table-tested with no CloudKit, no keychain and no clock: every event in,
/// every effect out. The spec's states S1a–S1e map to the phases; the frozen
/// contract's rules — first verified fetch freezes, any later difference
/// refuses, Codes Match is the only commit, the window bounds everything
/// before it, every end burns the nonce and deletes the record — are each a
/// row here.
struct PairingCeremonyTests {
    static let start: TimeInterval = 1_800_000_000

    /// A ceremony begun at `start` with `PhoneHalf.nonce`.
    static func begun(rotating: Bool = false) -> (PairingCeremonyState, [PairingEffect]) {
        var state = PairingCeremonyState()
        let effects = state.apply(.begin(nonce: PhoneHalf.nonce, rotating: rotating, now: start))
        return (state, effects)
    }

    /// Ticks to the first poll and answers it with `fetch`.
    static func polled(_ state: inout PairingCeremonyState, _ fetch: PairingFetch,
                       at seconds: TimeInterval = PairingCeremonyState.pollInterval) -> [PairingEffect] {
        let tick = state.apply(.tick(now: start + seconds))
        guard tick == [.fetch(recordName: PhoneHalf.recordName())] else { return [.audit(.nonceUnavailable)] + tick }
        return state.apply(.fetched(fetch, now: start + seconds))
    }

    /// A ceremony in S1c over a verified response.
    static func comparing() throws -> (PairingCeremonyState, PairingCandidate) {
        var (state, _) = begun()
        let response = try PhoneHalf.response()
        #expect(polled(&state, .found(.response(response))) == [.audit(.verified)])
        guard case .comparing(let candidate) = state.phase else {
            Issue.record("not comparing: \(state.phase)")
            throw CancellationError()
        }
        return (state, candidate)
    }

    static func deleted() -> PairingEffect { .delete(recordName: PhoneHalf.recordName()) }

    // MARK: - Begin (S1a)

    @Test func beginShowsTheCodeAndRemembersOnlyTheRecordsName() throws {
        let (state, effects) = Self.begun()
        let name = PhoneHalf.recordName()
        #expect(effects == [.rememberRecord(name), .audit(.begun(rotating: false))])
        #expect(name.count == 64 && name.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(!effects.contains { "\($0)".contains(ApprovalSigning.pairingPayload(nonce: PhoneHalf.nonce)!) },
                "the payload is never an effect")
        #expect(state.phase == .showing(offline: false))
        #expect(state.qrPayload == ApprovalSigning.pairingPayload(nonce: PhoneHalf.nonce))
        #expect(ApprovalSigning.pairingNonce(fromPayload: try #require(state.qrPayload)) == PhoneHalf.nonce, "the phone reads it back")
        #expect(state.holdsNonce)
        #expect(state.deadline == Self.start + 300 && state.secondsLeft(now: Self.start + 2) == 298)
    }

    /// The name is SHA-256 of the label and the nonce — computed here from
    /// the wire's own builder and an independent digest, and equal to the
    /// one the phone derives (`PairingCeremony.response` on the phone uses
    /// the same two builders).
    @Test func theRecordNameIsTheLabelledDigestOfTheNonce() throws {
        let input = Array("napcat-pair-name-v1".utf8) + PhoneHalf.nonce
        let expected = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
        #expect(PairingResponseCheck.recordName(nonce: PhoneHalf.nonce) == expected)
        #expect(PairingResponseCheck.recordName(nonce: Array(PhoneHalf.nonce.dropLast())) == nil)
    }

    @Test func aNonceOfTheWrongSizeBeginsNothing() {
        var state = PairingCeremonyState()
        #expect(state.apply(.begin(nonce: [1, 2, 3], rotating: false, now: Self.start)) == [.audit(.nonceUnavailable)])
        #expect(state.phase == .idle && !state.holdsNonce && state.qrPayload == nil)
    }

    /// Starting a ceremony burns any live one: its record goes, its nonce
    /// dies, and the new one remembers its own name.
    @Test func startingANewCeremonyBurnsTheLiveOne() throws {
        var (state, _) = Self.begun()
        let effects = state.apply(.begin(nonce: PhoneHalf.otherNonce, rotating: false, now: Self.start + 10))
        #expect(effects == [Self.deleted(), .rememberRecord(PhoneHalf.recordName(PhoneHalf.otherNonce)),
                            .audit(.begun(rotating: false))])
        #expect(state.qrPayload == ApprovalSigning.pairingPayload(nonce: PhoneHalf.otherNonce))
    }

    // MARK: - Hidden (S1b)

    /// Not key or occluded: the code is hidden, the window keeps running,
    /// and the nonce is NOT burned; back to S1a on key.
    @Test func aHiddenSheetHidesTheCodeAndKeepsTheCeremony() {
        var (state, _) = Self.begun()
        #expect(state.apply(.visible(false)) == [])
        #expect(state.qrPayload == nil && state.holdsNonce && state.phase == .showing(offline: false))
        #expect(state.apply(.tick(now: Self.start + 3)) == [.fetch(recordName: PhoneHalf.recordName())], "polls go on")
        _ = state.apply(.visible(true))
        #expect(state.qrPayload == ApprovalSigning.pairingPayload(nonce: PhoneHalf.nonce))
    }

    // MARK: - Polling

    @Test func pollsRunEveryFewSecondsOneAtATime() {
        var (state, _) = Self.begun()
        #expect(state.apply(.tick(now: Self.start + 1)) == [], "not before the first interval")
        #expect(state.apply(.tick(now: Self.start + 2.5)) == [.fetch(recordName: PhoneHalf.recordName())])
        #expect(state.apply(.tick(now: Self.start + 6)) == [], "one fetch at a time")
        #expect(state.apply(.fetched(.nothing, now: Self.start + 6)) == [])
        #expect(state.apply(.tick(now: Self.start + 6)) == [.fetch(recordName: PhoneHalf.recordName())])
        #expect(state.apply(.fetched(.unreachable, now: Self.start + 6.5)) == [])
        #expect(state.phase == .showing(offline: true), "the offline variant")
        _ = state.apply(.tick(now: Self.start + 9))
        _ = state.apply(.fetched(.nothing, now: Self.start + 9))
        #expect(state.phase == .showing(offline: false))
        #expect(state.apply(.fetched(.nothing, now: Self.start + 9)) == [], "an answer nobody asked for changes nothing")
    }

    // MARK: - The first response: checked, then frozen (S1c)

    @Test func aVerifiedResponseIsFrozenForComparison() throws {
        let (state, candidate) = try Self.comparing()
        #expect(state.qrPayload == nil, "the QR never returns once frozen")
        #expect(state.holdsNonce, "the nonce lives until the ceremony ends")
        #expect(candidate.fingerprint == PhoneHalf.fingerprint(candidate.response))
    }

    struct RefusalRow: Sendable {
        let name: String
        let fetch: @Sendable () throws -> PairingFetch
        let refusal: PairingRefusal
    }

    /// Every way the first response fails: each refuses, burns the nonce and
    /// deletes the record — and nothing is committed.
    static let refusals: [RefusalRow] = [
        RefusalRow(name: "a malformed record", fetch: { .found(.malformed(.unencryptedField)) },
                   refusal: .malformed(.unencryptedField)),
        RefusalRow(name: "a MAC keyed by another nonce (a forger without the code)", fetch: {
            .found(.response(try PhoneHalf.response(macNonce: PhoneHalf.otherNonce))) }, refusal: .confirmationInvalid),
        RefusalRow(name: "a MAC over another key (the key swapped after the MAC)", fetch: {
            let honest = try PhoneHalf.response()
            let swapped = try PhoneHalf.response()
            return .found(.response(PairingResponseClaim(publicKey: swapped.publicKey, confirmation: honest.confirmation,
                                                         proof: swapped.proof))) }, refusal: .confirmationInvalid),
        RefusalRow(name: "a zeroed MAC", fetch: {
            let honest = try PhoneHalf.response()
            return .found(.response(PairingResponseClaim(publicKey: honest.publicKey, confirmation: Array(repeating: 0, count: 32),
                                                         proof: honest.proof))) }, refusal: .confirmationInvalid),
        RefusalRow(name: "a proof signed by another key", fetch: {
            .found(.response(try PhoneHalf.response(signer: P256.Signing.PrivateKey()))) }, refusal: .proofInvalid),
        RefusalRow(name: "a proof over another nonce", fetch: {
            .found(.response(try PhoneHalf.response(proofNonce: PhoneHalf.otherNonce))) }, refusal: .proofInvalid),
        RefusalRow(name: "a proof of zeroes", fetch: {
            let honest = try PhoneHalf.response()
            return .found(.response(PairingResponseClaim(publicKey: honest.publicKey, confirmation: honest.confirmation,
                                                         proof: Array(repeating: 0, count: 64)))) }, refusal: .proofInvalid),
        RefusalRow(name: "a key that is no curve point (its MAC honest)", fetch: {
            let key = [UInt8(0x04)] + Array(repeating: 0xab, count: 64)
            let message = ApprovalSigning.pairingConfirmationMessage(wireVersion: 1, publicKey: key)!
            let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: PhoneHalf.nonce))
            return .found(.response(PairingResponseClaim(publicKey: key, confirmation: Array(mac),
                                                         proof: Array(repeating: 1, count: 64)))) }, refusal: .proofInvalid),
    ]

    @Test func everyBadFirstResponseRefusesAndBurns() throws {
        for row in Self.refusals {
            var (state, _) = Self.begun()
            let effects = Self.polled(&state, try row.fetch())
            #expect(effects == [.audit(.refused(row.refusal)), Self.deleted(), .audit(.ended(.refused))], "\(row.name)")
            #expect(state.phase == .ended(.refused) && !state.holdsNonce && state.qrPayload == nil, "\(row.name)")
            #expect(!effects.contains { if case .commit = $0 { true } else { false } }, "\(row.name): nothing is kept")
        }
    }

    /// The check itself, out of the state machine: the honest response
    /// verifies; MAC before proof (a response failing both is refused on
    /// its MAC).
    @Test func theChecksRunInOrder() throws {
        let honest = try PhoneHalf.response()
        #expect(PairingResponseCheck.check(honest, nonce: PhoneHalf.nonce)
                == .verified(PairingCandidate(response: honest, fingerprint: try #require(PhoneHalf.fingerprint(honest)))))
        let both = try PhoneHalf.response(macNonce: PhoneHalf.otherNonce, signer: P256.Signing.PrivateKey())
        #expect(PairingResponseCheck.check(both, nonce: PhoneHalf.nonce) == .refused(.confirmationInvalid))
        #expect(PairingResponseCheck.check(honest, nonce: PhoneHalf.otherNonce) == .refused(.confirmationInvalid))
        #expect(PairingResponseCheck.check(honest, nonce: []) == .refused(.confirmationInvalid))
    }

    // MARK: - After the freeze

    @Test func theSameResponseAgainChangesNothing() throws {
        var (state, candidate) = try Self.comparing()
        #expect(Self.polled(&state, .found(.response(candidate.response)), at: 6) == [])
        #expect(Self.polled(&state, .unreachable, at: 9) == [], "an unreachable poll is not content")
        #expect(state.phase == .comparing(candidate))
    }

    /// Any later poll reading something else tears S1c down: refused,
    /// burned — never a swapped code.
    @Test func aDifferentResponseAfterTheFreezeRefuses() throws {
        let other = try PhoneHalf.response()
        let rows: [(String, PairingFetch, PairingRefusal)] = [
            ("a second, valid response", .found(.response(other)), .differentResponse),
            ("a malformed record", .found(.malformed(.wrongWireVersion)), .differentResponse),
            ("the record gone", .nothing, .responseGone),
        ]
        for (name, fetch, refusal) in rows {
            var (state, _) = try Self.comparing()
            let effects = Self.polled(&state, fetch, at: 6)
            #expect(effects == [.audit(.refused(refusal)), Self.deleted(), .audit(.ended(.refused))], "\(name)")
            #expect(state.phase == .ended(.refused) && !state.holdsNonce, "\(name)")
            #expect(state.apply(.codesMatch(now: Self.start + 7)) == [], "\(name): nothing left to confirm")
        }
    }

    // MARK: - The owner's decision

    /// Codes Match is THE way to a commit; the record is deleted only after
    /// the keychain write reports success.
    @Test func codesMatchCommitsThenDeletesTheRecord() throws {
        var (state, candidate) = try Self.comparing()
        #expect(state.apply(.codesMatch(now: Self.start + 10)) == [.commit(candidate)])
        #expect(state.phase == .committing(candidate))
        #expect(state.apply(.cancel) == [], "a write under way is not cancelled")
        #expect(state.apply(.committed(true)) == [Self.deleted(), .audit(.committed)])
        #expect(state.phase == .paired(candidate.fingerprint) && !state.holdsNonce)
        #expect(state.apply(.cancel) == [] && state.phase == .idle, "Done closes")
    }

    @Test func aFailedWriteEndsSaveFailedAndKeepsNothing() throws {
        var (state, candidate) = try Self.comparing()
        _ = state.apply(.codesMatch(now: Self.start + 10))
        #expect(state.apply(.committed(false)) == [Self.deleted(), .audit(.ended(.saveFailed))])
        #expect(state.phase == .ended(.saveFailed) && !state.holdsNonce)
        _ = candidate
    }

    @Test func theyDontMatchStopsAndBurns() throws {
        var (state, _) = try Self.comparing()
        #expect(state.apply(.codesDiffer) == [Self.deleted(), .audit(.ended(.stoppedMismatch))])
        #expect(state.phase == .ended(.stoppedMismatch) && !state.holdsNonce)
    }

    /// Nothing but Codes Match commits: no other event, in any phase, ever
    /// returns a commit.
    @Test func nothingElseEverCommits() throws {
        let response = try PhoneHalf.response()
        let events: [PairingEvent] = [
            .visible(false), .visible(true), .tick(now: Self.start + 2.5), .fetched(.found(.response(response)), now: Self.start + 2.5),
            .tick(now: Self.start + 5), .fetched(.found(.response(response)), now: Self.start + 5), .codesDiffer, .committed(true),
            .cancel, .tick(now: Self.start + 400),
        ]
        var (state, _) = Self.begun()
        for event in events where event != .codesDiffer {
            #expect(!state.apply(event).contains { if case .commit = $0 { true } else { false } }, "\(event) committed")
        }
        // … and Codes Match outside S1c commits nothing either.
        var (showing, _) = Self.begun()
        #expect(showing.apply(.codesMatch(now: Self.start + 1)) == [])
        var idle = PairingCeremonyState()
        #expect(idle.apply(.codesMatch(now: Self.start)) == [])
    }

    // MARK: - The window (TTL bounds everything before the commit)

    @Test func theWindowEndsTheCodeAndTheComparison() throws {
        var (showing, _) = Self.begun()
        #expect(showing.apply(.tick(now: Self.start + 299.9)) == [.fetch(recordName: PhoneHalf.recordName())])
        _ = showing.apply(.fetched(.nothing, now: Self.start + 299.95))
        #expect(showing.apply(.tick(now: Self.start + 300)) == [Self.deleted(), .audit(.ended(.expired))])
        #expect(showing.phase == .ended(.expired) && !showing.holdsNonce)

        var (comparing, _) = try Self.comparing()
        #expect(comparing.apply(.tick(now: Self.start + 300)) == [Self.deleted(), .audit(.ended(.expired))])
        #expect(comparing.phase == .ended(.expired))

        var (late, _) = try Self.comparing()
        #expect(late.apply(.codesMatch(now: Self.start + 301)) == [Self.deleted(), .audit(.ended(.expired))],
                "a confirm after the window commits nothing")

        var (answered, _) = Self.begun()
        _ = answered.apply(.tick(now: Self.start + 298))
        #expect(answered.apply(.fetched(.found(.response(try PhoneHalf.response())), now: Self.start + 300))
                == [Self.deleted(), .audit(.ended(.expired))], "a response read after the window is not checked")
    }

    // MARK: - Cancel (Esc, Cancel, the window closing)

    @Test func cancelBurnsTheNonceAndDeletesTheRecord() throws {
        var (showing, _) = Self.begun()
        #expect(showing.apply(.cancel) == [Self.deleted(), .audit(.cancelled)])
        #expect(showing.phase == .idle && !showing.holdsNonce && showing.qrPayload == nil)

        var (comparing, _) = try Self.comparing()
        #expect(comparing.apply(.cancel) == [Self.deleted(), .audit(.cancelled)])
        #expect(comparing.phase == .idle && !comparing.holdsNonce)

        var (ended, _) = Self.begun()
        _ = ended.apply(.codesDiffer)
        _ = ended.apply(.tick(now: Self.start + 400))
        #expect(ended.phase == .ended(.expired))
        #expect(ended.apply(.cancel) == [] && ended.phase == .idle, "Close after an end deletes nothing twice")
    }

    /// Rotation: a ceremony over a paired phone says so, and touches nothing
    /// of the old key until the commit (the state machine never names it).
    @Test func aRotationIsMarkedAndOtherwiseTheSame() throws {
        let (state, effects) = Self.begun(rotating: true)
        #expect(state.rotating)
        #expect(effects == [.rememberRecord(PhoneHalf.recordName()), .audit(.begun(rotating: true))])
        var cancelled = state
        #expect(cancelled.apply(.cancel) == [Self.deleted(), .audit(.cancelled)], "cancel leaves the old key alone")
    }

    // MARK: - The audit's closed vocabulary

    @Test func auditCodesNameNoSecret() throws {
        let response = try PhoneHalf.response()
        let codes = [PairingAudit.begun(rotating: false), .begun(rotating: true), .verified, .cancelled, .committed,
                     .nonceUnavailable, .unpaired, .unpairFailed, .leftoverDeleted, .leftoverKept]
            .map(\.code)
            + PairingEnd.allCases.map { PairingAudit.ended($0).code }
            + PairingResponseFault.allCases.map { PairingAudit.refused(.malformed($0)).code }
            + [PairingRefusal.confirmationInvalid, .proofInvalid, .differentResponse, .responseGone].map { PairingAudit.refused($0).code }
        let secrets = [ApprovalSigning.lowercaseHex(PhoneHalf.nonce), ApprovalSigning.pairingPayload(nonce: PhoneHalf.nonce)!,
                       PhoneHalf.recordName(), ApprovalSigning.lowercaseHex(response.publicKey)]
        for code in codes {
            #expect(code.hasPrefix("pairing.") && code.range(of: #"^pairing\.[A-Za-z.]+( rotating)?$"#, options: .regularExpression) != nil,
                    "'\(code)' is a closed code")
            for secret in secrets { #expect(!code.contains(secret)) }
        }
        #expect(Set(codes).count == codes.count, "every code is distinct")
    }
}
