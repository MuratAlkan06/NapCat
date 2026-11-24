import CryptoKit
import Foundation
import NapCatWire
import Testing

// MARK: - BEGIN SIGNING VECTORS
// This region is byte-identical in Tests/NapCatTests/ApprovalSigningVectorTests.swift
// and ios/NapCatPhone/NapCatPhoneTests/ApprovalSigningVectorTests.swift: the Mac's
// `ApprovalSigningVectorTwinTests` compares the two, so both devices run these
// exact rows against the one shared builder (NapCatWire's `ApprovalSigning`).

/// F4 slice S-PAIR-A (#161): the canonical bytes of signed decisions and of
/// the pairing ceremony, pinned row for row on BOTH devices. The pinned values
/// come from an independent reference written from the frozen design's byte
/// layouts, not from the code under test. The builders assemble bytes only;
/// the digests and MACs here are CryptoKit's, as each app will take them.
///
/// The hostile-Unicode rows hold text Swift calls EQUAL (canonically
/// equivalent: NFC against NFD, combining marks in two orders) that must
/// still digest differently, because the digest is over the bytes the phone
/// decoded, never a normalized or displayed form; and text whose characters
/// and bytes disagree in number (CRLF is one Character, an emoji ZWJ
/// sequence is one Character of eleven bytes).
@Suite struct ApprovalSigningVectorTests {
    struct Shown: Sendable {
        let name: String
        let toolName: String
        let inputPreview: String
        let projectLabel: String
        let byteCount: Int
        /// The whole input as hex (nil for the long row: its count and its
        /// digest pin it).
        let bytes: String?
        let digest: String
    }

    struct Decision: Sendable {
        let name: String
        let wireVersion: Int
        let promptID: String
        let verdict: ApprovalWire.Verdict
        let decidedAt: Int
        let shown: String
        let message: String
        let digest: String
    }

    struct Payload: Sendable {
        let name: String
        let nonce: String
        let payload: String
    }

    struct Confirmation: Sendable {
        let name: String
        let wireVersion: Int
        let nonce: String
        let publicKey: String
        let message: String
        /// HMAC-SHA256 of the message, keyed by the nonce.
        let mac: String
    }

    struct Proof: Sendable {
        let name: String
        let nonce: String
        let publicKey: String
        let message: String
        let digest: String
    }

    struct RecordName: Sendable {
        let name: String
        let nonce: String
        let input: String
        let recordName: String
    }

    static let shown: [Shown] = [
        Shown(name: "ascii", toolName: "Bash", inputPreview: "{\"command\":\"git status\"}", projectLabel: "NapCat",
              byteCount: 95, bytes: "6e61706361742d73686f776e2d76310a746f6f6c4e616d653a340a426173680a696e707574507265766965773a32340a7b22636f6d6d616e64223a2267697420737461747573227d0a70726f6a6563744c6162656c3a360a4e61704361740a",
              digest: "ef7db7a70798acb8ecaff204a0239cded2be604277c0f2f10fea8f1f055922b7"),
        Shown(name: "empty", toolName: "", inputPreview: "", projectLabel: "",
              byteCount: 60, bytes: "6e61706361742d73686f776e2d76310a746f6f6c4e616d653a300a0a696e707574507265766965773a300a0a70726f6a6563744c6162656c3a300a0a",
              digest: "de4a32e1c763341a74cd02d9730220f63c2d28844fa277a46dfc03ff337fcf75"),
        Shown(name: "nfc", toolName: "Read", inputPreview: "{\"file_path\":\"/Users/me/Caf\u{E9}.md\"}", projectLabel: "Caf\u{E9}",
              byteCount: 104, bytes: "6e61706361742d73686f776e2d76310a746f6f6c4e616d653a340a526561640a696e707574507265766965773a33340a7b2266696c655f70617468223a222f55736572732f6d652f436166c3a92e6d64227d0a70726f6a6563744c6162656c3a350a436166c3a90a",
              digest: "d5235cacb8b9cb5bd330f0fccd6f7e3fd3a2a11f8b974ae8df2e4ddc36171723"),
        Shown(name: "nfd", toolName: "Read", inputPreview: "{\"file_path\":\"/Users/me/Cafe\u{301}.md\"}", projectLabel: "Cafe\u{301}",
              byteCount: 106, bytes: "6e61706361742d73686f776e2d76310a746f6f6c4e616d653a340a526561640a696e707574507265766965773a33350a7b2266696c655f70617468223a222f55736572732f6d652f43616665cc812e6d64227d0a70726f6a6563744c6162656c3a360a43616665cc810a",
              digest: "aae80692b31d7a5c5387ebf79067784460f693fdc2d5b994fb61057dfbaffcd4"),
        Shown(name: "combiningOrderA", toolName: "Bash", inputPreview: "a\u{301}\u{323}", projectLabel: "q",
              byteCount: 70, bytes: "6e61706361742d73686f776e2d76310a746f6f6c4e616d653a340a426173680a696e707574507265766965773a350a61cc81cca30a70726f6a6563744c6162656c3a310a710a",
              digest: "1adfb3b8aed8aaa7b0bc5b0f2eea39a0e6f67fde182c8564bb436e3db398f5ab"),
        Shown(name: "combiningOrderB", toolName: "Bash", inputPreview: "a\u{323}\u{301}", projectLabel: "q",
              byteCount: 70, bytes: "6e61706361742d73686f776e2d76310a746f6f6c4e616d653a340a426173680a696e707574507265766965773a350a61cca3cc810a70726f6a6563744c6162656c3a310a710a",
              digest: "1e734d5789d9a8b2371ee1d6fd55eed4b4f76c389d50353a7b3eec3e922aac6b"),
        Shown(name: "emojiZWJ", toolName: "Bash", inputPreview: "{\"command\":\"echo \u{1F469}\u{200D}\u{1F4BB}\"}", projectLabel: "\u{1F469}\u{200D}\u{1F4BB}",
              byteCount: 107, bytes: "6e61706361742d73686f776e2d76310a746f6f6c4e616d653a340a426173680a696e707574507265766965773a33300a7b22636f6d6d616e64223a226563686f20f09f91a9e2808df09f92bb227d0a70726f6a6563744c6162656c3a31310af09f91a9e2808df09f92bb0a",
              digest: "9e4b3fe4cf72d0ab68281252cbc2aac922e4e6b1b68d5e8ebad104c746a5016d"),
        Shown(name: "lineSeparators", toolName: "Write", inputPreview: "{\"content\":\"a\u{2028}b\"}", projectLabel: "x\u{2029}y",
              byteCount: 90, bytes: "6e61706361742d73686f776e2d76310a746f6f6c4e616d653a350a57726974650a696e707574507265766965773a31390a7b22636f6e74656e74223a2261e280a862227d0a70726f6a6563744c6162656c3a350a78e280a9790a",
              digest: "1e7bfa569a0f7ba0d2e42abe033670d2b8b381c3501841a7028b9b595d5b0992"),
        Shown(name: "crlf", toolName: "Write", inputPreview: "line1\r\nline2", projectLabel: "a\r\n",
              byteCount: 81, bytes: "6e61706361742d73686f776e2d76310a746f6f6c4e616d653a350a57726974650a696e707574507265766965773a31320a6c696e65310d0a6c696e65320a70726f6a6563744c6162656c3a330a610d0a0a",
              digest: "eaaef4c4152d9d5c531fe45df9404a81aff94ae59ee92be65cbb5f9e07cbf7a9"),
        Shown(name: "lf", toolName: "Write", inputPreview: "line1\nline2", projectLabel: "a\n",
              byteCount: 79, bytes: "6e61706361742d73686f776e2d76310a746f6f6c4e616d653a350a57726974650a696e707574507265766965773a31310a6c696e65310a6c696e65320a70726f6a6563744c6162656c3a320a610a0a",
              digest: "a23524b1552fa992accc8b67bed7a3773391213701502360418a65e506504053"),
        Shown(name: "invisibles", toolName: "Bash", inputPreview: "\u{FEFF}{}", projectLabel: "\u{200B}",
              byteCount: 72, bytes: "6e61706361742d73686f776e2d76310a746f6f6c4e616d653a340a426173680a696e707574507265766965773a350aefbbbf7b7d0a70726f6a6563744c6162656c3a330ae2808b0a",
              digest: "cbc96c3a217c4f5ce98d6f4a41f8d432c13cee47e48c90c76bbb823628e41721"),
        Shown(name: "whitespace", toolName: "Bash", inputPreview: "git  status\t\u{A0}", projectLabel: " ",
              byteCount: 80, bytes: "6e61706361742d73686f776e2d76310a746f6f6c4e616d653a340a426173680a696e707574507265766965773a31340a676974202073746174757309c2a00a70726f6a6563744c6162656c3a310a200a",
              digest: "de768cbe3a363f48780048868f216187f706c515c9692eb6e4e1c6d41358f4a7"),
        Shown(name: "fieldInjection", toolName: "Bash", inputPreview: "x\nprojectLabel:4\nevil", projectLabel: "",
              byteCount: 86, bytes: "6e61706361742d73686f776e2d76310a746f6f6c4e616d653a340a426173680a696e707574507265766965773a32310a780a70726f6a6563744c6162656c3a340a6576696c0a70726f6a6563744c6162656c3a300a0a",
              digest: "d143b92e4ba5d5352016470967d7f9304eb67a2c063b9b29df4a71070ce4ebd0"),
        Shown(name: "splitA", toolName: "ab", inputPreview: "c", projectLabel: "",
              byteCount: 63, bytes: "6e61706361742d73686f776e2d76310a746f6f6c4e616d653a320a61620a696e707574507265766965773a310a630a70726f6a6563744c6162656c3a300a0a",
              digest: "9af6bf6a237093dd6db2fa531d6be34b82c761917b2d3ca6932ab28563b39100"),
        Shown(name: "splitB", toolName: "a", inputPreview: "bc", projectLabel: "",
              byteCount: 63, bytes: "6e61706361742d73686f776e2d76310a746f6f6c4e616d653a310a610a696e707574507265766965773a320a62630a70726f6a6563744c6162656c3a300a0a",
              digest: "96f262208ea8ab4c43238fbe1cbc4f39ec1bc22050a1271a0fc0ff52729fcc32"),
    ]

    static let maxLengths = Shown(name: "maxLengths", toolName: String(repeating: "T", count: 64),
                                  inputPreview: "{\"content\":\"" + String(repeating: "x", count: 32_754) + "\"}",
                                  projectLabel: String(repeating: "\u{E9}", count: 512),
                                  byteCount: 33924, bytes: nil,
                                  digest: "82284009076a96e189661df46add8f9fb35413ffbd62a84ef0ff2f6e3c8c445d")

    static let decisions: [Decision] = [
        Decision(name: "allow", wireVersion: 1, promptID: "0123456789abcdef0123456789abcdef", verdict: .allow, decidedAt: 1763942400,
                 shown: "ef7db7a70798acb8ecaff204a0239cded2be604277c0f2f10fea8f1f055922b7",
                 message: "6e61706361742d6465636973696f6e2d76310a776972653a310a70726f6d70743a30313233343536373839616263646566303132333435363738396162636465660a766572646963743a616c6c6f770a646563696465643a313736333934323430300a73686f776e3a656637646237613730373938616362386563616666323034613032333963646564326265363034323737633066326631306665613866316630353539323262370a",
                 digest: "fbb5d67f0a9551ef7d28fedad51737e4dd9878e8117dfedbcf80fc6229a1b441"),
        Decision(name: "deny", wireVersion: 1, promptID: "0123456789abcdef0123456789abcdef", verdict: .deny, decidedAt: 1763942400,
                 shown: "ef7db7a70798acb8ecaff204a0239cded2be604277c0f2f10fea8f1f055922b7",
                 message: "6e61706361742d6465636973696f6e2d76310a776972653a310a70726f6d70743a30313233343536373839616263646566303132333435363738396162636465660a766572646963743a64656e790a646563696465643a313736333934323430300a73686f776e3a656637646237613730373938616362386563616666323034613032333963646564326265363034323737633066326631306665613866316630353539323262370a",
                 digest: "55d766369cbf8637491f97b81ada55898475f883968b5b06d319f812e0b8fb5b"),
        Decision(name: "epoch", wireVersion: 1, promptID: "00000000000000000000000000000001", verdict: .allow, decidedAt: 0,
                 shown: "0000000000000000000000000000000000000000000000000000000000000000",
                 message: "6e61706361742d6465636973696f6e2d76310a776972653a310a70726f6d70743a30303030303030303030303030303030303030303030303030303030303030310a766572646963743a616c6c6f770a646563696465643a300a73686f776e3a303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a",
                 digest: "b6494c2a409d64a49432d05b833d2e66ede7b0437f9d27c2873afc98e015b0dc"),
        Decision(name: "max", wireVersion: 1, promptID: "ffffffffffffffffffffffffffffffff", verdict: .deny, decidedAt: 9223372036854775807,
                 shown: "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
                 message: "6e61706361742d6465636973696f6e2d76310a776972653a310a70726f6d70743a66666666666666666666666666666666666666666666666666666666666666660a766572646963743a64656e790a646563696465643a393232333337323033363835343737353830370a73686f776e3a666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660a",
                 digest: "471ae5178a55b20c7a39d1089cd59d08a4dbcba0c6839b78cc4935d72cb73cba"),
        Decision(name: "nfdShown", wireVersion: 1, promptID: "8f14e45fceea167a5a36dedd4bea2543", verdict: .allow, decidedAt: 1763942459,
                 shown: "aae80692b31d7a5c5387ebf79067784460f693fdc2d5b994fb61057dfbaffcd4",
                 message: "6e61706361742d6465636973696f6e2d76310a776972653a310a70726f6d70743a38663134653435666365656131363761356133366465646434626561323534330a766572646963743a616c6c6f770a646563696465643a313736333934323435390a73686f776e3a616165383036393262333164376135633533383765626637393036373738343436306636393366646332643562393934666236313035376466626166666364340a",
                 digest: "26afbb6535e80cb4bb86ef330e8767200cf3c88d0cf6ed49551d19fd4451b5e6"),
    ]

    static let payloads: [Payload] = [
        Payload(name: "zeros", nonce: "0000000000000000000000000000000000000000000000000000000000000000",
                payload: "napcat-pair-v1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
        Payload(name: "ones", nonce: "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
                payload: "napcat-pair-v1:__________________________________________8"),
        Payload(name: "counting", nonce: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
                payload: "napcat-pair-v1:AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"),
        Payload(name: "dashUnderscore", nonce: "fbefbefffffffbefbefffffffbefbefffffffbefbefffffffbefbefffffffbef",
                payload: "napcat-pair-v1:----____----____----____----____----____--8"),
    ]

    static let confirmations: [Confirmation] = [
        Confirmation(name: "counting", wireVersion: 1, nonce: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
                     publicKey: "040102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40",
                     message: "6e61706361742d706169722d636f6e6669726d2d76310a7769726556657273696f6e3a310a310a7075626c69634b65793a36350a040102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f400a",
                     mac: "9c2c2a106c8b48c5a10bc503f2eac772bc615e05ba3262f73454f2155315656c"),
        Confirmation(name: "zerosNonce", wireVersion: 1, nonce: "0000000000000000000000000000000000000000000000000000000000000000",
                     publicKey: "04ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
                     message: "6e61706361742d706169722d636f6e6669726d2d76310a7769726556657273696f6e3a310a310a7075626c69634b65793a36350a04ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff0a",
                     mac: "ae72809a519cff055a399314cffebd399fd3755a34067b0745687787b83becaf"),
    ]

    static let proofs: [Proof] = [
        Proof(name: "counting", nonce: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
              publicKey: "040102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40",
              message: "6e61706361742d706169722d70726f6f662d76310a6e6f6e63653a33320a000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f0a7075626c69634b65793a36350a040102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f400a",
              digest: "8364a4e5043b9eb9c67643ca7caa5f21fdd8c65587c75f8061e8787502f93e71"),
        Proof(name: "zerosNonce", nonce: "0000000000000000000000000000000000000000000000000000000000000000",
              publicKey: "04ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
              message: "6e61706361742d706169722d70726f6f662d76310a6e6f6e63653a33320a00000000000000000000000000000000000000000000000000000000000000000a7075626c69634b65793a36350a04ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff0a",
              digest: "918fa0d1c5b527e5fb7c1453d5757b52bed3a50f37c85d335e1ebd0790ed00be"),
    ]

    static let recordNames: [RecordName] = [
        RecordName(name: "zeros", nonce: "0000000000000000000000000000000000000000000000000000000000000000",
                   input: "6e61706361742d706169722d6e616d652d76310000000000000000000000000000000000000000000000000000000000000000",
                   recordName: "90d25eac6ef39796d7d87e4d0539908cff7d6a323d24848d059bffc226387a6b"),
        RecordName(name: "counting", nonce: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
                   input: "6e61706361742d706169722d6e616d652d7631000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
                   recordName: "cb2786474ca52d1254c260a158ace26a6ebdc3aef444d1284c27637dc08fbda7"),
        RecordName(name: "ones", nonce: "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
                   input: "6e61706361742d706169722d6e616d652d7631ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
                   recordName: "34d1b228474af4bf14a3d8ac4ba62811445a9ea0e014e88cd4fe01e56d0e5880"),
    ]

    // MARK: Helpers (the suite's own hex: it never borrows the wire's)

    static func hex(_ bytes: some Sequence<UInt8>) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    static func bytes(_ hex: String) -> [UInt8] {
        let digits = Array(hex.utf8)
        return stride(from: 0, to: digits.count - 1, by: 2).map {
            UInt8(String(decoding: digits[$0...$0 + 1], as: UTF8.self), radix: 16) ?? 0
        }
    }

    static func sha256(_ bytes: [UInt8]) -> [UInt8] { Array(SHA256.hash(data: bytes)) }

    static func hmacSHA256(_ message: [UInt8], key: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    static func row(_ name: String) -> Shown { shown.first { $0.name == name } ?? maxLengths }

    static func input(_ row: Shown) -> [UInt8] {
        ApprovalSigning.shownDigestInput(toolName: row.toolName, inputPreview: row.inputPreview, projectLabel: row.projectLabel)
    }

    // MARK: The table itself

    @Test func everyPinnedValueIsLowercaseHex() {
        let pinned = Self.shown.compactMap(\.bytes) + Self.shown.map(\.digest) + [Self.maxLengths.digest]
            + Self.decisions.flatMap { [$0.shown, $0.message, $0.digest] } + Self.payloads.map(\.nonce)
            + Self.confirmations.flatMap { [$0.nonce, $0.publicKey, $0.message, $0.mac] }
            + Self.proofs.flatMap { [$0.nonce, $0.publicKey, $0.message, $0.digest] }
            + Self.recordNames.flatMap { [$0.nonce, $0.input, $0.recordName] }
        #expect(pinned.count == 75, "vacuity: every row's values are checked")
        for value in pinned {
            #expect(!value.isEmpty && value.count % 2 == 0 && value.allSatisfy { "0123456789abcdef".contains($0) },
                    "'\(value.prefix(16))…' is not lowercase hex")
        }
        #expect(Self.bytes("00ff7f10") == [0x00, 0xff, 0x7f, 0x10] && Self.hex([0x00, 0xff, 0x7f, 0x10]) == "00ff7f10")
        let everyByte = Array(UInt8(0)...UInt8(255))
        #expect(ApprovalSigning.lowercaseHex(everyByte) == Self.hex(everyByte), "the wire's hex is the suite's")
    }

    @Test func theDomainsAndSizesArePinned() {
        #expect(ApprovalSigning.decisionDomain == "napcat-decision-v1")
        #expect(ApprovalSigning.shownDomain == "napcat-shown-v1")
        #expect(ApprovalSigning.pairDomain == "napcat-pair-v1")
        #expect(ApprovalSigning.pairConfirmDomain == "napcat-pair-confirm-v1")
        #expect(ApprovalSigning.pairProofDomain == "napcat-pair-proof-v1")
        #expect(ApprovalSigning.pairNameLabel == "napcat-pair-name-v1")
        let domains = [ApprovalSigning.decisionDomain, ApprovalSigning.shownDomain, ApprovalSigning.pairDomain,
                       ApprovalSigning.pairConfirmDomain, ApprovalSigning.pairProofDomain, ApprovalSigning.pairNameLabel]
        #expect(Set(domains).count == domains.count)
        for first in domains {
            for second in domains where first != second {
                #expect(!second.hasPrefix(first), "\(first) opens \(second): a message of one could start like the other")
            }
        }
        #expect(ApprovalSigning.signatureByteCount == 64)
        #expect(ApprovalSigning.digestByteCount == 32)
        #expect(ApprovalSigning.pairingNonceByteCount == 32, "a 256-bit nonce")
        #expect(ApprovalSigning.pairingNonceCharacterCount == 43, "32 bytes as unpadded base64url")
        #expect(ApprovalSigning.publicKeyByteCount == 65, "x9.63: 0x04, x, y")
        #expect(ApprovalSigning.recordNameHexDigits == 64)
    }

    /// Each message opens with its own domain and a separator, so no
    /// signature or MAC made for one can be read as another.
    @Test func everyMessageOpensWithItsOwnDomain() {
        func opens(_ message: [UInt8], _ head: String) -> Bool { message.starts(with: Array(head.utf8)) }
        #expect(opens(Self.bytes(Self.decisions[0].message), ApprovalSigning.decisionDomain + "\n"))
        #expect(opens(Self.input(Self.row("ascii")), ApprovalSigning.shownDomain + "\n"))
        #expect(opens(Self.bytes(Self.confirmations[0].message), ApprovalSigning.pairConfirmDomain + "\n"))
        #expect(opens(Self.bytes(Self.proofs[0].message), ApprovalSigning.pairProofDomain + "\n"))
        #expect(opens(Array(Self.payloads[0].payload.utf8), ApprovalSigning.pairDomain + ":"))
        #expect(opens(Self.bytes(Self.recordNames[0].input), ApprovalSigning.pairNameLabel))
    }

    // MARK: The shown-digest input (napcat-shown-v1)

    @Test(arguments: ApprovalSigningVectorTests.shown + [ApprovalSigningVectorTests.maxLengths])
    func theShownDigestInputIsPinned(_ row: Shown) {
        let input = Self.input(row)
        #expect(input.count == row.byteCount, "\(row.name)")
        if let pinned = row.bytes { #expect(Self.hex(input) == pinned, "\(row.name)") }
        #expect(Self.hex(Self.sha256(input)) == row.digest, "\(row.name)")
    }

    @Test func canonicallyEquivalentTextIsStillOtherBytes() {
        for (first, second) in [("nfc", "nfd"), ("combiningOrderA", "combiningOrderB")] {
            let a = Self.row(first), b = Self.row(second)
            #expect(a.inputPreview == b.inputPreview, "vacuity: Swift reads \(first) and \(second) as equal text")
            #expect(Array(a.inputPreview.utf8) != Array(b.inputPreview.utf8), "vacuity: \(first) and \(second) are other bytes")
            #expect(a.digest != b.digest, "\(first) and \(second) must digest differently: the digest is over bytes")
        }
        #expect(Self.row("nfc").projectLabel == Self.row("nfd").projectLabel)
    }

    @Test func theLengthPrefixCountsBytesNotCharacters() {
        #expect("a\r\n".count == 2 && Array("a\r\n".utf8).count == 3, "vacuity: CRLF is one Character, two bytes")
        let technologist = "\u{1F469}\u{200D}\u{1F4BB}"
        #expect(technologist.count == 1 && Array(technologist.utf8).count == 11, "vacuity: one Character, eleven bytes")
        let crlf = Self.hex(Self.input(Self.row("crlf")))
        #expect(crlf.contains(Self.hex(Array("projectLabel:3\n".utf8))))
        let emoji = Self.hex(Self.input(Self.row("emojiZWJ")))
        #expect(emoji.contains(Self.hex(Array("projectLabel:11\n".utf8))))
        let separators = Self.hex(Self.input(Self.row("lineSeparators")))
        #expect(separators.contains(Self.hex(Array("projectLabel:5\n".utf8))), "U+2029 is three bytes, not a line end")
        #expect(Self.row("crlf").digest != Self.row("lf").digest)
    }

    @Test func aFieldNeverSpillsIntoTheNext() {
        #expect(Self.row("splitA").digest != Self.row("splitB").digest, "ab|c and a|bc are other inputs")
        let injected = Self.input(Self.row("fieldInjection"))
        #expect(Self.hex(injected).contains(Self.hex(Array("inputPreview:21\n".utf8))), "the forged header stays in the preview")
        let tail = Array("projectLabel:0\n\n".utf8)
        #expect(Array(injected.suffix(tail.count)) == tail, "the real (empty) label is the last field")
    }

    @Test func theBoundaryRowsSpanTheGatesLimits() {
        #expect(Array(Self.maxLengths.toolName.utf8).count == ApprovalGate.maxToolNameBytes)
        #expect(Array(Self.maxLengths.inputPreview.utf8).count == ApprovalGate.maxPreviewBytes)
        #expect(Array(Self.maxLengths.projectLabel.utf8).count == 1_024)
        #expect(Self.row("empty").bytes == Self.hex(Array("napcat-shown-v1\ntoolName:0\n\ninputPreview:0\n\nprojectLabel:0\n\n".utf8)))
    }

    // MARK: The decision message (napcat-decision-v1)

    @Test(arguments: ApprovalSigningVectorTests.decisions)
    func theDecisionMessageIsPinned(_ row: Decision) throws {
        let id = try #require(PromptID(hex: row.promptID))
        let message = try #require(ApprovalSigning.decisionMessage(wireVersion: row.wireVersion, promptID: id, verdict: row.verdict,
                                                                   decidedAt: row.decidedAt, shownDigest: Self.bytes(row.shown)))
        #expect(Self.hex(message) == row.message, "\(row.name)")
        #expect(Self.hex(Self.sha256(message)) == row.digest, "\(row.name)")
        let lines = message.split(separator: 0x0a, omittingEmptySubsequences: false)
        #expect(lines.count == 7 && lines.last?.isEmpty == true, "\(row.name): six lines, each ending in a line feed")
        #expect(message.allSatisfy { $0 == 0x0a || (0x20..<0x7f).contains($0) }, "\(row.name): printable ASCII and line feeds only")
    }

    @Test func aDecisionSignsTheDigestOfTheCopyItShowed() {
        #expect(Self.decisions.first { $0.name == "allow" }?.shown == Self.row("ascii").digest)
        #expect(Self.decisions.first { $0.name == "nfdShown" }?.shown == Self.row("nfd").digest)
        let allow = Self.decisions[0], deny = Self.decisions[1]
        #expect(allow.promptID == deny.promptID && allow.decidedAt == deny.decidedAt && allow.digest != deny.digest,
                "the verdict is signed")
    }

    @Test func theDecisionBuilderRefusesValuesOutsideItsAlphabet() throws {
        let id = try #require(PromptID(hex: "0123456789abcdef0123456789abcdef"))
        let digest = [UInt8](repeating: 0, count: 32)
        #expect(ApprovalSigning.decisionMessage(wireVersion: 1, promptID: id, verdict: .allow, decidedAt: 0, shownDigest: digest) != nil)
        #expect(ApprovalSigning.decisionMessage(wireVersion: 1, promptID: id, verdict: .allow, decidedAt: -1, shownDigest: digest) == nil)
        #expect(ApprovalSigning.decisionMessage(wireVersion: -1, promptID: id, verdict: .allow, decidedAt: 0, shownDigest: digest) == nil)
        for count in [0, 31, 33, 64] {
            #expect(ApprovalSigning.decisionMessage(wireVersion: 1, promptID: id, verdict: .deny, decidedAt: 0,
                                                    shownDigest: [UInt8](repeating: 0, count: count)) == nil, "a \(count)-byte digest")
        }
        // The prompt line is the record-name form: one spelling, nothing else.
        for hex in ["0123456789ABCDEF0123456789abcdef", "0123456789abcdef0123456789abcde", "0123456789abcdef0123456789abcdef0",
                    "00000000000000000000000000000000", "0123456789abcdef0123456789abcdeg", " 123456789abcdef0123456789abcdef"] {
            #expect(PromptID(hex: hex) == nil, "'\(hex)'")
        }
    }

    // MARK: The pairing QR payload (napcat-pair-v1)

    @Test(arguments: ApprovalSigningVectorTests.payloads)
    func thePairingPayloadIsPinned(_ row: Payload) {
        #expect(ApprovalSigning.pairingPayload(nonce: Self.bytes(row.nonce)) == row.payload, "\(row.name)")
        #expect(ApprovalSigning.pairingNonce(fromPayload: row.payload) == Self.bytes(row.nonce), "\(row.name)")
        #expect(row.payload.utf8.count == 58, "\(row.name)")
    }

    @Test func thePairingPayloadIsReadStrictly() {
        let valid = Self.payloads[2].payload
        let body = String(valid.dropFirst(ApprovalSigning.pairDomain.count + 1))
        let dashed = Self.payloads[3].payload
        #expect(dashed.contains("-") && dashed.contains("_"), "vacuity: a row holds both URL-safe characters")
        let refused: [(String, String)] = [
            ("empty", ""),
            ("the prefix only", "napcat-pair-v1:"),
            ("an uppercase prefix", "NAPCAT-PAIR-V1:" + body),
            ("another version", "napcat-pair-v2:" + body),
            ("no colon", "napcat-pair-v1" + body),
            ("a semicolon", "napcat-pair-v1;" + body),
            ("a leading space", " " + valid),
            ("a space after the colon", "napcat-pair-v1: " + body),
            ("a byte order mark", "\u{FEFF}" + valid),
            ("a trailing line feed", valid + "\n"),
            ("a trailing CRLF", valid + "\r\n"),
            ("a trailing space", valid + " "),
            ("padding", valid + "="),
            ("one character short", String(valid.dropLast())),
            ("one character long", valid + "A"),
            ("the prefix twice", "napcat-pair-v1:" + valid),
            ("standard base64", dashed.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")),
            ("a dot", "napcat-pair-v1:." + body.dropFirst()),
            ("a space inside", "napcat-pair-v1:" + body.prefix(20) + " " + body.dropFirst(21)),
            ("a NUL", String(valid.dropLast()) + "\u{0}"),
            ("a fullwidth letter", "napcat-pair-v1:\u{FF21}" + body.dropFirst()),
            ("a non-canonical last character (zeros)", "napcat-pair-v1:" + String(repeating: "A", count: 42) + "B"),
            ("a non-canonical last character (ones)", "napcat-pair-v1:" + String(repeating: "_", count: 42) + "9"),
        ]
        for (name, text) in refused {
            #expect(ApprovalSigning.pairingNonce(fromPayload: text) == nil, "\(name) must be refused")
        }
        for count in [0, 16, 31, 33, 64] {
            #expect(ApprovalSigning.pairingPayload(nonce: [UInt8](repeating: 7, count: count)) == nil, "a \(count)-byte nonce")
        }
        for seed in 0..<64 {
            let nonce = (0..<32).map { UInt8(truncatingIfNeeded: $0 * 37 + seed * 11) }
            let payload = ApprovalSigning.pairingPayload(nonce: nonce)
            #expect(payload.flatMap(ApprovalSigning.pairingNonce(fromPayload:)) == nonce, "seed \(seed) round-trips")
        }
    }

    // MARK: The pairing response (napcat-pair-confirm-v1, napcat-pair-proof-v1, napcat-pair-name-v1)

    @Test(arguments: ApprovalSigningVectorTests.confirmations)
    func theConfirmationMessageIsPinned(_ row: Confirmation) throws {
        let message = try #require(ApprovalSigning.pairingConfirmationMessage(wireVersion: row.wireVersion,
                                                                              publicKey: Self.bytes(row.publicKey)))
        #expect(Self.hex(message) == row.message, "\(row.name)")
        #expect(Self.hex(Self.hmacSHA256(message, key: Self.bytes(row.nonce))) == row.mac, "\(row.name)")
    }

    @Test(arguments: ApprovalSigningVectorTests.proofs)
    func theProofMessageIsPinned(_ row: Proof) throws {
        let message = try #require(ApprovalSigning.pairingProofMessage(nonce: Self.bytes(row.nonce), publicKey: Self.bytes(row.publicKey)))
        #expect(Self.hex(message) == row.message, "\(row.name)")
        #expect(Self.hex(Self.sha256(message)) == row.digest, "\(row.name)")
    }

    @Test(arguments: ApprovalSigningVectorTests.recordNames)
    func theRecordNameIsPinned(_ row: RecordName) throws {
        let input = try #require(ApprovalSigning.pairingRecordNameInput(nonce: Self.bytes(row.nonce)))
        #expect(Self.hex(input) == row.input, "\(row.name)")
        let name = try #require(ApprovalSigning.pairingRecordName(digest: Self.sha256(input)))
        #expect(name == row.recordName, "\(row.name)")
        #expect(name.count == ApprovalSigning.recordNameHexDigits)
    }

    @Test func thePairingBuildersTakeAKeyAndANonceOnly() {
        let key = Self.bytes(Self.confirmations[0].publicKey)
        let nonce = Self.bytes(Self.proofs[0].nonce)
        var compressedPrefix = key
        compressedPrefix[0] = 0x03
        for bad in [Array(key.dropLast()), key + [0], compressedPrefix, [], Array(key.dropFirst())] {
            #expect(ApprovalSigning.pairingConfirmationMessage(wireVersion: 1, publicKey: bad) == nil, "a \(bad.count)-byte key")
            #expect(ApprovalSigning.pairingProofMessage(nonce: nonce, publicKey: bad) == nil, "a \(bad.count)-byte key")
        }
        #expect(ApprovalSigning.pairingConfirmationMessage(wireVersion: -1, publicKey: key) == nil)
        for count in [0, 31, 33] {
            let wrong = [UInt8](repeating: 1, count: count)
            #expect(ApprovalSigning.pairingProofMessage(nonce: wrong, publicKey: key) == nil, "a \(count)-byte nonce")
            #expect(ApprovalSigning.pairingRecordNameInput(nonce: wrong) == nil, "a \(count)-byte nonce")
            #expect(ApprovalSigning.pairingRecordName(digest: wrong) == nil, "a \(count)-byte digest")
        }
    }

    /// The builders take the key form CryptoKit really writes, and a real
    /// signature's raw form is the 64 bytes the decision field carries.
    @Test func aRealP256KeyAndSignatureHaveTheWireSizes() throws {
        let privateKey = P256.Signing.PrivateKey()
        let x963 = Array(privateKey.publicKey.x963Representation)
        #expect(x963.count == ApprovalSigning.publicKeyByteCount && x963.first == 0x04)
        #expect(ApprovalSigning.pairingProofMessage(nonce: [UInt8](repeating: 9, count: 32), publicKey: x963) != nil)
        #expect(ApprovalSigning.pairingConfirmationMessage(wireVersion: 1,
                                                           publicKey: Array(privateKey.publicKey.compressedRepresentation)) == nil)
        let signature = try privateKey.signature(for: Self.bytes(Self.decisions[0].message))
        #expect(signature.rawRepresentation.count == ApprovalSigning.signatureByteCount)
    }
}
// MARK: - END SIGNING VECTORS
