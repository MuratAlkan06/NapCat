// NapCatWire — F4 remote approvals: the wire the channel server speaks with
// Claude Code (slice S1). Design: design/remote-approvals.md.
//
// PURE — no imports, no I/O, no clock. Every inbound line is read by the ONE
// strict reader (ApprovalPreview.swift) and by nothing else: a line it
// refuses has no effect, and there is no second parser. The prompt itself is
// classified only by ApprovalGate (ApprovalClassification.swift), on NapCat's
// side of the seam.
//
// The wire is MCP JSON-RPC 2.0 over stdio, one message per line. The server
// opts into the channel and permission-relay capabilities, answers
// `initialize` and `ping`, refuses every other request, and reads exactly one
// notification: the relay's permission request. The only message it ever
// sends on its own is a verdict for a request it relayed. It never sends a
// channel message into the session (replies are F4.1, out of the MVP).

/// The channel server's constants.
public enum ApprovalChannel {
    /// The server's behaviour version. Bump it with every behaviour change;
    /// the design doc carries the same value on its stamp line (parity-locked,
    /// like the busy hook's version stamp). Claude Code sees it as the
    /// server's `serverInfo.version`.
    public static let serverVersion = 1

    /// The design doc's stamp line starts with this, followed by the version.
    public static let serverVersionStampPrefix = "napcat-channel-version: "

    /// The server's MCP name (`serverInfo.name`).
    public static let serverName = "napcat"

    /// The MCP revisions the server negotiates, newest first: the
    /// `initialize`-based ones only. Never 2026-07-28: Claude Code does not
    /// register a channel server that negotiates it, because that revision
    /// cannot carry channel messages.
    public static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

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
    /// Answer with the capabilities.
    case initialize(id: ChannelMessageID, protocolVersion: String)
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
            return .initialize(id: id, protocolVersion: version)
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
