// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCatWire

/// F4 slice S1: the channel server's wire (`ApprovalChannel`) and its version
/// stamp. The stamp follows the busy hook's precedent: one Swift constant, one
/// stamp line in the design doc, byte-matched here.
struct ApprovalChannelTests {
    // MARK: - The version stamp (Swift ↔ design doc parity)

    static let designDocURL = LidGuardStructureTests.repoRoot().appendingPathComponent("design/remote-approvals.md")

    /// Exactly one stamp line, reading exactly `<prefix><expected>`.
    static func versionStampFailures(_ doc: String, expected: Int) -> [String] {
        let prefix = ApprovalChannel.serverVersionStampPrefix
        let lines = doc.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let stamps = lines.filter { $0.contains(prefix) }
        guard stamps.count == 1, let stamp = stamps.first else {
            return ["exactly one stamp line in the design doc — found \(stamps.count)"]
        }
        return stamp == prefix + "\(expected)" ? [] : ["the stamp line reads '\(stamp)', expected '\(prefix)\(expected)'"]
    }

    @Test func theServerVersionStampMatchesTheDesignDoc() throws {
        let doc = try String(contentsOf: Self.designDocURL, encoding: .utf8)
        let failures = Self.versionStampFailures(doc, expected: ApprovalChannel.serverVersion)
        #expect(failures.isEmpty, "\(failures)")
        #expect(ApprovalChannel.serverVersion == 1, "the contract value of this slice")
        #expect(ApprovalChannel.serverVersionStampPrefix == "napcat-channel-version: ")
    }

    /// Canaries: a drift on either side, a duplicate or a dropped stamp fail.
    @Test func theStampParityCatchesADriftOnEitherSide() throws {
        let doc = try String(contentsOf: Self.designDocURL, encoding: .utf8)
        let expected = ApprovalChannel.serverVersion
        let stamp = ApprovalChannel.serverVersionStampPrefix + "\(expected)"
        try #require(Self.versionStampFailures(doc, expected: expected).isEmpty, "canary baseline must be clean")
        #expect(!Self.versionStampFailures(doc, expected: expected + 1).isEmpty, "Swift bumped, doc not")
        let mutants: [(String, String)] = [
            ("doc bumped, Swift not", doc.replacingOccurrences(of: stamp, with: ApprovalChannel.serverVersionStampPrefix + "\(expected + 1)")),
            ("stamp dropped", doc.replacingOccurrences(of: stamp, with: "")),
            ("duplicate stamp", doc + "\n" + stamp + "\n"),
        ]
        for (name, mutant) in mutants {
            #expect(mutant != doc, "canary setup '\(name)'")
            #expect(!Self.versionStampFailures(mutant, expected: expected).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    /// Claude Code sees the same version as the server's `serverInfo.version`.
    @Test func theServerReportsItsVersionInTheHandshake() throws {
        let line = ApprovalChannel.initializeResult(id: .number("1"), requestedVersion: "2025-06-18")
        let members = try #require(ApprovalPreview.parseObject(line))
        guard case .object(let result)? = members.first(where: { $0.key == "result" })?.value,
              case .object(let info)? = result.first(where: { $0.key == "serverInfo" })?.value else {
            Issue.record("no serverInfo in \(line)")
            return
        }
        #expect(info.first { $0.key == "version" }?.value == .string("\(ApprovalChannel.serverVersion)"))
        #expect(info.first { $0.key == "name" }?.value == .string(ApprovalChannel.serverName))
    }

    // MARK: - Constants

    @Test func theChannelConstantsArePinned() {
        #expect(ApprovalChannel.serverName == "napcat")
        #expect(ApprovalChannel.protocolVersions == ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"])
        #expect(ApprovalChannel.channelCapability == "claude/channel")
        #expect(ApprovalChannel.permissionCapability == "claude/channel/permission")
        #expect(ApprovalChannel.permissionRequestMethod == "notifications/claude/channel/permission_request")
        #expect(ApprovalChannel.verdictMethod == "notifications/claude/channel/permission")
        #expect(ApprovalChannel.requestIDLength == 5)
        #expect(ApprovalChannel.requestIDAlphabet == "abcdefghijkmnopqrstuvwxyz", "a–z without l")
        #expect(ApprovalChannel.frameVersion == 1)
        #expect(ApprovalChannel.maxFrameBytes > 6 * ApprovalGate.maxPreviewBytes,
                "a preview the gate could forward always fits a frame, even fully escaped")
        #expect(ApprovalChannel.maxLineBytes > ApprovalChannel.maxFrameBytes)
        #expect(ApprovalChannel.maxOpenRequests == 32)
    }

    // MARK: - Request IDs

    @Test(arguments: ["abcde", "zyxwv", "aaaaa", "kmnop"])
    func wellFormedRequestIDsAreAccepted(_ text: String) {
        #expect(ChannelRequestID(text)?.text == text)
    }

    @Test(arguments: ["abcdl", "lllll", "ABCDE", "Abcde", "abcd", "abcdef", "", "abc1e", "abc e", "abcdé", "abcd\n", "ａbcde"])
    func everyOtherSpellingIsRefused(_ text: String) {
        #expect(ChannelRequestID(text) == nil)
    }

    // MARK: - Writing

    static let trickyStrings = [
        "plain", "", "quote \" and backslash \\", "line\nbreak\r\ttab", "\u{1}\u{1F}\u{7F}", "\u{2028}\u{2029}",
        "unicode é ✓ 🐈", "slash / and </script>", #"{"nested":"json"}"#,
    ]

    /// Every written string reads back exactly, and no written line holds a
    /// raw line break (a line is one message).
    @Test(arguments: trickyStrings)
    func quotedStringsRoundTripAndHoldNoLineBreak(_ text: String) throws {
        let quoted = ApprovalChannel.quoted(text)
        #expect(!quoted.utf8.contains(0x0A) && !quoted.utf8.contains(0x0D))
        let members = try #require(ApprovalPreview.parseObject("{\"k\":" + quoted + "}"))
        #expect(members == [PreviewMember(key: "k", value: .string(text))])
    }

    @Test func everyWrittenLineIsOneStrictObjectWithoutALineBreak() throws {
        let id = ChannelRequestID("abcde")!
        let request = ChannelPermissionRequest(requestID: id, toolName: "Bash\n", inputPreview: "{\"command\":\"ls\"}\n")
        let lines = [
            ApprovalChannel.initializeResult(id: .string("i\n1"), requestedVersion: "2025-06-18"),
            ApprovalChannel.pingResult(id: .number("-12")),
            ApprovalChannel.errorResponse(id: .number("3"), code: .methodNotFound),
            ApprovalChannel.errorResponse(id: .number("3"), code: .invalidParams),
            ApprovalChannel.verdictNotification(requestID: id, verdict: .allow),
            try #require(ApprovalChannel.promptFrame(request)),
            ApprovalChannel.verdictFrame(id, .deny),
        ]
        for line in lines {
            #expect(!line.utf8.contains(0x0A) && !line.utf8.contains(0x0D), "\(line)")
            #expect(ApprovalPreview.parseObject(line) != nil, "\(line)")
        }
    }

    // MARK: - Seam frames

    @Test func framesRoundTrip() throws {
        let id = ChannelRequestID("qwert")!
        let request = ChannelPermissionRequest(requestID: id, toolName: "Edit",
                                               inputPreview: #"{"file_path":"/a/b","old_string":"x","new_string":"y"}"#)
        let prompt = try #require(ApprovalChannel.promptFrame(request))
        #expect(prompt == #"{"frame":"prompt","v":1,"request":"qwert","tool":"Edit","preview":"{\"file_path\":\"/a/b\",\"old_string\":\"x\",\"new_string\":\"y\"}"}"#)
        #expect(ApprovalChannel.frame(Array(prompt.utf8)) == .prompt(request))
        for verdict in ApprovalWire.Verdict.allCases {
            let line = ApprovalChannel.verdictFrame(id, verdict)
            #expect(line == #"{"frame":"verdict","v":1,"request":"qwert","verdict":"\#(verdict.rawValue)"}"#)
            #expect(ApprovalChannel.frame(Array(line.utf8)) == .verdict(id, verdict))
        }
    }

    static let refusedFrames: [String] = [
        #"{"frame":"prompt","v":1,"request":"abcde","tool":"Bash"}"#,
        #"{"frame":"prompt","v":1,"request":"abcde","tool":"Bash","preview":"{}","description":"d"}"#,
        #"{"frame":"prompt","v":1,"request":"abcde","tool":"Bash","preview":{}}"#,
        #"{"frame":"prompt","v":1,"request":"abcde","tool":7,"preview":"{}"}"#,
        #"{"frame":"prompt","v":2,"request":"abcde","tool":"Bash","preview":"{}"}"#,
        #"{"frame":"prompt","v":1,"request":"ABCDE","tool":"Bash","preview":"{}"}"#,
        #"{"frame":"prompt","request":"abcde","tool":"Bash","preview":"{}"}"#,
        #"{"frame":"verdict","v":1,"request":"abcde","verdict":"maybe"}"#,
        #"{"frame":"verdict","v":1,"request":"abcde","verdict":"Allow"}"#,
        #"{"frame":"verdict","v":1,"request":"abcde","verdict":"allow","note":""}"#,
        #"{"frame":"verdict","v":1,"verdict":"allow"}"#,
        #"{"frame":"verdict","v":1,"request":null,"verdict":"allow"}"#,
        #"{"frame":"verdict","v":-1,"request":"abcde","verdict":"allow"}"#,
        #"{"frame":"verdict","v":10e-1,"request":"abcde","verdict":"allow"}"#,
        #"{"frame":"Verdict","v":1,"request":"abcde","verdict":"allow"}"#,
        #"{"v":1,"request":"abcde","verdict":"allow"}"#,
        #"{"frame":"verdict","v":1,"request":"abcde","verdict":"allow"} {}"#,
        #"[{"frame":"verdict","v":1,"request":"abcde","verdict":"allow"}]"#,
        #"{"frame":"verdict","v":1,"request":"abcde","request":"bcdef","verdict":"allow"}"#,
        #"{"frame":"verdict","v":1,"request":"abcde","verdict":"allow\u0000"}"#,
        "",
    ]

    @Test(arguments: refusedFrames)
    func aFrameOutsideTheGrammarIsRefused(_ line: String) {
        #expect(ApprovalChannel.frame(Array(line.utf8)) == nil)
    }

    /// An invalid byte inside the preview would decode leniently to U+FFFD
    /// and leave a valid frame behind; the frame is refused instead.
    @Test func anInvalidUTF8OrOverlongFrameIsRefused() {
        let head = Array(#"{"frame":"prompt","v":1,"request":"abcde","tool":"Bash","preview":"{\"command\":\"ls"#.utf8)
        let tail = Array(#"\"}"}"#.utf8)
        #expect(ApprovalChannel.frame(head + tail) != nil, "baseline")
        for invalid: [UInt8] in [[0xFF], [0xC3], [0xED, 0xA0, 0x80], [0xC0, 0xAF], [0xF4, 0x90, 0x80, 0x80]] {
            #expect(ApprovalChannel.frame(head + invalid + tail) == nil, "\(invalid)")
        }
        let padded = Array(#"{"frame":"verdict","v":1,"request":"abcde","verdict":"allow"}"#.utf8)
            + Array(repeating: UInt8(ascii: " "), count: ApprovalChannel.maxFrameBytes)
        #expect(ApprovalChannel.frame(padded) == nil, "the length cap applies before reading")
    }

    @Test func aPromptTooLargeForAFrameHasNoFrame() {
        let id = ChannelRequestID("abcde")!
        let big = String(repeating: "a", count: ApprovalChannel.maxFrameBytes)
        #expect(ApprovalChannel.promptFrame(ChannelPermissionRequest(requestID: id, toolName: "Write", inputPreview: big)) == nil)
        let fits = String(repeating: "a", count: ApprovalGate.maxPreviewBytes)
        #expect(ApprovalChannel.promptFrame(ChannelPermissionRequest(requestID: id, toolName: "Write", inputPreview: fits)) != nil)
    }

    // MARK: - The line reader

    @Test func theLineReaderSplitsAndHoldsPartialLines() {
        var reader = ChannelLineReader(limit: 8)
        #expect(reader.feed(Array("ab\ncd".utf8)) == [.line(Array("ab".utf8))])
        #expect(reader.feed(Array("ef\n\ngh".utf8)) == [.line(Array("cdef".utf8)), .line([])])
        #expect(reader.feed(Array("\n".utf8)) == [.line(Array("gh".utf8))])
        #expect(reader.feed([]).isEmpty)
    }

    @Test func anOverlongLineIsReportedOnceAndDroppedThroughItsNewline() {
        var reader = ChannelLineReader(limit: 4)
        #expect(reader.feed(Array("abcd".utf8)).isEmpty, "exactly the limit is still a line")
        #expect(reader.feed(Array("\n".utf8)) == [.line(Array("abcd".utf8))])
        #expect(reader.feed(Array("abcde".utf8)) == [.overlong])
        #expect(reader.feed(Array("fgh".utf8)).isEmpty, "the rest is dropped, not reported again")
        #expect(reader.feed(Array("ij\nok\n".utf8)) == [.line(Array("ok".utf8))], "the next line reads normally")
        #expect(reader.feed(Array("toolong\nx\n".utf8)) == [.overlong, .line(Array("x".utf8))])
    }
}
