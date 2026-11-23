import Foundation
import NapCatWire
@testable import NapCatPhone
import Testing

/// The biometric seam, played by a test: a fixed availability and a scripted
/// answer, every request for a match counted. `during` runs while the
/// "match" is under way (the prompt is on screen), so a test can let time
/// pass or a withdrawal arrive meanwhile. Never the real prompt.
@MainActor
final class ScriptedBiometricGate: BiometricGate {
    var available: BiometricAvailability
    var result: BiometricResult
    var during: (() -> Void)?
    private(set) var requests: [String] = []

    init(available: BiometricAvailability = .available(.faceID), result: BiometricResult = .confirmed) {
        self.available = available
        self.result = result
    }

    func availability() -> BiometricAvailability { available }

    func confirm(reason: String) async -> BiometricResult {
        requests.append(reason)
        during?()
        return result
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

/// Allow and Deny on the phone (CL-3): Allow needs a biometric match, every
/// time; Deny never asks; neither answers an expired or withdrawn request;
/// each answer touches only its own request, and is sent, never "allowed".
@MainActor
@Suite struct RequestAnsweringTests {
    typealias F = RequestFixtures

    @MainActor
    struct World {
        let clock = TestClock()
        let gate: ScriptedBiometricGate
        let writer: RecordingDecisionWriter
        let inbox: RequestInbox
        let request: PendingRequest

        init(result: BiometricResult = .confirmed, outcome: DecisionWriteOutcome = .saved) {
            gate = ScriptedBiometricGate(result: result)
            writer = RecordingDecisionWriter(outcome)
            inbox = RequestInbox(writer: writer, biometrics: gate, clock: { [clock] in clock.now })
            request = F.request(1, createdAt: clock.now)
            inbox.receive([request])
        }
    }

    // MARK: Allow needs the match; Deny does not

    @Test func allowAsksForAMatchThenSends() async {
        let world = World()
        await world.inbox.allow(world.request.id)
        #expect(world.gate.requests == [RequestInbox.allowReason])
        #expect(await world.writer.written == [PhoneDecision(promptID: world.request.id, verdict: .allow,
                                                             decidedAt: world.clock.now)])
        #expect(world.inbox.status(of: world.request.id) == .sent(.allow))
    }

    /// No match, no Allow: nothing is written, and the request stays
    /// answerable, with a note saying why nothing went out.
    @Test func allowWithoutAMatchSendsNothing() async {
        let world = World(result: .notConfirmed)
        await world.inbox.allow(world.request.id)
        #expect(world.gate.requests.count == 1)
        #expect(await world.writer.written.isEmpty)
        let status = world.inbox.status(of: world.request.id)
        #expect(status == .pending(until: world.request.expiresAt, note: .notConfirmed))
        #expect(status?.isAnswerable == true)
    }

    /// Each Allow asks again: an earlier match is never reused.
    @Test func everyAllowAsksAgain() async {
        let world = World(result: .notConfirmed)
        await world.inbox.allow(world.request.id)
        world.gate.result = .confirmed
        await world.inbox.allow(world.request.id)
        #expect(world.gate.requests.count == 2)
        #expect(await world.writer.written.map(\.verdict) == [.allow])
    }

    @Test func denySendsWithoutAMatch() async {
        let world = World(result: .notConfirmed)
        await world.inbox.deny(world.request.id)
        #expect(world.gate.requests.isEmpty, "Deny never asks for a match")
        #expect(await world.writer.written.map(\.verdict) == [.deny])
        #expect(world.inbox.status(of: world.request.id) == .sent(.deny))
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
    @Test func aWindowThatClosesDuringTheMatchSendsNothing() async {
        let world = World()
        world.gate.during = { world.clock.advance(PendingRequest.timeToLive) }
        await world.inbox.allow(world.request.id)
        #expect(world.gate.requests.count == 1)
        #expect(await world.writer.written.isEmpty)
        #expect(world.inbox.status(of: world.request.id) == .expired)
    }

    @Test func aWithdrawalDuringTheMatchSendsNothing() async {
        let world = World()
        world.gate.during = { world.inbox.withdraw(world.request.id) }
        await world.inbox.allow(world.request.id)
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

    /// Once sent, a request takes no second answer, of either kind.
    @Test func aSentRequestTakesNoSecondAnswer() async {
        let world = World()
        await world.inbox.deny(world.request.id)
        await world.inbox.allow(world.request.id)
        await world.inbox.deny(world.request.id)
        #expect(world.gate.requests.isEmpty)
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
        let gate = ScriptedBiometricGate(available: .unavailable)
        let inbox = RequestInbox(writer: RecordingDecisionWriter(), biometrics: gate)
        #expect(inbox.biometry == .unavailable)
        gate.available = .available(.touchID)
        inbox.refreshBiometry()
        #expect(inbox.biometry == .available(.touchID))
    }

    /// The system prompt's reason is fixed words: nothing from a request.
    @Test func theMatchReasonCarriesNothingFromTheRequest() {
        #expect(RequestInbox.allowReason == "Confirm Allow for this permission prompt on your Mac.")
    }
}
