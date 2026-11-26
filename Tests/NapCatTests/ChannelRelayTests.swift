// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCatChannel
@testable import NapCatWire

/// A link to NapCat that records frames and lets the test answer.
final class FakeChannelLink: ChannelLink {
    var sent: [String] = []
    var failSends = false
    private(set) var closed = false
    var onFrame: (([UInt8]) -> Void)?
    var onClose: (() -> Void)?

    func send(_ line: String) -> Bool {
        guard !closed, !failSends else {
            close()
            return false
        }
        sent.append(line)
        return true
    }

    func close() {
        guard !closed else { return }
        closed = true
        onClose?()
    }

    /// NapCat sends one frame.
    func deliver(_ line: String) { onFrame?(Array(line.utf8)) }
}

/// The relay with everything around it faked: Claude Code's stdout, the
/// connector and the notes.
final class RelayHarness {
    var emitted: [String] = []
    var notes: [ChannelNote] = []
    var links: [FakeChannelLink] = []
    var reachable = true
    var connectAttempts = 0
    var link: FakeChannelLink? { links.last }

    lazy var relay = ChannelRelay(emit: { [unowned self] in emitted.append($0) }, connect: { [unowned self] onFrame, onClose in
        connectAttempts += 1
        guard reachable else { return nil }
        let link = FakeChannelLink()
        link.onFrame = onFrame
        link.onClose = onClose
        links.append(link)
        return link
    }, note: { [unowned self] in notes.append($0) })

    func stdin(_ line: String) { relay.receive(stdinLine: Array(line.utf8)) }

    static let initializeLine = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"2.1.326"}}}"#

    /// A harness past the handshake, with its answer cleared.
    static func initialized() -> RelayHarness {
        let harness = RelayHarness()
        harness.stdin(initializeLine)
        harness.emitted.removeAll()
        return harness
    }

    static func quote(_ text: String) -> String { ApprovalChannel.quoted(text) }

    static func permissionRequest(_ id: String, tool: String = "Bash", preview: String = #"{"command":"git status"}"#,
                                  description: String = "List files") -> String {
        #"{"jsonrpc":"2.0","method":"notifications/claude/channel/permission_request","params":{"request_id":"#
            + quote(id) + #","tool_name":"# + quote(tool) + #","description":"# + quote(description)
            + #","input_preview":"# + quote(preview) + "}}"
    }

    static func verdict(_ id: String, _ verdict: ApprovalWire.Verdict) -> String {
        ApprovalChannel.verdictFrame(ChannelRequestID(id)!, verdict)
    }

    static func verdictLine(_ id: String, _ verdict: ApprovalWire.Verdict) -> String {
        ApprovalChannel.verdictNotification(requestID: ChannelRequestID(id)!, verdict: verdict)
    }
}

/// F4 slice S1: the channel server's behaviour (`ChannelRelay`), driven line
/// by line with no process, no socket and no Claude Code. The safety rules:
/// the handshake declares exactly the two channel capabilities; nothing but
/// NapCat's verdict frame for an open, relayed request ever produces a
/// verdict, and only once; every failure keeps the prompt local.
struct ChannelRelayTests {
    // MARK: - The handshake

    static func members(_ line: String) -> [PreviewMember]? { ApprovalPreview.parseObject(line) }

    static func field(_ path: [String], in line: String) -> PreviewValue? {
        guard var members = members(line) else { return nil }
        for (index, key) in path.enumerated() {
            guard let value = members.first(where: { $0.key == key })?.value else { return nil }
            if index == path.count - 1 { return value }
            guard case .object(let inner) = value else { return nil }
            members = inner
        }
        return nil
    }

    @Test func theHandshakeDeclaresTheTwoChannelCapabilitiesAndNothingElse() throws {
        let harness = RelayHarness()
        harness.stdin(RelayHarness.initializeLine)
        let answer = try #require(harness.emitted.first)
        #expect(harness.emitted.count == 1)
        #expect(Self.field(["id"], in: answer) == .number("1"))
        #expect(Self.field(["result", "protocolVersion"], in: answer) == .string("2025-06-18"))
        let capabilities = try #require(Self.field(["result", "capabilities"], in: answer))
        #expect(capabilities == .object([PreviewMember(key: "experimental", value: .object([
            PreviewMember(key: "claude/channel", value: .object([])),
            PreviewMember(key: "claude/channel/permission", value: .object([])),
        ]))]), "exactly the channel and relay capabilities: no tools, no other experimental key")
        #expect(Self.field(["result", "instructions"], in: answer) == nil, "nothing is put in front of Claude")
    }

    /// The requested revision when the server speaks it, otherwise its
    /// newest — never 2026-07-28.
    @Test(arguments: [
        ("2025-11-25", "2025-11-25"), ("2025-06-18", "2025-06-18"), ("2025-03-26", "2025-03-26"),
        ("2024-11-05", "2024-11-05"), ("2026-07-28", "2025-11-25"), ("1999-01-01", "2025-11-25"), ("", "2025-11-25"),
    ])
    func theRevisionIsNegotiatedAmongTheInitializeEraOnly(_ requested: String, _ answered: String) {
        let harness = RelayHarness()
        harness.stdin(#"{"jsonrpc":"2.0","id":7,"method":"initialize","params":{"protocolVersion":"# + RelayHarness.quote(requested) + "}}")
        #expect(harness.emitted.count == 1)
        #expect(Self.field(["result", "protocolVersion"], in: harness.emitted.first ?? "") == .string(answered))
        #expect(!ApprovalChannel.protocolVersions.contains("2026-07-28"))
    }

    @Test(arguments: [
        (#"{"jsonrpc":"2.0","id":"p-1","method":"ping"}"#, #"{"jsonrpc":"2.0","id":"p-1","result":{}}"#),
        (#"{"jsonrpc":"2.0","id":-3,"method":"ping","params":{}}"#, #"{"jsonrpc":"2.0","id":-3,"result":{}}"#),
        (#"{"jsonrpc":"2.0","id":0,"method":"server/discover","params":{"_meta":{}}}"#,
         #"{"jsonrpc":"2.0","id":0,"error":{"code":-32601,"message":"Method not found"}}"#),
        (#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
         #"{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"Method not found"}}"#),
        (#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"reply"}}"#,
         #"{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"Method not found"}}"#),
        (#"{"jsonrpc":"2.0","id":4,"method":"initialize","params":{}}"#,
         #"{"jsonrpc":"2.0","id":4,"error":{"code":-32602,"message":"Invalid params"}}"#),
        (#"{"jsonrpc":"2.0","id":5,"method":"initialize","params":{"protocolVersion":20250618}}"#,
         #"{"jsonrpc":"2.0","id":5,"error":{"code":-32602,"message":"Invalid params"}}"#),
        (#"{"jsonrpc":"2.0","id":6,"method":"ping","params":[]}"#,
         #"{"jsonrpc":"2.0","id":6,"error":{"code":-32602,"message":"Invalid params"}}"#),
    ])
    func requestsAreAnsweredOrRefused(_ line: String, _ answer: String) {
        let harness = RelayHarness()
        harness.stdin(line)
        #expect(harness.emitted == [answer])
        #expect(harness.connectAttempts == 0)
    }

    /// Notifications the server has no use for, responses it never asked for,
    /// and every line the strict reader refuses: no answer, no effect.
    static let silentLines: [String] = [
        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/claude/channel","params":{"content":"hi"}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/claude/channel/permission","params":{"request_id":"abcde","behavior":"allow"}}"#,
        #"{"jsonrpc":"2.0","id":9,"result":{}}"#,
        #"{"jsonrpc":"2.0","id":9,"error":{"code":1,"message":"x"}}"#,
        #"{"jsonrpc":"1.0","id":1,"method":"ping"}"#,
        #"{"id":1,"method":"ping"}"#,
        #"{"jsonrpc":"2.0","jsonrpc":"2.0","id":1,"method":"ping"}"#,
        #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#,
        #"{"jsonrpc":"2.0","id":1.5,"method":"ping"}"#,
        #"{"jsonrpc":"2.0","id":1e3,"method":"ping"}"#,
        #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#,
        #"{"jsonrpc":"2.0","id":[1],"method":"ping"}"#,
        #"{"jsonrpc":"2.0","id":12345678901234567890,"method":"ping"}"#,
        #"{"jsonrpc":"2.0","id":1,"method":"ping","extra":1}"#,
        #"{"jsonrpc":"2.0","id":1,"method":7}"#,
        #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#,
        #"{"jsonrpc":"2.0","id":1,"method":"ping"} x"#,
        #"{"jsonrpc":"2.0","id":1,"method":"ping""#,
        "\u{FEFF}" + #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#,
        #"{"jsonrpc":"2.0","id":"\u0000","method":"ping"}"#,
        "",
        "ping",
    ]

    @Test(arguments: silentLines)
    func linesWithNoUseOrNoStrictReadingGetNoAnswer(_ line: String) {
        let harness = RelayHarness.initialized()
        harness.stdin(line)
        #expect(harness.emitted.isEmpty, "answered \(harness.emitted)")
        #expect(harness.connectAttempts == 0)
    }

    /// An invalid byte inside a string would decode leniently to U+FFFD and
    /// leave valid JSON behind; the line is refused before that can happen.
    @Test func invalidUTF8IsRefusedBeforeTheReaderSeesIt() {
        let harness = RelayHarness.initialized()
        let head = Array(#"{"jsonrpc":"2.0","id":"x"#.utf8)
        let tail = Array(#"","method":"ping"}"#.utf8)
        harness.relay.receive(stdinLine: head + tail)
        #expect(harness.emitted.count == 1, "baseline: the clean line is answered")
        for invalid: [UInt8] in [[0xFF], [0xC3], [0xED, 0xA0, 0x80], [0xC0, 0xAF]] {
            harness.relay.receive(stdinLine: head + invalid + tail)
        }
        harness.stdin(RelayHarness.initializeLine)
        harness.relay.receive(stdinLine: Array(RelayHarness.permissionRequest("abcde", preview: "{\"command\":\"ls X\"}").utf8)
            .split(separator: UInt8(ascii: "X")).joined(separator: [0xFF]).map { $0 })
        #expect(harness.emitted.count == 2, "only the clean ping and the handshake are answered")
        #expect(harness.connectAttempts == 0, "a request with an invalid byte in its preview is never relayed")
    }

    // MARK: - Relaying a prompt

    @Test func aPermissionRequestIsRelayedAsAPromptFrameWithoutTheDescription() throws {
        let harness = RelayHarness.initialized()
        let sentinel = "DESCRIPTION-SENTINEL"
        harness.stdin(RelayHarness.permissionRequest("abcde", tool: "Write",
                                                     preview: #"{"file_path":"/tmp/x","content":"hi"}"#, description: sentinel))
        let link = try #require(harness.link)
        let frame = try #require(link.sent.first)
        #expect(link.sent.count == 1)
        let request = ChannelPermissionRequest(requestID: ChannelRequestID("abcde")!, toolName: "Write",
                                               inputPreview: #"{"file_path":"/tmp/x","content":"hi"}"#)
        #expect(ApprovalChannel.frame(Array(frame.utf8)) == .prompt(request, server: ApprovalChannel.serverVersion,
                                                                     client: ChannelClient(name: "claude-code", version: "2.1.326")),
                "the frame names this server's version and the session's confirmed client (#150)")
        #expect(!frame.contains(sentinel), "the description never crosses the seam")
        #expect(!frame.contains("description"))
        #expect(harness.emitted.isEmpty, "a relayed prompt is never answered by the server itself")
        #expect(harness.notes == [.relayed])
    }

    @Test func beforeTheHandshakeNothingIsRelayed() {
        let harness = RelayHarness()
        harness.stdin(RelayHarness.permissionRequest("abcde"))
        #expect(harness.connectAttempts == 0)
        #expect(harness.notes == [.heldBeforeInitialize])
    }

    // MARK: - Only a confirmed client's prompts are relayed

    /// An `initialize` line whose params carry `clientInfo` as this raw JSON
    /// (none when nil).
    static func initializeLine(clientInfo: String?) -> String {
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}"#
            + (clientInfo.map { #","clientInfo":"# + $0 } ?? "") + "}}"
    }

    @Test func theHarnessHandshakeNamesTheConfirmedClient() {
        #expect(RelayHarness.initializeLine == Self.initializeLine(clientInfo: #"{"name":"claude-code","version":"2.1.326"}"#))
    }

    /// Anything but exactly a confirmed name and version, as strings.
    static let unconfirmedClients: [String?] = [
        nil, "null", #""claude-code""#, "[]", "{}",
        #"{"name":"claude-code"}"#,
        #"{"version":"2.1.326"}"#,
        #"{"name":"claude-code","version":"2.1.327"}"#,
        #"{"name":"claude-code","version":"2.1.325"}"#,
        #"{"name":"claude-code","version":"2.1.32"}"#,
        #"{"name":"claude-code","version":"2.1.3260"}"#,
        #"{"name":"claude-code","version":"2.1.326.0"}"#,
        #"{"name":"claude-code","version":"2.1.326-beta"}"#,
        #"{"name":"claude-code","version":"v2.1.326"}"#,
        #"{"name":"claude-code","version":"2.1.326 "}"#,
        #"{"name":"claude-code","version":" 2.1.326"}"#,
        #"{"name":"claude-code","version":"2.1.326\n"}"#,
        #"{"name":"claude-code","version":"２.1.326"}"#,
        #"{"name":"claude-code","version":""}"#,
        #"{"name":"claude-code","version":2.1}"#,
        #"{"name":"claude-code","version":["2.1.326"]}"#,
        #"{"name":"claude-code","version":null}"#,
        #"{"name":"Claude-Code","version":"2.1.326"}"#,
        #"{"name":"claude-code ","version":"2.1.326"}"#,
        #"{"name":"claude","version":"2.1.326"}"#,
        #"{"name":"claude-code-x","version":"2.1.326"}"#,
        #"{"name":"other-client","version":"2.1.326"}"#,
        #"{"name":null,"version":"2.1.326"}"#,
        #"{"name":"2.1.326","version":"claude-code"}"#,
    ]

    /// The handshake is still answered (the session works as unwired), but
    /// no prompt is relayed, and the seam is never even reached.
    @Test(arguments: unconfirmedClients)
    func anUnconfirmedClientsPromptsStayLocal(_ clientInfo: String?) {
        let harness = RelayHarness()
        harness.stdin(Self.initializeLine(clientInfo: clientInfo))
        #expect(harness.emitted.count == 1, "the handshake is answered")
        #expect(Self.field(["result", "protocolVersion"], in: harness.emitted.first ?? "") == .string("2025-06-18"))
        harness.stdin(RelayHarness.permissionRequest("abcde"))
        harness.stdin(RelayHarness.permissionRequest("bcdef"))
        #expect(harness.connectAttempts == 0)
        #expect(harness.notes == [.heldUnconfirmedClient, .heldUnconfirmedClient])
    }

    /// Exactly the confirmed name and version are read; other `clientInfo`
    /// members are ignored, and an escape decodes to the same text.
    @Test(arguments: [
        #"{"name":"claude-code","version":"2.1.326"}"#,
        #"{"version":"2.1.326","name":"claude-code"}"#,
        #"{"name":"claude-code","version":"2.1.326","title":"Claude Code"}"#,
        #"{"name":"claude-code","version":"2.1.326"}"#,
    ])
    func theConfirmedClientsPromptsAreRelayed(_ clientInfo: String) throws {
        let harness = RelayHarness()
        harness.stdin(Self.initializeLine(clientInfo: clientInfo))
        harness.stdin(RelayHarness.permissionRequest("abcde"))
        let sent = try #require(harness.link).sent
        #expect(sent.count == 1)
        #expect(harness.notes == [.relayed])
        // The frame names the client as read: the confirmed one, decoded (#150).
        guard case .prompt(_, let server, let client)? = ApprovalChannel.frame(Array((sent.first ?? "").utf8)) else {
            Issue.record("no prompt frame in \(sent)")
            return
        }
        #expect(server == ApprovalChannel.serverVersion)
        #expect(client == ApprovalChannel.confirmedClients[0])
    }

    /// A later handshake can keep a session's prompts local, never release
    /// them again.
    @Test func aLaterHandshakeCanOnlyKeepPromptsLocal() throws {
        let harness = RelayHarness.initialized()
        harness.stdin(RelayHarness.permissionRequest("abcde"))
        harness.stdin(Self.initializeLine(clientInfo: #"{"name":"claude-code","version":"2.1.327"}"#))
        harness.stdin(RelayHarness.permissionRequest("bcdef"))
        harness.stdin(RelayHarness.initializeLine)
        harness.stdin(RelayHarness.permissionRequest("cdefg"))
        #expect(try #require(harness.link).sent.count == 1)
        #expect(harness.notes == [.relayed, .heldUnconfirmedClient, .heldUnconfirmedClient])
        // The one frame names the confirmed client; none ever names another (#150).
        let frames: [SeamFrame?] = (harness.link?.sent ?? []).map { ApprovalChannel.frame(Array($0.utf8)) }
        let request = ChannelPermissionRequest(requestID: ChannelRequestID("abcde")!, toolName: "Bash", inputPreview: #"{"command":"git status"}"#)
        let relayed: SeamFrame = .prompt(request, server: ApprovalChannel.serverVersion, client: ApprovalChannel.confirmedClients[0])
        #expect(frames == [relayed])
    }

    /// The confirmed list is exactly the one checked build: a new build joins
    /// it only after its relay has been checked again.
    @Test func theConfirmedClientsAreExactlyTheCheckedBuild() {
        #expect(ApprovalChannel.confirmedClients == [ChannelClient(name: "claude-code", version: "2.1.326")])
        #expect(ApprovalChannel.confirms(ChannelClient(name: "claude-code", version: "2.1.326")))
        #expect(!ApprovalChannel.confirms(nil))
        #expect(!ApprovalChannel.confirms(ChannelClient(name: "claude-code", version: "2.1.327")))
    }

    static let malformedRequests: [String] = [
        RelayHarness.permissionRequest("abcdl"), RelayHarness.permissionRequest("ABCDE"),
        RelayHarness.permissionRequest("abcd"), RelayHarness.permissionRequest("abcdef"),
        RelayHarness.permissionRequest("abc1e"), RelayHarness.permissionRequest("abcdé"),
        #"{"jsonrpc":"2.0","method":"notifications/claude/channel/permission_request","params":{"request_id":"abcde","tool_name":"Bash","input_preview":"{}"}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/claude/channel/permission_request","params":{"request_id":"abcde","tool_name":"Bash","description":"d","input_preview":"{}","session":"s"}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/claude/channel/permission_request","params":{"request_id":"abcde","tool_name":"Bash","description":"d","input_preview":{}}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/claude/channel/permission_request","params":{"request_id":"abcde","tool_name":1,"description":"d","input_preview":"{}"}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/claude/channel/permission_request","params":"abcde"}"#,
        #"{"jsonrpc":"2.0","method":"notifications/claude/channel/permission_request"}"#,
        #"{"jsonrpc":"2.0","id":1,"method":"notifications/claude/channel/permission_request","params":{"request_id":"abcde","tool_name":"Bash","description":"d","input_preview":"{}"}}"#,
    ]

    @Test(arguments: malformedRequests)
    func aMalformedPermissionRequestIsNeverRelayed(_ line: String) {
        let harness = RelayHarness.initialized()
        harness.stdin(line)
        #expect(harness.connectAttempts == 0, "relayed: \(line)")
        #expect(harness.emitted.allSatisfy { !$0.contains(ApprovalChannel.verdictMethod) })
    }

    @Test func aRepeatedRequestIDIsNeverRelayedAgain() throws {
        let harness = RelayHarness.initialized()
        harness.stdin(RelayHarness.permissionRequest("abcde"))
        harness.stdin(RelayHarness.permissionRequest("abcde", preview: #"{"command":"pwd"}"#))
        #expect(try #require(harness.link).sent.count == 1)
        #expect(harness.notes == [.relayed, .heldRepeatedID])
    }

    // MARK: - Relaying a verdict

    @Test(arguments: ApprovalWire.Verdict.allCases)
    func aVerdictForAnOpenRequestIsRelayedExactlyOnce(_ verdict: ApprovalWire.Verdict) throws {
        let harness = RelayHarness.initialized()
        harness.stdin(RelayHarness.permissionRequest("qwert"))
        let link = try #require(harness.link)
        link.deliver(RelayHarness.verdict("qwert", verdict))
        #expect(harness.emitted == [RelayHarness.verdictLine("qwert", verdict)])
        link.deliver(RelayHarness.verdict("qwert", verdict == .allow ? .deny : .allow))
        #expect(harness.emitted.count == 1, "one-shot: a second verdict for the same request does nothing")
        #expect(harness.notes == [.relayed, .verdictRelayed, .verdictIgnored])
        #expect(!link.closed)
    }

    @Test func theVerdictLineIsTheDocumentedNotification() {
        #expect(RelayHarness.verdictLine("abcde", .allow)
            == #"{"jsonrpc":"2.0","method":"notifications/claude/channel/permission","params":{"request_id":"abcde","behavior":"allow"}}"#)
        #expect(RelayHarness.verdictLine("zyxwv", .deny)
            == #"{"jsonrpc":"2.0","method":"notifications/claude/channel/permission","params":{"request_id":"zyxwv","behavior":"deny"}}"#)
    }

    @Test func aVerdictForARequestNeverRelayedIsIgnored() throws {
        let harness = RelayHarness.initialized()
        harness.stdin(RelayHarness.permissionRequest("abcde"))
        let link = try #require(harness.link)
        link.deliver(RelayHarness.verdict("zzzzz", .allow))
        #expect(harness.emitted.isEmpty)
        #expect(!link.closed, "a well-formed verdict for nothing open is ignored, not punished")
        link.deliver(RelayHarness.verdict("abcde", .deny))
        #expect(harness.emitted == [RelayHarness.verdictLine("abcde", .deny)])
    }

    static let refusedFrames: [String] = [
        "not json",
        "",
        #"{"frame":"verdict","v":2,"request":"abcde","verdict":"yes"}"#,
        #"{"frame":"verdict","v":2,"request":"abcde","verdict":"ALLOW"}"#,
        #"{"frame":"verdict","v":1,"request":"abcde","verdict":"allow"}"#,
        #"{"frame":"verdict","v":3,"request":"abcde","verdict":"allow"}"#,
        #"{"frame":"verdict","v":"2","request":"abcde","verdict":"allow"}"#,
        #"{"frame":"verdict","v":2.0,"request":"abcde","verdict":"allow"}"#,
        #"{"frame":"verdict","v":2,"request":"abcdl","verdict":"allow"}"#,
        #"{"frame":"verdict","v":2,"request":"abcde","verdict":"allow","always":true}"#,
        #"{"frame":"verdict","v":2,"request":"abcde"}"#,
        #"{"frame":"verdict","v":2,"request":"abcde","verdict":"allow","verdict":"deny"}"#,
        #"{"frame":"prompt","v":2,"request":"abcde","tool":"Bash","preview":"{}","server":2,"client":"claude-code","clientVersion":"2.1.326"}"#,
        #"{"frame":"decision","v":2,"request":"abcde","verdict":"allow"}"#,
        #"{"jsonrpc":"2.0","method":"notifications/claude/channel/permission","params":{"request_id":"abcde","behavior":"allow"}}"#,
    ]

    /// Anything the strict reader refuses (or a prompt frame from NapCat)
    /// closes the link; the open request stays local and can no longer be
    /// answered remotely, even after a reconnect.
    @Test(arguments: refusedFrames)
    func aRefusedFrameClosesTheLinkAndOpenRequestsStayLocal(_ frame: String) throws {
        let harness = RelayHarness.initialized()
        harness.stdin(RelayHarness.permissionRequest("abcde"))
        let first = try #require(harness.link)
        first.deliver(frame)
        #expect(first.closed, "the link must close on \(frame)")
        #expect(harness.emitted.isEmpty)
        #expect(harness.notes == [.relayed, .frameRefused, .seamClosed])
        harness.stdin(RelayHarness.permissionRequest("bcdef"))
        let second = try #require(harness.link)
        #expect(second !== first, "the next prompt reconnects")
        second.deliver(RelayHarness.verdict("abcde", .allow))
        #expect(harness.emitted.isEmpty, "a request open on a closed link stays local")
        second.deliver(RelayHarness.verdict("bcdef", .allow))
        #expect(harness.emitted == [RelayHarness.verdictLine("bcdef", .allow)])
    }

    // MARK: - Every failure keeps the prompt local

    @Test func withoutTheSeamPromptsStayLocalAndTheNextOneRetries() throws {
        let harness = RelayHarness.initialized()
        harness.reachable = false
        harness.stdin(RelayHarness.permissionRequest("abcde"))
        #expect(harness.connectAttempts == 1)
        #expect(harness.emitted.isEmpty)
        harness.reachable = true
        harness.stdin(RelayHarness.permissionRequest("bcdef"))
        #expect(harness.connectAttempts == 2)
        #expect(try #require(harness.link).sent.count == 1)
        #expect(harness.notes == [.heldNoSeam, .relayed])
    }

    @Test func aFailedSendKeepsThePromptLocal() throws {
        let harness = RelayHarness.initialized()
        harness.stdin(RelayHarness.permissionRequest("abcde"))
        let link = try #require(harness.link)
        link.failSends = true
        harness.stdin(RelayHarness.permissionRequest("bcdef"))
        #expect(link.closed)
        #expect(harness.notes == [.relayed, .seamClosed, .heldSendFailed])
        link.deliver(RelayHarness.verdict("bcdef", .allow))
        #expect(harness.emitted.isEmpty)
    }

    @Test func atMostMaxOpenRequestsWaitForAVerdict() throws {
        let harness = RelayHarness.initialized()
        let ids = Self.requestIDs(ApprovalChannel.maxOpenRequests + 1)
        for id in ids { harness.stdin(RelayHarness.permissionRequest(id)) }
        let link = try #require(harness.link)
        #expect(link.sent.count == ApprovalChannel.maxOpenRequests)
        #expect(harness.notes.last == .heldTooManyOpen)
        link.deliver(RelayHarness.verdict(ids[0], .deny))
        harness.stdin(RelayHarness.permissionRequest("zzzzz"))
        #expect(link.sent.count == ApprovalChannel.maxOpenRequests + 1, "a verdict frees a slot")
    }

    @Test func aPromptTooLargeForAFrameStaysLocal() {
        let harness = RelayHarness.initialized()
        let content = String(repeating: "x", count: ApprovalChannel.maxFrameBytes)
        harness.stdin(RelayHarness.permissionRequest("abcde", tool: "Write", preview: #"{"content":"# + RelayHarness.quote(content) + "}"))
        #expect(harness.connectAttempts == 0)
        #expect(harness.notes == [.heldTooLarge])
    }

    /// The property: across every line Claude Code could send and every frame
    /// NapCat could send, the only verdicts emitted are the ones NapCat's
    /// valid frames asked for, for requests the server relayed.
    @Test func nothingButAValidVerdictFrameEverProducesAVerdict() throws {
        let harness = RelayHarness.initialized()
        for line in Self.silentLines + Self.malformedRequests { harness.stdin(line) }
        harness.stdin(RelayHarness.permissionRequest("abcde"))
        for frame in Self.refusedFrames.prefix(3) { harness.link?.deliver(frame) }
        harness.stdin(RelayHarness.permissionRequest("bcdef"))
        harness.link?.deliver(RelayHarness.verdict("zzzzz", .allow))
        #expect(harness.emitted.filter { $0.contains(ApprovalChannel.verdictMethod) }.isEmpty)
        harness.link?.deliver(RelayHarness.verdict("bcdef", .allow))
        #expect(harness.emitted.filter { $0.contains(ApprovalChannel.verdictMethod) } == [RelayHarness.verdictLine("bcdef", .allow)])
    }

    static func requestIDs(_ count: Int) -> [String] { IntakeHarness.requestIDs(count) }
}
