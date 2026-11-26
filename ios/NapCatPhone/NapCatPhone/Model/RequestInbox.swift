import Foundation
import NapCatWire
import Observation

/// Where a forwarded permission prompt stands on this phone.
enum RequestPhase: Equatable, Sendable {
    /// It may be answered until `until`, on this phone's clock.
    case pending(until: Date)
    /// Its window closed before it was answered here. Terminal.
    case expired
    /// The Mac took it back: answered at the Mac, its session ended, the
    /// Mac's switch went off, or the Mac's own clock ran out. Terminal.
    case withdrawn

    /// Whether the phone may still answer it.
    var isPending: Bool {
        if case .pending = self { return true }
        return false
    }
}

/// How far this phone got with its answer to one request.
enum RequestAnswer: Equatable, Sendable {
    case none
    /// The answer is waiting for the biometric match.
    case confirming(ApprovalWire.Verdict)
    case sending(ApprovalWire.Verdict)
    /// iCloud saved it. The Mac has not said what it did with it.
    case sent(ApprovalWire.Verdict)
    /// A decision for this prompt was saved already; nothing new was sent.
    case answeredElsewhere
    /// The answer was not confirmed; nothing was sent.
    case notConfirmed
    /// The paired key did not sign it; nothing was sent.
    case unsigned
    /// Nothing was saved.
    case unsent(ApprovalWire.Verdict)
    /// iCloud did not confirm it.
    case unconfirmed(ApprovalWire.Verdict)
}

/// The permission prompts the Mac forwarded to this phone, each with its
/// window and this phone's answer.
///
/// A request is answerable only while it is pending: until the Mac's expiry,
/// and never longer than its own window after this phone first saw it (a
/// Mac clock running ahead cannot stretch it; no window is longer than the
/// wire's maximum, `PendingRequest.longestWindow`). Expired and withdrawn
/// are terminal: once a request is either, nothing makes it pending again.
///
/// Live prompts (F4, #194) come from one snapshot read of every prompt
/// the Mac offers, at launch, on foreground, on a pull and on a prompt
/// push, never on a timer, and only while the owner's switch is on with a
/// committed key (`ApprovalsSwitch`); off, nothing is read and the inbox is
/// empty. A failed read changes nothing.
///
/// Allow and Deny alike ask for a biometric match first, every time (CL-3,
/// and the owner's uniform-signing ruling: every answer is signed, and the
/// key signs only after a match). Both re-check the window right before
/// anything is written, and each answer touches only its own request.
///
/// An answer iCloud left unconfirmed may have reached the Mac, which counts
/// the first answer saved: from then on it is the only answer offered, and
/// each resend asks for a match of its own and is signed afresh (#154).
///
/// Every answer is signed by the phone's committed key (`PhoneKeyring`,
/// `DecisionSigner`) between the window's re-check and the write: an
/// unpaired phone offers no answer, and a phone whose key stopped signing
/// after its biometrics changed unpairs itself and says so.
@MainActor
@Observable
final class RequestInbox {
    struct Entry: Equatable, Sendable {
        let request: PendingRequest
        /// When this phone first saw the request.
        let firstSeen: Date
        /// The Mac took it back (terminal).
        var withdrawn = false
        /// Its window was seen closed (terminal, whatever the clock does next).
        var expired = false
        var answer = RequestAnswer.none
        /// An answer iCloud left unconfirmed (#154): it may have been saved,
        /// and the Mac counts the first answer saved, so from then on it is
        /// the only answer offered, to send again, whatever a later try
        /// comes to. Only its verdict is kept, never its signature or its
        /// time: a resend asks for a match of its own and is signed afresh.
        var mayHaveLanded: ApprovalWire.Verdict?

        /// The last moment this phone may answer: the Mac's expiry, or the
        /// record's own window from first sight, whichever comes first.
        var answerableUntil: Date {
            min(request.expiresAt, firstSeen.addingTimeInterval(request.window))
        }
    }

    /// The most requests held at once (the Mac forwards far fewer); past it
    /// the oldest finished ones go first.
    nonisolated static let capacity = 64

    /// What the biometric prompt says each answer is for (Touch ID shows
    /// it; Face ID shows the app's usage description the first time). Fixed
    /// words: nothing from the request reaches the system prompt. The match
    /// is asked for here, on the phone; the prompt it answers is the Mac's,
    /// and what the answer does there is the Mac's to decide.
    nonisolated static let allowReason = "Confirm it's you to send Allow to your Mac's permission prompt."
    nonisolated static let denyReason = "Confirm it's you to send Deny to your Mac's permission prompt."

    nonisolated static func reason(for verdict: ApprovalWire.Verdict) -> String {
        switch verdict {
        case .allow: return allowReason
        case .deny: return denyReason
        }
    }

    private(set) var entries: [PromptID: Entry] = [:]
    /// Whether an answer can be confirmed here, as last read.
    private(set) var biometry: BiometricAvailability
    /// Where this phone's pairing stands, as last read (with no prompt).
    private(set) var keyHealth: PhoneKeyring.Health
    @ObservationIgnored private let writer: any DecisionWriter
    /// Whether answers from here go nowhere: the writer is the unsent one
    /// (the live inbox's until the answer path is armed). One fact, the
    /// writer's own type, so it cannot drift from what an answer would do:
    /// the prompt screen offers no answer while it holds (#194).
    var isReadOnly: Bool { writer is UnsentDecisionWriter }
    @ObservationIgnored private let biometrics: any BiometricGate
    @ObservationIgnored private let keyring: PhoneKeyring
    @ObservationIgnored private let clock: () -> Date
    /// The live pairing over this inbox's own key (F4, slice S-PAIR-C1.6):
    /// Settings' Pair with Mac opens its ceremonies, and the key one commits
    /// is the key this inbox signs with. nil for a fixture inbox, whose key
    /// is software, and in tests.
    let pairing: LivePairing?
    /// Where live prompts come from (F4, #194): nil for a fixture inbox,
    /// in a build that cannot reach iCloud, and in tests that give none.
    @ObservationIgnored private let prompts: (any PromptSource)?
    /// The owner's switch as last handed in (`syncPrompts`).
    @ObservationIgnored private var switchedOn = false
    /// Whether the prompt subscription is known to exist (made or found).
    @ObservationIgnored private var subscribed = false
    /// Whether this launch may have left a prompt subscription on the
    /// server: set as the switch takes effect, cleared once it is removed.
    @ObservationIgnored private var mayHoldSubscription = false
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var syncAgain = false
    /// A prompt whose push the owner tapped, until the inbox holds it.
    @ObservationIgnored private var awaited: PromptID?
    /// The request the main screen opens next, once (`opened()` clears it).
    private(set) var opening: PromptID?

    /// `clock` is this phone's wall clock (a test seam, like the others).
    init(writer: any DecisionWriter, biometrics: any BiometricGate, keyring: PhoneKeyring, pairing: LivePairing? = nil,
         prompts: (any PromptSource)? = nil, clock: @escaping () -> Date = Date.init) {
        self.writer = writer
        self.biometrics = biometrics
        self.keyring = keyring
        self.pairing = pairing
        self.prompts = prompts
        self.clock = clock
        self.biometry = biometrics.availability()
        self.keyHealth = keyring.health()
    }

    /// The launch's inbox. A recognised `-NapCatRequest` shows that fixture
    /// request, answered by a fixture writer and signed by a fixture key;
    /// otherwise the inbox starts empty, signs with this phone's own key
    /// (the Secure Enclave, the keychain) and writes nothing (no record path
    /// reaches the Mac yet), and the live pairing (S-PAIR-C1.6) is made over
    /// that same key. Both ask the real biometric gate before every answer.
    /// The live approvals database is built here once, for a build that can
    /// hold the iCloud entitlement, and shared by the live pairing and the
    /// live prompt source (#194); every answer still goes to the unsent writer.
    static func make(options: LaunchOptions, now: Date) -> RequestInbox {
        let biometrics = LocalAuthenticationGate()
        guard let state = options.request else {
            let keyring = PhoneKeyring(store: KeychainSigningKeyStore.phoneKeychain, enclave: SecureEnclaveSigner(),
                                       enrollment: LocalAuthenticationEnrollment())
            let database = CloudKitAlertSource.makeLiveApprovalDatabase()
            return RequestInbox(writer: UnsentDecisionWriter(), biometrics: biometrics, keyring: keyring,
                                pairing: LivePairing.make(keyring: keyring, biometrics: biometrics, database: database),
                                prompts: database.map { LivePromptSource(database: $0) })
        }
        return FixtureRequests.inbox(state, now: now, biometrics: biometrics)
    }

    /// The requests, newest first.
    var requests: [PendingRequest] {
        entries.values.map(\.request).sorted { ($0.createdAt, $0.id.hex) > ($1.createdAt, $1.id.hex) }
    }

    /// Where `id` stands at `now`; nil for a request never held.
    func phase(of id: PromptID, at now: Date) -> RequestPhase? {
        guard let entry = entries[id] else { return nil }
        if entry.withdrawn { return .withdrawn }
        if entry.expired || now >= entry.answerableUntil { return .expired }
        return .pending(until: entry.answerableUntil)
    }

    /// Where `id` stands now.
    func phase(of id: PromptID) -> RequestPhase? {
        phase(of: id, at: clock())
    }

    /// What the request screen shows for `id` at `now`; nil for a request
    /// never held.
    func status(of id: PromptID, at now: Date) -> RequestStatus? {
        guard let entry = entries[id], let phase = phase(of: id, at: now) else { return nil }
        return RequestStatus(phase: phase, answer: entry.answer, mayHaveLanded: entry.mayHaveLanded)
    }

    /// What the request screen shows for `id` now.
    func status(of id: PromptID) -> RequestStatus? {
        status(of: id, at: clock())
    }

    // MARK: Receiving

    /// A fetch of every request the Mac still offers. A new one is held from
    /// now; one held here and missing from the fetch was taken back. A
    /// request already finished here stays as it is, even if its record
    /// shows up again.
    func receive(_ offered: [PendingRequest]) {
        tick()
        let now = clock()
        let offeredIDs = Set(offered.map(\.id))
        for request in offered where entries[request.id] == nil {
            entries[request.id] = Entry(request: request, firstSeen: now)
        }
        for (id, entry) in entries where !offeredIDs.contains(id) && !entry.expired && !entry.withdrawn {
            entries[id]?.withdrawn = true
        }
        prune()
        offerAwaited()
    }

    /// The requests still pending here, newest first: the main screen's
    /// waiting list.
    var pendingRequests: [PendingRequest] {
        let now = clock()
        return requests.filter { phase(of: $0.id, at: now)?.isPending == true }
    }

    // MARK: Live prompts (F4, #194)

    /// Brings the live prompts in line with the owner's switch, as handed in
    /// (`ApprovalsSwitch.effective`, with the pairing read afresh). On: the
    /// prompt subscription is made sure of (looked up first, created only
    /// when missing, once per launch), then one snapshot read is received
    /// (`receive`); a failed read changes nothing. Off: nothing is read, the
    /// inbox is emptied, and a subscription this launch may have left is
    /// deleted (until that is done, each sync tries again). A call made while
    /// one runs makes the running one go round once more. With no live
    /// source, nothing.
    func syncPrompts(switchedOn stored: Bool) async {
        switchedOn = stored
        guard let prompts else { return }
        if syncing {
            syncAgain = true
            return
        }
        syncing = true
        repeat {
            syncAgain = false
            await syncOnce(prompts)
        } while syncAgain
        syncing = false
    }

    /// A sync with the switch as last handed in (a prompt push's).
    func refreshPrompts() async {
        await syncPrompts(switchedOn: switchedOn)
    }

    private func syncOnce(_ prompts: any PromptSource) async {
        refreshKeyHealth()
        guard ApprovalsSwitch.effective(stored: switchedOn, keyHealth: keyHealth) else {
            awaited = nil
            if !entries.isEmpty { entries.removeAll() }
            guard mayHoldSubscription else { return }
            if await prompts.removeSubscription() {
                mayHoldSubscription = false
                subscribed = false
            }
            return
        }
        mayHoldSubscription = true
        if !subscribed { subscribed = await prompts.ensureSubscription() }
        guard let offered = await prompts.snapshot(), switchedOn else { return }
        receive(offered)
    }

    /// The owner tapped `id`'s push: the main screen opens it once the inbox
    /// holds it (now, or after the read the push starts).
    func open(_ id: PromptID) {
        awaited = id
        offerAwaited()
    }

    /// The main screen opened `opening`.
    func opened() {
        if opening != nil { opening = nil }
    }

    private func offerAwaited() {
        guard let id = awaited, entries[id] != nil else { return }
        awaited = nil
        opening = id
    }

    /// One request taken back (its record is gone). Terminal.
    func withdraw(_ id: PromptID) {
        tick()
        guard let entry = entries[id], !entry.expired else { return }
        entries[id]?.withdrawn = true
    }

    /// Marks every request whose window has closed as expired, for good.
    func tick() {
        let now = clock()
        for (id, entry) in entries where !entry.expired && !entry.withdrawn && now >= entry.answerableUntil {
            entries[id]?.expired = true
        }
    }

    /// Re-reads whether an answer can be confirmed (the screen does, as it
    /// appears: the owner may have changed Settings).
    func refreshBiometry() {
        let current = biometrics.availability()
        if current != biometry { biometry = current }
    }

    /// Re-reads where the pairing stands, asking for nothing (the screen
    /// does, as it appears and as the app returns to the foreground: a
    /// changed enrollment shows before anything is answered).
    func refreshKeyHealth() {
        let current = keyring.health()
        if current != keyHealth { keyHealth = current }
    }

    // MARK: Answering

    /// Allow: only while Allow is on offer, and only after a biometric
    /// match, asked for now (CL-3). Sent again after iCloud left it
    /// unconfirmed, it asks for a new match and is signed afresh.
    func allow(_ id: PromptID) async {
        guard isAnswerable(id, with: .allow) else { return }
        await confirmAndSend(.allow, for: id)
    }

    /// Deny: exactly as Allow (the owner's uniform-signing ruling: a Deny is
    /// signed like an Allow, so it asks for the same match).
    func deny(_ id: PromptID) async {
        guard isAnswerable(id, with: .deny) else { return }
        await confirmAndSend(.deny, for: id)
    }

    /// Asks for the match for this one answer, and sends only with it. The
    /// window is checked again after the match, since the prompt may have
    /// expired or been withdrawn meanwhile.
    private func confirmAndSend(_ verdict: ApprovalWire.Verdict, for id: PromptID) async {
        entries[id]?.answer = .confirming(verdict)
        guard case .confirmed(let match) = await biometrics.confirm(reason: Self.reason(for: verdict)) else {
            entries[id]?.answer = .notConfirmed
            return
        }
        await send(verdict, for: id, match: match)
    }

    /// Pending, no answer under way or done, `verdict` on offer (once iCloud
    /// left an answer unconfirmed, only that one is: #154), and a key to
    /// sign with: an unpaired phone asks for no match it could not use.
    private func isAnswerable(_ id: PromptID, with verdict: ApprovalWire.Verdict) -> Bool {
        tick()
        refreshKeyHealth()
        if case .unpaired = keyHealth { return false }
        guard let entry = entries[id], phase(of: id)?.isPending == true else { return false }
        let status: RequestStatus = RequestStatus(phase: .pending(until: entry.answerableUntil), answer: entry.answer,
                                                  mayHaveLanded: entry.mayHaveLanded)
        return status.answers.contains(verdict)
    }

    /// Signs and writes the decision, if the request is still pending right
    /// now. The match ends here, whatever happens: the signature spends it,
    /// and it is never kept for another answer.
    private func send(_ verdict: ApprovalWire.Verdict, for id: PromptID, match: any BiometricMatch) async {
        defer { match.invalidate() }
        tick()
        guard phase(of: id)?.isPending == true, let request = entries[id]?.request else {
            entries[id]?.answer = .none
            return
        }
        let signing = DecisionSigner.sign(verdict, for: request, at: clock(), with: keyring, match: match)
        guard case .signed(let decision) = signing else {
            entries[id]?.answer = signing == .notSigned ? .unsigned : .none
            refreshKeyHealth()
            return
        }
        entries[id]?.answer = .sending(verdict)
        let outcome = await writer.write(decision)
        entries[id]?.answer = switch outcome {
        case .saved: .sent(verdict)
        case .alreadyAnswered: .answeredElsewhere
        case .failed: .unsent(verdict)
        case .unconfirmed: .unconfirmed(verdict)
        }
        if outcome == .unconfirmed { entries[id]?.mayHaveLanded = verdict }
    }

    /// Past `capacity`, finished requests go first, oldest first; a pending
    /// one is never dropped for a finished one.
    private func prune() {
        guard entries.count > Self.capacity else { return }
        let finished = entries.values.filter { $0.withdrawn || $0.expired }
            .sorted { ($0.firstSeen, $0.request.id.hex) < ($1.firstSeen, $1.request.id.hex) }
        for entry in finished.prefix(entries.count - Self.capacity) {
            entries[entry.request.id] = nil
        }
    }
}
