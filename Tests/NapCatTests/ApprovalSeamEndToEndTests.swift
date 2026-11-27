// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat
@testable import NapCatChannel
@testable import NapCatSeam
@testable import NapCatWire

/// The record store, called on the host's queue and read by the test.
final class InboxApprovalSink: ApprovalRecordSink, @unchecked Sendable {
    let saved = SeamInbox<RecordingApprovalSink.Saved>()
    let retracted = SeamInbox<PromptID>()
    let superseded = SeamInbox<PromptID>()

    func save(_ id: PromptID, tool: ApprovalTool, inputPreview: String, expiresAt: Int) {
        saved.put(RecordingApprovalSink.Saved(id: id, tool: tool, inputPreview: inputPreview, expiresAt: expiresAt))
    }

    func retract(_ id: PromptID) { retracted.put(id) }
    func supersedeWaitingAlert(_ id: PromptID) { superseded.put(id) }
}

/// The real relay (`napcat-channel`'s logic) over the real seam to the real
/// host (listener and intake), in a scratch directory. Only Claude Code's
/// stdio, CloudKit and the phone's decision are faked.
final class SeamWorld: @unchecked Sendable {
    let fixture: SeamFixture
    let sink = InboxApprovalSink()
    let audits = SeamInbox<String>()
    let host: ApprovalSeamHost
    let serverQueue = DispatchQueue(label: "test.e2e.server")
    let emitted = SeamInbox<String>()
    let notes = SeamInbox<ChannelNote>()
    private(set) var relay: ChannelRelay!

    init(armed: Bool = true, hostPeerReader: @escaping (Int32) -> SeamPeer? = SeamSocket.peer(of:)) throws {
        fixture = try SeamFixture()
        let ids = SeamInbox<PromptID>()
        for n in 1...16 { ids.put(PromptID(high: 0xE2E, low: UInt64(n))!) }
        let audits = self.audits
        host = ApprovalSeamHost(socketPath: fixture.socketPath, armed: { armed }, secrets: { [] }, records: sink,
                                audit: { audits.put($0.code) }, newPromptID: { ids.next(within: 0) }, now: { 1_000 },
                                peerReader: hostPeerReader)
        let socketPath = fixture.socketPath
        let queue = serverQueue
        let emitted = self.emitted
        let notes = self.notes
        relay = ChannelRelay(emit: { emitted.put($0) }, connect: { onFrame, onClose in
            guard let connection = SeamClient.connect(socketPath: socketPath, queue: queue) else { return nil }
            connection.start(onLine: onFrame, onClose: onClose)
            return connection
        }, note: { notes.put($0) })
    }

    /// Claude Code writes one line to the server.
    func stdin(_ line: String) {
        let relay = self.relay!
        serverQueue.sync { relay.receive(stdinLine: Array(line.utf8)) }
    }

    /// The handshake, its answer drained.
    func handshake() {
        stdin(RelayHarness.initializeLine)
        _ = emitted.next()
    }

    /// The relay's notes up to and including the first of `wanted`, or false
    /// once the next note takes longer than `seconds` to arrive.
    func waitForNote(_ wanted: ChannelNote..., within seconds: Double = 5) -> Bool {
        while let note = notes.next(within: seconds) { if wanted.contains(note) { return true } }
        return false
    }
}

/// F4 slice S1, end to end over the real socket: a permission request
/// crosses the seam, the gate decides on NapCat's side, and only a valid
/// signed decision comes back across the seam as a verdict frame, which the
/// server withholds from Claude Code until the seam checks which program
/// listens (#221). No Claude Code, no CloudKit, no real home directory.
struct ApprovalSeamEndToEndTests {
    @Test(arguments: ApprovalWire.Verdict.allCases)
    func aPromptCrossesTheSeamAndASignedDecisionComesBackButIsWithheld(_ verdict: ApprovalWire.Verdict) throws {
        let world = try SeamWorld()
        #expect(world.host.start())
        defer { world.host.stop() }
        world.handshake()
        let preview = #"{"command":"make test"}"#
        world.stdin(RelayHarness.permissionRequest("abcde", preview: preview, description: "Run the tests"))
        let saved = try #require(world.sink.saved.next(), "the forwardable prompt must reach the record store")
        #expect(saved.tool == .bash)
        #expect(saved.inputPreview == preview, "exactly what the gate classified")
        #expect(world.emitted.next(within: 0.2) == nil, "nothing is answered while the prompt waits")
        world.host.withIntake { intake in
            intake.apply(.saveAccepted, to: saved.id)
            intake.decide(.verified(ApprovalDecision(promptID: saved.id, verdict: verdict, wireVersion: ApprovalWire.wireVersion,
                                                     signatureVerified: true)))
        }
        #expect(world.sink.superseded.next() == saved.id)
        #expect(world.sink.retracted.next() == saved.id)
        #expect(world.waitForNote(.verdictWithheld), "the verdict frame reaches the server, which withholds it")
        #expect(world.emitted.next(within: 0.2) == nil, "no answer reaches Claude Code")
    }

    /// A Bash preview carries the model's own description as a member; what
    /// reaches the record store is the gate's copy without it, and neither
    /// description (the relay's field or the member) is anywhere in it.
    @Test func whatReachesTheRecordStoreIsTheGatesCopy() throws {
        let world = try SeamWorld()
        #expect(world.host.start())
        defer { world.host.stop() }
        world.handshake()
        let preview = #"{ "command": "git status", "description": "MEMBER-SENTINEL" }"#
        world.stdin(RelayHarness.permissionRequest("abcde", preview: preview, description: "FIELD-SENTINEL"))
        let saved = try #require(world.sink.saved.next(), "the forwardable prompt must reach the record store")
        #expect(saved.tool == .bash)
        #expect(saved.inputPreview == #"{"command":"git status"}"#)
        #expect(!saved.inputPreview.contains("SENTINEL"))
    }

    @Test func aForbiddenPromptCrossesTheSeamButNeverLeavesTheMac() throws {
        let world = try SeamWorld()
        #expect(world.host.start())
        defer { world.host.stop() }
        world.handshake()
        world.stdin(RelayHarness.permissionRequest("abcde", preview: #"{"command":"sudo pmset -a disablesleep 1"}"#))
        let id = PromptID(high: 0xE2E, low: 1)!
        #expect(world.audits.next() == "prompt=\(id.hex) suppressed.gate.forbidden.privilegeEscalation")
        #expect(world.sink.saved.next(within: 0.2) == nil)
        world.host.withIntake {
            $0.decide(.verified(ApprovalDecision(promptID: id, verdict: .allow, wireVersion: 1, signatureVerified: true)))
        }
        #expect(world.audits.next() == "prompt=\(id.hex) ignored.notForwarded")
        #expect(world.emitted.next(within: 0.2) == nil, "no verdict for a prompt that never left")
    }

    /// Armed, a Read crosses the seam and stays on the Mac whatever its path
    /// (#231): kept as `localOnly.read`, never saved, and a decision for it
    /// answers nothing.
    @Test func anArmedReadPromptCrossesTheSeamButNeverLeavesTheMac() throws {
        let world = try SeamWorld(armed: true)
        #expect(world.host.start())
        defer { world.host.stop() }
        world.handshake()
        let preview = #"{"file_path":"/Users/someone/project/notes.md","offset":1,"limit":200}"#
        world.stdin(RelayHarness.permissionRequest("abcde", tool: "Read", preview: preview, description: "Read a file"))
        let id = PromptID(high: 0xE2E, low: 1)!
        #expect(world.audits.next() == "prompt=\(id.hex) suppressed.gate.localOnly.read")
        #expect(world.sink.saved.next(within: 0.2) == nil, "a Read never reaches the record store")
        let counted = world.host.withIntake { $0.recentForwardableTools(within: ApprovalIntake.waitingContextSeconds) }
        #expect(counted?.isEmpty == true, "nor is it counted for a waiting push")
        world.host.withIntake {
            $0.decide(.verified(ApprovalDecision(promptID: id, verdict: .allow, wireVersion: 1, signatureVerified: true)))
        }
        #expect(world.audits.next() == "prompt=\(id.hex) ignored.notForwarded")
        #expect(world.emitted.next(within: 0.2) == nil, "no verdict for a prompt that never left")
    }

    /// S1's production posture end to end: the seam carries the prompt, but
    /// the unarmed intake saves nothing.
    @Test func unarmedThePromptIsHeardButNothingIsSaved() throws {
        let world = try SeamWorld(armed: false)
        #expect(world.host.start())
        defer { world.host.stop() }
        world.handshake()
        world.stdin(RelayHarness.permissionRequest("abcde"))
        #expect(world.audits.next() == "prompt=\(PromptID(high: 0xE2E, low: 1)!.hex) suppressed.notArmed")
        #expect(world.sink.saved.next(within: 0.2) == nil)
    }

    /// The host refuses a peer that fails the check before reading its frame;
    /// the server's prompt stays local.
    ///
    /// Any of three orderings is correct (#129), and each gives a fixed run
    /// of the relay's notes:
    /// - the frame is written before the refusal: `.relayed`, then
    ///   `.seamClosed` once the end of stream reaches the server (this can lag
    ///   on a loaded CI VM);
    /// - the refusal lands before the write: `.seamClosed` (the EPIPE closes
    ///   the link), then `.heldSendFailed`;
    /// - the refusal lands before the server's own check of NapCat, whose
    ///   audit token is then unreadable: the server refuses in turn, the link
    ///   never opens, and the note is `.heldNoSeam`.
    @Test func aServerFailingThePeerCheckIsRefusedUnread() throws {
        let world = try SeamWorld(hostPeerReader: { _ in ApprovalSeamTests.foreign })
        #expect(world.host.start())
        defer { world.host.stop() }
        world.handshake()
        world.stdin(RelayHarness.permissionRequest("abcde"))
        #expect(world.audits.next() == "seam.peerRefused")
        #expect(world.waitForNote(.seamClosed, .heldNoSeam, within: ApprovalSeamTests.closeObservationSeconds),
                "the server sees the link end, or never opens it")
        #expect(world.sink.saved.next(within: 0.2) == nil)
        #expect(world.audits.next(within: 0.2) == nil, "no frame from the refused peer was read")
    }

    /// Nobody listening (the feature off, or NapCat not running): the prompt
    /// stays local and nothing is emitted.
    @Test func withoutTheHostThePromptStaysLocal() throws {
        let world = try SeamWorld()
        world.handshake()
        world.stdin(RelayHarness.permissionRequest("abcde"))
        #expect(world.waitForNote(.heldNoSeam))
        #expect(world.emitted.next(within: 0.2) == nil)
    }

    /// A listener of this user that is not NapCat (a bare seam listener, no
    /// host, no intake) at NapCat's socket path: the seam's peer check reads
    /// its user, not which program it is, so it reads the prompt, and its
    /// `allow` for a privileged command reaches Claude Code as nothing
    /// (#221). The link stays and the next prompt still crosses.
    @Test func aListenerThatIsNotNapCatGetsNoAnswerToClaudeCode() throws {
        let world = try SeamWorld()
        let listener = ApprovalSeamTests.Server(world.fixture)
        #expect(listener.start())
        defer { listener.stop() }
        world.handshake()
        let preview = #"{"command":"sudo pmset -a disablesleep 0"}"#
        world.stdin(RelayHarness.permissionRequest("abcde", preview: preview))
        let line = try #require(listener.lines.next(), "the prompt reaches whatever listens there")
        let request = ChannelPermissionRequest(requestID: ChannelRequestID("abcde")!, toolName: "Bash", inputPreview: preview)
        let relayed: SeamFrame? = ApprovalChannel.frame(Array(line.utf8))
        #expect(relayed == .prompt(request, server: ApprovalChannel.serverVersion, client: ApprovalChannel.confirmedClients[0]))
        let connection = try #require(listener.connections.next())
        let answer: String = ApprovalChannel.verdictFrame(request.requestID, .allow)
        #expect(listener.queue.sync { connection.send(answer) })
        #expect(world.waitForNote(.verdictWithheld), "the server withholds the listener's answer")
        #expect(world.emitted.next(within: 0.2) == nil, "Claude Code's side receives nothing")
        world.stdin(RelayHarness.permissionRequest("bcdef"))
        #expect(listener.lines.next() != nil, "the link stays: the next prompt crosses it")
        #expect(listener.connections.next(within: 0.2) == nil && listener.closes.next(within: 0.2) == nil)
        #expect(world.emitted.next(within: 0.2) == nil)
    }

    /// Stopping the host is the kill switch: the open prompt is withdrawn,
    /// the server is disconnected, the socket goes away, and a later decision
    /// answers nothing.
    @Test func stoppingTheHostIsTheKillSwitch() throws {
        let world = try SeamWorld()
        #expect(world.host.start())
        world.handshake()
        world.stdin(RelayHarness.permissionRequest("abcde"))
        let saved = try #require(world.sink.saved.next())
        world.host.withIntake { $0.apply(.saveAccepted, to: saved.id) }
        world.host.stop()
        #expect(world.sink.retracted.next() == saved.id)
        #expect(world.waitForNote(.seamClosed, within: ApprovalSeamTests.closeObservationSeconds))
        #expect(!FileManager.default.fileExists(atPath: world.fixture.socketPath))
        world.host.withIntake {
            $0.decide(.verified(ApprovalDecision(promptID: saved.id, verdict: .allow, wireVersion: 1, signatureVerified: true)))
        }
        #expect(world.emitted.next(within: 0.2) == nil)
        #expect(world.audits.all.contains("prompt=\(saved.id.hex) retracted.killSwitch"))
    }

    /// The session ends (its server's connection closes): its open prompt is
    /// withdrawn, never answered.
    @Test func whenTheServerGoesAwayItsPromptIsWithdrawn() throws {
        let world = try SeamWorld()
        #expect(world.host.start())
        defer { world.host.stop() }
        let queue = DispatchQueue(label: "test.e2e.raw")
        let client = try #require(queue.sync { SeamClient.connect(socketPath: world.fixture.socketPath, queue: queue) })
        let frame = ApprovalChannel.promptFrame(ChannelPermissionRequest(requestID: ChannelRequestID("abcde")!, toolName: "Bash",
                                                                         inputPreview: #"{"command":"make test"}"#),
                                                client: ApprovalChannel.confirmedClients[0])!
        #expect(queue.sync { client.send(frame) })
        let saved = try #require(world.sink.saved.next())
        queue.sync { client.close() }
        #expect(world.sink.retracted.next(within: ApprovalSeamTests.closeObservationSeconds) == saved.id)
        #expect(world.audits.all.last == "prompt=\(saved.id.hex) retracted.sessionEnded")
    }

    /// A frame a stale or foreign server could write.
    struct StaleFrame: Sendable, CustomTestStringConvertible {
        let name: String
        let line: String
        let code: String
        var testDescription: String { name }
    }

    /// #150: a version-1 frame exactly as the server wrote one before #150,
    /// a frame from a server of another version (the one before #221 among
    /// them), and one for a client NapCat has not confirmed.
    static let staleFrames: [StaleFrame] = [
        StaleFrame(name: "a version-1 frame",
                   line: #"{"frame":"prompt","v":1,"request":"bcdef","tool":"Bash","preview":"{\"command\":\"make test\"}"}"#,
                   code: "seam.frameRefused"),
        StaleFrame(name: "another server version",
                   line: #"{"frame":"prompt","v":2,"request":"bcdef","tool":"Bash","preview":"{\"command\":\"make test\"}","server":1,"client":"claude-code","clientVersion":"2.1.326"}"#,
                   code: "seam.serverVersionRefused"),
        StaleFrame(name: "the server version before #221",
                   line: #"{"frame":"prompt","v":2,"request":"bcdef","tool":"Bash","preview":"{\"command\":\"make test\"}","server":2,"client":"claude-code","clientVersion":"2.1.326"}"#,
                   code: "seam.serverVersionRefused"),
        StaleFrame(name: "an unconfirmed client",
                   line: #"{"frame":"prompt","v":2,"request":"bcdef","tool":"Bash","preview":"{\"command\":\"make test\"}","server":3,"client":"claude-code","clientVersion":"2.1.327"}"#,
                   code: "seam.clientRefused"),
    ]

    /// Over the real socket, after an honest prompt on the same connection:
    /// the stale frame is refused with its closed code, the connection is
    /// closed (so the honest prompt is withdrawn), and no lifecycle opens for
    /// it and nothing of it is saved, though the gate would forward it and
    /// the host is armed.
    @Test(arguments: staleFrames)
    func aFrameFromAStaleOrForeignServerIsRefusedOverTheSocket(_ row: StaleFrame) throws {
        let world = try SeamWorld()
        #expect(world.host.start())
        defer { world.host.stop() }
        let client = ApprovalSeamTests.Client(world.fixture)
        let request = ChannelPermissionRequest(requestID: ChannelRequestID("abcde")!, toolName: "Bash", inputPreview: #"{"command":"git status"}"#)
        let honest: String = try #require(ApprovalChannel.promptFrame(request, client: ApprovalChannel.confirmedClients[0]))
        #expect(client.send(honest))
        let saved = try #require(world.sink.saved.next(), "the honest frame is heard")
        world.host.withIntake { $0.apply(.saveAccepted, to: saved.id) }
        #expect(client.send(row.line))
        #expect(client.closes.next(within: ApprovalSeamTests.closeObservationSeconds) != nil, "the connection is closed")
        #expect(world.sink.retracted.next(within: ApprovalSeamTests.closeObservationSeconds) == saved.id, "its open prompt is withdrawn")
        #expect(world.sink.saved.next(within: 0.2) == nil, "the refused frame saved nothing")
        let id: String = saved.id.hex
        let expected: [String] = ["prompt=\(id) forwarded", row.code, "prompt=\(id) retracted.sessionEnded"]
        #expect(world.audits.all == expected)
        #expect(world.host.withIntake { $0.prompts.count } == 1, "no lifecycle opened for the refused frame")
    }
}
