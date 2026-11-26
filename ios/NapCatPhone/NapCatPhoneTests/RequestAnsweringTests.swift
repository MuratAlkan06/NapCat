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
        OutcomeRow(outcome: .unconfirmed) { .pending(until: $0, note: .unconfirmed(.deny)) },
    ]

    /// Saved is sent; a decision already saved for the prompt ends it; a
    /// failed or unconfirmed write leaves it answerable, saying why (an
    /// unconfirmed one names the answer, the only one offered again).
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

    // MARK: After an unconfirmed answer, only that answer again (#154)

    nonisolated static func other(_ verdict: ApprovalWire.Verdict) -> ApprovalWire.Verdict {
        verdict == .allow ? .deny : .allow
    }

    /// iCloud left the answer unconfirmed: it may have reached the Mac,
    /// which counts the first answer saved. So the request says so and
    /// offers that answer alone; the other asks for no match and writes
    /// nothing.
    @Test(arguments: ApprovalWire.Verdict.allCases)
    func anUnconfirmedAnswerIsTheOnlyOneOfferedAgain(_ verdict: ApprovalWire.Verdict) async {
        let world: World = World(outcome: .unconfirmed)
        await world.answer(verdict)
        let status: RequestStatus? = world.inbox.status(of: world.request.id)
        #expect(status == .pending(until: world.request.expiresAt, note: .unconfirmed(verdict)))
        #expect(status?.answers == [verdict])
        #expect(status?.resend == verdict)
        #expect(status?.isAnswerable == true)
        await world.answer(Self.other(verdict))
        #expect(world.gate.requests == [RequestInbox.reason(for: verdict)], "the other answer asked for no match")
        #expect(await world.writer.written.map(\.verdict) == [verdict])
        #expect(world.inbox.status(of: world.request.id) == status)
    }

    /// A definite failure saved nothing, so both answers stay on offer, and
    /// the other one goes out.
    @Test(arguments: ApprovalWire.Verdict.allCases)
    func aFailedAnswerKeepsBothOnOffer(_ verdict: ApprovalWire.Verdict) async {
        let world: World = World(outcome: .failed)
        await world.answer(verdict)
        let status: RequestStatus? = world.inbox.status(of: world.request.id)
        #expect(status == .pending(until: world.request.expiresAt, note: .unsent))
        #expect(status?.answers == ApprovalWire.Verdict.allCases)
        #expect(status?.resend == nil)
        await world.writer.answer(with: .saved)
        await world.answer(Self.other(verdict))
        #expect(await world.writer.written.map(\.verdict) == [verdict, Self.other(verdict)])
        #expect(world.inbox.status(of: world.request.id) == .sent(Self.other(verdict)))
    }

    /// Nothing goes out again on its own. Sent again, the answer asks for a
    /// match of its own and is signed afresh, at its own time: of the first
    /// try only the verdict is kept, never its match, message or signature.
    @Test(arguments: ApprovalWire.Verdict.allCases)
    func aResendAsksForANewMatchAndIsSignedAfresh(_ verdict: ApprovalWire.Verdict) async throws {
        let world: World = World(outcome: .unconfirmed)
        await world.answer(verdict)
        world.clock.advance(30)
        world.inbox.tick()
        world.inbox.receive([world.request])
        #expect(await world.writer.written.count == 1, "nothing goes out again on its own")
        await world.writer.answer(with: .saved)
        await world.answer(verdict)
        let reason: String = RequestInbox.reason(for: verdict)
        #expect(world.gate.requests == [reason, reason])
        #expect(Set(world.gate.matches.map(ObjectIdentifier.init)).count == 2, "a new match, never the first")
        #expect(world.gate.matches.allSatisfy { !$0.isValid })
        #expect(world.keys.enclave.signed.count == 2, "one signature per match")
        let written: [PhoneDecision] = await world.writer.written
        try #require(written.count == 2)
        #expect(written.allSatisfy { $0.verdict == verdict })
        #expect(written[1].decidedAt == DecisionSigner.wholeSecond(world.clock.now))
        #expect(written[1].decidedAt > written[0].decidedAt)
        #expect(world.keys.enclave.signed[1] != world.keys.enclave.signed[0], "a new message, at the resend's time")
        #expect(written[1].signature != written[0].signature)
        #expect(MacCheck.verifies(written[1], copy: world.request, publicKey: world.publicKey))
        #expect(world.inbox.status(of: world.request.id) == .sent(verdict))
    }

    /// A resend re-checks the window like any answer: one closed before it
    /// asks for no match, and one that closes during its match writes
    /// nothing, the match spent unused.
    @Test(arguments: ApprovalWire.Verdict.allCases)
    func aResendReChecksTheWindow(_ verdict: ApprovalWire.Verdict) async {
        let closedBefore: World = World(outcome: .unconfirmed)
        await closedBefore.answer(verdict)
        closedBefore.clock.advance(PendingRequest.timeToLive)
        await closedBefore.answer(verdict)
        #expect(closedBefore.gate.requests.count == 1, "an expired window asks for no match")
        #expect(await closedBefore.writer.written.count == 1)
        #expect(closedBefore.inbox.status(of: closedBefore.request.id) == .expired)
        let closedDuring: World = World(outcome: .unconfirmed)
        await closedDuring.answer(verdict)
        closedDuring.gate.during = { closedDuring.clock.advance(PendingRequest.timeToLive) }
        await closedDuring.answer(verdict)
        #expect(closedDuring.gate.requests.count == 2)
        #expect(closedDuring.gate.matches.count == 2 && closedDuring.gate.matches.allSatisfy { !$0.isValid })
        #expect(await closedDuring.writer.written.count == 1)
        #expect(closedDuring.inbox.status(of: closedDuring.request.id) == .expired)
    }

    /// A resend that finds a decision saved for the prompt already (the
    /// first try landed, as it may have) reads Answered and offers nothing.
    @Test(arguments: ApprovalWire.Verdict.allCases)
    func aResendThatFindsAnAnswerSavedReadsAnswered(_ verdict: ApprovalWire.Verdict) async {
        let world: World = World(outcome: .unconfirmed)
        await world.answer(verdict)
        await world.writer.answer(with: .alreadyAnswered)
        await world.answer(verdict)
        let status: RequestStatus? = world.inbox.status(of: world.request.id)
        #expect(status == .answered)
        #expect(status?.answers == [])
        #expect(status?.line(at: world.clock.now).text == "Answered — an answer to this prompt was already saved")
        await world.answer(Self.other(verdict))
        #expect(world.gate.requests.count == 2, "nothing more is asked for")
    }

    /// What a later try came to.
    enum LaterTry: String, CaseIterable, Sendable {
        case notConfirmed, unsigned, failed, unconfirmed
    }

    /// No later try lifts it: the first answer may still stand on the Mac.
    /// A resend whose match was not given, whose key did not sign, or whose
    /// save failed outright leaves that answer the only one on offer, and
    /// the request still says why.
    @Test(arguments: LaterTry.allCases)
    func aLaterTryNeverLiftsTheRestriction(_ later: LaterTry) async {
        let world: World = World(outcome: .unconfirmed)
        await world.inbox.allow(world.request.id)
        switch later {
        case .notConfirmed: world.gate.confirms = false
        case .unsigned: world.keys.enclave.forced = .notAuthorized
        case .failed: await world.writer.answer(with: .failed)
        case .unconfirmed: break
        }
        await world.inbox.allow(world.request.id)
        #expect(world.gate.requests.count == 2)
        let status: RequestStatus? = world.inbox.status(of: world.request.id)
        #expect(status == .pending(until: world.request.expiresAt, note: .unconfirmed(.allow)))
        #expect(status?.answers == [.allow])
        await world.inbox.deny(world.request.id)
        #expect(world.gate.requests.count == 2, "Deny asked for no match")
        #expect(await world.writer.written.allSatisfy { $0.verdict == .allow })
        #expect(world.inbox.keyHealth == .paired)
    }

    /// The restriction is the request's own: another request still offers
    /// both answers.
    @Test func anUnconfirmedAnswerRestrictsOnlyItsOwnRequest() async {
        let world: World = World(outcome: .unconfirmed)
        let other: PendingRequest = F.request(2, createdAt: world.clock.now)
        world.inbox.receive([world.request, other])
        await world.inbox.allow(world.request.id)
        #expect(world.inbox.status(of: other.id)?.answers == ApprovalWire.Verdict.allCases)
        await world.writer.answer(with: .saved)
        await world.inbox.deny(other.id)
        #expect(world.inbox.status(of: other.id) == .sent(.deny))
        #expect(world.inbox.status(of: world.request.id)?.answers == [.allow])
    }

    /// The fold, row by row: a saved answer, one under way and a finished
    /// request outrank the unconfirmed answer; while pending it outranks
    /// what a later try came to. Without one, each try reads as itself, and
    /// an unconfirmed answer alone still offers only itself. AMENDED (the
    /// #154 design review): one under way carries the unconfirmed answer
    /// (`afterUnconfirmed`), so the screen's footnote holds through it.
    @Test func theUnconfirmedAnswerFoldsIntoThePendingState() {
        let until: Date = Date(timeIntervalSince1970: 1_800_000_600)
        let pending: RequestPhase = .pending(until: until)
        let restricted: RequestStatus = .pending(until: until, note: .unconfirmed(.allow))
        let laterTries: [RequestAnswer] = [.none, .notConfirmed, .unsigned, .unsent(.allow), .unconfirmed(.allow)]
        for answer in laterTries {
            #expect(RequestStatus(phase: pending, answer: answer, mayHaveLanded: .allow) == restricted, "\(answer)")
        }
        #expect(RequestStatus(phase: pending, answer: .confirming(.allow), mayHaveLanded: .allow)
                == .confirming(.allow, afterUnconfirmed: true))
        #expect(RequestStatus(phase: pending, answer: .sending(.allow), mayHaveLanded: .allow)
                == .sending(.allow, afterUnconfirmed: true))
        #expect(RequestStatus(phase: pending, answer: .sent(.allow), mayHaveLanded: .allow) == .sent(.allow))
        #expect(RequestStatus(phase: pending, answer: .answeredElsewhere, mayHaveLanded: .allow) == .answered)
        #expect(RequestStatus(phase: .expired, answer: .unconfirmed(.allow), mayHaveLanded: .allow) == .expired)
        #expect(RequestStatus(phase: .withdrawn, answer: .unsent(.allow), mayHaveLanded: .allow) == .withdrawn)
        #expect(RequestStatus(phase: pending, answer: .unsent(.deny), mayHaveLanded: nil) == .pending(until: until, note: .unsent))
        let alone: [ApprovalWire.Verdict] = RequestStatus(phase: pending, answer: .unconfirmed(.deny), mayHaveLanded: nil).answers
        #expect(alone == [.deny])
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
