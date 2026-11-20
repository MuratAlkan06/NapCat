// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// Ordered record of which transport was called, across both fakes.
final class TransportLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func add(_ entry: String) {
        lock.lock()
        stored.append(entry)
        lock.unlock()
    }

    var entries: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// A `MessageSender` fake that logs its name in call order, records what it
/// was asked to send, answers with a stubbed outcome — inline, or held until
/// `release` (to keep a send in flight). Never touches any network.
final class ScriptedSender: MessageSender, @unchecked Sendable {
    let name: String
    private let log: TransportLog
    private let lock = NSLock()
    private var outcome: MessageSendOutcome
    private var holds = false
    private var recorded: [RecordedMessageSend] = []
    private var pending: [@Sendable (MessageSendOutcome) -> Void] = []

    init(_ name: String, log: TransportLog, outcome: MessageSendOutcome = .accepted) {
        self.name = name
        self.log = log
        self.outcome = outcome
    }

    var sends: [RecordedMessageSend] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func hold() {
        lock.lock()
        holds = true
        lock.unlock()
    }

    /// Completes the oldest held send with `outcome`.
    func release(_ outcome: MessageSendOutcome) {
        lock.lock()
        let completion = pending.isEmpty ? nil : pending.removeFirst()
        lock.unlock()
        completion?(outcome)
    }

    func send(
        _ kind: LidGuardMessageKind,
        to destination: NtfyDestination,
        at firedAt: Date,
        completion: @escaping @Sendable (MessageSendOutcome) -> Void
    ) {
        log.add(name)
        lock.lock()
        recorded.append(RecordedMessageSend(kind: kind, destination: destination, firedAt: firedAt))
        if holds {
            pending.append(completion)
            lock.unlock()
            return
        }
        let answer = outcome
        lock.unlock()
        completion(answer)
    }
}

/// F3 stage 1 — the composite's routing contract (frozen ADR): phone first
/// only when toggled on in an entitled build; ntfy fallback ONLY after a
/// definitive phone failure, never after an unconfirmed one; per-lane single
/// flight across the whole chain; and with the toggle off, today's ntfy path
/// bit for bit. Fakes only — no CloudKit, no network.
struct CompositeMessageSenderTests {
    static let destination = NtfyDestination(server: "https://ntfy.sh", topic: "napcat-composite-tests")
    static let firedAt = Date(timeIntervalSince1970: 1_800_000_000)

    static let everyKind: [LidGuardMessageKind] = [
        .lidAlert(busySessionCount: 2),
        .test,
        .sessionFinished(minutes: 42, folded: 1, stillWorking: 1),
        .needsAttention(minutes: 12, stillWorking: 0),
        .connectionRestored(minutes: 14, deliveredLate: 2, dropped: 0, lidMissed: 1),
    ]

    static let everyOutcome: [MessageSendOutcome] = [
        .accepted, .rejected(429), .timedOutUnconfirmed, .sendFailed("the ntfy server refused the connection"),
    ]

    /// Two scripted transports behind a composite on an isolated defaults
    /// suite (removed again when the rig goes away).
    final class Rig {
        let log: TransportLog
        let ntfy: ScriptedSender
        let phone: ScriptedSender
        let probe: CallCounter
        let suite: String
        let defaults: UserDefaults
        let composite: CompositeMessageSender

        init(enabled: Bool?, entitled: Bool = true,
             phoneOutcome: MessageSendOutcome = .accepted, ntfyOutcome: MessageSendOutcome = .accepted) {
            let log = TransportLog()
            let probe = CallCounter()
            self.log = log
            self.probe = probe
            ntfy = ScriptedSender("ntfy", log: log, outcome: ntfyOutcome)
            phone = ScriptedSender("phone", log: log, outcome: phoneOutcome)
            suite = "com.muratalkan.napcat.tests.composite.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            if let enabled { defaults.set(enabled, forKey: DefaultsKey.phoneTransportEnabled) }
            composite = CompositeMessageSender(ntfy: ntfy, phone: phone, defaults: defaults,
                                               isEntitled: {
                                                   probe.bump()
                                                   return entitled
                                               },
                                               now: { 1_800_000_060 })
        }

        deinit {
            defaults.removePersistentDomain(forName: suite)
        }

        func send(_ kind: LidGuardMessageKind = .test, at firedAt: Date = CompositeMessageSenderTests.firedAt)
            -> OutcomeLog {
            let outcomes = OutcomeLog()
            composite.send(kind, to: CompositeMessageSenderTests.destination, at: firedAt) { outcomes.append($0) }
            return outcomes
        }
    }

    // MARK: - Toggle off: bit-identical to the ntfy sender alone

    /// The same calls against a bare ntfy fake and against the composite
    /// (toggle unset, then explicitly off) produce identical sends, identical
    /// outcomes, delivered inline exactly when the bare sender delivers them —
    /// and the phone transport and the entitlement probe are never touched.
    @Test(arguments: [nil, false] as [Bool?])
    func toggleOffIsTheNtfyPathBitForBit(_ stored: Bool?) {
        for outcome in Self.everyOutcome {
            let bareLog = TransportLog()
            let bare = ScriptedSender("ntfy", log: bareLog, outcome: outcome)
            let rig = Rig(enabled: stored, ntfyOutcome: outcome)
            for (offset, kind) in Self.everyKind.enumerated() {
                let at = Self.firedAt.addingTimeInterval(Double(offset))
                let direct = OutcomeLog()
                bare.send(kind, to: Self.destination, at: at) { direct.append($0) }
                let wrapped = rig.send(kind, at: at)
                #expect(wrapped.values == direct.values, "\(kind) / \(outcome): inline outcome differs")
            }
            #expect(rig.ntfy.sends == bare.sends, "the ntfy sender must see exactly the direct calls")
            #expect(rig.phone.sends.isEmpty, "the phone transport must not be touched while off")
            #expect(rig.probe.count == 0, "the entitlement probe must not even be consulted while off")
            #expect(rig.log.entries == Array(repeating: "ntfy", count: Self.everyKind.count))
            let snapshot = rig.composite.phoneSnapshot
            #expect(snapshot == PhoneTransportSnapshot(enabled: false, available: false,
                                                       lastOutcome: nil, lastOutcomeAt: nil))
            #expect(rig.probe.count == 0, "nor by the snapshot")
        }
    }

    /// Off adds NO claim of its own: overlapping sends in one lane both reach
    /// the ntfy sender, whose own single flight is the one that decides —
    /// exactly as before the composite existed.
    @Test func toggleOffAddsNoClaimOfItsOwn() {
        let rig = Rig(enabled: false)
        rig.ntfy.hold()
        let first = rig.send(.sessionFinished(minutes: 3, folded: 1, stillWorking: 0))
        let second = rig.send(.needsAttention(minutes: 4, stillWorking: 0))
        #expect(rig.ntfy.sends.count == 2, "both calls handed straight through")
        #expect(first.values.isEmpty && second.values.isEmpty, "nothing answered by the composite itself")
        rig.ntfy.release(.accepted)
        rig.ntfy.release(.rejected(500))
        #expect(first.values == [.accepted] && second.values == [.rejected(500)])
    }

    // MARK: - Phone first, fallback only on a definitive failure

    @Test func aDefinitiveFailureFallsBackToNtfyWithTheSameMessage() {
        for ntfyOutcome in Self.everyOutcome {
            let rig = Rig(enabled: true, phoneOutcome: .sendFailed(CloudKitMessageSender.noInternetText),
                          ntfyOutcome: ntfyOutcome)
            let kind = LidGuardMessageKind.lidAlert(busySessionCount: 1)
            let outcomes = rig.send(kind)
            #expect(rig.log.entries == ["phone", "ntfy"], "phone first, then the ntfy fallback")
            #expect(rig.phone.sends == rig.ntfy.sends, "the fallback carries the same kind, destination and time")
            #expect(rig.ntfy.sends == [RecordedMessageSend(kind: kind, destination: Self.destination,
                                                           firedAt: Self.firedAt)])
            #expect(outcomes.values == [ntfyOutcome], "the caller sees the fallback's outcome")
        }
    }

    /// The double-buzz rule: an unconfirmed phone send may already have
    /// landed, so ntfy is NOT tried.
    @Test func anUnconfirmedPhoneSendNeverFallsBack() {
        let rig = Rig(enabled: true, phoneOutcome: .timedOutUnconfirmed)
        let outcomes = rig.send(.sessionFinished(minutes: 9, folded: 1, stillWorking: 0))
        #expect(rig.log.entries == ["phone"])
        #expect(rig.ntfy.sends.isEmpty)
        #expect(outcomes.values == [.timedOutUnconfirmed])
    }

    @Test func anAcceptedOrRejectedPhoneSendNeverFallsBack() {
        for outcome: MessageSendOutcome in [.accepted, .rejected(403)] {
            let rig = Rig(enabled: true, phoneOutcome: outcome)
            let outcomes = rig.send()
            #expect(rig.log.entries == ["phone"], "\(outcome)")
            #expect(outcomes.values == [outcome])
        }
    }

    @Test func onlyADefinitiveFailureFallsBack() {
        #expect(CompositeMessageSender.fallsBack(after: .sendFailed("x")))
        for outcome: MessageSendOutcome in [.accepted, .timedOutUnconfirmed, .rejected(429), .rejected(500)] {
            #expect(!CompositeMessageSender.fallsBack(after: outcome), "\(outcome)")
        }
    }

    /// Toggle on but an unentitled build (every ad-hoc `make` build): the
    /// phone transport is never asked — straight to ntfy.
    @Test func anUnentitledBuildGoesStraightToNtfy() {
        let rig = Rig(enabled: true, entitled: false)
        let outcomes = rig.send()
        #expect(rig.log.entries == ["ntfy"])
        #expect(rig.phone.sends.isEmpty)
        #expect(outcomes.values == [.accepted])
        let snapshot = rig.composite.phoneSnapshot
        #expect(snapshot.enabled && !snapshot.available)
        #expect(snapshot.lastOutcome == nil, "no CloudKit attempt was made")
    }

    /// The toggle is read at every send: flipping it applies to the next one.
    @Test func theToggleIsReadLive() {
        let rig = Rig(enabled: false)
        _ = rig.send()
        rig.composite.setPhoneTransportEnabled(true)
        _ = rig.send()
        rig.composite.setPhoneTransportEnabled(false)
        _ = rig.send()
        #expect(rig.log.entries == ["ntfy", "phone", "ntfy"])
    }

    /// The snapshot remembers the last CloudKit attempt (outcome + time),
    /// whatever the fallback did.
    @Test func theSnapshotRecordsTheLastPhoneAttempt() {
        let rig = Rig(enabled: true, phoneOutcome: .sendFailed(CloudKitMessageSender.notSignedInText),
                      ntfyOutcome: .accepted)
        _ = rig.send()
        #expect(rig.composite.phoneSnapshot == PhoneTransportSnapshot(
            enabled: true, available: true,
            lastOutcome: .sendFailed(CloudKitMessageSender.notSignedInText), lastOutcomeAt: 1_800_000_060))
    }

    // MARK: - Single flight per lane, across the whole chain

    @Test func theLaneIsClaimedForPhoneAndFallbackTogether() {
        let rig = Rig(enabled: true)
        rig.phone.hold()
        rig.ntfy.hold()
        let first = rig.send(.needsAttention(minutes: 2, stillWorking: 0))
        // Same lane while the phone send is in flight: refused inline, and
        // it can NOT slip out over ntfy instead.
        let refused = rig.send(.sessionFinished(minutes: 3, folded: 1, stillWorking: 0))
        #expect(refused.values == [.sendFailed(CompositeMessageSender.busyLaneText)])
        #expect(rig.log.entries == ["phone"])
        // The other lane is never blocked.
        _ = rig.send(.lidAlert(busySessionCount: 1))
        #expect(rig.log.entries == ["phone", "phone"])

        // The first session send fails definitively → fallback in flight:
        // the lane stays claimed until ntfy answers.
        rig.phone.release(.sendFailed(CloudKitMessageSender.unreachableText))
        #expect(rig.log.entries == ["phone", "phone", "ntfy"])
        let stillBusy = rig.send(.sessionFinished(minutes: 4, folded: 1, stillWorking: 0))
        #expect(stillBusy.values == [.sendFailed(CompositeMessageSender.busyLaneText)])
        rig.ntfy.release(.accepted)
        #expect(first.values == [.accepted])

        // Free again.
        rig.phone.release(.accepted)   // the lid-lane send
        let next = rig.send(.sessionFinished(minutes: 5, folded: 1, stillWorking: 0))
        #expect(rig.log.entries == ["phone", "phone", "ntfy", "phone"])
        rig.phone.release(.accepted)
        #expect(next.values == [.accepted])
    }

    /// The refusal text is the ntfy sender's own, so callers that already
    /// handle a busy lane (the lid guard's inline cooldown rollback) see the
    /// same thing on either path.
    @Test func theBusyRefusalMatchesTheOtherSenders() {
        #expect(CompositeMessageSender.busyLaneText == CloudKitMessageSender.busyLaneText)
        #expect(CompositeMessageSender.busyLaneText == "another message is still being sent")
    }
}
