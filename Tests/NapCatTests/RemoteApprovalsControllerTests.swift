// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat
@testable import NapCatChannel
@testable import NapCatSeam
@testable import NapCatWire

/// Collects values delivered on another queue, with a bounded wait (slice
/// S2's own, so these tests do not lean on the S1 seam files' helpers).
///
/// A wait for something that MUST arrive returns the moment it does, so its
/// deadline is generous (`arrivalSeconds`): on a loaded CI VM a socket's
/// close or a frame can take seconds to reach its read source (#129). Only
/// the waits that prove something does NOT happen are short.
final class ApprovalsInbox<Value>: @unchecked Sendable {
    static var arrivalSeconds: Double { 30 }

    private let lock = NSLock()
    private let arrived = DispatchSemaphore(value: 0)
    private var values: [Value] = []
    private var taken = 0

    func put(_ value: Value) {
        lock.lock()
        values.append(value)
        lock.unlock()
        arrived.signal()
    }

    /// The next value not yet taken, or nil after `seconds`.
    func next(within seconds: Double = arrivalSeconds) -> Value? {
        guard arrived.wait(timeout: .now() + seconds) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        taken += 1
        return values[taken - 1]
    }

    /// Takes values until one satisfies `match`, or nil after `seconds`.
    func next(within seconds: Double = arrivalSeconds, where match: (Value) -> Bool) -> Value? {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0, let value = next(within: left) else { return nil }
            if match(value) { return value }
        }
    }

    /// Everything delivered so far, taken or not.
    var all: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

/// A private scratch directory whose seam socket path fits `sun_path`.
/// Never the real Application Support directory.
final class ApprovalsScratch {
    let root: URL
    let socketPath: String

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("nca-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        socketPath = root.path + "/approvals/seam.sock"
        precondition(socketPath.utf8.count < 104, "the scratch path must fit sun_path: \(socketPath)")
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var directoryPath: String { root.path + "/approvals" }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
}

/// The record sink a test-built ARMED host writes to (never the app's).
final class ApprovalsRecordingSink: ApprovalRecordSink, @unchecked Sendable {
    let saved = ApprovalsInbox<PromptID>()
    let retracted = ApprovalsInbox<PromptID>()
    let superseded = ApprovalsInbox<PromptID>()

    func save(_ id: PromptID, tool: ApprovalTool, inputPreview: String, expiresAt: Int) { saved.put(id) }
    func retract(_ id: PromptID) { retracted.put(id) }
    func supersedeWaitingAlert(_ id: PromptID) { superseded.put(id) }
}

/// The toggle over a scratch socket, an in-memory stored value and a counted
/// probe, plus a real channel relay (`napcat-channel`'s logic) that reaches
/// the toggle's host over the real seam. Claude Code's stdio, CloudKit and the
/// phone are the only things faked; no defaults, keychain or home is touched.
@MainActor
final class ApprovalsWorld {
    let scratch: ApprovalsScratch
    /// What the app's own domain holds (the toggle writes here).
    var stored: Any?
    /// What the defaults search list holds above the app's own domain (a
    /// launch argument, a managed setting, a per-host value) and below it
    /// (the global domain, a registered default); nil: nothing there (#205).
    var outranking: Any?
    var below: Any?
    /// What the search list reads: the first of the three that holds a value.
    var searched: Any? { outranking ?? stored ?? below }
    /// Every value the toggle wrote, in order.
    private(set) var writes: [Bool] = []
    /// While true the store keeps reading what it held: a write it does not
    /// take (#205).
    var readIgnoresWrites = false
    var probes = 0
    var finding = ChannelPolicyFinding.noFilePolicy
    let audits = ApprovalsInbox<String>()
    let emitted = ApprovalsInbox<String>()
    let notes = ApprovalsInbox<ChannelNote>()
    let serverQueue = DispatchQueue(label: "test.approvals.server")
    private(set) var controller: RemoteApprovalsController!
    private(set) var relay: ChannelRelay!
    private(set) var changes = 0
    /// Every host the toggle had its factory build (its own `host` is
    /// private), oldest first.
    private(set) var builtHosts: [ApprovalSeamHost] = []
    /// The host the toggle holds: the one its factory built last.
    var host: ApprovalSeamHost? { builtHosts.last }

    /// `makeHost` nil ⇒ the production fail-dark factory, over the scratch
    /// socket and a recording audit.
    init(makeHost: ((String, @escaping @Sendable (ApprovalAuditEvent) -> Void) -> ApprovalSeamHost)? = nil) throws {
        scratch = try ApprovalsScratch()
        let audits = self.audits
        let record: @Sendable (ApprovalAuditEvent) -> Void = { audits.put($0.code) }
        let factory: RemoteApprovalsController.HostFactory = { [unowned self] path in
            let host = makeHost?(path, record)
                ?? RemoteApprovalsController.failDarkHost(socketPath: path, secrets: { @Sendable in [] }, audit: record)
            builtHosts.append(host)
            return host
        }
        controller = RemoteApprovalsController(
            socketPath: scratch.socketPath,
            readStored: { [unowned self] in RemoteApprovalsPolicy.enabled(stored: stored, searched: searched) },
            writeStored: { [unowned self] in
                writes.append($0)
                if !readIgnoresWrites { stored = $0 }
            },
            makeHost: factory,
            probe: { [unowned self] in
                probes += 1
                return finding
            },
            audit: record)
        controller.setChangeHandler { [unowned self] in changes += 1 }
        let socketPath = scratch.socketPath
        let queue = serverQueue
        let emitted = self.emitted
        let notes = self.notes
        // The relay runs on the server's queue: its closures are @Sendable,
        // so none of them is isolated to the main actor.
        relay = ChannelRelay(emit: { @Sendable in emitted.put($0) }, connect: { @Sendable onFrame, onClose in
            guard let connection = SeamClient.connect(socketPath: socketPath, queue: queue) else { return nil }
            connection.start(onLine: onFrame, onClose: onClose)
            return connection
        }, note: { @Sendable in notes.put($0) })
        stdin(RelayHarness.initializeLine)
        _ = emitted.next()
    }

    /// Claude Code writes one line to the channel server.
    func stdin(_ line: String) {
        let relay = self.relay!
        serverQueue.sync { relay.receive(stdinLine: Array(line.utf8)) }
    }

    /// A permission dialog opens in the wired session.
    func prompt(_ request: String, preview: String = #"{"command":"git status"}"#) {
        stdin(RelayHarness.permissionRequest(request, tool: "Bash", preview: preview))
    }

    /// The relay's notes up to and including `wanted`.
    func waitForNote(_ wanted: ChannelNote) -> Bool { notes.next(where: { $0 == wanted }) != nil }

    /// The prompt ID in the next lifecycle audit line ending in `code`.
    func nextPrompt(endingIn code: String) -> PromptID? {
        guard let line = audits.next(where: { $0.hasPrefix("prompt=") && $0.hasSuffix(" " + code) }) else { return nil }
        return PromptID(hex: String(line.dropFirst("prompt=".count).prefix(ApprovalWire.promptIDHexDigits)))
    }

    /// A phone decision reaching the toggle's host as the verifier's result
    /// (S-PAIR-C2), as a later slice will deliver one.
    func decide(_ id: PromptID, _ verdict: ApprovalWire.Verdict = .allow) {
        host?.withIntake {
            $0.decide(.verified(ApprovalDecision(promptID: id, verdict: verdict, wireVersion: ApprovalWire.wireVersion,
                                                 signatureVerified: true)))
        }
    }

    var socketExists: Bool { scratch.exists(scratch.socketPath) }
}

/// F4 slice S2: the Mac toggle drives the seam host and the policy probe.
/// Off — the default — leaves zero footprint; on listens, fail-dark; off
/// again is the kill switch, including while a prompt is pending; a quit is a
/// hard stop.
@MainActor
struct RemoteApprovalsControllerTests {
    // MARK: - Off: zero footprint

    /// The default (nothing stored) and any junk value: no host, no socket —
    /// not even the socket's directory — no probe, however often the menu
    /// and Settings refresh. A wired session finds nothing to connect to.
    @Test(arguments: [nil, "YES", 2] as [(any Sendable)?])
    func offLeavesZeroFootprint(_ stored: (any Sendable)?) throws {
        let world = try ApprovalsWorld()
        world.stored = stored
        world.controller.reconcile()
        world.controller.refresh()
        world.controller.refresh()
        #expect(world.controller.phase == .off)
        #expect(world.builtHosts.isEmpty, "the host is never built while off")
        #expect(world.probes == 0, "the probe never runs while off")
        #expect(!world.scratch.exists(world.scratch.directoryPath), "not even the socket's directory exists")
        #expect(world.controller.finding == nil)
        world.prompt("abcde")
        #expect(world.waitForNote(.heldNoSeam), "the session's prompt stays local")
        #expect(world.audits.all.isEmpty, "nothing was heard, so nothing was logged")
        #expect(world.changes == 0)
    }

    // MARK: - On: listening, fail-dark

    @Test func onListensAndProbesAndOffIsTheKillSwitch() throws {
        let world = try ApprovalsWorld()
        world.finding = .defaultAllowlist
        world.controller.setEnabled(true)
        #expect(world.stored as? Bool == true, "the choice is stored")
        #expect(world.controller.phase == .listening)
        #expect(world.socketExists)
        #expect(world.probes == 1)
        #expect(world.controller.finding == .defaultAllowlist)
        #expect(world.audits.next() == "seam.listening")
        world.controller.refresh()
        #expect(world.probes == 2, "every menu or Settings open re-reads the policy while on")
        #expect(world.controller.phase == .listening)

        world.controller.setEnabled(false)
        #expect(world.stored as? Bool == false)
        #expect(world.controller.phase == .off)
        #expect(!world.socketExists, "the kill switch removes the socket")
        #expect(world.controller.finding == nil)
        #expect(world.audits.next() == "seam.stopped")
        world.controller.refresh()
        #expect(world.probes == 2, "off: no probe")
        #expect(world.changes > 0)
    }

    /// Toggling ON forwards nothing: the production host hears the wired
    /// session's forwardable prompt and keeps it on this Mac (never armed —
    /// no record is asked for, and its sink writes nothing anyway), and even
    /// a decision for it answers nothing.
    @Test func onForwardsNothingEvenAForwardablePrompt() throws {
        let world = try ApprovalsWorld()
        world.controller.setEnabled(true)
        #expect(world.audits.next() == "seam.listening")
        world.prompt("abcde", preview: #"{"command":"git status"}"#)
        let id = try #require(world.nextPrompt(endingIn: "suppressed.notArmed"),
                              "the gate would forward it; the unarmed host keeps it local")
        #expect(ApprovalGate.classify(toolName: "Bash", inputPreview: #"{"command":"git status"}"#, topic: .absent, policy: .listedOnly) == .forward(.bash),
                "vacuity: the prompt is one the gate forwards")
        world.decide(id)
        #expect(world.audits.next() == "prompt=\(id.hex) ignored.notForwarded")
        #expect(world.emitted.next(within: 0.3) == nil, "no verdict reaches Claude Code")
        #expect(!world.audits.all.contains { $0.hasSuffix(" forwarded") }, "nothing was forwarded")
        world.controller.setEnabled(false)
    }

    // MARK: - The kill switch while a prompt is pending

    /// The S2 posture end to end: a wired session's prompt is open at the
    /// terminal (the channel server holds it, waiting for a verdict that
    /// never comes). Off: the server is disconnected — the prompt stays local
    /// — the socket is gone, and a later decision answers nothing and is
    /// logged as ignored.
    @Test func theKillSwitchWhileASessionsPromptIsOpen() throws {
        let world = try ApprovalsWorld()
        world.controller.setEnabled(true)
        world.prompt("abcde")
        let id = try #require(world.nextPrompt(endingIn: "suppressed.notArmed"))
        #expect(world.waitForNote(.relayed), "the server holds the prompt open")

        world.controller.setEnabled(false)
        #expect(world.waitForNote(.seamClosed), "the kill switch disconnects the server")
        #expect(!world.socketExists)
        #expect(world.audits.next(where: { $0 == "seam.stopped" }) != nil)
        world.decide(id, .allow)
        #expect(world.audits.next() == "prompt=\(id.hex) ignored.notForwarded", "a late decision is logged as ignored")
        #expect(world.emitted.next(within: 0.3) == nil, "and answers nothing")

        world.prompt("bcdef")
        #expect(world.waitForNote(.heldNoSeam), "after the kill switch, a new prompt finds nothing to connect to")
    }

    /// #205: off is the kill switch in process, at once, with no read-back —
    /// proven over a store whose read ignores writes: it still reads on
    /// after the off is written. Before, off wrote the store and read it
    /// back, and that read kept everything running. Now the switch goes
    /// off, the session's server is disconnected, the socket goes, the
    /// stop is audited once, and nothing listens again before the store is
    /// next read (such a store would read on then); the off is still
    /// written, and a late decision is ignored and logged.
    @Test func offAppliesInProcessEvenWhenTheStoreReadIgnoresWrites() throws {
        let world = try ApprovalsWorld()
        world.controller.setEnabled(true)
        #expect(world.controller.phase == .listening)
        world.prompt("abcde")
        let id = try #require(world.nextPrompt(endingIn: "suppressed.notArmed"))
        #expect(world.waitForNote(.relayed), "the server holds the prompt open")

        world.readIgnoresWrites = true
        let changes: Int = world.changes
        world.controller.setEnabled(false)
        #expect(world.stored as? Bool == true, "vacuity: the store still reads on")
        #expect(world.writes == [true, false], "the off is written all the same")
        #expect(world.controller.phase == .off, "the kill switch applied")
        #expect(world.changes > changes, "and the menu was told")
        #expect(world.waitForNote(.seamClosed), "the session's server is disconnected")
        #expect(!world.socketExists)
        #expect(world.audits.next(where: { $0 == "seam.stopped" }) != nil)
        #expect(world.controller.phase == .off, "it did not snap back")
        let all: [String] = world.audits.all
        #expect(all.filter { $0 == "seam.listening" }.count == 1 && all.filter { $0 == "seam.stopped" }.count == 1,
                "one listen, one stop: \(all)")
        world.decide(id, .allow)
        #expect(world.audits.next() == "prompt=\(id.hex) ignored.notForwarded", "a late decision is logged as ignored")
        #expect(world.emitted.next(within: 0.3) == nil, "and answers nothing")
    }

    /// The same with a FORWARDED prompt (a test-built armed host — the app's
    /// is never armed in this slice): off withdraws its record, disconnects
    /// the server, and the phone's later decision is ignored and logged.
    @Test func theKillSwitchWithdrawsAForwardedPromptAndIgnoresItsDecision() throws {
        let sink = ApprovalsRecordingSink()
        let world = try ApprovalsWorld(makeHost: { path, audit in
            ApprovalSeamHost(socketPath: path, armed: { @Sendable in true }, secrets: { @Sendable in [] }, records: sink,
                             audit: audit)
        })
        world.controller.setEnabled(true)
        world.prompt("abcde")
        let id = try #require(sink.saved.next(), "armed, the forwardable prompt is saved")
        world.host?.withIntake { $0.apply(.saveAccepted, to: id) }
        #expect(world.host?.withIntake { $0.prompts[id]?.lifecycle.phase } == .forwarded, "pending on the phone")

        world.controller.setEnabled(false)
        #expect(sink.retracted.next() == id, "the kill switch retracts the pending record")
        #expect(world.audits.next(where: { $0 == "prompt=\(id.hex) retracted.killSwitch" }) != nil)
        #expect(world.audits.next(where: { $0 == "seam.stopped" }) != nil)
        #expect(world.waitForNote(.seamClosed))
        #expect(!world.socketExists)

        world.decide(id, .allow)
        #expect(world.audits.next() == "prompt=\(id.hex) ignored.retracted", "the in-flight decision is ignored, and logged")
        #expect(world.emitted.next(within: 0.3) == nil, "no verdict reaches Claude Code")
    }

    /// Off then on again: the same host listens again (kept, so a decision
    /// for a withdrawn prompt is still answered by that prompt's lifecycle),
    /// and a new prompt is heard.
    @Test func onAgainListensWithTheSameHost() throws {
        let world = try ApprovalsWorld()
        world.controller.setEnabled(true)
        let first = try #require(world.host)
        world.controller.setEnabled(false)
        world.controller.setEnabled(true)
        #expect(world.builtHosts.count == 1 && world.host === first, "built once, and listening again")
        #expect(world.controller.phase == .listening)
        #expect(world.socketExists)
        world.prompt("abcde")
        #expect(world.nextPrompt(endingIn: "suppressed.notArmed") != nil)
        world.controller.setEnabled(false)
    }

    // MARK: - Quit, an unusable socket, an outside write

    /// Quitting is a hard stop: the socket goes, and nothing starts again.
    @Test func aQuitIsAHardStop() throws {
        let world = try ApprovalsWorld()
        world.controller.setEnabled(true)
        #expect(world.socketExists)
        world.controller.shutdown()
        #expect(!world.socketExists)
        #expect(world.controller.phase == .off)
        #expect(world.audits.next(where: { $0 == "seam.stopped" }) != nil)
        world.controller.setEnabled(true)
        world.controller.refresh()
        #expect(world.controller.phase == .off, "after the quit nothing listens again")
        #expect(!world.socketExists)
    }

    /// Something other than a stale socket of its own at the path: nothing
    /// listens, the panel can say so, and a refresh retries once it is gone.
    @Test func anUnusableSocketIsUnavailableAndRetriedOnRefresh() throws {
        let world = try ApprovalsWorld()
        try FileManager.default.createDirectory(atPath: world.scratch.directoryPath, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        #expect(FileManager.default.createFile(atPath: world.scratch.socketPath, contents: Data("keep".utf8)))
        world.controller.setEnabled(true)
        #expect(world.controller.phase == .unavailable)
        #expect(world.audits.next() == "seam.listenFailed")
        #expect(FileManager.default.contents(atPath: world.scratch.socketPath) == Data("keep".utf8), "left untouched")
        #expect(world.probes == 1, "the policy is read even so")
        try FileManager.default.removeItem(atPath: world.scratch.socketPath)
        world.controller.refresh()
        #expect(world.controller.phase == .listening)
        #expect(world.audits.next() == "seam.listening")
        world.controller.setEnabled(false)
    }

    /// A value written outside NapCat (`defaults write`) into NapCat's own
    /// domain takes effect at the next menu or Settings open.
    @Test func anOutsideWriteTakesEffectOnTheNextRefresh() throws {
        let world = try ApprovalsWorld()
        world.stored = true
        #expect(world.controller.phase == .off, "nothing happens until NapCat looks")
        world.controller.refresh()
        #expect(world.controller.phase == .listening)
        world.stored = "junk"
        world.controller.refresh()
        #expect(world.controller.phase == .off, "junk reads as off: the kill switch")
        #expect(!world.socketExists)
    }

    /// #205: a `true` anywhere but the app's own domain — above it (a launch
    /// argument, a managed setting, a per-host value) or below it (the
    /// global domain, a registered default) — never turns the toggle on,
    /// however often the menu opens: zero footprint.
    @Test(arguments: [true, false])
    func anOutsideTrueNeverTurnsItOn(_ outranks: Bool) throws {
        let world = try ApprovalsWorld()
        if outranks { world.outranking = true } else { world.below = true }
        #expect(world.searched as? Bool == true, "vacuity: the search list reads on")
        world.controller.reconcile()
        world.controller.refresh()
        world.controller.refresh()
        #expect(world.controller.phase == .off)
        #expect(world.builtHosts.isEmpty && world.probes == 0, "no host, no probe")
        #expect(!world.scratch.exists(world.scratch.directoryPath), "not even the socket's directory exists")
        #expect(world.changes == 0)
    }

    /// #205: a value that outranks the app's own and disagrees is the kill
    /// switch at the next refresh, and keeps a switch-on off (written, read
    /// back, vetoed, and written back off). With an outranking `true` the
    /// owner's own on and off both hold, and an off stays off across
    /// refreshes: it was written to the app's own domain, which is read for
    /// on.
    @Test func anOutrankingValueVetoesAndTheOwnersOffStaysOff() throws {
        let world = try ApprovalsWorld()
        world.controller.setEnabled(true)
        #expect(world.controller.phase == .listening)
        world.outranking = false
        world.controller.refresh()
        #expect(world.controller.phase == .off, "an outranking false is the kill switch")
        #expect(!world.socketExists)
        world.controller.setEnabled(true)
        #expect(world.stored as? Bool == false && world.controller.phase == .off,
                "a switch-on is written, vetoed, then written back off")
        #expect(world.writes == [true, true, false])

        world.outranking = true
        world.controller.refresh()
        #expect(world.controller.phase == .off, "the vetoed switch-on was not left stored")
        world.controller.setEnabled(true)
        #expect(world.controller.phase == .listening, "the owner's own true, and nothing disagrees")
        world.controller.setEnabled(false)
        world.controller.refresh()
        world.controller.refresh()
        #expect(world.controller.phase == .off, "the owner's off stays off: the outranking true cannot turn it back on")
        #expect(world.stored as? Bool == false && !world.socketExists)
    }

    /// #205: a switch-on that an outranking value vetoes is written back
    /// off, so the app's own domain holds what the switch shows. Before, the
    /// stored `true` stayed: the switch read off and could not clear it, and
    /// once the outranking value was gone the next refresh (or launch) came
    /// up on with no gesture. Now it stays off, with zero footprint.
    @Test func aVetoedSwitchOnIsWrittenBackOff() throws {
        let world = try ApprovalsWorld()
        world.outranking = "YES"
        world.controller.setEnabled(true)
        #expect(world.controller.phase == .off)
        #expect(world.writes == [true, false], "the switch-on is written, then written back off")
        #expect(world.stored as? Bool == false, "what is stored matches what the switch shows")
        world.outranking = nil
        world.controller.refresh()
        #expect(world.controller.phase == .off)
        #expect(world.builtHosts.isEmpty && world.probes == 0, "no host, no probe")
        #expect(!world.scratch.exists(world.scratch.directoryPath), "not even the socket's directory exists")
        world.controller.setEnabled(false)
        #expect(world.writes == [true, false, false], "the off is written as ever")
    }

    /// The toggle's own audit lines join the S1 vocabulary: closed codes, a
    /// random prompt ID at most — never prompt text, a request ID or a path.
    static let toggleCodes: Set<String> = ["seam.listening", "seam.listenFailed", "seam.stopped", "seam.connectionLimit"]

    @Test func everyAuditLineIsAClosedCode() throws {
        let world = try ApprovalsWorld()
        world.controller.setEnabled(true)
        world.prompt("abcde", preview: #"{"command":"sudo ls"}"#)
        world.prompt("bcdef")
        let id = try #require(world.nextPrompt(endingIn: "suppressed.notArmed"))
        world.decide(id)
        #expect(world.audits.next(where: { $0.hasSuffix("ignored.notForwarded") }) != nil)
        world.controller.setEnabled(false)
        #expect(world.audits.next(where: { $0 == "seam.stopped" }) != nil)
        let vocabulary = ApprovalIntakeTests.vocabulary.union(Self.toggleCodes)
        let lines = world.audits.all
        #expect(lines.count >= 5, "vacuity: \(lines)")
        for line in lines {
            var words = Substring(line)
            if words.hasPrefix("prompt=") {
                #expect(PromptID(hex: String(words.dropFirst("prompt=".count).prefix(ApprovalWire.promptIDHexDigits))) != nil)
                words = words.dropFirst("prompt=".count + ApprovalWire.promptIDHexDigits + 1)
            }
            #expect(vocabulary.contains(String(words)), "'\(line)' is outside the audit vocabulary")
            #expect(!line.contains("sudo") && !line.contains("abcde") && !line.contains("/"), "'\(line)' carries prompt data")
        }
        #expect(Set([ApprovalAuditEvent.listening, .listenFailed, .stopped, .connectionLimit].map(\.code)) == Self.toggleCodes)
    }

    /// The production sink writes nothing — and the production host never
    /// asks it to (never armed).
    @Test func theFailDarkSinkIsInert() throws {
        let sink = FailDarkApprovalRecords()
        let id = try #require(PromptID(high: 1, low: 2))
        sink.save(id, tool: .bash, inputPreview: "{}", expiresAt: 0)
        sink.retract(id)
        sink.supersedeWaitingAlert(id)
        #expect(Mirror(reflecting: sink).children.isEmpty, "no state to write to")
    }
}
