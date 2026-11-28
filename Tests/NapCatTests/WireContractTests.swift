// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import NapCatWire
import Testing

/// F3 stage 1: the NapCatWire constants are the contract between the Mac
/// writer and the iOS receiver. A silent change to any of them would leave
/// the two apps talking past each other (the phone subscribed to a record
/// type nobody writes, or two subscriptions buzzing twice), so every value is
/// byte-pinned here, and the target itself must stay import-free. F4 adds
/// the approval constants (`ApprovalWire`) under the same rules.
struct WireContractTests {
    @Test func theWireConstantsArePinned() {
        #expect(AlertWire.containerIdentifier == "iCloud.com.muratalkan.napcat")
        #expect(AlertWire.recordType == "Alert")
        #expect(AlertWire.subscriptionID == "napcat-alert-created-v1")
    }

    /// The record schema is EXACTLY these three fields, in this order — a
    /// fourth case would widen what an alert record can carry.
    @Test func theFieldSetIsExactlyBodyLaneFiredAt() {
        #expect(AlertWire.Field.allCases.map(\.rawValue) == ["body", "lane", "firedAt"])
    }

    @Test func theLaneValuesArePinned() {
        #expect(AlertWire.Lane.allCases.map(\.rawValue) == ["lid", "session"])
    }

    // MARK: - F4 remote approvals (ApprovalWire)

    /// The approval records share the alert container but never its zone or
    /// subscription: a mix-up would make the phone buzz for the wrong record.
    @Test func theApprovalConstantsArePinned() {
        #expect(ApprovalWire.containerIdentifier == AlertWire.containerIdentifier)
        #expect(ApprovalWire.zoneName == "napcat-approvals-v1")
        #expect(ApprovalWire.promptSubscriptionID == "napcat-prompt-created-v1")
        #expect(ApprovalWire.promptSubscriptionID != AlertWire.subscriptionID)
        #expect(ApprovalWire.wireVersion == 1)
        #expect(ApprovalWire.promptTimeToLiveSeconds == 600, "the ruled 10-minute TTL")
        #expect(ApprovalWire.promptIDByteCount == 16, "128-bit prompt IDs")
        #expect(ApprovalWire.promptIDHexDigits == 2 * ApprovalWire.promptIDByteCount)
    }

    /// A prompt's window lies between 5 minutes and 1 hour, and the default
    /// lies inside those bounds, so clamping never moves it.
    @Test func theWindowBoundsArePinned() {
        let minimum: Int = ApprovalWire.minPromptTimeToLiveSeconds
        let maximum: Int = ApprovalWire.maxPromptTimeToLiveSeconds
        let standard: Int = ApprovalWire.promptTimeToLiveSeconds
        #expect(minimum == 300, "5 minutes")
        #expect(maximum == 3_600, "1 hour")
        #expect(minimum < standard && standard < maximum, "the default window is strictly inside the bounds")
    }

    /// One prompt ID and the name of its decision record.
    struct DecisionNameRow: Sendable, CustomTestStringConvertible {
        let high: UInt64
        let low: UInt64
        let name: String
        var testDescription: String { name }
    }

    /// A decision record is named after its prompt: the prompt's record name
    /// and `-decision`, as the phone's decision writer and the Mac's routing
    /// tests already spell it.
    static let decisionNameRows: [DecisionNameRow] = [
        DecisionNameRow(high: 0x0123_4567_89AB_CDEF, low: 0xFEDC_BA98_7654_3210,
                        name: "0123456789abcdeffedcba9876543210-decision"),
        DecisionNameRow(high: 1, low: 2, name: "00000000000000010000000000000002-decision"),
        DecisionNameRow(high: 0, low: 1, name: "00000000000000000000000000000001-decision"),
        DecisionNameRow(high: .max, low: .max, name: "ffffffffffffffffffffffffffffffff-decision"),
    ]

    @Test(arguments: decisionNameRows)
    func theDecisionRecordIsNamedAfterItsPrompt(_ row: DecisionNameRow) throws {
        let id: PromptID = try #require(PromptID(high: row.high, low: row.low))
        let name: String = ApprovalWire.decisionRecordName(for: id)
        let spelledToday: String = id.hex + "-decision"
        #expect(name == row.name)
        #expect(name == spelledToday, "the spelling the phone's writer and the routing tests use")
        #expect(PromptID(hex: name) == nil, "a decision name is never a prompt record name")
        #expect(ApprovalWire.decisionRecordName(for: id) == name, "one name per prompt, every time")
    }

    /// Two prompts never share a decision record.
    @Test func distinctPromptsHaveDistinctDecisionNames() {
        let ids: [PromptID] = Self.decisionNameRows.compactMap { PromptID(high: $0.high, low: $0.low) }
        let names: Set<String> = Set(ids.map { ApprovalWire.decisionRecordName(for: $0) })
        #expect(ids.count == Self.decisionNameRows.count, "vacuity: every row is a prompt ID")
        #expect(names.count == ids.count && names.count == 4)
    }

    /// S-PAIR-C1 (#168) added the pairing response, deliberately.
    @Test func theApprovalRecordTypesAreExactlyPromptDecisionAndPairingResponse() {
        #expect(ApprovalWire.RecordType.allCases.map(\.rawValue) == ["PromptRequest", "PromptDecision", "PairingResponse"])
        #expect(!ApprovalWire.RecordType.allCases.map(\.rawValue).contains(AlertWire.recordType))
    }

    /// The field sets are exact. A prompt never carries the description (the
    /// display relies on the tool name and the preview), a session id or the
    /// Claude Code request id; a decision carries the CL-1 signature.
    @Test func theApprovalFieldSetsArePinned() {
        #expect(ApprovalWire.PromptField.allCases.map(\.rawValue)
            == ["wireVersion", "toolName", "inputPreview", "projectLabel", "createdAt", "expiresAt"])
        #expect(ApprovalWire.DecisionField.allCases.map(\.rawValue)
            == ["wireVersion", "promptID", "verdict", "decidedAt", "signature"])
        // S-PAIR-C1 (#168): no fingerprint and no nonce on the wire.
        #expect(ApprovalWire.PairingResponseField.allCases.map(\.rawValue)
            == ["wireVersion", "publicKey", "confirmation", "proof"])
        let names = (ApprovalWire.PromptField.allCases.map(\.rawValue)
            + ApprovalWire.DecisionField.allCases.map(\.rawValue)
            + ApprovalWire.PairingResponseField.allCases.map(\.rawValue)).map { $0.lowercased() }
        for leak in ["description", "session", "request", "topic", "cwd", "fingerprint", "nonce"] {
            #expect(!names.contains { $0.contains(leak) }, "an approval field names '\(leak)'")
        }
    }

    /// Every human-readable field is encrypted; the version and dates are not.
    @Test func theEncryptedFieldsArePinned() {
        #expect(ApprovalWire.encryptedPromptFields == [.toolName, .inputPreview, .projectLabel])
        #expect(ApprovalWire.encryptedDecisionFields == [.promptID, .verdict, .signature])
        // S-PAIR-C1 (#168, ratified): every pairing field but the version.
        #expect(ApprovalWire.encryptedPairingResponseFields == [.publicKey, .confirmation, .proof])
        #expect(Set(ApprovalWire.encryptedPairingResponseFields.map(\.rawValue))
            == Set(ApprovalWire.PairingResponseField.allCases.map(\.rawValue)).subtracting(["wireVersion"]))
    }

    @Test func theVerdictsAreExactlyAllowAndDeny() {
        #expect(ApprovalWire.Verdict.allCases.map(\.rawValue) == ["allow", "deny"])
    }

    // MARK: - Structure locks

    /// The constants files: values only, no functions or state.
    static let constantsFiles = ["AlertWire.swift", "ApprovalWire.swift"]
    /// The pure files: I/O-free logic over the constants. S1 added the
    /// channel server's wire (`ApprovalChannel.swift`) and the managed-settings
    /// allowlist reading (`ApprovalChannelPolicy.swift`) under the same locks.
    /// S-PAIR-A (#161) added the canonical bytes of signed decisions and of
    /// pairing (`ApprovalSigning.swift`: byte assembly only — the hashing and
    /// the signatures stay in the apps; ApprovalSigningVectorTests pins it on
    /// both devices). S-PAIR-C1 (#168) added the pairing code's rendering
    /// (`PairingFingerprint.swift`: text assembly only — the digest stays in
    /// the apps; PairingFingerprintVectorTests pins it on both devices). The
    /// project label rule (`ApprovalProjectLabel.swift`) joined for the live
    /// approval path: the caller reads the path, the rule only reads bytes.
    static let pureFiles = ["ApprovalChannel.swift", "ApprovalChannelPolicy.swift", "ApprovalClassification.swift",
                            "ApprovalFloor.swift",
                            "ApprovalForwardingPolicy.swift",
                            "ApprovalPreview.swift", "ApprovalProjectLabel.swift", "ApprovalSigning.swift",
                            "ApprovalStateMachine.swift", "PairingFingerprint.swift"]

    static func wireDirectory() -> URL {
        LidGuardStructureTests.repoRoot().appendingPathComponent("Sources/NapCatWire")
    }

    static func wireCode(_ file: String) throws -> String {
        LidGuardStructureTests.codeOnly(
            try String(contentsOf: wireDirectory().appendingPathComponent(file), encoding: .utf8))
    }

    /// Tokens that reach outside the process (files, network, processes,
    /// defaults, keychain, CloudKit) or read a clock or a random source. A
    /// NapCatWire file needs none of them. (The keychain token is split so
    /// this file never names a Security item call itself.)
    static let ioTokens = [
        "Foundation", "Darwin", "Glibc", "Dispatch", "Process", "NSTask", "posix_spawn", "popen",
        "system(", "fopen", "FileHandle", "FileManager", "URLSession", "URLRequest", "NWConnection",
        "socket(", "UserDefaults", "CloudKit", "CKContainer", "CKRecord", "Sec" + "Item", "getenv",
        "Date(", "Clock", "Timer", "Thread", "RandomNumberGenerator", ".random(",
    ]

    /// Lines that import anything (the standard library needs no import).
    static func importLines(_ code: String) -> [String] {
        code.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("import ") || $0.hasPrefix("@_exported") || $0.hasPrefix("@testable") }
    }

    /// Exactly the known files: a new one must join a list (and its locks).
    @Test func theWireTargetHoldsExactlyTheKnownFiles() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.wireDirectory().path)
            .filter { $0.hasSuffix(".swift") }.sorted()
        #expect(files == (Self.constantsFiles + Self.pureFiles).sorted(), "NapCatWire holds \(files)")
    }

    /// No import statement at all (so it builds for iOS and cannot reach
    /// I/O), and no I/O, clock or randomness token, in every file.
    @Test func theWireTargetIsImportFreeAndIOFree() throws {
        for file in Self.constantsFiles + Self.pureFiles {
            let code = try Self.wireCode(file)
            #expect(Self.importLines(code).isEmpty, "\(file) must stay import-free: \(Self.importLines(code))")
            for token in Self.ioTokens {
                #expect(!code.contains(token), "'\(token)' in \(file) — NapCatWire performs no I/O")
            }
        }
    }

    /// The constants files hold constants only.
    @Test func theConstantsFilesHoldConstantsOnly() throws {
        for file in Self.constantsFiles {
            let code = try Self.wireCode(file)
            for token in ["func ", "var ", "class ", "init("] {
                #expect(!code.contains(token), "'\(token)' in \(file) — it holds constants only")
            }
        }
        #expect(try Self.wireCode("AlertWire.swift").contains("public enum AlertWire"), "vacuity: the scanned file")
        #expect(try Self.wireCode("ApprovalWire.swift").contains("public enum ApprovalWire"), "vacuity: the scanned file")
    }

    /// The locks themselves can fail: each catches a planted line.
    @Test func theStructureLocksCatchAPlantedLine() {
        #expect(Self.importLines("import Foundation\nlet x = 1") == ["import Foundation"])
        #expect(Self.importLines("  @testable import NapCat") == ["@testable import NapCat"])
        #expect(Self.importLines("let important = 1").isEmpty)
        let planted = "let t = Process()\nlet s = URLSession.shared\nlet now = Date()"
        #expect(Self.ioTokens.filter { planted.contains($0) } == ["Process", "URLSession", "Date("])
    }
}
