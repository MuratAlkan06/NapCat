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
                return WaitingPromptContext(counts: provider.counts)
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
            #expect(provider.reads == 1, "arming reads once, so no prompt relayed before it is new to a later diff")

            store.put(H.s1, ts: H.t0, event: H.waiting)
            await settle(factory, scheduler)
            #expect(sender.sends.map(\.kind) == [.needsAttention(minutes: 12, stillWorking: 1,
                                                                 prompts: WaitingPromptCounts(bash: 1))])
            #expect(provider.reads == 2, "one read for the waiting diff")
            #expect(LidGuardPolicy.messageBody(kind: sender.sends[0].kind, clockTime: "09:41")
                    == "Claude is waiting for you — 12 min in — 1 Bash permission prompt — 1 other still working")

            store.remove(H.s2)
            await settle(factory, scheduler)
            #expect(provider.reads == 2, "a finish-only diff never reads the seam")
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
        harness.receive("cdefg", tool: "Read", preview: #"{"file_path":"/Users/someone/project/notes.md"}"#, from: 2)
        harness.receive("defgh", tool: "mcp__webhook__reply", preview: #"{"text":"hi"}"#, from: 2)
        harness.receive("efghi", tool: "Write", preview: #"{"file_path":"/Users/someone/project/notes.md","content":"x"}"#,
                        from: 2)
        harness.receive("fghij", preview: #"{"command":"make test"}"#, from: 2)
        let within = ApprovalIntake.waitingContextSeconds
        #expect(harness.intake.recentForwardableTools(within: within) == [.bash, .bash],
                "the forbidden, the Read, the MCP and the file-edit prompts are never counted")
        #expect(harness.sink.saved.isEmpty, "counting is not forwarding")

        harness.intake.connectionClosed(2)
        #expect(harness.intake.recentForwardableTools(within: within) == [.bash], "a session that ended no longer counts")

        harness.now += within + 1
        #expect(harness.intake.recentForwardableTools(within: within).isEmpty, "an older prompt is not this wait's")
    }

    /// No Read is ever counted (#231), armed or not, whatever its path: the
    /// waiting push names only the prompts the gate could let leave the
    /// Mac, and no Read is one. Its kind and word stay in the closed table
    /// (like Write's), so only the count changes: a wait on Reads alone
    /// reads as a plain waiting push.
    @Test(arguments: [false, true])
    func aReadIsNeverCounted(_ armed: Bool) {
        let harness = IntakeHarness()
        harness.armed = armed
        let previews = [#"{"file_path":"/Users/someone/project/notes.md"}"#, #"{"file_path":"/Users/someone/.sometool-token"}"#,
                        #"{"file_path":"/tmp/a.txt","offset":0,"limit":10}"#]
        for (preview, request) in zip(previews, IntakeHarness.requestIDs(previews.count)) {
            harness.receive(request, tool: "Read", preview: preview, from: 1)
        }
        let within = ApprovalIntake.waitingContextSeconds
        #expect(harness.intake.prompts.count == previews.count, "vacuity: every Read was heard")
        #expect(harness.intake.recentForwardableTools(within: within).isEmpty)
        let readsOnly = WaitingPromptCounts(harness.intake.recentForwardableTools(within: within))
        #expect(readsOnly == .none)
        #expect(LidGuardPolicy.messageBody(kind: .needsAttention(minutes: 3, stillWorking: 0, prompts: readsOnly), clockTime: "09:41")
                == "Claude is waiting for you — 3 min in", "Reads alone: the plain push")
        harness.receive("zzzzz", preview: #"{"command":"git diff"}"#, from: 1)
        let withBash = WaitingPromptCounts(harness.intake.recentForwardableTools(within: within))
        #expect(withBash == WaitingPromptCounts(bash: 1), "control: a listed command beside them is counted")
        #expect(LidGuardPolicy.messageBody(kind: .needsAttention(minutes: 3, stillWorking: 0, prompts: withBash), clockTime: "09:41")
                == "Claude is waiting for you — 3 min in — 1 Bash permission prompt", "only the Bash prompt is named")
    }

    /// Through the toggle and the real seam: a Read the wired session
    /// relays is heard and kept, and the push counts only the Bash prompt.
    @Test func theToggleNeverCountsARead() throws {
        let world = try ApprovalsWorld()
        world.controller.setEnabled(true)
        world.stdin(RelayHarness.permissionRequest("abcde", tool: "Read",
                                                   preview: #"{"file_path":"/Users/someone/project/notes.md"}"#))
        #expect(world.nextPrompt(endingIn: "suppressed.notArmed") != nil, "the Read was heard")
        #expect(world.controller.waitingPrompts().counts == .none, "a Read is never counted")
        world.prompt("bcdef", preview: #"{"command":"git status"}"#)
        #expect(world.nextPrompt(endingIn: "suppressed.notArmed") != nil)
        #expect(world.controller.waitingPrompts().counts == WaitingPromptCounts(bash: 1), "control: the Bash prompt is")
        world.controller.setEnabled(false)
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
        #expect(world.controller.waitingPrompts().counts == WaitingPromptCounts(bash: 1), "the sudo prompt is never counted")

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
        #expect(world.controller.waitingPrompts().counts == WaitingPromptCounts(bash: 1))
        world.controller.setEnabled(false)
        let before = clockReads.all.count
        #expect(world.controller.waitingPrompts() == .none)
        #expect(world.controller.waitingPrompts() == .none)
        #expect(clockReads.all.count == before, "off: the intake was not asked")
    }

    // MARK: - One alert for one permission wait (#216)

    /// The intake's clock, set by the test, read on the seam's queue.
    final class SeamClock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds = 1_000

        var now: Int {
            lock.lock()
            defer { lock.unlock() }
            return seconds
        }

        func advance(_ by: Int) {
            lock.lock()
            seconds += by
            lock.unlock()
        }
    }

    /// Every context the alert lane was handed, in order.
    final class ContextLog {
        var reads: [WaitingPromptContext] = []
    }

    /// A host's limits for these tests: a server idle for longer than any
    /// run of the suite (whose shared main actor can stretch one test to
    /// minutes) is never let go mid-test, even with no prompt still open.
    nonisolated static let patient = ApprovalSeamHost.Limits(idleSeconds: 3_600)

    /// The toggle over an ARMED test host, its record sink recorded and its
    /// clock the test's, so a prompt can reach `.forwarded`; the test plays
    /// the record path's part through the door. (The app's one host is never
    /// armed and its sink writes nothing.)
    func armedWorld(_ clock: SeamClock, _ sink: ApprovalsRecordingSink) throws -> ApprovalsWorld {
        try ApprovalsWorld(makeHost: { path, audit in
            ApprovalSeamHost(socketPath: path, armed: { @Sendable in true }, secrets: { @Sendable in [] }, records: sink,
                             audit: audit, now: { @Sendable in clock.now }, limits: Self.patient)
        })
    }

    /// One wired session's listed command, relayed over the seam and saved:
    /// `accepted` plays CloudKit accepting its record, `found` the record
    /// path finding the phone's prompt subscription.
    func relay(_ world: ApprovalsWorld, _ sink: ApprovalsRecordingSink, _ request: String,
               accepted: Bool = true, found: Bool = true) throws -> PromptID {
        world.prompt(request)
        let id = try #require(sink.saved.next(), "the armed host saves a listed command")
        world.host?.withIntake {
            if accepted { $0.apply(.saveAccepted, to: id) }
            if found { $0.noteSubscriptionFound(id) }
        }
        return id
    }

    /// The alert lane wired to the toggle as the app wires it, every context
    /// it is handed logged.
    func withWiredAlerts(_ world: ApprovalsWorld, _ log: ContextLog,
                         _ body: (FinishAlertHarness) async throws -> Void) async throws {
        try await withFinishAlertHarness(waitingPrompts: {
            let context = world.controller.waitingPrompts()
            log.reads.append(context)
            return context
        }, body)
    }

    func bodies(_ h: FinishAlertHarness) -> [String] {
        h.sends.map { LidGuardPolicy.messageBody(kind: $0.kind, clockTime: "09:41") }
    }

    /// What the seam says when the one new prompt has evidence.
    static let covered = WaitingPromptContext(counts: WaitingPromptCounts(bash: 1), countsWithEvidence: WaitingPromptCounts(bash: 1),
                                              newPrompts: 1, newPromptsWithEvidence: 1)

    /// A lone wired wait whose prompt has evidence: the phone's push stands
    /// for it, so no plain waiting alert goes; a finish in the same diff
    /// still does, and so does the next lone wait, unwired.
    @Test func aLoneWiredWaitWithEvidenceSendsNoPlainAlertButItsFinishesStillGo() async throws {
        let clock = SeamClock()
        let sink = ApprovalsRecordingSink()
        let log = ContextLog()
        let world = try armedWorld(clock, sink)
        world.controller.setEnabled(true)
        defer { world.controller.setEnabled(false) }
        try await withWiredAlerts(world, log) { h in
            h.store.put(H.s1, ts: H.t0 - 720)
            h.store.put(H.s2, ts: H.t0 - 1200)
            h.store.put(H.s3, ts: H.t0 - 1800)
            h.controller.reconcile()
            clock.advance(1)
            _ = try relay(world, sink, "abcde")
            h.store.put(H.s1, ts: H.t0, event: H.waiting)
            h.store.remove(H.s2)
            await h.settle()
            #expect(log.reads.last == Self.covered, "vacuity: the seam reported the one prompt with its evidence")
            #expect(h.sends.map(\.kind) == [.sessionFinished(minutes: 20, folded: 1, stillWorking: 2)],
                    "the wait's plain alert yields to the phone's push; the finish beside it still goes")
            h.advance(31)
            clock.advance(2)
            h.store.put(H.s3, ts: h.now, event: H.waiting)
            await h.settle()
            #expect(h.sends.dropFirst().map(\.kind) == [.needsAttention(minutes: 30, stillWorking: 1, prompts: .none)],
                    "the next lone wait alerts, and does not name the prompt the phone showed")
        }
    }

    /// A wired and an unwired wait in one diff: one plain alert, which
    /// leaves out the prompt the phone showed.
    @Test func aWiredAndAnUnwiredWaitInOneDiffGiveOnePlainAlert() async throws {
        let clock = SeamClock()
        let sink = ApprovalsRecordingSink()
        let log = ContextLog()
        let world = try armedWorld(clock, sink)
        world.controller.setEnabled(true)
        defer { world.controller.setEnabled(false) }
        try await withWiredAlerts(world, log) { h in
            h.store.put(H.s1, ts: H.t0 - 720)
            h.store.put(H.s2, ts: H.t0 - 1200)
            h.controller.reconcile()
            clock.advance(1)
            _ = try relay(world, sink, "abcde")
            h.store.put(H.s1, ts: H.t0, event: H.waiting)
            h.store.put(H.s2, ts: H.t0, event: H.waiting)
            await h.settle()
            #expect(log.reads.last == Self.covered)
            #expect(h.sends.map(\.kind) == [.needsAttention(minutes: nil, stillWorking: 1, prompts: .none)])
            #expect(bodies(h) == ["Claude is waiting for you — 1 other still working"])
        }
    }

    /// Where the one prompt stands when the lone wait is read: the test sets
    /// the record path's finding on it in every case but `notFound`.
    enum NoEvidence: String, CaseIterable, Sendable {
        case keptByTheGate, saveFailed, savePending, notFound
    }

    /// No evidence, no fold: a prompt the gate keeps, a save that failed or
    /// is still in flight, and an accepted one whose subscription was not
    /// found each leave the plain alert exactly as today, counts and all.
    @Test(arguments: NoEvidence.allCases)
    func aPromptWithoutEvidenceLeavesThePlainAlertAsToday(_ state: NoEvidence) async throws {
        let clock = SeamClock()
        let sink = ApprovalsRecordingSink()
        let log = ContextLog()
        let world = try armedWorld(clock, sink)
        world.controller.setEnabled(true)
        defer { world.controller.setEnabled(false) }
        try await withWiredAlerts(world, log) { h in
            h.store.put(H.s1, ts: H.t0 - 720)
            h.controller.reconcile()
            clock.advance(1)
            switch state {
            case .keptByTheGate:
                world.prompt("abcde", preview: #"{"command":"sudo pmset -a disablesleep 1"}"#)
                let id = try #require(world.nextPrompt(endingIn: "suppressed.gate.forbidden.privilegeEscalation"))
                world.host?.withIntake { $0.noteSubscriptionFound(id) }
            case .saveFailed:
                let id = try relay(world, sink, "abcde", accepted: false)
                world.host?.withIntake { $0.apply(.saveFailed, to: id) }
            case .savePending:
                _ = try relay(world, sink, "abcde", accepted: false)
            case .notFound:
                _ = try relay(world, sink, "abcde", found: false)
            }
            let today = WaitingPromptCounts(world.host?.withIntake { $0.recentForwardableTools(within: ApprovalIntake.waitingContextSeconds) } ?? [])
            let counted: WaitingPromptCounts = state == .keptByTheGate ? .none : WaitingPromptCounts(bash: 1)
            #expect(today == counted, "vacuity: what the waiting alert counted before this change")
            h.store.put(H.s1, ts: H.t0, event: H.waiting)
            await h.settle()
            #expect(log.reads.last?.newPrompts == 1 && log.reads.last?.newPromptsWithEvidence == 0)
            #expect(h.sends.map(\.kind) == [.needsAttention(minutes: 12, stillWorking: 0, prompts: today)])
            #expect(bodies(h) == [state == .keptByTheGate ? "Claude is waiting for you — 12 min in"
                                                           : "Claude is waiting for you — 12 min in — 1 Bash permission prompt"])
        }
    }

    /// A prompt that folded one wait never folds another: the next lone
    /// wait alerts.
    @Test func aPromptThatFoldedOnceNeverFoldsAgain() async throws {
        let clock = SeamClock()
        let sink = ApprovalsRecordingSink()
        let log = ContextLog()
        let world = try armedWorld(clock, sink)
        world.controller.setEnabled(true)
        defer { world.controller.setEnabled(false) }
        try await withWiredAlerts(world, log) { h in
            h.store.put(H.s1, ts: H.t0 - 720)
            h.store.put(H.s2, ts: H.t0 - 1200)
            h.controller.reconcile()
            clock.advance(1)
            _ = try relay(world, sink, "abcde")
            h.store.put(H.s1, ts: H.t0, event: H.waiting)
            await h.settle()
            #expect(h.sends.isEmpty, "folded")
            clock.advance(3)
            h.store.put(H.s2, ts: H.t0, event: H.waiting)
            await h.settle()
            #expect(log.reads.last?.newPrompts == 0, "the prompt is new to one read only")
            #expect(h.sends.map(\.kind) == [.needsAttention(minutes: 20, stillWorking: 1, prompts: .none)])
        }
    }

    /// A prompt older than the new-prompt window never folds a wait (exactly
    /// the window still does).
    @Test(arguments: [0, ApprovalIntake.newPromptSeconds, ApprovalIntake.newPromptSeconds + 1])
    func aPromptOlderThanTheWindowNeverFolds(_ age: Int) async throws {
        let clock = SeamClock()
        let sink = ApprovalsRecordingSink()
        let log = ContextLog()
        let world = try armedWorld(clock, sink)
        world.controller.setEnabled(true)
        defer { world.controller.setEnabled(false) }
        try await withWiredAlerts(world, log) { h in
            h.store.put(H.s1, ts: H.t0 - 720)
            h.controller.reconcile()
            clock.advance(1)
            _ = try relay(world, sink, "abcde")
            clock.advance(age)
            h.store.put(H.s1, ts: H.t0, event: H.waiting)
            await h.settle()
            let folds: Bool = age <= ApprovalIntake.newPromptSeconds
            #expect(h.sends.map(\.kind) == (folds ? [] : [.needsAttention(minutes: 12, stillWorking: 0, prompts: .none)]))
        }
    }

    /// A wired wait under the run floor sends nothing, as before, but its
    /// diff still reads the seam and uses its prompt up, so the next lone
    /// wait, unwired, still alerts.
    @Test func aWaitUnderTheFloorUsesUpItsPrompt() async throws {
        let clock = SeamClock()
        let sink = ApprovalsRecordingSink()
        let log = ContextLog()
        let world = try armedWorld(clock, sink)
        world.controller.setEnabled(true)
        defer { world.controller.setEnabled(false) }
        try await withWiredAlerts(world, log) { h in
            h.store.put(H.s1, ts: H.t0 - 10)
            h.store.put(H.s2, ts: H.t0 - 720)
            h.controller.reconcile()
            clock.advance(1)
            _ = try relay(world, sink, "abcde")
            h.store.put(H.s1, ts: H.t0, event: H.waiting)
            await h.settle()
            #expect(h.sends.isEmpty, "under the floor: no alert, as before")
            #expect(log.reads.count == 2 && log.reads.last == Self.covered, "the arm's read, then the suppressed wait's")
            clock.advance(2)
            h.store.put(H.s2, ts: H.t0, event: H.waiting)
            await h.settle()
            #expect(h.sends.map(\.kind) == [.needsAttention(minutes: 12, stillWorking: 1, prompts: .none)])
        }
    }

    /// The same diffs with no run floor ("Immediately", issue #242): nothing
    /// is under the floor, so the short wired wait has an alert of its own —
    /// and it yields to the phone's push, as any covered wait does: still no
    /// send. The next short wait, unwired, now alerts (under a minute, so no
    /// minutes).
    @Test func withNoFloorAShortCoveredWaitYieldsToThePhonesPush() async throws {
        let clock = SeamClock()
        let sink = ApprovalsRecordingSink()
        let log = ContextLog()
        let world = try armedWorld(clock, sink)
        world.controller.setEnabled(true)
        defer { world.controller.setEnabled(false) }
        try await withWiredAlerts(world, log) { h in
            h.runFloor.value = FinishAlertTuning.immediatelySeconds
            h.store.put(H.s1, ts: H.t0 - 10)
            h.store.put(H.s2, ts: H.t0 - 10)
            h.controller.reconcile()
            clock.advance(1)
            _ = try relay(world, sink, "abcde")
            h.store.put(H.s1, ts: H.t0, event: H.waiting)
            await h.settle()
            #expect(log.reads.count == 2 && log.reads.last == Self.covered, "the arm's read, then the wait's")
            #expect(h.sends.isEmpty, "an alerting wait, covered: the phone's push stands for it")
            clock.advance(2)
            h.store.put(H.s2, ts: H.t0, event: H.waiting)
            await h.settle()
            #expect(h.sends.map(\.kind) == [.needsAttention(minutes: nil, stillWorking: 1, prompts: .none)])
        }
    }

    /// The mark is set as the alert lane arms: a prompt relayed before it
    /// stands for no wait the lane then sees.
    @Test func theMarkIsSetWhenAlertsArm() async throws {
        let clock = SeamClock()
        let sink = ApprovalsRecordingSink()
        let log = ContextLog()
        let world = try armedWorld(clock, sink)
        world.controller.setEnabled(true)
        defer { world.controller.setEnabled(false) }
        try await withWiredAlerts(world, log) { h in
            _ = try relay(world, sink, "abcde")
            h.store.put(H.s1, ts: H.t0 - 720)
            h.controller.reconcile()
            #expect(log.reads == [Self.covered], "arming reads once")
            clock.advance(1)
            h.store.put(H.s1, ts: H.t0, event: H.waiting)
            await h.settle()
            #expect(log.reads.count == 2 && log.reads[1].newPrompts == 0)
            #expect(h.sends.map(\.kind) == [.needsAttention(minutes: 12, stillWorking: 0, prompts: .none)])
        }
    }

    /// A read (the arm's) at one second; session A's prompt, kept by the
    /// gate (no phone push), relayed later in that second; session B's
    /// covered prompt the next second; then a change holding A's waiting
    /// write alone. A's prompt is new to that change's read, so the read
    /// finds two new prompts, and A's plain alert goes out. (Both reach the
    /// seam through the test's one relay: which server relays a prompt
    /// changes no count of the read.)
    @Test func aKeptPromptLaterInAReadsOwnSecondKeepsTheNextLoneWaitsAlert() async throws {
        let clock = SeamClock()
        let sink = ApprovalsRecordingSink()
        let log = ContextLog()
        let world = try armedWorld(clock, sink)
        world.controller.setEnabled(true)
        defer { world.controller.setEnabled(false) }
        try await withWiredAlerts(world, log) { h in
            h.store.put(H.s1, ts: H.t0 - 720)
            h.store.put(H.s2, ts: H.t0 - 1200)
            h.controller.reconcile()
            #expect(log.reads == [.none], "vacuity: the arm read this second and saw no prompt")
            world.prompt("abcde", preview: #"{"command":"sudo pmset -a disablesleep 1"}"#)
            #expect(world.nextPrompt(endingIn: "suppressed.gate.forbidden.privilegeEscalation") != nil, "A's prompt, kept on the Mac")
            clock.advance(1)
            _ = try relay(world, sink, "bcdef")
            h.store.put(H.s1, ts: H.t0, event: H.waiting)
            await h.settle()
            #expect(log.reads.last == WaitingPromptContext(counts: WaitingPromptCounts(bash: 1), countsWithEvidence: WaitingPromptCounts(bash: 1),
                                                           newPrompts: 2, newPromptsWithEvidence: 1),
                    "A's prompt is new to this read: two new prompts, one with evidence")
            #expect(h.sends.map(\.kind) == [.needsAttention(minutes: 12, stillWorking: 1, prompts: .none)], "A's alert is sent")
        }
    }

    /// A prompt relayed later in a read's own second never brings evidence
    /// to the next read: a covered prompt the arm's read saw, then a kept
    /// one later in that second, then a lone wait the next second. The read
    /// finds one new prompt, without evidence, and the alert goes out.
    @Test func aPromptLaterInAReadsOwnSecondBringsNoEvidence() async throws {
        let clock = SeamClock()
        let sink = ApprovalsRecordingSink()
        let log = ContextLog()
        let world = try armedWorld(clock, sink)
        world.controller.setEnabled(true)
        defer { world.controller.setEnabled(false) }
        try await withWiredAlerts(world, log) { h in
            _ = try relay(world, sink, "abcde")
            h.store.put(H.s1, ts: H.t0 - 720)
            h.controller.reconcile()
            #expect(log.reads == [Self.covered], "vacuity: the arm read the covered prompt")
            world.prompt("bcdef", preview: #"{"command":"sudo pmset -a disablesleep 1"}"#)
            #expect(world.nextPrompt(endingIn: "suppressed.gate.forbidden.privilegeEscalation") != nil)
            clock.advance(1)
            h.store.put(H.s1, ts: H.t0, event: H.waiting)
            await h.settle()
            #expect(log.reads.last == WaitingPromptContext(counts: WaitingPromptCounts(bash: 1), countsWithEvidence: WaitingPromptCounts(bash: 1),
                                                           newPrompts: 1),
                    "one new prompt, the kept one, without evidence")
            #expect(h.sends.map(\.kind) == [.needsAttention(minutes: 12, stillWorking: 0, prompts: .none)])
        }
    }

    /// Every read moves the mark, whether or not the rule yields: two waits
    /// at once (no fold) use the prompt up, and so does a read before its
    /// evidence existed, so a later lone wait alerts.
    @Test(arguments: [false, true])
    func aReadThatDoesNotFoldStillUsesUpItsPrompt(_ evidenceLate: Bool) async throws {
        let clock = SeamClock()
        let sink = ApprovalsRecordingSink()
        let log = ContextLog()
        let world = try armedWorld(clock, sink)
        world.controller.setEnabled(true)
        defer { world.controller.setEnabled(false) }
        try await withWiredAlerts(world, log) { h in
            h.store.put(H.s1, ts: H.t0 - 720)
            h.store.put(H.s2, ts: H.t0 - 1200)
            h.store.put(H.s3, ts: H.t0 - 1800)
            h.controller.reconcile()
            clock.advance(1)
            let id = try relay(world, sink, "abcde", found: !evidenceLate)
            h.store.put(H.s1, ts: H.t0, event: H.waiting)
            if !evidenceLate { h.store.put(H.s2, ts: H.t0, event: H.waiting) }
            await h.settle()
            #expect(h.sends.count == 1, "no fold: two waits at once, or no evidence yet")
            if evidenceLate { world.host?.withIntake { $0.noteSubscriptionFound(id) } }
            h.advance(31)
            clock.advance(2)
            h.store.put(H.s3, ts: h.now, event: H.waiting)
            await h.settle()
            #expect(log.reads.last?.newPrompts == 0 && log.reads.last?.newPromptsWithEvidence == 0, "used up by the earlier read")
            #expect(h.sends.dropFirst().map(\.kind) == [.needsAttention(minutes: 30, stillWorking: 2, prompts: .none)])
        }
    }

    /// The rule can yield for a diff that has no waiting event to drop (a
    /// waiting marker rewritten, with a finish beside it): nothing is
    /// dropped, the finish goes, and the prompt is only used up, so the next
    /// lone wait alerts.
    @Test func aYieldWithNoWaitingEventOnlyUsesUpItsPrompt() async throws {
        let clock = SeamClock()
        let sink = ApprovalsRecordingSink()
        let log = ContextLog()
        let world = try armedWorld(clock, sink)
        world.controller.setEnabled(true)
        defer { world.controller.setEnabled(false) }
        try await withWiredAlerts(world, log) { h in
            h.store.put(H.s1, ts: H.t0 - 720)
            h.store.put(H.s2, ts: H.t0 - 1200)
            h.store.put(H.s3, ts: H.t0 - 1800)
            h.controller.reconcile()
            h.store.put(H.s1, ts: H.t0, event: H.waiting)
            await h.settle()
            #expect(h.sends.map(\.kind) == [.needsAttention(minutes: 12, stillWorking: 2, prompts: .none)], "an unwired wait")
            h.advance(31)
            clock.advance(1)
            _ = try relay(world, sink, "abcde")
            h.store.put(H.s1, ts: h.now, event: H.waiting)
            h.store.remove(H.s2)
            await h.settle()
            #expect(log.reads.last == Self.covered, "vacuity: the rewrite's diff would yield")
            #expect(h.sends.dropFirst().map(\.kind) == [.sessionFinished(minutes: 20, folded: 1, stillWorking: 2)])
            h.advance(31)
            clock.advance(2)
            h.store.put(H.s3, ts: h.now, event: H.waiting)
            await h.settle()
            #expect(h.sends.dropFirst(2).map(\.kind) == [.needsAttention(minutes: 31, stillWorking: 1, prompts: .none)])
        }
    }

    /// A buzz that goes out leaves out the prompts with evidence over the
    /// same 30 s its counts cover: one the phone showed, no longer new, is
    /// still left out; one outside the window takes nothing from a prompt
    /// inside it.
    @Test func evidenceCoversTheCountsOwnWindow() async throws {
        let clock = SeamClock()
        let sink = ApprovalsRecordingSink()
        let log = ContextLog()
        let world = try armedWorld(clock, sink)
        world.controller.setEnabled(true)
        defer { world.controller.setEnabled(false) }
        try await withWiredAlerts(world, log) { h in
            h.store.put(H.s1, ts: H.t0 - 720)
            h.store.put(H.s2, ts: H.t0 - 1200)
            h.store.put(H.s3, ts: H.t0 - 1800)
            h.controller.reconcile()
            clock.advance(1)
            _ = try relay(world, sink, "abcde")
            h.store.put(H.s1, ts: H.t0, event: H.waiting)
            await h.settle()
            #expect(h.sends.isEmpty, "folded")
            clock.advance(15)
            h.store.put(H.s2, ts: H.t0, event: H.waiting)
            await h.settle()
            #expect(log.reads.last == WaitingPromptContext(counts: WaitingPromptCounts(bash: 1), countsWithEvidence: WaitingPromptCounts(bash: 1)))
            #expect(bodies(h) == ["Claude is waiting for you — 20 min in — 2 others still working"],
                    "no longer new, the prompt the phone showed is still left out")
            clock.advance(10)
            _ = try relay(world, sink, "bcdef", found: false)
            clock.advance(6)
            h.advance(31)
            h.store.put(H.s3, ts: h.now, event: H.waiting)
            await h.settle()
            #expect(log.reads.last == WaitingPromptContext(counts: WaitingPromptCounts(bash: 1), newPrompts: 1))
            #expect(h.sends.dropFirst().map(\.kind) == [.needsAttention(minutes: 30, stillWorking: 2, prompts: WaitingPromptCounts(bash: 1))],
                    "the first prompt's evidence is outside the window: it takes nothing from the second")
        }
    }

    /// A corpus of diffs through one alert controller: a lone wait, a
    /// finish, a wait under the floor, a waiting rewrite beside a finish, a
    /// wait left and two waits at once, each diff past the last send's batch
    /// window. Returns every send.
    func alertCorpus(_ waitingPrompts: @escaping () -> WaitingPromptContext) async throws -> [LidGuardMessageKind] {
        var kinds: [LidGuardMessageKind] = []
        let s5 = "eeee0005-0000-4abc-8def-000000000005"
        try await withFinishAlertHarness(waitingPrompts: waitingPrompts) { h in
            h.store.put(H.s1, ts: H.t0 - 720)
            h.store.put(H.s2, ts: H.t0 - 1200)
            h.store.put(H.s3, ts: H.t0 - 1800)
            h.store.put(s5, ts: H.t0 - 900)
            h.controller.reconcile()
            h.store.put(H.s1, ts: h.now, event: H.waiting)
            await h.settle()
            h.advance(31)
            h.store.remove(H.s2)
            await h.settle()
            h.advance(31)
            h.store.put(H.s4, ts: h.now, event: H.waiting)
            await h.settle()
            h.advance(31)
            h.store.put(H.s1, ts: h.now, event: H.waiting)
            h.store.remove(H.s3)
            await h.settle()
            h.advance(31)
            h.store.put(H.s1, ts: h.now)
            await h.settle()
            h.advance(31)
            h.store.put(H.s1, ts: h.now, event: H.waiting)
            h.store.put(s5, ts: h.now, event: H.waiting)
            await h.settle()
            kinds = h.sends.map(\.kind)
        }
        return kinds
    }

    /// The corpus's sends with remote approvals off, and with `prompts`
    /// counted for each waiting alert.
    static func corpusSends(_ prompts: WaitingPromptCounts) -> [LidGuardMessageKind] {
        [.needsAttention(minutes: 12, stillWorking: 3, prompts: prompts), .sessionFinished(minutes: 20, folded: 1, stillWorking: 3),
         .sessionFinished(minutes: 31, folded: 1, stillWorking: 3), .needsAttention(minutes: nil, stillWorking: 2, prompts: prompts)]
    }

    enum Quiet: String, CaseIterable, Sendable {
        case off, unavailable
    }

    /// Off, or on but not listening (the socket could not be opened): the
    /// alert lane never reaches the seam — not as it arms, not for any diff —
    /// and every alert is byte for byte what the corpus's own wiring
    /// (`.none`) sends.
    @Test(arguments: Quiet.allCases)
    func offOrNotListeningTheAlertLaneNeverReachesTheSeam(_ quiet: Quiet) async throws {
        let clockReads = ApprovalsInbox<Void>()
        let world = try ApprovalsWorld(makeHost: { path, audit in
            ApprovalSeamHost(socketPath: path, armed: { @Sendable in true }, secrets: { @Sendable in [] }, records: ApprovalsRecordingSink(),
                             audit: audit, now: { @Sendable in
                                 clockReads.put(())
                                 return 1_000
                             })
        })
        if quiet == .unavailable {
            try FileManager.default.createDirectory(atPath: world.scratch.directoryPath, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            #expect(FileManager.default.createFile(atPath: world.scratch.socketPath, contents: Data("keep".utf8)))
            world.controller.setEnabled(true)
            #expect(world.controller.phase == .unavailable && world.builtHosts.count == 1, "vacuity: a host, not listening")
        }
        let log = ContextLog()
        let wired: [LidGuardMessageKind] = try await alertCorpus {
            let context = world.controller.waitingPrompts()
            log.reads.append(context)
            return context
        }
        let plain: [LidGuardMessageKind] = try await alertCorpus { .none }
        #expect(plain == Self.corpusSends(.none), "vacuity: the corpus sends what it says")
        #expect(wired == plain)
        #expect(log.reads.count == 5 && log.reads.allSatisfy { $0 == .none }, "the arm and the four diffs with a waiting write")
        #expect(clockReads.all.isEmpty, "zero hops: the intake was never asked")
        world.controller.setEnabled(false)
    }

    /// The app's own wiring: the fail-dark host (never armed, the sink that
    /// writes nothing: `failDarkHost`'s arguments, on the test's clock and
    /// `patient`, so neither the 30 s window nor the idle limit depends on
    /// how fast the suite runs) behind the toggle, on and listening, with a
    /// listed command and a kept one relayed. Nothing produces evidence, so every alert is the one this
    /// lane sent before (#216): the corpus's, each waiting alert counting the
    /// one listed command. Even the record path's finding, set by hand,
    /// changes nothing: no prompt of that host is ever forwarded.
    @Test func theAppsWiringSendsEveryAlertAsBefore() async throws {
        let clock = SeamClock()
        let world = try ApprovalsWorld(makeHost: { path, audit in
            ApprovalSeamHost(socketPath: path, armed: { @Sendable in false }, secrets: { @Sendable in [] },
                             records: FailDarkApprovalRecords(), audit: audit, now: { @Sendable in clock.now }, limits: Self.patient)
        })
        world.controller.setEnabled(true)
        defer { world.controller.setEnabled(false) }
        world.prompt("abcde")
        let listed = try #require(world.nextPrompt(endingIn: "suppressed.notArmed"))
        world.prompt("bcdef", preview: #"{"command":"sudo pmset -a disablesleep 1"}"#)
        #expect(world.nextPrompt(endingIn: "suppressed.notArmed") != nil)
        let log = ContextLog()
        let wired: [LidGuardMessageKind] = try await alertCorpus {
            let context = world.controller.waitingPrompts()
            log.reads.append(context)
            return context
        }
        #expect(wired == Self.corpusSends(WaitingPromptCounts(bash: 1)), "every alert and every phrase as before")
        #expect(log.reads.count == 5 && log.reads.allSatisfy { $0.newPromptsWithEvidence == 0 && $0.countsWithEvidence == .none })
        #expect(log.reads.first?.newPrompts == 2, "vacuity: the arm's read saw both prompts")
        world.host?.withIntake { $0.noteSubscriptionFound(listed) }
        let after = world.controller.waitingPrompts()
        #expect(after.counts == WaitingPromptCounts(bash: 1) && after.countsWithEvidence == .none && after.newPromptsWithEvidence == 0,
                "never forwarded, so never evidence")
    }

    // MARK: - Dark: nothing in the app produces evidence (#216)

    /// The record path's finding and its one setter, in the four targets:
    /// the flag's declaration, the evidence's one reading, the setter's
    /// declaration and its one write. Nothing in the app calls the setter
    /// or sets the flag otherwise, so no prompt carries evidence until the
    /// record path that will set it amends this list.
    static let findingSites: [String: [String: Int]] = [
        ApprovalChannelStructureTests.intakeFile: [
            "var subscriptionFound = false": 1,
            "var hasPushEvidence: Bool { subscriptionFound && lifecycle.phase == .forwarded }": 1,
            "func noteSubscriptionFound(_ id: PromptID) {": 1,
            "prompts[id]?.subscriptionFound = true": 1],
    ]
    static let findingPattern: String = #"\bsubscriptionFound\b|\bnoteSubscriptionFound\b"#

    static func findingFailures(_ sources: ApprovalChannelStructureTests.Sources) -> [String] {
        DecisionSinkStructureTests.absent(findingSites.keys, in: sources)
            + PairingStructureTests.appSiteFailures(findingPattern, in: sources, allowed: findingSites,
                                                    rule: "the record path's finding is named at its declaration, the evidence and its one setter alone")
    }

    @Test func nothingInTheAppSetsTheFindingYet() throws {
        let sources = try DecisionSinkStructureTests.uncutSources()
        #expect(Self.findingFailures(sources).isEmpty, "\(Self.findingFailures(sources))")
        let intake: String = ApprovalChannelStructureTests.intakeFile
        let toggle: String = ApprovalChannelStructureTests.toggleFile
        let entry: String = "forwardable: classification.forwardedTool)"
        #expect(DecisionSinkStructureTests.text(intake, in: sources).contains(entry), "vacuity: the entry is where a canary plants")
        let mutants: [(String, ApprovalChannelStructureTests.Sources)] = [
            ("the toggle calls the setter", DecisionSinkStructureTests.mutate(sources, toggle) {
                $0 + "\nfunc zz(_ h: ApprovalSeamHost, _ id: PromptID) { _ = h.withIntake { $0.noteSubscriptionFound(id) } }" }),
            ("the entry made with the finding", DecisionSinkStructureTests.mutate(sources, intake) {
                $0.replacingOccurrences(of: entry, with: "forwardable: classification.forwardedTool, subscriptionFound: true)") }),
            ("the flag set through a key path", DecisionSinkStructureTests.mutate(sources, intake) {
                $0 + "\nlet zz = \\ApprovalIntake.Entry.subscriptionFound" }),
            ("the setter called, backticked, from a new file", DecisionSinkStructureTests.adding(sources, "ZZFinding.swift",
                "func zz(_ i: ApprovalIntake, _ id: PromptID) { i.`noteSubscriptionFound`(id) }\n")),
            ("a second write inside the intake", DecisionSinkStructureTests.mutate(sources, intake) {
                $0.replacingOccurrences(of: "        prompts[id]?.subscriptionFound = true\n",
                                        with: "        prompts[id]?.subscriptionFound = true\n        prompts[id]?.subscriptionFound = true\n") }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.findingFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: names that only contain the pinned ones, and a
        // whole-line comment naming them.
        let controls = DecisionSinkStructureTests.mutate(sources, toggle) {
            $0 + "\nlet subscriptionFoundCount = 0, wasSubscriptionFound = false"
                + LidGuardStructureTests.wholeLineCommentsRemoved("\n/// never noteSubscriptionFound(id), never subscriptionFound = true")
        }
        #expect(controls.map { $0.text } != sources.map { $0.text }, "the controls applied")
        #expect(Self.findingFailures(controls).isEmpty, "over-match: \(Self.findingFailures(controls))")
    }

    // MARK: - The alert lane's evidence, at today's sites (#216)

    /// Where the alert lane's evidence and its reads of the seam are named
    /// in the four targets, line by line: the evidence counts at their
    /// declarations, in the intake's one read that fills them, in the
    /// toggle's one construction of the context and in the policy's rule and
    /// fold; the context built there and as `.none`, alone; and the lane's
    /// closure, stored, called as it arms and for a diff, its one fold call,
    /// the toggle's read it is handed and the app's one closure line. So a
    /// second construction, another read, or a closure that hands the lane a
    /// context of its own fails. (An implicit `.init(` builds a context
    /// unnamed; one that carries evidence still names the counts.)
    static let laneSites: [(pattern: String, allowed: [String: [String: Int]], rule: String)] = [
        (#"\bnewPromptsWithEvidence\b|\bcountsWithEvidence\b"#, [
            ApprovalChannelStructureTests.intakeFile: [
                "let newPromptsWithEvidence: Int": 1,
                "newPrompts: relayed.count + rest, newPromptsWithEvidence: relayed.filter(\\.hasPushEvidence).count,": 1],
            FinishAlertStructureTests.policyFile: [
                "var countsWithEvidence = WaitingPromptCounts.none": 1, "var newPromptsWithEvidence = 0": 1,
                "newPromptsWithEvidence: Int) -> Bool {": 1, "waitingWrites == 1 && newPrompts == 1 && newPromptsWithEvidence == 1": 1,
                "let prompts: WaitingPromptCounts = promptsWithoutEvidence(context.counts, withEvidence: context.countsWithEvidence)": 1,
                "newPromptsWithEvidence: context.newPromptsWithEvidence) else {": 2],
            ApprovalChannelStructureTests.toggleFile: [
                "countsWithEvidence: WaitingPromptCounts(prompts.recentWithEvidence),": 1,
                "newPrompts: prompts.newPrompts, newPromptsWithEvidence: prompts.newPromptsWithEvidence)": 2]],
         "the evidence counts are named at their declarations, the intake's read, the toggle's construction and the policy's rule and fold alone"),
        (ApprovalRecordPathStructureTests.constructionPattern("WaitingPromptContext"), [
            FinishAlertStructureTests.policyFile: ["static let none = WaitingPromptContext()": 1],
            ApprovalChannelStructureTests.toggleFile: ["return WaitingPromptContext(counts: WaitingPromptCounts(prompts.recent),": 1]],
         "the context is built by the toggle's one read, and as `.none`, alone"),
        (#"\bwaitingPrompts\b|\bpromptPushFold\b"#, [
            FinishAlertStructureTests.controllerFile: [
                "private let waitingPrompts: () -> WaitingPromptContext": 1,
                "waitingPrompts: @escaping () -> WaitingPromptContext = { .none }": 2, "self.waitingPrompts = waitingPrompts": 2,
                "waitingPrompts: waitingPrompts": 2, "_ = waitingPrompts()": 1,
                "let context: WaitingPromptContext = observation.waitingWrites > 0 ? waitingPrompts() : .none": 1,
                "let fold = FinishAlertPolicy.promptPushFold(events: observation.events, waitingWrites: observation.waitingWrites,": 1],
            FinishAlertStructureTests.policyFile: [
                "static func promptPushFold(events: [FinishAlertEvent], waitingWrites: Int, context: WaitingPromptContext)": 1],
            ApprovalChannelStructureTests.toggleFile: ["func waitingPrompts() -> WaitingPromptContext {": 1],
            "NapCatApp.swift": ["waitingPrompts: { approvals?.waitingPrompts() ?? .none }": 2]],
         "the lane's closure is stored, called and folded at today's sites, and the app hands it the toggle's read alone"),
    ]

    static func laneFailures(_ sources: ApprovalChannelStructureTests.Sources) -> [String] {
        laneSites.flatMap { site in
            DecisionSinkStructureTests.absent(site.allowed.keys, in: sources)
                + PairingStructureTests.appSiteFailures(site.pattern, in: sources, allowed: site.allowed, rule: site.rule)
        }
    }

    @Test func theAlertLanesEvidenceIsNamedAtTodaysSitesAlone() throws {
        let sources = try DecisionSinkStructureTests.uncutSources()
        #expect(Self.laneFailures(sources).isEmpty, "\(Self.laneFailures(sources))")
        let controller: String = FinishAlertStructureTests.controllerFile
        let toggle: String = ApprovalChannelStructureTests.toggleFile
        let app: String = "NapCatApp.swift"
        let diffRead: String = "let context: WaitingPromptContext = observation.waitingWrites > 0 ? waitingPrompts() : .none"
        let closure: String = "waitingPrompts: { approvals?.waitingPrompts() ?? .none }"
        let built: String = "        return WaitingPromptContext(counts: WaitingPromptCounts(prompts.recent),\n"
        let armRead: String = "        _ = waitingPrompts()\n"
        for (file, anchor) in [(controller, diffRead), (controller, armRead), (app, closure), (toggle, built)] {
            #expect(ApprovalChannelStructureTests.count(anchor, in: DecisionSinkStructureTests.text(file, in: sources)) == 1,
                    "vacuity: '\(anchor.prefix(50))' is in \(file) once")
        }
        let covered: String = "WaitingPromptContext(counts: .none, countsWithEvidence: .none, newPrompts: 1, newPromptsWithEvidence: 1)"
        let mutants: [(String, ApprovalChannelStructureTests.Sources)] = [
            ("a second construction, with evidence, in the controller's read", DecisionSinkStructureTests.mutate(sources, controller) {
                $0.replacingOccurrences(of: diffRead,
                                        with: "let context: WaitingPromptContext = observation.waitingWrites > 0 ? " + covered + " : .none") }),
            ("a second construction naming no evidence, in a new file", DecisionSinkStructureTests.adding(sources, "ZZContext.swift",
                "func zz() -> WaitingPromptContext { WaitingPromptContext(newPrompts: 1) }\n")),
            ("a second construction in the toggle", DecisionSinkStructureTests.mutate(sources, toggle) {
                $0.replacingOccurrences(of: built, with: "        _ = WaitingPromptContext(newPrompts: 0)\n" + built) }),
            ("the app's closure replaced by a constant context", DecisionSinkStructureTests.mutate(sources, app) {
                $0.replacingOccurrences(of: closure, with: "waitingPrompts: { " + covered + " }") }),
            ("the app's closure replaced by an implicit context with evidence", DecisionSinkStructureTests.mutate(sources, app) {
                $0.replacingOccurrences(of: closure, with: "waitingPrompts: { .init(newPrompts: 1, newPromptsWithEvidence: 1) }") }),
            ("the app's closure replaced by `.none`", DecisionSinkStructureTests.mutate(sources, app) {
                $0.replacingOccurrences(of: closure, with: "waitingPrompts: { .none }") }),
            ("evidence set on a copy of `.none`", DecisionSinkStructureTests.mutate(sources, toggle) {
                $0 + "\nfunc zz() -> WaitingPromptContext { var c = WaitingPromptContext.none; c.newPromptsWithEvidence = 1; return c }" }),
            ("evidence named through a key path, in a new file", DecisionSinkStructureTests.adding(sources, "ZZKeyPath.swift",
                "let zz = \\WaitingPromptContext.countsWithEvidence\n")),
            ("a second read of the seam as the lane arms", DecisionSinkStructureTests.mutate(sources, controller) {
                $0.replacingOccurrences(of: armRead, with: armRead + armRead) }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.laneFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: names that only contain the pinned ones, a
        // type named like the context and built, and a whole-line comment
        // naming them.
        let controls = DecisionSinkStructureTests.mutate(sources, toggle) {
            $0 + "\nlet newPromptsWithEvidenceCount = 0, recountsWithEvidence = 1, waitingPromptsRead = 2"
                + "\nstruct WaitingPromptContextLog {}\nlet zzLog = WaitingPromptContextLog()"
                + LidGuardStructureTests.wholeLineCommentsRemoved("\n/// never waitingPrompts: { .none }, never WaitingPromptContext(newPrompts: 1)")
        }
        #expect(controls.map { $0.text } != sources.map { $0.text }, "the controls applied")
        #expect(Self.laneFailures(controls).isEmpty, "over-match: \(Self.laneFailures(controls))")
    }
}
