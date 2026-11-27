// NapCatWire — F4 remote approvals: the two wires the channel server speaks
// (slice S1). Design: design/remote-approvals.md.
//
// PURE — no imports, no I/O, no clock. Every inbound line on either wire is
// read by the ONE strict reader (ApprovalPreview.swift) and by nothing else:
// a line it refuses has no effect, and there is no second parser. The prompt
// itself is classified only by ApprovalGate (ApprovalClassification.swift),
// on NapCat's side of the seam.
//
// Wire 1, Claude Code ↔ the server: MCP JSON-RPC 2.0 over stdio, one message
// per line. The server opts into the channel and permission-relay
// capabilities, answers `initialize` and `ping`, refuses every other request,
// and reads exactly one notification: the relay's permission request. The
// only message it would send on its own is a verdict for a request it
// relayed, and it sends none while `ApprovalChannel.passesAnswersBack` is
// false (#221). It never sends a channel message into the session (replies
// are F4.1, out of the MVP).
//
// Wire 2, the server ↔ NapCat: the seam (NapCatSeam), one JSON object per
// line over a Unix socket restricted to this user (which program is on the
// other end is not checked yet). The server sends `prompt` frames, NapCat
// answers with `verdict` frames, and each side accepts only its own inbound
// kind.

/// The channel server's constants.
public enum ApprovalChannel {
    /// The server's behaviour version. Bump it with every behaviour change;
    /// the design doc carries the same value on its stamp line, and the app
    /// bundle's Info.plist as `NapCatChannelVersion` (both parity-locked, like
    /// the busy hook's version stamp). Claude Code sees it as the server's
    /// `serverInfo.version`; every prompt frame names it too (frame version
    /// 2), and NapCat refuses a frame from a server of another version
    /// (#150). Version 3 (#221): the server passes no answer back
    /// (`passesAnswersBack`).
    public static let serverVersion = 3

    /// The design doc's stamp line starts with this, followed by the version.
    public static let serverVersionStampPrefix = "napcat-channel-version: "

    /// The server's MCP name (`serverInfo.name`).
    public static let serverName = "napcat"

    /// The MCP revisions the server negotiates, newest first: the
    /// `initialize`-based ones only. Never 2026-07-28: Claude Code does not
    /// register a channel server that negotiates it, because that revision
    /// cannot carry channel messages.
    public static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    /// The Claude Code builds whose permission relay NapCat has checked, each
    /// exactly as it names itself in `initialize` (`clientInfo`). A session
    /// whose client is not on this list, or does not name itself, keeps every
    /// prompt local. A build joins only after its relay has been re-checked.
    public static let confirmedClients = [ChannelClient(name: "claude-code", version: "2.1.326")]

    /// Whether the server passes a verdict from the seam back to Claude Code
    /// as the permission answer. False: the seam's peer check confirms that
    /// the listener runs as this user, not that it is NapCat, so the relay
    /// drops every verdict frame (`ChannelNote.verdictWithheld`) and each
    /// dialog is answered in the terminal; prompts are still relayed. It
    /// flips only in the slice that checks the listener's code identity on
    /// the seam (#221; lint-locked: declared once, read once, by the relay).
    public static let passesAnswersBack = false

    /// The experimental capability that makes the server a channel.
    public static let channelCapability = "claude/channel"
    /// The experimental capability that opts it into the permission relay.
    public static let permissionCapability = "claude/channel/permission"
    /// Claude Code → server: a permission dialog opened.
    public static let permissionRequestMethod = "notifications/claude/channel/permission_request"
    /// Server → Claude Code: the verdict for one open request.
    public static let verdictMethod = "notifications/claude/channel/permission"

    /// The longest inbound line read; a longer one is dropped unread.
    public static let maxLineBytes = 1_048_576

    /// A relay request ID: exactly this many letters from `requestIDAlphabet`
    /// (lowercase `a`–`z` without `l`).
    public static let requestIDLength = 5
    public static let requestIDAlphabet = "abcdefghijkmnopqrstuvwxyz"

    /// The members a JSON-RPC message may have.
    static let messageKeys = ["jsonrpc", "id", "method", "params"]
    /// The members of a permission request's `params`, exactly. The
    /// description is read only to check the shape; it is never kept.
    static let permissionRequestKeys = ["request_id", "tool_name", "description", "input_preview"]
    /// The longest string request ID echoed back.
    static let maxMessageIDBytes = 128

    /// The seam's frame version: every frame carries it as `v`, and a frame
    /// with any other value is refused. Since version 2 (#150) a prompt frame
    /// also names the server's version and the confirmed client it relays
    /// for, which NapCat checks again before the gate.
    public static let frameVersion = 2
    /// The longest seam frame either side sends or reads.
    public static let maxFrameBytes = 262_144
    /// At most this many relayed requests wait for a verdict per server; a
    /// prompt beyond them stays local.
    public static let maxOpenRequests = 32
    /// A prompt frame's members, exactly.
    static let promptFrameKeys = ["frame", "v", "request", "tool", "preview", "server", "client", "clientVersion"]
    /// A verdict frame's members, exactly.
    static let verdictFrameKeys = ["frame", "v", "request", "verdict"]
}

/// One seam frame. The server only ever reads `verdict` and NapCat only ever
/// reads `prompt`; each side refuses the other kind.
public enum SeamFrame: Equatable, Sendable {
    /// Server → NapCat: a relayed permission prompt, with the version of the
    /// server that relayed it and the client that server confirmed. The
    /// reader only reads them; NapCat's intake judges them (#150).
    case prompt(ChannelPermissionRequest, server: Int, client: ChannelClient)
    /// NapCat → server: the verdict for one relayed request.
    case verdict(ChannelRequestID, ApprovalWire.Verdict)
}

/// A JSON-RPC request ID, echoed back exactly as it came: an integer (its
/// literal text) or a string.
public enum ChannelMessageID: Hashable, Sendable {
    case number(String)
    case string(String)
}

/// The two errors the server answers with.
public enum ChannelErrorCode: Int, CaseIterable, Sendable {
    case invalidParams = -32602
    case methodNotFound = -32601
}

/// A relay request ID that passed the grammar. Only Claude Code issues them;
/// a verdict is only ever sent for one the server was given.
public struct ChannelRequestID: Hashable, Sendable, CustomStringConvertible {
    public let text: String

    public init?(_ text: String) {
        let bytes = Array(text.utf8)
        let alphabet = Array(ApprovalChannel.requestIDAlphabet.utf8)
        guard bytes.count == ApprovalChannel.requestIDLength, bytes.allSatisfy({ alphabet.contains($0) }) else {
            return nil
        }
        self.text = text
    }

    public var description: String { text }
}

/// The client that opened the session, as its `initialize` named itself
/// (`clientInfo.name` and `clientInfo.version`).
public struct ChannelClient: Equatable, Sendable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

/// A relayed permission prompt: exactly what the gate classifies. There is
/// no description here (classification and display rely on the tool name and
/// the input preview, never the description).
public struct ChannelPermissionRequest: Equatable, Sendable {
    public let requestID: ChannelRequestID
    public let toolName: String
    public let inputPreview: String

    public init(requestID: ChannelRequestID, toolName: String, inputPreview: String) {
        self.requestID = requestID
        self.toolName = toolName
        self.inputPreview = inputPreview
    }
}

/// What one inbound MCP line asks of the server.
public enum ChannelMessage: Equatable, Sendable {
    /// Answer with the capabilities. `client` is the `clientInfo` name and
    /// version, or nil when the client did not give both as strings.
    case initialize(id: ChannelMessageID, protocolVersion: String, client: ChannelClient?)
    /// Answer with an empty result.
    case ping(id: ChannelMessageID)
    /// Answer with this error: any other request, including the 2026-07-28
    /// `server/discover` probe, so the client falls back to `initialize`.
    case refused(id: ChannelMessageID, ChannelErrorCode)
    /// A permission dialog opened.
    case permissionRequest(ChannelPermissionRequest)
    /// A notification the server has no use for.
    case ignored
    /// Not one strict JSON-RPC 2.0 message (or a response, which this server
    /// never asked for): no effect, no answer.
    case malformed
}

extension ApprovalChannel {
    // MARK: - Reading

    /// Reads one inbound MCP line (without its newline).
    public static func message(_ line: [UInt8]) -> ChannelMessage {
        guard let members = object(line),
              members.allSatisfy({ messageKeys.contains($0.key) }),
              value("jsonrpc", in: members) == .string("2.0"),
              case .string(let method)? = value("method", in: members) else {
            return .malformed
        }
        let params = value("params", in: members)
        guard let rawID = value("id", in: members) else {
            guard method == permissionRequestMethod else { return .ignored }
            guard case .object(let fields)? = params, let request = permissionRequest(fields) else { return .malformed }
            return .permissionRequest(request)
        }
        guard let id = messageID(rawID) else { return .malformed }
        if let params, !isObject(params) { return .refused(id: id, .invalidParams) }
        switch method {
        case "initialize":
            guard case .object(let fields)? = params, case .string(let version)? = value("protocolVersion", in: fields) else {
                return .refused(id: id, .invalidParams)
            }
            return .initialize(id: id, protocolVersion: version, client: clientInfo(value("clientInfo", in: fields)))
        case "ping":
            return .ping(id: id)
        default:
            return .refused(id: id, .methodNotFound)
        }
    }

    /// The four string fields, exactly, with a well-formed request ID. The
    /// description is checked for type and then dropped.
    static func permissionRequest(_ fields: [PreviewMember]) -> ChannelPermissionRequest? {
        guard fields.count == permissionRequestKeys.count,
              permissionRequestKeys.allSatisfy({ key in fields.contains { $0.key == key } }),
              fields.allSatisfy({ if case .string = $0.value { return true } else { return false } }),
              case .string(let rawRequestID)? = value("request_id", in: fields),
              let requestID = ChannelRequestID(rawRequestID),
              case .string(let toolName)? = value("tool_name", in: fields),
              case .string(let inputPreview)? = value("input_preview", in: fields) else {
            return nil
        }
        return ChannelPermissionRequest(requestID: requestID, toolName: toolName, inputPreview: inputPreview)
    }

    /// The `clientInfo` object's `name` and `version`, both strings, or nil.
    /// Its other members are not read.
    static func clientInfo(_ raw: PreviewValue?) -> ChannelClient? {
        guard case .object(let fields)? = raw, case .string(let name)? = value("name", in: fields),
              case .string(let version)? = value("version", in: fields) else { return nil }
        return ChannelClient(name: name, version: version)
    }

    /// Whether `client` is one of `confirmedClients`, byte for byte (never
    /// by Unicode equivalence, never by prefix).
    public static func confirms(_ client: ChannelClient?) -> Bool {
        guard let client else { return false }
        return confirmedClients.contains {
            $0.name.utf8.elementsEqual(client.name.utf8) && $0.version.utf8.elementsEqual(client.version.utf8)
        }
    }

    /// An integer (no fraction, no exponent) or a short string; never null.
    static func messageID(_ raw: PreviewValue) -> ChannelMessageID? {
        switch raw {
        case .number(let literal):
            var digits = Array(literal.utf8)
            if digits.first == UInt8(ascii: "-") { digits.removeFirst() }
            guard !digits.isEmpty, digits.count <= 19,
                  digits.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) else { return nil }
            return .number(literal)
        case .string(let text):
            guard text.utf8.count <= maxMessageIDBytes else { return nil }
            return .string(text)
        case .bool, .null, .array, .object:
            return nil
        }
    }

    /// The members of `line` when it is valid UTF-8 holding exactly one strict
    /// JSON object (the S0 reader decides), or nil.
    static func object(_ line: [UInt8]) -> [PreviewMember]? {
        let text = String(decoding: line, as: UTF8.self)
        guard text.utf8.elementsEqual(line) else { return nil }
        return ApprovalPreview.parseObject(text)
    }

    /// Reads one seam frame (without its newline): exactly the members of its
    /// kind, the current frame version, a well-formed request ID, for a
    /// prompt an integer server version and the client's name and version as
    /// strings, and, for a verdict, exactly `allow` or `deny`. Anything else
    /// is nil.
    public static func frame(_ line: [UInt8]) -> SeamFrame? {
        guard line.count <= maxFrameBytes, let members = object(line),
              value("v", in: members) == .number(String(frameVersion)),
              case .string(let kind)? = value("frame", in: members),
              case .string(let rawRequestID)? = value("request", in: members),
              let requestID = ChannelRequestID(rawRequestID) else {
            return nil
        }
        switch kind {
        case "prompt":
            guard hasExactly(promptFrameKeys, members),
                  case .string(let toolName)? = value("tool", in: members),
                  case .string(let inputPreview)? = value("preview", in: members),
                  case .number(let serverText)? = value("server", in: members), let server = Int(serverText),
                  case .string(let clientName)? = value("client", in: members),
                  case .string(let clientVersion)? = value("clientVersion", in: members) else { return nil }
            let request = ChannelPermissionRequest(requestID: requestID, toolName: toolName, inputPreview: inputPreview)
            return .prompt(request, server: server, client: ChannelClient(name: clientName, version: clientVersion))
        case "verdict":
            guard hasExactly(verdictFrameKeys, members),
                  case .string(let rawVerdict)? = value("verdict", in: members),
                  let verdict = ApprovalWire.Verdict(rawValue: rawVerdict) else { return nil }
            return .verdict(requestID, verdict)
        default:
            return nil
        }
    }

    /// Whether `members` are exactly `keys` (the reader already refused
    /// duplicates).
    static func hasExactly(_ keys: [String], _ members: [PreviewMember]) -> Bool {
        members.count == keys.count && keys.allSatisfy { key in members.contains { $0.key == key } }
    }

    static func value(_ key: String, in members: [PreviewMember]) -> PreviewValue? {
        members.first { $0.key == key }?.value
    }

    static func isObject(_ value: PreviewValue) -> Bool {
        if case .object = value { return true }
        return false
    }

    // MARK: - Writing (each line comes back without its newline, and has none)

    /// The `initialize` answer: the requested revision when the server speaks
    /// it, otherwise its newest; the two channel capabilities and nothing
    /// else (no tools: the server offers Claude nothing to call).
    public static func initializeResult(id: ChannelMessageID, requestedVersion: String) -> String {
        let version = protocolVersions.contains(requestedVersion) ? requestedVersion : protocolVersions[0]
        let capabilities = "{\"experimental\":{" + quoted(channelCapability) + ":{}," + quoted(permissionCapability) + ":{}}}"
        let serverInfo = "{\"name\":" + quoted(serverName) + ",\"version\":" + quoted(String(serverVersion)) + "}"
        return response(id, result: "{\"protocolVersion\":" + quoted(version) + ",\"capabilities\":" + capabilities
            + ",\"serverInfo\":" + serverInfo + "}")
    }

    public static func pingResult(id: ChannelMessageID) -> String {
        response(id, result: "{}")
    }

    public static func errorResponse(id: ChannelMessageID, code: ChannelErrorCode) -> String {
        let message: String
        switch code {
        case .invalidParams: message = "Invalid params"
        case .methodNotFound: message = "Method not found"
        }
        return "{\"jsonrpc\":\"2.0\",\"id\":" + json(id) + ",\"error\":{\"code\":" + String(code.rawValue)
            + ",\"message\":" + quoted(message) + "}}"
    }

    /// The verdict notification for one relayed request.
    public static func verdictNotification(requestID: ChannelRequestID, verdict: ApprovalWire.Verdict) -> String {
        "{\"jsonrpc\":\"2.0\",\"method\":" + quoted(verdictMethod) + ",\"params\":{\"request_id\":" + quoted(requestID.text)
            + ",\"behavior\":" + quoted(verdict.rawValue) + "}}"
    }

    /// The prompt frame for one relayed request, naming this server's version
    /// and the session's confirmed `client`, or nil when it would be longer
    /// than `maxFrameBytes` (the prompt then stays local).
    public static func promptFrame(_ request: ChannelPermissionRequest, client: ChannelClient) -> String? {
        let prompt: String = "{\"frame\":\"prompt\",\"v\":" + String(frameVersion) + ",\"request\":" + quoted(request.requestID.text)
            + ",\"tool\":" + quoted(request.toolName) + ",\"preview\":" + quoted(request.inputPreview)
        let origin: String = ",\"server\":" + String(serverVersion) + ",\"client\":" + quoted(client.name)
            + ",\"clientVersion\":" + quoted(client.version) + "}"
        let line: String = prompt + origin
        return line.utf8.count <= maxFrameBytes ? line : nil
    }

    /// The verdict frame for one relayed request.
    public static func verdictFrame(_ requestID: ChannelRequestID, _ verdict: ApprovalWire.Verdict) -> String {
        "{\"frame\":\"verdict\",\"v\":" + String(frameVersion) + ",\"request\":" + quoted(requestID.text)
            + ",\"verdict\":" + quoted(verdict.rawValue) + "}"
    }

    static func response(_ id: ChannelMessageID, result: String) -> String {
        "{\"jsonrpc\":\"2.0\",\"id\":" + json(id) + ",\"result\":" + result + "}"
    }

    static func json(_ id: ChannelMessageID) -> String {
        switch id {
        case .number(let literal): return literal
        case .string(let text): return quoted(text)
        }
    }

    /// `text` as a JSON string. Quote, backslash and every control character
    /// are escaped, so the result never holds a raw line break.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x00..<0x20, 0x7F, 0x2028, 0x2029:
                let digits = Array("0123456789abcdef")
                out += "\\u"
                for shift in [12, 8, 4, 0] { out.append(digits[Int(scalar.value >> UInt32(shift)) & 0xF]) }
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

/// One piece of an inbound byte stream.
public enum ChannelLine: Equatable, Sendable {
    /// A complete line, its newline removed.
    case line([UInt8])
    /// A line ran past the limit: its bytes are dropped up to the next newline.
    case overlong
}

/// Splits an inbound byte stream into lines of at most `limit` bytes. Bytes
/// after the last newline wait for more; a line that grows past the limit is
/// reported once as `.overlong` and discarded through its newline.
public struct ChannelLineReader: Sendable {
    public let limit: Int
    private var pending: [UInt8] = []
    private var discarding = false

    public init(limit: Int) {
        self.limit = limit
    }

    /// Whether part of a line is buffered, waiting for the rest of it.
    public var hasPartialLine: Bool { !pending.isEmpty }

    public mutating func feed(_ bytes: [UInt8]) -> [ChannelLine] {
        var lines: [ChannelLine] = []
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let newline = bytes[start...].firstIndex(of: 0x0A)
            let end = newline ?? bytes.endIndex
            if !discarding {
                pending += bytes[start..<end]
                if pending.count > limit {
                    pending.removeAll()
                    discarding = true
                    lines.append(.overlong)
                }
            }
            guard let newline else { break }
            if !discarding { lines.append(.line(pending)) }
            pending.removeAll(keepingCapacity: true)
            discarding = false
            start = newline + 1
        }
        return lines
    }
}
