import CryptoKit
import Foundation
import NapCatWire

// F4 slice S-PAIR-C1 (#168, Refs #161): the Mac's half of the pairing
// ceremony, as a PURE state machine (no clock, no I/O, no randomness: the
// shell, `PairingController`, feeds it events and performs the effects it
// returns), table-tested headlessly. Design: design/remote-approvals.md,
// "Slice S-PAIR"; the sheet's states S1a–S1e are the ratified UX spec's.
//
// 1. Begin: a fresh 256-bit nonce N (made by the shell), shown as the QR
//    payload `napcat-pair-v1:<base64url N>`; the response's record name is
//    derived from it, SHA-256("napcat-pair-name-v1" || N), and that NAME —
//    never N — is persisted first, so a crash can still delete the record at
//    the next launch. Starting a ceremony burns any live one.
// 2. While the code shows, the shell polls the name every few seconds (the
//    sheet's life only). The FIRST response read is checked at once: the
//    confirmation MAC keyed by N, then the proof signed by the delivered key.
//    Any failure refuses, and burns the nonce.
// 3. The first verified response is FROZEN: the QR never returns, the code
//    to compare is the frozen key's, and any later poll that reads anything
//    else (another response, or none) refuses — never a swapped code.
// 4. Only the owner's Codes Match commits the key (one effect, from one
//    event: PairingStructureTests); They Don't Match stops. The keychain
//    write comes before the record's deletion; a failed write ends as
//    save-failed, the slot as it was.
// 5. The five-minute window bounds everything before the commit, the
//    comparison included. Every end — accept, cancel, mismatch, refusal,
//    expiry, a failed save — burns the nonce and deletes the record.
//
// Nothing here arms anything or names a decision: pairing installs a key,
// and no reader of decisions uses it in this slice (S-PAIR-C2).

// MARK: - The record seam

/// What one fetch of the pairing record by name came to.
enum PairingFetch: Equatable, Sendable {
    /// No record by that name (yet).
    case nothing
    /// iCloud did not answer; the ceremony keeps waiting.
    case unreachable
    /// The record, read strictly (`PairingResponseReader`).
    case found(PairingResponseReading)
}

/// THE seam over the pairing record: fetch it by its derived name, delete it
/// by that name. Nothing else: no query, no listing, no save. Since
/// S-PAIR-C1.5 (#170) the app's one conformer is `CloudKitPairingRecords`
/// (the record path's file, lint-locked to its declaration's line); tests
/// play CloudKit's part.
protocol PairingRecordSource: AnyObject, Sendable {
    func fetch(recordName: String) async -> PairingFetch
    /// True when the record is gone: deleted now, or never there.
    func delete(recordName: String) async -> Bool
}

// MARK: - The checks

/// A response that passed both checks, frozen as read.
struct PairingCandidate: Equatable, Sendable {
    let response: PairingResponseClaim
    /// The code of the delivered key, computed here from its bytes.
    let fingerprint: PairingFingerprint
}

/// Why a fetched response was refused (closed vocabulary; also the audit's).
enum PairingRefusal: Equatable, Sendable {
    /// The record failed the strict reading.
    case malformed(PairingResponseFault)
    /// The confirmation is not the MAC keyed by this ceremony's nonce.
    case confirmationInvalid
    /// The delivered key did not sign the proof (or is no P-256 key).
    case proofInvalid
    /// After the freeze, a poll read a different response.
    case differentResponse
    /// After the freeze, a poll found the record gone.
    case responseGone

    var code: String {
        switch self {
        case .malformed(let fault): return "malformed." + fault.rawValue
        case .confirmationInvalid: return "confirmationInvalid"
        case .proofInvalid: return "proofInvalid"
        case .differentResponse: return "differentResponse"
        case .responseGone: return "responseGone"
        }
    }
}

enum PairingResponseCheck {
    enum Outcome: Equatable, Sendable {
        case verified(PairingCandidate)
        case refused(PairingRefusal)
    }

    /// The ceremony's two checks, in order: the confirmation must be the
    /// HMAC-SHA256 keyed by `nonce` over the confirmation message (only a
    /// holder of the code on this screen can make it), and the delivered key
    /// must have signed the proof message over `nonce` and itself (the key
    /// the record names can sign). The MAC is compared in constant time.
    static func check(_ response: PairingResponseClaim, nonce: [UInt8]) -> Outcome {
        guard nonce.count == ApprovalSigning.pairingNonceByteCount,
              let confirmationMessage = ApprovalSigning.pairingConfirmationMessage(wireVersion: ApprovalWire.wireVersion,
                                                                                    publicKey: response.publicKey),
              HMAC<SHA256>.isValidAuthenticationCode(response.confirmation, authenticating: confirmationMessage,
                                                      using: SymmetricKey(data: nonce)) else {
            return .refused(.confirmationInvalid)
        }
        guard let proofMessage = ApprovalSigning.pairingProofMessage(nonce: nonce, publicKey: response.publicKey),
              let key = try? P256.Signing.PublicKey(x963Representation: response.publicKey),
              let proof = try? P256.Signing.ECDSASignature(rawRepresentation: response.proof),
              key.isValidSignature(proof, for: SHA256.hash(data: proofMessage)),
              let fingerprint = PairingFingerprint(digest: Array(SHA256.hash(data: response.publicKey))) else {
            return .refused(.proofInvalid)
        }
        return .verified(PairingCandidate(response: response, fingerprint: fingerprint))
    }

    /// The record name a nonce derives: SHA-256 of the label and the nonce,
    /// as 64 lowercase hex digits. nil unless the nonce is 32 bytes.
    static func recordName(nonce: [UInt8]) -> String? {
        ApprovalSigning.pairingRecordNameInput(nonce: nonce)
            .flatMap { ApprovalSigning.pairingRecordName(digest: Array(SHA256.hash(data: $0))) }
    }

    /// Whether `name` has a pairing record name's shape — exactly 64
    /// lowercase hex digits, `^[0-9a-f]{64}$` read byte by byte (no line end,
    /// no other character, no other case) — the only names the app ever
    /// fetches or deletes a pairing record by (S-PAIR-C1.5, #170).
    static func isRecordName(_ name: String) -> Bool {
        let hex = Set("0123456789abcdef".utf8)
        return name.utf8.count == ApprovalSigning.recordNameHexDigits && name.utf8.allSatisfy(hex.contains)
    }
}

// MARK: - The state machine

/// How a ceremony ended without pairing (S1e): a CLOSED set, no free text.
enum PairingEnd: String, CaseIterable, Sendable {
    /// The window closed first.
    case expired
    /// A response failed a check, or changed after the freeze.
    case refused
    /// The owner said the codes differ.
    case stoppedMismatch
    /// The owner confirmed, but the key could not be saved.
    case saveFailed
}

enum PairingPhase: Equatable, Sendable {
    /// No ceremony: the sheet is closed.
    case idle
    /// S1a (and S1b while the sheet is hidden): the code is up, waiting for
    /// the response. `offline`: the last poll could not reach iCloud.
    case showing(offline: Bool)
    /// S1c: a verified response, frozen; the owner compares the codes.
    case comparing(PairingCandidate)
    /// Codes Match pressed: the keychain write is under way.
    case committing(PairingCandidate)
    /// S1d: the key is kept. Final until the sheet closes.
    case paired(PairingFingerprint)
    /// S1e. Final until the sheet closes or starts over.
    case ended(PairingEnd)

    /// Before the commit: the window bounds it, and polls run.
    var isLive: Bool {
        switch self {
        case .showing, .comparing: return true
        case .idle, .committing, .paired, .ended: return false
        }
    }
}

enum PairingEvent: Equatable, Sendable {
    /// Pair iPhone… or Start Over. `nonce`: 32 fresh random bytes.
    /// `rotating`: a phone is already paired (its key keeps working until
    /// the new one is committed).
    case begin(nonce: [UInt8], rotating: Bool, now: TimeInterval)
    /// The sheet is key and unoccluded (S1a) or not (S1b).
    case visible(Bool)
    /// The shell's one-second tick: the window, and the poll schedule.
    case tick(now: TimeInterval)
    case fetched(PairingFetch, now: TimeInterval)
    case codesMatch(now: TimeInterval)
    case codesDiffer
    /// The keychain write's outcome.
    case committed(Bool)
    /// Cancel, Esc, Done, Close, or the Settings window closing.
    case cancel
}

enum PairingEffect: Equatable, Sendable {
    /// Keep the derived record NAME for the next launch's cleanup (never N).
    case rememberRecord(String)
    case fetch(recordName: String)
    /// Delete the record (and, once gone, forget its name).
    case delete(recordName: String)
    /// Keep the candidate's key: the keychain write. Codes Match only.
    case commit(PairingCandidate)
    case audit(PairingAudit)
}

/// One pairing log line: closed codes only — never the nonce, the payload,
/// a key's bytes or the record name.
enum PairingAudit: Equatable, Sendable {
    case begun(rotating: Bool)
    case verified
    case refused(PairingRefusal)
    case ended(PairingEnd)
    case cancelled
    case committed
    case nonceUnavailable
    case unpaired
    case unpairFailed
    /// A record remembered from a ceremony that never ended, at launch.
    case leftoverDeleted
    case leftoverKept
    /// A remembered name with no pairing record name's shape: nothing is
    /// deleted by it, and it is forgotten (S-PAIR-C1.5, #170).
    case leftoverMalformed

    var code: String {
        switch self {
        case .begun(let rotating): return rotating ? "pairing.begun rotating" : "pairing.begun"
        case .verified: return "pairing.verified"
        case .refused(let refusal): return "pairing.refused." + refusal.code
        case .ended(let end): return "pairing.ended." + end.rawValue
        case .cancelled: return "pairing.cancelled"
        case .committed: return "pairing.committed"
        case .nonceUnavailable: return "pairing.nonceUnavailable"
        case .unpaired: return "pairing.unpaired"
        case .unpairFailed: return "pairing.unpairFailed"
        case .leftoverDeleted: return "pairing.leftover.deleted"
        case .leftoverKept: return "pairing.leftover.kept"
        case .leftoverMalformed: return "pairing.leftover.malformed"
        }
    }
}

struct PairingCeremonyState: Equatable, Sendable {
    /// The code's life: five minutes from when it is first shown.
    static let window: TimeInterval = 300
    /// How often the shell fetches the record while the code is live.
    static let pollInterval: TimeInterval = 2.5

    private(set) var phase = PairingPhase.idle
    /// Whether a phone was already paired when this ceremony began.
    private(set) var rotating = false
    /// Whether the sheet is key and unoccluded (S1a) rather than hidden (S1b).
    private(set) var visible = true
    private(set) var deadline: TimeInterval = 0
    /// The nonce, while a ceremony is live; nil after every end (burned).
    private var nonce: [UInt8]?
    private var recordName: String?
    private var nextPoll: TimeInterval = 0
    private var fetchInFlight = false

    /// Whether a nonce is held (for the tests: a burned ceremony holds none).
    var holdsNonce: Bool { nonce != nil }

    /// The QR payload, while S1a draws it: a live, unfrozen ceremony whose
    /// sheet is key and unoccluded. nil otherwise — the QR never returns
    /// once a response is frozen.
    var qrPayload: String? {
        guard case .showing = phase, visible, let nonce else { return nil }
        return ApprovalSigning.pairingPayload(nonce: nonce)
    }

    /// Whole seconds left in the window (never negative).
    func secondsLeft(now: TimeInterval) -> Int {
        max(0, Int((deadline - now).rounded(.up)))
    }

    mutating func apply(_ event: PairingEvent) -> [PairingEffect] {
        switch event {
        case let .begin(nonce, rotating, now): return begin(nonce: nonce, rotating: rotating, now: now)
        case .visible(let visible):
            self.visible = visible
            return []
        case .tick(let now): return tick(now: now)
        case let .fetched(fetch, now): return fetched(fetch, now: now)
        case .codesMatch(let now): return codesMatch(now: now)
        case .codesDiffer: return codesDiffer()
        case .committed(let saved): return committed(saved)
        case .cancel: return cancel()
        }
    }

    // MARK: Events

    private mutating func begin(nonce: [UInt8], rotating: Bool, now: TimeInterval) -> [PairingEffect] {
        var effects = phase.isLive ? burn() : []
        guard ApprovalSigning.pairingPayload(nonce: nonce) != nil, let name = PairingResponseCheck.recordName(nonce: nonce) else {
            phase = .idle
            return effects + [.audit(.nonceUnavailable)]
        }
        self.nonce = nonce
        recordName = name
        self.rotating = rotating
        visible = true
        deadline = now + Self.window
        nextPoll = now + Self.pollInterval
        fetchInFlight = false
        phase = .showing(offline: false)
        effects += [.rememberRecord(name), .audit(.begun(rotating: rotating))]
        return effects
    }

    private mutating func tick(now: TimeInterval) -> [PairingEffect] {
        guard phase.isLive else { return [] }
        guard now < deadline else { return end(.expired) }
        guard !fetchInFlight, now >= nextPoll, let recordName else { return [] }
        fetchInFlight = true
        nextPoll = now + Self.pollInterval
        return [.fetch(recordName: recordName)]
    }

    private mutating func fetched(_ fetch: PairingFetch, now: TimeInterval) -> [PairingEffect] {
        guard phase.isLive, fetchInFlight else { return [] }
        fetchInFlight = false
        guard now < deadline else { return end(.expired) }
        switch (phase, fetch) {
        case (_, .unreachable):
            if case .showing = phase { phase = .showing(offline: true) }
            return []
        case (.showing, .nothing):
            phase = .showing(offline: false)
            return []
        case (.showing, .found(.malformed(let fault))):
            return refuse(.malformed(fault))
        case (.showing, .found(.response(let response))):
            guard let nonce else { return refuse(.confirmationInvalid) }
            switch PairingResponseCheck.check(response, nonce: nonce) {
            case .refused(let refusal):
                return refuse(refusal)
            case .verified(let candidate):
                phase = .comparing(candidate)
                return [.audit(.verified)]
            }
        case (.comparing(let candidate), .found(let reading)):
            return reading == .response(candidate.response) ? [] : refuse(.differentResponse)
        case (.comparing, .nothing):
            return refuse(.responseGone)
        default:
            return []
        }
    }

    /// THE way to a commit: the owner's Codes Match, while comparing, inside
    /// the window.
    private mutating func codesMatch(now: TimeInterval) -> [PairingEffect] {
        guard case .comparing(let candidate) = phase else { return [] }
        guard now < deadline else { return end(.expired) }
        phase = .committing(candidate)
        return [.commit(candidate)]
    }

    private mutating func codesDiffer() -> [PairingEffect] {
        guard case .comparing = phase else { return [] }
        return end(.stoppedMismatch)
    }

    private mutating func committed(_ saved: Bool) -> [PairingEffect] {
        guard case .committing(let candidate) = phase else { return [] }
        guard saved else { return finish(.ended(.saveFailed), audit: .ended(.saveFailed)) }
        return finish(.paired(candidate.fingerprint), audit: .committed)
    }

    private mutating func cancel() -> [PairingEffect] {
        switch phase {
        case .idle: return []
        case .showing, .comparing:
            let effects = burn()
            phase = .idle
            return effects + [.audit(.cancelled)]
        case .committing:
            // The keychain write is under way; its outcome closes the sheet.
            return []
        case .paired, .ended:
            phase = .idle
            return []
        }
    }

    // MARK: Ends

    private mutating func refuse(_ refusal: PairingRefusal) -> [PairingEffect] {
        [.audit(.refused(refusal))] + end(.refused)
    }

    private mutating func end(_ cause: PairingEnd) -> [PairingEffect] {
        finish(.ended(cause), audit: .ended(cause))
    }

    private mutating func finish(_ final: PairingPhase, audit: PairingAudit) -> [PairingEffect] {
        let effects = burn()
        phase = final
        return effects + [.audit(audit)]
    }

    /// The nonce dies, and the record goes.
    private mutating func burn() -> [PairingEffect] {
        nonce = nil
        fetchInFlight = false
        defer { recordName = nil }
        return recordName.map { [.delete(recordName: $0)] } ?? []
    }
}

// MARK: - Never printed, dumped or reflected (S-PAIR-C1.5, the C1 security delta check's (b))

/// The nonce stays on the screen (PairingStructureTests lock 7): the values
/// that hold it — the state machine, and the event that hands it in — print,
/// debug-print, dump and reflect as their type's name and nothing more,
/// however and wherever they are described (`String(describing:)`, an
/// interpolation, `String(reflecting:)`, `dump`, a `Mirror`): the
/// conformance is the type's own, so no spelling and no file gets past it.
extension PairingCeremonyState: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "PairingCeremonyState(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

extension PairingEvent: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "PairingEvent(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .enum) }
}
