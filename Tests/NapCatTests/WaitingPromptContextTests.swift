// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat
@testable import NapCatWire

/// F4 slice S2: while remote approvals are on, the waiting buzz says how many
/// permission prompts wired sessions just relayed, and of which kind — Int
/// counts per kind the category gate would forward, in fixed words. Never a
/// tool name as sent, a preview, a path or a command; never a prompt the gate
/// keeps on the Mac; and nothing at all while the feature is off or the
/// session is unwired (the buzz is then exactly what it was).
@MainActor
struct WaitingPromptContextTests {
    typealias H = FinishAlertHarness

    // MARK: - The words (byte-locked)

    struct BodyRow: Sendable, CustomTestStringConvertible {
        let kind: LidGuardMessageKind
        let expected: String
        var testDescription: String { expected }
    }

    nonisolated static let bodyRows: [BodyRow] = [
        BodyRow(kind: .needsAttention(minutes: 12, stillWorking: 0), expected: "Claude is waiting for you — 12 min in"),
        BodyRow(kind: .needsAttention(minutes: 12, stillWorking: 0, prompts: WaitingPromptCounts(bash: 1)),
                expected: "Claude is waiting for you — 12 min in — 1 Bash permission prompt"),
        BodyRow(kind: .needsAttention(minutes: 12, stillWorking: 1, prompts: WaitingPromptCounts(bash: 2)),
                expected: "Claude is waiting for you — 12 min in — 2 Bash permission prompts — 1 other still working"),
        BodyRow(kind: .needsAttention(minutes: nil, stillWorking: 2, prompts: WaitingPromptCounts(write: 1, edit: 1)),
                expected: "Claude is waiting for you — 2 permission prompts — 2 others still working"),
        BodyRow(kind: .needsAttention(minutes: nil, stillWorking: 0, prompts: WaitingPromptCounts(notebookEdit: 1)),
                expected: "Claude is waiting for you — 1 NotebookEdit permission prompt"),
        BodyRow(kind: .needsAttention(minutes: 3, stillWorking: 0, prompts: WaitingPromptCounts(read: 4)),
                expected: "Claude is waiting for you — 3 min in — 4 Read permission prompts"),
        BodyRow(kind: .needsAttention(minutes: 0, stillWorking: 0, prompts: WaitingPromptCounts(write: 1)),
                expected: "Claude is waiting for you — 1 Write permission prompt"),
    ]

    @Test(arguments: bodyRows)
    func theWaitingBuzzWords(_ row: BodyRow) {
        #expect(LidGuardPolicy.messageBody(kind: row.kind, clockTime: "09:41") == row.expected)
    }

    /// Without counts the buzz is byte-for-byte what it was before this slice
    /// (an unwired session, or remote approvals off).
    @Test func noCountsLeaveTheBuzzAsItWas() {
        for minutes: Int? in [nil, 12] {
            for working in [0, 1, 3] {
                let before = LidGuardPolicy.messageBody(kind: .needsAttention(minutes: minutes, stillWorking: working),
                                                        clockTime: "09:41")
                let none = LidGuardPolicy.messageBody(
                    kind: .needsAttention(minutes: minutes, stillWorking: working, prompts: .none), clockTime: "09:41")
                #expect(before == none)
                #expect(!before.contains("prompt"))
            }
        }
    }

    /// A closed vocabulary: whatever the counts, the body is fixed words,
    /// digits and the dash — the kind words come from the table, never from
    /// input.
    @Test func everyBodyIsClosedVocabulary() {
        let words: Set<Substring> = ["Claude", "is", "waiting", "for", "you", "—", "min", "in", "other", "others", "still",
                                     "working", "permission", "prompt", "prompts", "Bash", "Write", "Edit", "NotebookEdit",
                                     "Read"]
        var checked = 0
        for bash in 0...2 {
            for write in 0...1 {
                for read in 0...1 {
                    let counts = WaitingPromptCounts(bash: bash, write: write, read: read)
                    let body = LidGuardPolicy.messageBody(
                        kind: .needsAttention(minutes: 7, stillWorking: 1, prompts: counts), clockTime: "09:41")
                    for word in body.split(separator: " ") where !word.allSatisfy(\.isNumber) {
                        #expect(words.contains(word), "'\(word)' in '\(body)'")
                    }
                    checked += 1
                }
            }
        }
        #expect(checked == 12)
        #expect(LidGuardMessageKind.needsAttention(minutes: 1, stillWorking: 0, prompts: WaitingPromptCounts(bash: 1))
                != .needsAttention(minutes: 1, stillWorking: 0), "the counts distinguish two buzzes")
    }

    @Test func countsPerKindFromTheGatesTools() {
        let counts = WaitingPromptCounts([.bash, .bash, .write, .edit, .notebookEdit, .read, .read, .read])
        #expect(counts == WaitingPromptCounts(bash: 2, write: 1, edit: 1, notebookEdit: 1, read: 3))
        #expect(counts.total == 8)
        #expect(WaitingPromptCounts([]) == .none)
        #expect(WaitingPromptCounts(ApprovalTool.allCases).kinds.map(\.word) == ["Bash", "Write", "Edit", "NotebookEdit", "Read"])
    }

    // MARK: - The digest

    @Test func theDigestCarriesTheLatestWaitingCounts() {
        var digest = FinishAlertDigest()
        digest.fold(.waiting(minutes: 12), stillWorking: 2, prompts: WaitingPromptCounts(bash: 1), at: 100)
        digest.fold(.waiting(minutes: 3), stillWorking: 2, prompts: WaitingPromptCounts(bash: 1, write: 1), at: 101)
        digest.fold(.finished(minutes: 5), stillWorking: 2, at: 102)
        #expect(digest.messages() == [
            .needsAttention(minutes: nil, stillWorking: 1, prompts: WaitingPromptCounts(bash: 1, write: 1)),
            .sessionFinished(minutes: 5, folded: 1, stillWorking: 2),
        ], "the latest read covers the earlier prompts too; a finish never changes the counts")

        var finishOnly = FinishAlertDigest()
        finishOnly.fold(.finished(minutes: 5), stillWorking: 0, prompts: WaitingPromptCounts(bash: 9), at: 1)
        #expect(finishOnly.prompts == .none, "a finish carries no prompt counts")
    }

    /// A message folded back after a 429 keeps its counts — unless a newer
    /// waiting fold already brought fresher ones.
    @Test func anAbsorbedBuzzKeepsItsCountsUnlessNewerOnesAreThere() {
        var empty = FinishAlertDigest()
        empty.absorb(.needsAttention(minutes: 12, stillWorking: 0, prompts: WaitingPromptCounts(edit: 1)),
                     stillWorking: 1, at: 10)
        #expect(empty.messages().first == .needsAttention(minutes: 12, stillWorking: 0, prompts: WaitingPromptCounts(edit: 1)))

        var fresher = FinishAlertDigest()
        fresher.fold(.waiting(minutes: 2), stillWorking: 1, prompts: WaitingPromptCounts(read: 1), at: 20)
        fresher.absorb(.needsAttention(minutes: 12, stillWorking: 0, prompts: WaitingPromptCounts(edit: 1)),
                       stillWorking: 1, at: 10)
        #expect(fresher.prompts == WaitingPromptCounts(read: 1))
    }

    // MARK: - The finish alert reads the counts once per waiting diff

    final class Provider {
        var counts = WaitingPromptCounts.none
        var reads = 0
    }

    func withController(_ provider: Provider, _ body: (FinishAlertController, FakeMarkerStore, ManualScheduler,
                                                       WatcherFactory, RecordingMessageSender) async throws -> Void)
        async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("napcat-s2-wait-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeMarkerStore()
        let scheduler = ManualScheduler()
        let factory = WatcherFactory()
        let sender = RecordingMessageSender()
        let controller = FinishAlertController(
            store: store, markerDirURL: dir, config: FakeFinishConfig(), sender: sender,
            makeWatcher: { factory.make($0) }, scheduler: scheduler, now: { Double(H.t0) },
            waitingPrompts: {
                provider.reads += 1
                return provider.counts
            })
        try await body(controller, store, scheduler, factory, sender)
    }

    func settle(_ factory: WatcherFactory, _ scheduler: ManualScheduler) async {
        factory.latest?.deliver(.contentsChanged)
        await drainMain()
        scheduler.pending(delay: FinishAlertTuning.debounceSeconds).last?.fire()
        await drainMain()
    }

    @Test func theBuzzCarriesTheCountsAndOnlyAWaitingDiffReadsThem() async throws {
        let provider = Provider()
        provider.counts = WaitingPromptCounts(bash: 1)
        try await withController(provider) { controller, store, scheduler, factory, sender in
            store.put(H.s1, ts: H.t0 - 720)
            store.put(H.s2, ts: H.t0 - 1200)
            controller.reconcile()
            #expect(provider.reads == 0, "arming reads nothing")

            store.put(H.s1, ts: H.t0, event: H.waiting)
            await settle(factory, scheduler)
            #expect(sender.sends.map(\.kind) == [.needsAttention(minutes: 12, stillWorking: 1,
                                                                 prompts: WaitingPromptCounts(bash: 1))])
            #expect(provider.reads == 1, "one read for the waiting diff")
            #expect(LidGuardPolicy.messageBody(kind: sender.sends[0].kind, clockTime: "09:41")
                    == "Claude is waiting for you — 12 min in — 1 Bash permission prompt — 1 other still working")

            store.remove(H.s2)
            await settle(factory, scheduler)
            #expect(provider.reads == 1, "a finish-only diff never reads the seam")
        }
    }

    /// Off (the provider's `.none`): the buzz is exactly the pre-S2 one.
    @Test func offTheBuzzIsUnchanged() async throws {
        let provider = Provider()
        try await withController(provider) { controller, store, scheduler, factory, sender in
            store.put(H.s1, ts: H.t0 - 720)
            controller.reconcile()
            store.put(H.s1, ts: H.t0, event: H.waiting)
            await settle(factory, scheduler)
            #expect(sender.sends.map(\.kind) == [.needsAttention(minutes: 12, stillWorking: 0)])
            #expect(LidGuardPolicy.messageBody(kind: sender.sends[0].kind, clockTime: "09:41")
                    == "Claude is waiting for you — 12 min in")
        }
    }

    // MARK: - What the intake counts

    @Test func theIntakeCountsRecentForwardablePromptsOfLiveSessionsOnly() {
        let harness = IntakeHarness()
        harness.armed = false   // the S2 posture: classified, never forwarded
        harness.receive("abcde", preview: #"{"command":"git status"}"#, from: 1)
        harness.receive("bcdef", preview: #"{"command":"sudo ls"}"#, from: 1)
        harness.receive("cdefg", tool: "Write", preview: #"{"file_path":"/Users/someone/project/notes.md","content":"x"}"#,
                        from: 2)
        harness.receive("defgh", tool: "mcp__webhook__reply", preview: #"{"text":"hi"}"#, from: 2)
        let within = ApprovalIntake.waitingContextSeconds
        #expect(harness.intake.recentForwardableTools(within: within).sorted { $0.rawValue < $1.rawValue } == [.bash, .write],
                "the forbidden and the MCP prompts are never counted")
        #expect(harness.sink.saved.isEmpty, "counting is not forwarding")

        harness.intake.connectionClosed(2)
        #expect(harness.intake.recentForwardableTools(within: within) == [.bash], "a session that ended no longer counts")

        harness.now += within + 1
        #expect(harness.intake.recentForwardableTools(within: within).isEmpty, "an older prompt is not this wait's")
    }

    // MARK: - The toggle answers only while listening

    @Test func theToggleCountsOnlyWhileListening() throws {
        let world = try ApprovalsWorld()
        #expect(world.controller.waitingPrompts() == .none)
        #expect(world.builtHosts.isEmpty, "off: the seam is never even reached")

        world.controller.setEnabled(true)
        world.prompt("abcde", preview: #"{"command":"git status"}"#)
        #expect(world.nextPrompt(endingIn: "suppressed.notArmed") != nil)
        world.prompt("bcdef", preview: #"{"command":"sudo ls"}"#)
        #expect(world.nextPrompt(endingIn: "suppressed.notArmed") != nil)
        #expect(world.controller.waitingPrompts() == WaitingPromptCounts(bash: 1), "the sudo prompt is never counted")

        world.controller.setEnabled(false)
        #expect(world.controller.waitingPrompts() == .none, "the kill switch silences the counts too")
    }

    /// Off, the seam's intake is never consulted — not even through the
    /// stopped host the toggle keeps — so a waiting buzz costs the seam
    /// nothing while the feature is off. (The intake reads its clock on every
    /// query; a query after the kill switch would show up here.)
    @Test func offTheSeamIsNeverConsulted() throws {
        let clockReads = ApprovalsInbox<Void>()
        let world = try ApprovalsWorld(makeHost: { path, audit in
            ApprovalSeamHost(socketPath: path, armed: { @Sendable in false }, secrets: { @Sendable in [] },
                             records: FailDarkApprovalRecords(), audit: audit,
                             now: { @Sendable in
                                 clockReads.put(())
                                 return 1_000
                             })
        })
        world.controller.setEnabled(true)
        world.prompt("abcde")
        #expect(world.nextPrompt(endingIn: "suppressed.notArmed") != nil)
        #expect(world.controller.waitingPrompts() == WaitingPromptCounts(bash: 1))
        world.controller.setEnabled(false)
        let before = clockReads.all.count
        #expect(world.controller.waitingPrompts() == .none)
        #expect(world.controller.waitingPrompts() == .none)
        #expect(clockReads.all.count == before, "off: the intake was not asked")
    }
}
