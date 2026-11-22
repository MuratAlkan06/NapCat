// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import NapCatWire
import Testing

/// F4 slice S0: one prompt's lifecycle (`ApprovalLifecycle`) and its 128-bit
/// ID. Every transition is table-tested, and an exhaustive sweep over every
/// phase, event and moment proves the safety rules: nothing but a valid,
/// signed remote decision inside the TTL ever answers a dialog; terminal
/// phases never move; the first decision wins.
struct ApprovalStateMachineTests {
    // MARK: - Fixtures

    static let idA = PromptID(high: 0x0123_4567_89AB_CDEF, low: 0xFEDC_BA98_7654_3210)!
    static let idB = PromptID(high: 1, low: 2)!
    static let t0 = 1_000
    static var expiry: Int { t0 + ApprovalWire.promptTimeToLiveSeconds }

    static func decision(_ verdict: ApprovalWire.Verdict = .allow, id: PromptID = idA,
                         version: Int = ApprovalWire.wireVersion, signed: Bool = true) -> ApprovalEvent {
        .remoteDecision(ApprovalDecision(promptID: id, verdict: verdict, wireVersion: version, signatureVerified: signed))
    }

    /// A lifecycle for `idA` opened at `t0`, then driven by `events`.
    static func machine(_ classification: ApprovalClassification = .forward(.bash), armed: Bool = true,
                        events: [(ApprovalEvent, Int)] = []) -> ApprovalLifecycle {
        var lifecycle = ApprovalLifecycle.open(id: idA, classification: classification, armed: armed, now: t0).lifecycle
        for (event, now) in events { _ = lifecycle.apply(event, now: now) }
        return lifecycle
    }

    static var saving: ApprovalLifecycle { machine() }
    static var forwarded: ApprovalLifecycle { machine(events: [(.saveAccepted, t0 + 1)]) }

    struct Step: Sendable, CustomTestStringConvertible {
        let note: String
        let start: ApprovalLifecycle
        let event: ApprovalEvent
        let now: Int
        let phase: ApprovalPhase
        let effects: [ApprovalEffect]
        let audit: [ApprovalAudit]
        var testDescription: String { note }
    }

    static func step(_ note: String, _ start: ApprovalLifecycle, _ event: ApprovalEvent, at now: Int,
                     _ phase: ApprovalPhase, _ effects: [ApprovalEffect], _ audit: [ApprovalAudit]) -> Step {
        Step(note: note, start: start, event: event, now: now, phase: phase, effects: effects, audit: audit)
    }

    // MARK: - PromptID

    @Test func promptIDsRoundTripThroughTheirRecordName() throws {
        #expect(Self.idA.hex == "0123456789abcdeffedcba9876543210")
        #expect(PromptID(hex: Self.idA.hex) == Self.idA)
        #expect(Self.idB.hex == "00000000000000010000000000000002", "each half padded to 16 digits")
        #expect(Self.idB.description == Self.idB.hex)
        #expect(Self.idA.hex.count == ApprovalWire.promptIDHexDigits)
        let max = try #require(PromptID(high: .max, low: .max))
        #expect(max.hex == String(repeating: "f", count: 32))
        #expect(PromptID(hex: max.hex) == max)
        #expect(Set([Self.idA, Self.idB, PromptID(hex: Self.idA.hex)!]).count == 2)
    }

    @Test(arguments: [
        "", "0123456789abcdeffedcba987654321", "0123456789abcdeffedcba98765432100",
        "0123456789ABCDEFFEDCBA9876543210", "0123456789abcdeffedcba987654321g", "0x23456789abcdeffedcba9876543210",
        " 123456789abcdeffedcba9876543210", "0123456789abcdef-edcba9876543210", "00000000000000000000000000000000",
        "0123456789abcdeffedcba987654321\u{0661}",
    ])
    func promptIDsRefuseEveryOtherSpelling(_ text: String) {
        #expect(PromptID(hex: text) == nil)
    }

    @Test func theAllZeroIDIsNeverAPromptID() {
        #expect(PromptID(high: 0, low: 0) == nil)
        #expect(PromptID(high: 0, low: 1) != nil)
        #expect(PromptID(high: 1, low: 0) != nil)
    }

    // MARK: - Opening

    @Test func aPromptIsForwardedOnlyWhenTheGateForwardsAndBothSidesAreArmed() {
        let forwarded = ApprovalLifecycle.open(id: Self.idA, classification: .forward(.write), armed: true, now: Self.t0)
        #expect(forwarded.lifecycle.phase == .saving)
        #expect(forwarded.transition == ApprovalTransition(effects: [.saveRecord], audit: []))
        #expect(forwarded.lifecycle.expiresAt == Self.t0 + 600)

        let unarmed = ApprovalLifecycle.open(id: Self.idA, classification: .forward(.write), armed: false, now: Self.t0)
        #expect(unarmed.lifecycle.phase == .suppressed(.notArmed))
        #expect(unarmed.transition == ApprovalTransition(effects: [], audit: [.suppressed(.notArmed)]))

        let gated: ApprovalSuppression = .forbidden(.secretAccess)
        let kept = ApprovalLifecycle.open(id: Self.idA, classification: .suppress(gated), armed: true, now: Self.t0)
        #expect(kept.lifecycle.phase == .suppressed(.gate(gated)))
        #expect(kept.transition == ApprovalTransition(effects: [], audit: [.suppressed(.gate(gated))]))

        let both = ApprovalLifecycle.open(id: Self.idA, classification: .suppress(gated), armed: false, now: Self.t0)
        #expect(both.lifecycle.phase == .suppressed(.notArmed), "the feature being off comes first")
    }

    // MARK: - Every transition

    static let steps: [Step] = [
        // Saving.
        step("saving: accepted", saving, .saveAccepted, at: t0 + 1, .forwarded, [.supersedeWaitingAlert], [.forwarded]),
        step("saving: accepted after the TTL", saving, .saveAccepted, at: expiry, .expired, [.retractRecord], [.expired]),
        step("saving: failed", saving, .saveFailed, at: t0 + 1, .forwardFailed, [], [.forwardFailed]),
        step("saving: a decision before the save", saving, decision(), at: t0 + 1, .saving, [], [.ignored(.notForwarded)]),
        step("saving: answered locally", saving, .answeredLocally, at: t0 + 1, .resolved(.local), [.retractRecord],
             [.decided(.local)]),
        step("saving: tick inside the TTL", saving, .tick, at: expiry - 1, .saving, [], []),
        step("saving: tick at the TTL", saving, .tick, at: expiry, .expired, [.retractRecord], [.expired]),
        step("saving: kill switch", saving, .killSwitch, at: t0 + 1, .retracted(.killSwitch), [.retractRecord],
             [.retracted(.killSwitch)]),
        step("saving: session ended", saving, .sessionEnded, at: t0 + 1, .retracted(.sessionEnded), [.retractRecord],
             [.retracted(.sessionEnded)]),
        // Forwarded.
        step("forwarded: remote allow", forwarded, decision(.allow), at: t0 + 30, .resolved(.remote(.allow)),
             [.deliverVerdict(.allow), .retractRecord], [.decided(.remote(.allow))]),
        step("forwarded: remote deny", forwarded, decision(.deny), at: t0 + 30, .resolved(.remote(.deny)),
             [.deliverVerdict(.deny), .retractRecord], [.decided(.remote(.deny))]),
        step("forwarded: remote allow in the TTL's last second", forwarded, decision(.allow), at: expiry - 1,
             .resolved(.remote(.allow)), [.deliverVerdict(.allow), .retractRecord], [.decided(.remote(.allow))]),
        step("forwarded: remote allow at the TTL", forwarded, decision(.allow), at: expiry, .expired, [.retractRecord],
             [.expired, .ignored(.expired)]),
        step("forwarded: remote allow long after", forwarded, decision(.allow), at: expiry + 3_600, .expired,
             [.retractRecord], [.expired, .ignored(.expired)]),
        step("forwarded: decision for another prompt", forwarded, decision(id: idB), at: t0 + 30, .forwarded, [],
             [.ignored(.wrongPrompt)]),
        step("forwarded: decision of another wire version", forwarded, decision(version: ApprovalWire.wireVersion + 1),
             at: t0 + 30, .forwarded, [], [.ignored(.wrongWireVersion)]),
        step("forwarded: unsigned decision", forwarded, decision(signed: false), at: t0 + 30, .forwarded, [],
             [.ignored(.unauthenticated)]),
        step("forwarded: answered locally", forwarded, .answeredLocally, at: t0 + 30, .resolved(.local), [.retractRecord],
             [.decided(.local)]),
        step("forwarded: tick inside the TTL", forwarded, .tick, at: expiry - 1, .forwarded, [], []),
        step("forwarded: tick at the TTL", forwarded, .tick, at: expiry, .expired, [.retractRecord], [.expired]),
        step("forwarded: kill switch", forwarded, .killSwitch, at: t0 + 30, .retracted(.killSwitch), [.retractRecord],
             [.retracted(.killSwitch)]),
        step("forwarded: session ended", forwarded, .sessionEnded, at: t0 + 30, .retracted(.sessionEnded),
             [.retractRecord], [.retracted(.sessionEnded)]),
        step("forwarded: a repeated save callback", forwarded, .saveAccepted, at: t0 + 30, .forwarded, [], []),
        step("forwarded: a late failure callback", forwarded, .saveFailed, at: t0 + 30, .forwarded, [], []),
        // Terminal phases: decisions are losers, late records are deleted.
        step("resolved remotely: a second decision", machine(events: [(.saveAccepted, t0 + 1), (decision(.allow), t0 + 2)]),
             decision(.deny), at: t0 + 3, .resolved(.remote(.allow)), [], [.ignored(.alreadyResolved)]),
        step("resolved remotely: answered locally later", machine(events: [(.saveAccepted, t0 + 1), (decision(.deny), t0 + 2)]),
             .answeredLocally, at: t0 + 3, .resolved(.remote(.deny)), [], []),
        step("resolved locally: the remote decision loses", machine(events: [(.saveAccepted, t0 + 1), (.answeredLocally, t0 + 2)]),
             decision(.allow), at: t0 + 3, .resolved(.local), [], [.ignored(.alreadyResolved)]),
        step("resolved locally while saving: the late record is deleted", machine(events: [(.answeredLocally, t0 + 1)]),
             .saveAccepted, at: t0 + 2, .resolved(.local), [.retractRecord], []),
        step("expired: a late decision", machine(events: [(.saveAccepted, t0 + 1), (.tick, expiry)]), decision(), at: expiry + 1,
             .expired, [], [.ignored(.expired)]),
        step("expired while saving: the late record is deleted", machine(events: [(.tick, expiry)]), .saveAccepted,
             at: expiry + 1, .expired, [.retractRecord], []),
        step("expired: a decision for another prompt", machine(events: [(.saveAccepted, t0 + 1), (.tick, expiry)]),
             decision(id: idB), at: expiry + 1, .expired, [], [.ignored(.wrongPrompt)]),
        step("kill switch: a later decision has no effect", machine(events: [(.saveAccepted, t0 + 1), (.killSwitch, t0 + 2)]),
             decision(), at: t0 + 3, .retracted(.killSwitch), [], [.ignored(.retracted)]),
        step("kill switch while saving: the late record is deleted", machine(events: [(.killSwitch, t0 + 1)]), .saveAccepted,
             at: t0 + 2, .retracted(.killSwitch), [.retractRecord], []),
        step("kill switch: a second kill switch", machine(events: [(.saveAccepted, t0 + 1), (.killSwitch, t0 + 2)]), .killSwitch,
             at: t0 + 3, .retracted(.killSwitch), [], []),
        step("save failed: a decision", machine(events: [(.saveFailed, t0 + 1)]), decision(), at: t0 + 2, .forwardFailed, [],
             [.ignored(.notForwarded)]),
        step("save failed: the save landed after all", machine(events: [(.saveFailed, t0 + 1)]), .saveAccepted, at: t0 + 2,
             .forwardFailed, [.retractRecord], []),
        step("save failed: answered locally", machine(events: [(.saveFailed, t0 + 1)]), .answeredLocally, at: t0 + 2,
             .forwardFailed, [], []),
        step("suppressed: a decision", machine(.suppress(.localOnlyMCP)), decision(), at: t0 + 1,
             .suppressed(.gate(.localOnlyMCP)), [], [.ignored(.notForwarded)]),
        step("suppressed: a save callback", machine(.suppress(.localOnlyMCP)), .saveAccepted, at: t0 + 1,
             .suppressed(.gate(.localOnlyMCP)), [], []),
        step("suppressed: kill switch", machine(.suppress(.localOnlyMCP)), .killSwitch, at: t0 + 1,
             .suppressed(.gate(.localOnlyMCP)), [], []),
        step("suppressed: the TTL", machine(.suppress(.localOnlyMCP)), .tick, at: expiry, .suppressed(.gate(.localOnlyMCP)),
             [], []),
        step("not armed: a decision", machine(armed: false), decision(), at: t0 + 1, .suppressed(.notArmed), [],
             [.ignored(.notForwarded)]),
    ]

    @Test(arguments: steps)
    func everyTransition(_ step: Step) {
        var lifecycle = step.start
        let transition = lifecycle.apply(step.event, now: step.now)
        #expect(lifecycle.phase == step.phase)
        #expect(transition.effects == step.effects)
        #expect(transition.audit == step.audit)
        #expect(lifecycle.id == step.start.id && lifecycle.createdAt == step.start.createdAt, "identity never changes")
    }

    // MARK: - Safety sweep

    /// Every reachable phase, as a start.
    static var everyPhase: [ApprovalLifecycle] {
        [
            saving, forwarded,
            machine(events: [(.saveFailed, t0 + 1)]),
            machine(events: [(.saveAccepted, t0 + 1), (decision(.allow), t0 + 2)]),
            machine(events: [(.saveAccepted, t0 + 1), (decision(.deny), t0 + 2)]),
            machine(events: [(.saveAccepted, t0 + 1), (.answeredLocally, t0 + 2)]),
            machine(events: [(.saveAccepted, t0 + 1), (.tick, expiry)]),
            machine(events: [(.saveAccepted, t0 + 1), (.killSwitch, t0 + 2)]),
            machine(events: [(.saveAccepted, t0 + 1), (.sessionEnded, t0 + 2)]),
            machine(.suppress(.forbidden(.privilegeEscalation))),
            machine(.suppress(.unclassifiable(.unknownTool))),
            machine(armed: false),
        ]
    }

    /// Every event, with good and bad decisions of both verdicts.
    static var everyEvent: [ApprovalEvent] {
        var events: [ApprovalEvent] = [.saveAccepted, .saveFailed, .answeredLocally, .tick, .killSwitch, .sessionEnded]
        for verdict in ApprovalWire.Verdict.allCases {
            events += [decision(verdict), decision(verdict, id: idB), decision(verdict, version: 0),
                       decision(verdict, signed: false)]
        }
        return events
    }

    static let moments = [t0 - 5, t0, t0 + 1, t0 + 599, t0 + 600, t0 + 601, t0 + 100_000]

    /// NO AUTO-ACTION, EVER: a verdict is delivered only for a valid, signed,
    /// same-version decision for this prompt, while forwarded, before the TTL
    /// — and then it is exactly that decision's verdict. Nothing else ever
    /// saves a record, and only an accepted save supersedes the waiting alert.
    @Test func onlyAValidRemoteDecisionInsideTheTTLDeliversAVerdict() {
        var sweeps = 0
        for start in Self.everyPhase {
            for event in Self.everyEvent {
                for now in Self.moments {
                    var lifecycle = start
                    let effects = lifecycle.apply(event, now: now).effects
                    sweeps += 1
                    let delivered = effects.compactMap { effect -> ApprovalWire.Verdict? in
                        if case .deliverVerdict(let verdict) = effect { return verdict }
                        return nil
                    }
                    var expected: [ApprovalWire.Verdict] = []
                    if case .remoteDecision(let decision) = event, start.phase == .forwarded, now < start.expiresAt,
                       decision.promptID == start.id, decision.wireVersion == ApprovalWire.wireVersion,
                       decision.signatureVerified {
                        expected = [decision.verdict]
                    }
                    #expect(delivered == expected, "\(start.phase) + \(event) at \(now)")
                    #expect(!effects.contains(.saveRecord), "only opening saves a record")
                    if effects.contains(.supersedeWaitingAlert) {
                        #expect(start.phase == .saving && event == .saveAccepted && lifecycle.phase == .forwarded)
                    }
                }
            }
        }
        #expect(sweeps == Self.everyPhase.count * Self.everyEvent.count * Self.moments.count)
        #expect(sweeps > 1_000, "vacuity: the sweep ran")
    }

    /// Terminal phases never move: the first answer (or the end) stands.
    @Test func terminalPhasesNeverChange() {
        for start in Self.everyPhase where start.phase.isTerminal {
            for event in Self.everyEvent {
                for now in Self.moments {
                    var lifecycle = start
                    _ = lifecycle.apply(event, now: now)
                    #expect(lifecycle.phase == start.phase, "\(start.phase) + \(event) at \(now)")
                }
            }
        }
        #expect(!ApprovalPhase.saving.isTerminal && !ApprovalPhase.forwarded.isTerminal)
    }

    // MARK: - The acceptance scenarios, end to end

    /// AC 5: nobody answers. The TTL withdraws the record and answers nothing;
    /// a late or duplicate decision changes nothing and is logged as ignored.
    @Test func anUnansweredPromptIsWithdrawnNeverAnswered() {
        var lifecycle = Self.forwarded
        var effects: [ApprovalEffect] = []
        for now in stride(from: Self.t0 + 1, through: Self.expiry + 60, by: 30) {
            effects += lifecycle.apply(.tick, now: now).effects
        }
        #expect(lifecycle.phase == .expired)
        #expect(effects == [.retractRecord], "withdrawn exactly once, never answered")
        #expect(lifecycle.apply(Self.decision(.allow), now: Self.expiry + 61) == ApprovalTransition(effects: [], audit: [.ignored(.expired)]))
    }

    /// AC 7: the kill switch mid-pending retracts, and a later phone decision
    /// has no effect.
    @Test func theKillSwitchRetractsAndSilencesLaterDecisions() {
        var lifecycle = Self.forwarded
        #expect(lifecycle.apply(.killSwitch, now: Self.t0 + 5).effects == [.retractRecord])
        let late = lifecycle.apply(Self.decision(.allow), now: Self.t0 + 6)
        #expect(late.effects.isEmpty && late.audit == [.ignored(.retracted)])
    }

    /// AC 6: two pending prompts. A decision carries one prompt's ID, so it
    /// resolves that prompt and leaves the other exactly as it was.
    @Test func twoPendingPromptsAreIndependent() {
        var first = Self.forwarded
        var second = ApprovalLifecycle.open(id: Self.idB, classification: .forward(.bash), armed: true, now: Self.t0).lifecycle
        _ = second.apply(.saveAccepted, now: Self.t0 + 1)
        let untouched = second
        let answer = Self.decision(.deny, id: Self.idA)
        #expect(first.apply(answer, now: Self.t0 + 10).effects == [.deliverVerdict(.deny), .retractRecord])
        #expect(second.apply(answer, now: Self.t0 + 10).audit == [.ignored(.wrongPrompt)])
        #expect(second == untouched)
        #expect(second.apply(Self.decision(.allow, id: Self.idB), now: Self.t0 + 11).effects == [.deliverVerdict(.allow), .retractRecord])
    }

    /// The race: whichever answer comes first wins; the other is a no-op.
    @Test func theFirstDecisionWins() {
        var localFirst = Self.forwarded
        _ = localFirst.apply(.answeredLocally, now: Self.t0 + 5)
        #expect(localFirst.apply(Self.decision(.allow), now: Self.t0 + 6).audit == [.ignored(.alreadyResolved)])
        #expect(localFirst.phase == .resolved(.local))

        var remoteFirst = Self.forwarded
        _ = remoteFirst.apply(Self.decision(.allow), now: Self.t0 + 5)
        #expect(remoteFirst.apply(.answeredLocally, now: Self.t0 + 6) == ApprovalTransition.none)
        #expect(remoteFirst.apply(Self.decision(.allow), now: Self.t0 + 7).audit == [.ignored(.alreadyResolved)])
        #expect(remoteFirst.phase == .resolved(.remote(.allow)))
    }

    /// A failed save leaves the prompt local-only and keeps the plain waiting
    /// alert (no supersede effect), so a broken forward is never silent.
    @Test func aFailedSaveNeverSilencesTheWaitingAlert() {
        var lifecycle = Self.saving
        #expect(lifecycle.apply(.saveFailed, now: Self.t0 + 1).effects.isEmpty)
        #expect(lifecycle.phase == .forwardFailed)
    }

    // MARK: - Structure locks

    static func machineCode() throws -> String { try WireContractTests.wireCode("ApprovalStateMachine.swift") }

    static func structureFailures(_ code: String) -> [String] {
        var failures: [String] = []
        let deliveries = code.components(separatedBy: ".deliverVerdict(").count - 1
        if deliveries != 1 { failures.append("`.deliverVerdict(` appears \(deliveries) times, expected once") }
        for token in ["default:", "case _", "fallthrough", "600"] where code.contains(token) {
            failures.append("'\(token)' in the state machine")
        }
        if !code.contains("ApprovalWire.promptTimeToLiveSeconds") { failures.append("the TTL is not the wire's") }
        return failures
    }

    /// One verdict site; exhaustive switches (a new phase or event must be
    /// decided everywhere, never caught by a catch-all); the TTL comes from
    /// the wire contract, never a literal.
    @Test func theStateMachineHasOneVerdictSiteAndNoCatchAll() throws {
        let failures = Self.structureFailures(try Self.machineCode())
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test func theStructureLockCatchesMutants() throws {
        let code = try Self.machineCode()
        let mutants = [
            code.replacingOccurrences(of: "phase = .expired\n            return ApprovalTransition(effects: [.retractRecord], audit: [.expired])\n        case .suppressed",
                                      with: "phase = .expired\n            return ApprovalTransition(effects: [.deliverVerdict(.deny)], audit: [.expired])\n        case .suppressed"),
            code.replacingOccurrences(of: "        case .saving, .suppressed, .forwardFailed: return Self.ignored(.notForwarded)",
                                      with: "        default: return Self.ignored(.notForwarded)"),
            code.replacingOccurrences(of: "ApprovalWire.promptTimeToLiveSeconds }", with: "600 }"),
        ]
        for mutant in mutants {
            #expect(mutant != code, "the mutant applies")
            #expect(!Self.structureFailures(mutant).isEmpty, "a mutant was NOT caught")
        }
    }
}
