import Foundation
import NapCatWire
@testable import NapCatPhone
import Testing

/// The biometric seam, played by a test: a fixed availability and a scripted
/// answer, every request for a match counted, and every match it hands out
/// kept, so a test can see each one was fresh and was spent. `during` runs
/// while the "match" is under way (the prompt is on screen), so a test can
/// let time pass or a withdrawal arrive meanwhile. Never the real prompt.
@MainActor
final class ScriptedBiometricGate: BiometricGate {
    var available: BiometricAvailability
    var confirms: Bool
    var during: (() -> Void)?
    private(set) var requests: [String] = []
    private(set) var matches: [TestMatch] = []

    init(available: BiometricAvailability = .available(.faceID), confirms: Bool = true) {
        self.available = available
        self.confirms = confirms
    }

    func availability() -> BiometricAvailability { available }

    func confirm(reason: String) async -> BiometricResult {
        requests.append(reason)
        during?()
        guard confirms else { return .notConfirmed }
        let match = TestMatch()
        matches.append(match)
        return .confirmed(match)
    }
}

/// The decision seam, played by a test: keeps every decision and answers
/// with the scripted outcome. Nothing is written anywhere.
actor RecordingDecisionWriter: DecisionWriter {
    private(set) var written: [PhoneDecision] = []
    private var outcome: DecisionWriteOutcome

    init(_ outcome: DecisionWriteOutcome = .saved) {
        self.outcome = outcome
    }

    func answer(with outcome: DecisionWriteOutcome) {
        self.outcome = outcome
    }

    func write(_ decision: PhoneDecision) async -> DecisionWriteOutcome {
        written.append(decision)
        return outcome
    }
}

/// A decision writer that notes, as each write begins, what `check` says
/// (on the main actor, where the matches live).
@MainActor
final class WatchingDecisionWriter: DecisionWriter {
    private let check: () -> Bool
    private(set) var seen: [Bool] = []

    init(_ check: @escaping () -> Bool) {
        self.check = check
    }

    func write(_ decision: PhoneDecision) async -> DecisionWriteOutcome {
        seen.append(check())
        return .saved
    }
}

/// Allow and Deny on the phone (CL-3, and the owner's uniform-signing
/// ruling): each needs a biometric match of its own, every time, and spends
/// it; neither answers an expired or withdrawn request; each answer touches
/// only its own request, and is sent, never "allowed".
@MainActor
@Suite struct RequestAnsweringTests {
    typealias F = RequestFixtures

    @MainActor
    struct World {
        let clock = TestClock()
        let gate: ScriptedBiometricGate
        let writer: RecordingDecisionWriter
        /// The phone's keys: one committed software key unless `paired` is
        /// false.
        let keys = PhoneKeyringTests.World()
        let publicKey: [UInt8]
        let inbox: RequestInbox
        let request: PendingRequest

        init(confirms: Bool = true, outcome: DecisionWriteOutcome = .saved, paired: Bool = true) {
            gate = ScriptedBiometricGate(confirms: confirms)
            writer = RecordingDecisionWriter(outcome)
            publicKey = paired ? keys.keyring.makeProvisional() ?? [] : []
            if paired { _ = keys.keyring.commitProvisional() }
            inbox = RequestInbox(writer: writer, biometrics: gate, keyring: keys.keyring, clock: { [clock] in clock.now })
            request = F.request(1, createdAt: clock.now)
            inbox.receive([request])
        }

        func answer(_ verdict: ApprovalWire.Verdict) async {
            switch verdict {
            case .allow: await inbox.allow(request.id)
            case .deny: await inbox.deny(request.id)
            }
        }
    }

    // MARK: Every answer needs its own match

    /// Allow and Deny alike: a match, then the decision signed by the
    /// paired key over the prompt as received, in whole seconds, then the
    /// write. The Mac would count it.
    @Test(arguments: ApprovalWire.Verdict.allCases)
    func anAnswerAsksForAMatchThenSendsItSigned(_ verdict: ApprovalWire.Verdict) async throws {
        let world = World()
        world.clock.advance(0.6)
        await world.answer(verdict)
        #expect(world.gate.requests == [RequestInbox.reason(for: verdict)])
        let written = await world.writer.written
        try #require(written.count == 1)
        #expect(written[0].promptID == world.request.id && written[0].verdict == verdict)
        #expect(written[0].decidedAt == DecisionSigner.wholeSecond(world.clock.now))
        #expect(MacCheck.verifies(written[0], copy: world.request, publicKey: world.publicKey))
        #expect(world.inbox.status(of: world.request.id) == .sent(verdict))
    }

    /// The signature spends the match before anything is written: one
    /// signature per match, and no live match while the write is under way.
    @Test func theSignatureSpendsTheMatchBeforeTheWrite() async {
        let gate = ScriptedBiometricGate()
        let writer = WatchingDecisionWriter { gate.matches.allSatisfy { !$0.isValid } }
        let keyring = RequestFixtures.pairedKeyring()
        let clock = TestClock()
        let inbox = RequestInbox(writer: writer, biometrics: gate, keyring: keyring, clock: { clock.now })
        let request = F.request(1, createdAt: clock.now)
        inbox.receive([request])
        await inbox.deny(request.id)
        #expect(writer.seen == [true], "the match was spent when the write began")
        #expect(gate.matches.count == 1 && !gate.matches[0].isValid)
    }

    /// While the biometric prompt is up, the request says which answer the
    /// match will sign: Allow's wait and Deny's never read alike, and
    /// nothing is on offer meanwhile.
    @Test(arguments: ApprovalWire.Verdict.allCases)
    func theWaitForTheMatchNamesTheAnswer(_ verdict: ApprovalWire.Verdict) async {
        let world = World()
        var during: RequestStatus?
        world.gate.during = { during = world.inbox.status(of: world.request.id) }
        await world.answer(verdict)
        #expect(during == .confirming(verdict))
        #expect(during?.isAnswerable == false)
        #expect(during?.line(at: world.clock.now, biometric: .faceID).text
                == "Confirming — \(RequestStatus.name(verdict)), waiting for Face ID")
        #expect(world.inbox.status(of: world.request.id) == .sent(verdict))
    }

    // MARK: No key, no answer; a dead key after a changed enrollment unpairs

    /// An unpaired phone asks for no match it could not use, and writes
    /// nothing.
    @Test(arguments: ApprovalWire.Verdict.allCases)
    func anUnpairedPhoneAsksForNothing(_ verdict: ApprovalWire.Verdict) async {
        let world = World(paired: false)
        #expect(world.inbox.keyHealth == .unpaired(.neverPaired))
        await world.answer(verdict)
        #expect(world.gate.requests.isEmpty)
        #expect(await world.writer.written.isEmpty)
        #expect(world.inbox.status(of: world.request.id) == .pending(until: world.request.expiresAt, note: nil))
    }

    /// The key stopped signing after a good match, and the enrollment had
    /// changed: the phone unpairs itself, writes nothing, says why, and
    /// asks for nothing more.
    @Test func aDeadKeyAfterAChangedEnrollmentUnpairsThePhone() async throws {
        let world = World()
        world.keys.enclave.killed = [try #require(world.keys.committed()).keyData]
        world.keys.enrolled = PhoneKeyringTests.after
        await world.inbox.allow(world.request.id)
        #expect(world.gate.requests.count == 1)
        #expect(await world.writer.written.isEmpty)
        #expect(world.inbox.keyHealth == .unpaired(.enrollmentChanged))
        #expect(world.keys.committed() == nil)
        #expect(world.inbox.status(of: world.request.id) == .pending(until: world.request.expiresAt, note: nil))
        await world.inbox.deny(world.request.id)
        #expect(world.gate.requests.count == 1, "nothing left to sign with: no second prompt")
    }

    /// A key that would not sign while the enrollment is unchanged stays:
    /// the answer says it was not signed, and a retry can go out.
    @Test func aKeyThatDidNotSignLeavesANoteAndStays() async throws {
        let world = World()
        let key = try #require(world.keys.committed())
        world.keys.enclave.killed = [key.keyData]
        await world.inbox.deny(world.request.id)
        #expect(await world.writer.written.isEmpty)
        #expect(world.inbox.status(of: world.request.id) == .pending(until: world.request.expiresAt, note: .unsigned))
        #expect(world.inbox.keyHealth == .paired)
        #expect(world.keys.committed() == key)
        world.keys.enclave.killed = []
        await world.inbox.deny(world.request.id)
        #expect(await world.writer.written.map(\.verdict) == [.deny])
    }

    /// A cancel or a lockout at the key never unpairs, even with the
    /// enrollment changed.
    @Test func aCancelAtTheKeyNeverUnpairs() async {
        let world = World()
        world.keys.enclave.forced = .notAuthorized
        world.keys.enrolled = PhoneKeyringTests.after
        await world.inbox.allow(world.request.id)
        #expect(world.inbox.keyHealth == .enrollmentChanged)
        #expect(world.keys.committed() != nil)
        #expect(world.inbox.status(of: world.request.id) == .pending(until: world.request.expiresAt, note: .unsigned))
    }

    /// The health check asks for nothing and reads a changed enrollment.
    @Test func theInboxReadsThePairingWithNoPrompt() {
        let world = World()
        #expect(world.inbox.keyHealth == .paired)
        world.keys.enrolled = PhoneKeyringTests.after
        world.inbox.refreshKeyHealth()
        #expect(world.inbox.keyHealth == .enrollmentChanged)
        #expect(world.gate.requests.isEmpty && world.keys.enclave.signed.isEmpty)
    }

    /// No match, no answer, Deny included: nothing is written, and the
    /// request stays answerable, with a note saying why nothing went out.
    @Test(arguments: ApprovalWire.Verdict.allCases)
    func anAnswerWithoutAMatchSendsNothing(_ verdict: ApprovalWire.Verdict) async {
        let world = World(confirms: false)
        await world.answer(verdict)
        #expect(world.gate.requests == [RequestInbox.reason(for: verdict)])
        #expect(await world.writer.written.isEmpty)
        let status = world.inbox.status(of: world.request.id)
        #expect(status == .pending(until: world.request.expiresAt, note: .notConfirmed))
        #expect(status?.isAnswerable == true)
    }

    /// Each answer asks again: an earlier match is never reused.
    @Test(arguments: ApprovalWire.Verdict.allCases)
    func everyAnswerAsksAgain(_ verdict: ApprovalWire.Verdict) async {
        let world = World(confirms: false)
        await world.answer(verdict)
        world.gate.confirms = true
        await world.answer(verdict)
        #expect(world.gate.requests.count == 2)
        #expect(await world.writer.written.map(\.verdict) == [verdict])
    }

    /// Each answer gets a fresh match, and spends it: none outlives its
    /// answer, sent or not.
    @Test func everyMatchIsFreshAndSpent() async {
        let world = World(outcome: .failed)
        await world.inbox.deny(world.request.id)
        await world.inbox.allow(world.request.id)
        await world.writer.answer(with: .saved)
        await world.inbox.deny(world.request.id)
        #expect(world.gate.matches.count == 3)
        #expect(Set(world.gate.matches.map(ObjectIdentifier.init)).count == 3, "never the same match twice")
        #expect(world.gate.matches.allSatisfy { !$0.isValid })
        #expect(await world.writer.written.map(\.verdict) == [.deny, .allow, .deny])
    }

    /// A match whose request closed meanwhile is spent too, unused.
    @Test func aMatchForAClosedRequestIsSpentUnused() async {
        let world = World()
        world.gate.during = { world.clock.advance(PendingRequest.timeToLive) }
        await world.inbox.deny(world.request.id)
        #expect(world.gate.matches.count == 1)
        #expect(world.gate.matches.first?.isValid == false)
        #expect(await world.writer.written.isEmpty)
    }

    /// The system prompt names the answer it confirms.
    @Test func eachAnswerAsksInItsOwnWords() {
        #expect(RequestInbox.reason(for: .allow) == RequestInbox.allowReason)
        #expect(RequestInbox.reason(for: .deny) == RequestInbox.denyReason)
        #expect(RequestInbox.denyReason == "Confirm it's you to send Deny to your Mac's permission prompt.")
    }

    // MARK: Expired and withdrawn requests are not answerable

    @Test(arguments: [false, true])
    func anExpiredRequestTakesNoAnswer(_ allow: Bool) async {
        let world = World()
        world.clock.advance(PendingRequest.timeToLive)
        if allow { await world.inbox.allow(world.request.id) } else { await world.inbox.deny(world.request.id) }
        #expect(world.gate.requests.isEmpty)
        #expect(await world.writer.written.isEmpty)
        #expect(world.inbox.status(of: world.request.id) == .expired)
    }

    @Test(arguments: [false, true])
    func aWithdrawnRequestTakesNoAnswer(_ allow: Bool) async {
        let world = World()
        world.inbox.withdraw(world.request.id)
        if allow { await world.inbox.allow(world.request.id) } else { await world.inbox.deny(world.request.id) }
        #expect(world.gate.requests.isEmpty)
        #expect(await world.writer.written.isEmpty)
        #expect(world.inbox.status(of: world.request.id) == .withdrawn)
    }

    /// The window is checked again after the match: one that closed while
    /// the biometric prompt was up sends nothing.
    @Test(arguments: ApprovalWire.Verdict.allCases)
    func aWindowThatClosesDuringTheMatchSendsNothing(_ verdict: ApprovalWire.Verdict) async {
        let world = World()
        world.gate.during = { world.clock.advance(PendingRequest.timeToLive) }
        await world.answer(verdict)
        #expect(world.gate.requests.count == 1)
        #expect(await world.writer.written.isEmpty)
        #expect(world.inbox.status(of: world.request.id) == .expired)
    }

    @Test(arguments: ApprovalWire.Verdict.allCases)
    func aWithdrawalDuringTheMatchSendsNothing(_ verdict: ApprovalWire.Verdict) async {
        let world = World()
        world.gate.during = { world.inbox.withdraw(world.request.id) }
        await world.answer(verdict)
        #expect(await world.writer.written.isEmpty)
        #expect(world.inbox.status(of: world.request.id) == .withdrawn)
    }

    /// A request never held takes no answer.
    @Test func anUnknownRequestTakesNoAnswer() async {
        let world = World()
        await world.inbox.allow(F.id(99))
        await world.inbox.deny(F.id(99))
        #expect(world.gate.requests.isEmpty)
        #expect(await world.writer.written.isEmpty)
    }

    // MARK: One answer, its own request

    /// Once sent, a request takes no second answer, of either kind, and
    /// asks for no second match.
    @Test func aSentRequestTakesNoSecondAnswer() async {
        let world = World()
        await world.inbox.deny(world.request.id)
        await world.inbox.allow(world.request.id)
        await world.inbox.deny(world.request.id)
        #expect(world.gate.requests == [RequestInbox.denyReason])
        #expect(await world.writer.written.map(\.verdict) == [.deny])
    }

    @Test func anAnswerTouchesOnlyItsOwnRequest() async {
        let world = World()
        let other = F.request(2, createdAt: world.clock.now)
        world.inbox.receive([world.request, other])
        await world.inbox.allow(world.request.id)
        #expect(world.inbox.status(of: other.id) == .pending(until: other.expiresAt, note: nil))
        #expect(await world.writer.written.map(\.promptID) == [world.request.id])
    }

    // MARK: What the write came to

    struct OutcomeRow: CustomTestStringConvertible, Sendable {
        let outcome: DecisionWriteOutcome
        let expected: @Sendable (Date) -> RequestStatus
        var testDescription: String { "\(outcome)" }
    }

    nonisolated static let outcomes: [OutcomeRow] = [
        OutcomeRow(outcome: .saved) { _ in .sent(.deny) },
        OutcomeRow(outcome: .alreadyAnswered) { _ in .answered },
        OutcomeRow(outcome: .failed) { .pending(until: $0, note: .unsent) },
        OutcomeRow(outcome: .unconfirmed) { .pending(until: $0, note: .unconfirmed) },
    ]

    /// Saved is sent; a decision already saved for the prompt ends it; a
    /// failed or unconfirmed write leaves it answerable, saying why.
    @Test(arguments: outcomes)
    func theWritesOutcomeDecidesTheStatus(_ row: OutcomeRow) async {
        let world = World(outcome: row.outcome)
        await world.inbox.deny(world.request.id)
        #expect(world.inbox.status(of: world.request.id) == row.expected(world.request.expiresAt))
    }

    /// After a failed write the owner may answer again, and that answer goes
    /// out.
    @Test func aFailedAnswerCanBeRetried() async {
        let world = World(outcome: .failed)
        await world.inbox.deny(world.request.id)
        await world.writer.answer(with: .saved)
        await world.inbox.allow(world.request.id)
        #expect(await world.writer.written.map(\.verdict) == [.deny, .allow])
        #expect(world.inbox.status(of: world.request.id) == .sent(.allow))
    }

    // MARK: The biometry the screen offers

    @Test func theInboxReadsTheGatesAvailability() {
        let gate = ScriptedBiometricGate(available: .unavailable(.touchID))
        let inbox = RequestInbox(writer: RecordingDecisionWriter(), biometrics: gate, keyring: F.pairedKeyring())
        #expect(inbox.biometry == .unavailable(.touchID))
        gate.available = .available(.touchID)
        inbox.refreshBiometry()
        #expect(inbox.biometry == .available(.touchID))
    }

    /// An unavailable biometric still names itself, so the screen can say
    /// which one Allow needs.
    @Test func availabilityNamesThePhonesBiometric() {
        #expect(BiometricAvailability.available(.faceID).kind == .faceID)
        #expect(BiometricAvailability.unavailable(.opticID).kind == .opticID)
        #expect(BiometricAvailability.unavailable(nil).kind == nil)
    }

    /// The system prompt's reason is fixed words: nothing from a request.
    /// It cannot be read as "confirm on your Mac": the match is asked for
    /// here, and the prompt it answers is the Mac's.
    @Test func theMatchReasonCarriesNothingFromTheRequest() {
        #expect(RequestInbox.allowReason == "Confirm it's you to send Allow to your Mac's permission prompt.")
        for reason in [RequestInbox.allowReason, RequestInbox.denyReason] {
            #expect(!reason.contains("on your Mac"))
            for claim in ["Allowed", "Approve", "approve", "Denied"] {
                #expect(!reason.contains(claim), "\(claim)")
            }
        }
    }
}
