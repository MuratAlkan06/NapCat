// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import NapCatWire
import Testing

/// #248: the forwarding policy model, pure and unwired. The stored text has
/// one spelling, which the reader takes and nothing else; the effective set
/// is the listed commands alone unless every condition holds; one function
/// is the only way to a wider set; the two identity facts are false
/// literals; and no source but the model's own file names its types.
struct ApprovalForwardingPolicyTests {
    typealias Sources = ApprovalChannelStructureTests.Sources
    typealias RecordPath = ApprovalRecordPathStructureTests

    // MARK: - Fixtures

    /// The pairing the texts name (00 01 … 1f), and another one.
    static let pairing: [UInt8] = Array(0..<32)
    static let otherPairing: [UInt8] = Array(repeating: 0xab, count: 32)
    static let pairingHex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

    static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    /// `lines`, each ending in a line feed.
    static func text(_ lines: [String]) -> [UInt8] { bytes(lines.map { $0 + "\n" }.joined()) }

    /// The seven lines, with every value given.
    static func lines(pairing: String = pairingHex, developer: String = "on", privileged: String = "off",
                      claudeConfig: String = "off", secrets: String = "off", phoneSwitch: String = "on") -> [String] {
        ["napcat-forwarding-v1", "pairing:" + pairing, "developer:" + developer, "privileged:" + privileged,
         "claudeConfig:" + claudeConfig, "secrets:" + secrets, "phoneSwitch:" + phoneSwitch]
    }

    /// A canonical text, line for line, and as bytes.
    static let canonical: [String] = lines()
    static let canonicalText: [UInt8] = text(canonical)

    /// The canonical lines with line `index` replaced, inserted before
    /// `index`, removed, or two lines swapped.
    static func replacing(_ index: Int, with line: String) -> [UInt8] {
        var copy = canonical
        copy[index] = line
        return text(copy)
    }

    static func inserting(_ line: String, at index: Int) -> [UInt8] {
        var copy = canonical
        copy.insert(line, at: index)
        return text(copy)
    }

    static func removing(_ index: Int) -> [UInt8] {
        var copy = canonical
        copy.remove(at: index)
        return text(copy)
    }

    static func swapping(_ first: Int, _ second: Int) -> [UInt8] {
        var copy = canonical
        copy.swapAt(first, second)
        return text(copy)
    }

    /// The text with the `privileged` line's value replaced.
    static func admin(_ value: String) -> [UInt8] { replacing(3, with: "privileged:" + value) }

    // MARK: - The closed kinds

    @Test func theKindsAreClosedAndPinned() {
        #expect(ApprovalPromptKind.allCases == [.listedCommand, .shell, .fileEdit, .web, .outsideRead, .connector])
        #expect(ApprovalRiskyKind.allCases.map(\.rawValue) == ["privileged", "claudeConfig", "secrets"])
        #expect(ApprovalSwitchOrigin.allCases.map(\.rawValue) == ["mac", "phone"])
    }

    @Test func theTextsConstantsArePinned() {
        #expect(ApprovalForwardingPolicy.header == "napcat-forwarding-v1")
        #expect(ApprovalForwardingPolicy.lineNames == ["pairing", "developer", "privileged", "claudeConfig", "secrets", "phoneSwitch"])
        #expect(ApprovalForwardingPolicy.latestTime == 1 << 53, "2^53 s, the decision verifier's bound")
    }

    // MARK: - Accepted texts

    struct Accepted: Sendable, CustomTestStringConvertible {
        let name: String
        let lines: [String]
        let pairing: [UInt8]
        let developer: Bool
        let privileged: ApprovalRiskySwitch
        let claudeConfig: ApprovalRiskySwitch
        let secrets: ApprovalRiskySwitch
        let phoneSwitch: Bool
        var testDescription: String { name }
    }

    static let acceptedRows: [Accepted] = [
        Accepted(name: "the everyday kinds, every risky kind off", lines: lines(),
                 pairing: pairing, developer: true, privileged: .off, claudeConfig: .off, secrets: .off, phoneSwitch: true),
        Accepted(name: "everything off", lines: lines(developer: "off", phoneSwitch: "off"),
                 pairing: pairing, developer: false, privileged: .off, claudeConfig: .off, secrets: .off, phoneSwitch: false),
        Accepted(name: "privileged on at the Mac", lines: lines(privileged: "on mac 1764288000"),
                 pairing: pairing, developer: true, privileged: .on(origin: .mac, at: 1_764_288_000), claudeConfig: .off,
                 secrets: .off, phoneSwitch: true),
        Accepted(name: "claudeConfig on from the iPhone", lines: lines(claudeConfig: "on phone 1764288123", phoneSwitch: "off"),
                 pairing: pairing, developer: true, privileged: .off, claudeConfig: .on(origin: .phone, at: 1_764_288_123),
                 secrets: .off, phoneSwitch: false),
        Accepted(name: "secrets on at time 0", lines: lines(secrets: "on mac 0"),
                 pairing: pairing, developer: true, privileged: .off, claudeConfig: .off, secrets: .on(origin: .mac, at: 0),
                 phoneSwitch: true),
        Accepted(name: "all three on, mixed origins, the latest time",
                 lines: lines(privileged: "on phone 9007199254740992", claudeConfig: "on mac 1", secrets: "on phone 1234567890"),
                 pairing: pairing, developer: true, privileged: .on(origin: .phone, at: 9_007_199_254_740_992),
                 claudeConfig: .on(origin: .mac, at: 1), secrets: .on(origin: .phone, at: 1_234_567_890), phoneSwitch: true),
        Accepted(name: "the everyday kinds off, every risky kind on",
                 lines: lines(developer: "off", privileged: "on mac 10", claudeConfig: "on mac 20", secrets: "on mac 30"),
                 pairing: pairing, developer: false, privileged: .on(origin: .mac, at: 10), claudeConfig: .on(origin: .mac, at: 20),
                 secrets: .on(origin: .mac, at: 30), phoneSwitch: true),
        Accepted(name: "an all-zero pairing", lines: lines(pairing: String(repeating: "0", count: 64)),
                 pairing: Array(repeating: 0, count: 32), developer: true, privileged: .off, claudeConfig: .off, secrets: .off,
                 phoneSwitch: true),
        Accepted(name: "an all-f pairing", lines: lines(pairing: String(repeating: "f", count: 64)),
                 pairing: Array(repeating: 0xff, count: 32), developer: true, privileged: .off, claudeConfig: .off, secrets: .off,
                 phoneSwitch: true),
    ]

    /// Each accepted text reads as its policy, and the writer spells that
    /// policy as exactly the text.
    @Test(arguments: acceptedRows)
    func anAcceptedTextRoundTrips(_ row: Accepted) throws {
        let expected = try #require(ApprovalStoredPolicy(pairing: row.pairing, developer: row.developer, privileged: row.privileged,
                                                         claudeConfig: row.claudeConfig, secrets: row.secrets,
                                                         phoneSwitch: row.phoneSwitch))
        let given = Self.text(row.lines)
        #expect(ApprovalForwardingPolicy.read(given) == expected)
        #expect(ApprovalForwardingPolicy.text(of: expected) == given, "the writer's spelling is the one text")
    }

    // MARK: - Refused texts

    struct Refused: Sendable, CustomTestStringConvertible {
        let name: String
        let bytes: [UInt8]
        init(_ name: String, _ bytes: [UInt8]) {
            self.name = name
            self.bytes = bytes
        }
        var testDescription: String { name }
    }

    static let refusedRows: [Refused] = [
        // The whole text.
        Refused("empty", []),
        Refused("a lone line feed", [0x0a]),
        Refused("the header alone", bytes("napcat-forwarding-v1\n")),
        // The header.
        Refused("a newer header", replacing(0, with: "napcat-forwarding-v2")),
        Refused("an older header", replacing(0, with: "napcat-forwarding-v0")),
        Refused("the header in capitals", replacing(0, with: "NAPCAT-FORWARDING-V1")),
        Refused("no header", removing(0)),
        Refused("the header twice", inserting(canonical[0], at: 0)),
        Refused("the header last", text(Array(canonical.dropFirst()) + [canonical[0]])),
        // The lines.
        Refused("an unknown line in the middle", inserting("extra:on", at: 3)),
        Refused("an unknown line at the end", text(canonical + ["future:on"])),
        Refused("an unknown line in place of one", replacing(5, with: "tokens:off")),
        Refused("a line repeated", inserting(canonical[2], at: 3)),
        Refused("the last line repeated", text(canonical + [canonical[6]])),
        Refused("a line missing", removing(5)),
        Refused("the last line missing", text(Array(canonical.dropLast()))),
        Refused("pairing and developer swapped", swapping(1, 2)),
        Refused("two risky lines swapped", swapping(3, 4)),
        Refused("the first and last lines after the header swapped", swapping(1, 6)),
        Refused("an empty line inside", inserting("", at: 4)),
        Refused("a line name in capitals", replacing(2, with: "Developer:on")),
        Refused("no colon", replacing(2, with: "developer on")),
        Refused("a space before the colon", replacing(2, with: "developer :on")),
        Refused("a space after the colon", replacing(2, with: "developer: on")),
        Refused("two colons", replacing(2, with: "developer::on")),
        // On and off.
        Refused("developer neither on nor off", replacing(2, with: "developer:yes")),
        Refused("developer in capitals", replacing(2, with: "developer:ON")),
        Refused("developer empty", replacing(2, with: "developer:")),
        Refused("phoneSwitch misspelled", replacing(6, with: "phoneSwitch:of")),
        Refused("phoneSwitch as a boolean", replacing(6, with: "phoneSwitch:true")),
        // A risky switch.
        Refused("on without an origin", admin("on")),
        Refused("on without a time", admin("on mac")),
        Refused("on with a space and no time", admin("on mac ")),
        Refused("on with a time and no origin", admin("on 1764288000")),
        Refused("claudeConfig on without a time", replacing(4, with: "claudeConfig:on phone")),
        Refused("secrets on without an origin", replacing(5, with: "secrets:on")),
        Refused("an unknown origin", admin("on tablet 1764288000")),
        Refused("an origin in capitals", admin("on Mac 1764288000")),
        Refused("two spaces before the origin", admin("on  mac 1764288000")),
        Refused("two spaces before the time", admin("on mac  1764288000")),
        Refused("a word after the time", admin("on mac 1764288000 1")),
        Refused("the origin first", admin("mac on 1764288000")),
        Refused("off with a time", admin("off 1764288000")),
        Refused("off in capitals", admin("OFF")),
        Refused("on in capitals", admin("ON mac 1764288000")),
        // The time.
        Refused("a letter in the time", admin("on mac 17642880a0")),
        Refused("a negative time", admin("on mac -1")),
        Refused("a signed time", admin("on phone +1764288000")),
        Refused("a fractional time", admin("on mac 1764288000.5")),
        Refused("an exponent", admin("on mac 1e9")),
        Refused("a hex time", admin("on mac 0x10")),
        Refused("a digit separator", admin("on mac 1_764_288_000")),
        Refused("a leading zero", admin("on mac 01764288000")),
        Refused("zero twice", admin("on mac 00")),
        Refused("one past the latest time", admin("on mac 9007199254740993")),
        Refused("seventeen digits", admin("on mac 10000000000000000")),
        Refused("past Int's range", admin("on mac 99999999999999999999")),
        // The pairing.
        Refused("the pairing in capitals", replacing(1, with: "pairing:" + pairingHex.uppercased())),
        Refused("one capital hex digit", replacing(1, with: "pairing:" + String(pairingHex.dropLast()) + "F")),
        Refused("63 hex digits", replacing(1, with: "pairing:" + String(pairingHex.dropLast()))),
        Refused("65 hex digits", replacing(1, with: "pairing:" + pairingHex + "0")),
        Refused("a digit outside hex", replacing(1, with: "pairing:" + String(pairingHex.dropLast()) + "g")),
        Refused("a 0x prefix", replacing(1, with: "pairing:0x" + String(pairingHex.dropFirst(2)))),
        Refused("no pairing", replacing(1, with: "pairing:")),
        // The ending.
        Refused("no last line feed", Array(canonicalText.dropLast())),
        Refused("an extra line feed at the end", canonicalText + [0x0a]),
        Refused("a byte after the last line feed", canonicalText + bytes("x")),
        Refused("a line after the last line feed, unended", canonicalText + bytes("phoneSwitch:on")),
        Refused("a space after the last line feed", canonicalText + bytes(" ")),
        Refused("a NUL after the last line feed", canonicalText + [0]),
        // Bytes.
        Refused("CRLF line ends", bytes(canonical.map { $0 + "\r\n" }.joined())),
        Refused("one CR before a line feed", replacing(2, with: "developer:on\r")),
        Refused("a CR as the last line end", Array(canonicalText.dropLast()) + [0x0d]),
        Refused("a space leading a line", replacing(2, with: " developer:on")),
        Refused("a space trailing a line", replacing(2, with: "developer:on ")),
        Refused("a space trailing the header", replacing(0, with: "napcat-forwarding-v1 ")),
        Refused("a space leading the header", replacing(0, with: " napcat-forwarding-v1")),
        Refused("a tab before a value", replacing(2, with: "developer:\ton")),
        Refused("a byte order mark", [0xef, 0xbb, 0xbf] + canonicalText),
        Refused("a non-ASCII letter", replacing(2, with: "developer:\u{F6}n")),
        Refused("a full-width digit in the time", admin("on mac 176428800\u{FF10}")),
        Refused("a full-width digit in the pairing", replacing(1, with: "pairing:" + String(pairingHex.dropLast()) + "\u{FF10}")),
        Refused("a non-breaking space before the time", admin("on mac\u{A0}1764288000")),
        Refused("a NUL inside a line", replacing(2, with: "developer:on\u{0}")),
        Refused("a DEL byte", replacing(2, with: "developer:on\u{7F}")),
        Refused("a byte that is not UTF-8", Array(canonicalText.dropLast(2)) + [0xff, 0x0a]),
    ]

    /// Every refused text is refused, and gives the listed commands alone
    /// under every condition that would otherwise widen.
    @Test(arguments: refusedRows)
    func aMalformedTextIsRefused(_ row: Refused) {
        #expect(row.bytes != Self.canonicalText, "vacuity: the row bends the canonical text")
        #expect(ApprovalForwardingPolicy.read(row.bytes) == nil)
        #expect(Self.effectiveWithEveryFact(row.bytes, pairingInForce: Self.pairing) == .listedOnly)
    }

    /// The rows are distinct, so each is its own case.
    @Test func theRefusedRowsAreDistinct() {
        #expect(Set(Self.refusedRows.map(\.bytes)).count == Self.refusedRows.count)
        #expect(Set(Self.refusedRows.map(\.name)).count == Self.refusedRows.count)
        #expect(ApprovalForwardingPolicy.read(Self.canonicalText) != nil, "vacuity: the text every row bends is accepted")
    }

    // MARK: - The writer

    /// The eight combinations of the three risky switches: bit `k` of
    /// `mask` is the k-th of privileged, claudeConfig and secrets, each
    /// turned on from `origin` at a time of its own.
    static func switches(_ mask: Int, origin: ApprovalSwitchOrigin) -> [ApprovalRiskySwitch] {
        let times: [Int] = [0, 1_764_288_000, ApprovalForwardingPolicy.latestTime]
        return (0..<3).map { mask >> $0 & 1 == 1 ? .on(origin: origin, at: times[$0]) : .off }
    }

    /// The risky kinds `mask` turns on, spelled out apart from the code.
    static func onKinds(_ mask: Int) -> Set<ApprovalRiskyKind> {
        let order: [ApprovalRiskyKind] = [.privileged, .claudeConfig, .secrets]
        return Set((0..<3).filter { mask >> $0 & 1 == 1 }.map { order[$0] })
    }

    /// Every combination of the three switches, both origins, both values
    /// of `developer` and `phoneSwitch`, and both pairings: 128 policies.
    static let generated: [(mask: Int, policy: ApprovalStoredPolicy)] = {
        var policies: [(mask: Int, policy: ApprovalStoredPolicy)] = []
        for mask in 0..<8 {
            for origin in ApprovalSwitchOrigin.allCases {
                for developer in [true, false] {
                    for phoneSwitch in [true, false] {
                        for pairing in [Self.pairing, Self.otherPairing] {
                            let state = switches(mask, origin: origin)
                            if let policy = ApprovalStoredPolicy(pairing: pairing, developer: developer, privileged: state[0],
                                                                 claudeConfig: state[1], secrets: state[2], phoneSwitch: phoneSwitch) {
                                policies.append((mask, policy))
                            }
                        }
                    }
                }
            }
        }
        return policies
    }()

    /// What the writer gives reads back equal, and has the one ending: seven
    /// lines, every one ended by a single line feed, nothing after the last,
    /// only printable ASCII besides.
    @Test func everyPolicyRoundTripsWithTheOneEnding() throws {
        #expect(Self.generated.count == 128, "vacuity: every combination is a policy")
        for (_, policy) in Self.generated {
            let written = ApprovalForwardingPolicy.text(of: policy)
            #expect(ApprovalForwardingPolicy.read(written) == policy)
            #expect(written.last == 0x0a && written.dropLast().last != 0x0a, "one line feed ends the text")
            #expect(written.filter { $0 == 0x0a }.count == 7, "seven lines")
            #expect(written.allSatisfy { $0 == 0x0a || (0x20...0x7e).contains($0) }, "printable ASCII and line feeds only")
            let reread = try #require(ApprovalForwardingPolicy.read(written))
            #expect(ApprovalForwardingPolicy.text(of: reread) == written, "reading never changes the spelling")
        }
        // A switch that is off has no origin, so the two origins give the
        // same policy where every switch is off: 120 distinct policies.
        var policies: [ApprovalStoredPolicy] = []
        for (_, policy) in Self.generated where !policies.contains(policy) { policies.append(policy) }
        let texts = Set(Self.generated.map { ApprovalForwardingPolicy.text(of: $0.policy) })
        #expect(policies.count == 120, "vacuity: \(policies.count) distinct policies")
        #expect(texts.count == policies.count, "one text per policy, and one policy per text")
    }

    /// The stored policy refuses what its text cannot spell.
    @Test func theStoredPolicyRefusesWhatItsTextCannotSpell() {
        func policy(pairing: [UInt8] = Self.pairing, _ state: ApprovalRiskySwitch, at index: Int = 0) -> ApprovalStoredPolicy? {
            var states: [ApprovalRiskySwitch] = [.off, .off, .off]
            states[index] = state
            return ApprovalStoredPolicy(pairing: pairing, developer: true, privileged: states[0], claudeConfig: states[1],
                                        secrets: states[2], phoneSwitch: true)
        }
        for count in [0, 31, 33, 64] {
            #expect(policy(pairing: Array(repeating: 1, count: count), .off) == nil, "a \(count)-byte pairing")
        }
        for index in 0..<3 {
            for bad in [-1, Int.min, ApprovalForwardingPolicy.latestTime + 1, Int.max] {
                #expect(policy(.on(origin: .mac, at: bad), at: index) == nil, "switch \(index) at \(bad)")
            }
            for good in [0, 1, ApprovalForwardingPolicy.latestTime] {
                #expect(policy(.on(origin: .phone, at: good), at: index) != nil, "switch \(index) at \(good)")
            }
        }
        #expect(policy(.off) != nil, "vacuity: a 32-byte pairing with every switch off")
    }

    // MARK: - The effective set

    /// The effective set with every fact true.
    static func effectiveWithEveryFact(_ stored: [UInt8]?, pairingInForce: [UInt8]?) -> ApprovalForwardingSet {
        ApprovalForwardingPolicy.effective(stored: stored, pairingInForce: pairingInForce, mainSwitchOn: true,
                                           peerCodeConfirmed: true, promptsMacSigned: true, protectedStoreAvailable: true)
    }

    /// The four facts, in every combination: main switch, peer
    /// code-confirmed, prompts Mac-signed, protected store available.
    static let factCombinations: [[Bool]] = (0..<16).map { number in (0..<4).map { number >> $0 & 1 == 1 } }

    /// A spread of stored values: none, every refused text, every accepted
    /// text, and every generated policy's text.
    static var storedSpread: [[UInt8]?] {
        [nil] + refusedRows.map(\.bytes) + acceptedRows.map { text($0.lines) }
            + generated.map { ApprovalForwardingPolicy.text(of: $0.policy) }
    }

    /// Pairings in force: the one the texts name, another, none, and two of
    /// the wrong length.
    static let pairingsInForce: [[UInt8]?] = [pairing, otherPairing, nil, Array(pairing.prefix(31)), pairing + [0]]

    /// Unless all four facts hold, no stored value and no pairing in force
    /// gives anything but the listed commands alone.
    @Test func withAnyFactFalseTheSetIsTheListedCommandsAlone() {
        let spread = Self.storedSpread
        var widened: [String] = []
        var calls = 0
        for facts in Self.factCombinations where facts != [true, true, true, true] {
            for (index, stored) in spread.enumerated() {
                for pairingInForce in Self.pairingsInForce {
                    calls += 1
                    let set = ApprovalForwardingPolicy.effective(stored: stored, pairingInForce: pairingInForce, mainSwitchOn: facts[0],
                                                                 peerCodeConfirmed: facts[1], promptsMacSigned: facts[2],
                                                                 protectedStoreAvailable: facts[3])
                    if set != .listedOnly { widened.append("facts \(facts), stored #\(index)") }
                }
            }
        }
        #expect(widened.isEmpty, "\(widened.prefix(10))")
        #expect(calls == 15 * spread.count * Self.pairingsInForce.count && spread.count > 200, "vacuity: \(calls) calls")
    }

    /// With every fact true: a text from another pairing, or no pairing in
    /// force, or one of the wrong length, gives the listed commands alone.
    @Test func aTextFromAnotherPairingGivesTheListedCommandsAlone() {
        var widened: [String] = []
        for (mask, policy) in Self.generated {
            let stored = ApprovalForwardingPolicy.text(of: policy)
            let other: [UInt8] = policy.pairing == Self.pairing ? Self.otherPairing : Self.pairing
            for pairingInForce in [other, nil, Array(policy.pairing.prefix(31)), policy.pairing + [0]] {
                if Self.effectiveWithEveryFact(stored, pairingInForce: pairingInForce) != .listedOnly {
                    widened.append("mask \(mask), pairing in force \(pairingInForce?.count ?? -1) bytes")
                }
            }
        }
        #expect(widened.isEmpty, "\(widened)")
    }

    /// With every fact true and the pairing matching, `developer:off` gives
    /// the listed commands alone, whatever the risky switches say.
    @Test func developerOffGivesTheListedCommandsAlone() {
        let off = Self.generated.filter { !$0.policy.developer }
        #expect(off.count == 64, "vacuity")
        for (mask, policy) in off {
            #expect(Self.effectiveWithEveryFact(ApprovalForwardingPolicy.text(of: policy), pairingInForce: policy.pairing) == .listedOnly,
                    "mask \(mask)")
        }
    }

    /// With every fact true, the pairing matching and `developer:on`: every
    /// everyday kind, and exactly the risky kinds stored on, for all eight
    /// combinations.
    @Test(arguments: 0..<8)
    func everyConditionHeldGivesTheEverydayKindsAndTheStoredRiskyKinds(_ mask: Int) {
        let rows = Self.generated.filter { $0.mask == mask && $0.policy.developer }
        #expect(rows.count == 8, "vacuity: two origins, two phoneSwitch values, two pairings")
        for (_, policy) in rows {
            let set = Self.effectiveWithEveryFact(ApprovalForwardingPolicy.text(of: policy), pairingInForce: policy.pairing)
            #expect(set.kinds == Set(ApprovalPromptKind.allCases))
            #expect(set.riskyKinds == Self.onKinds(mask))
            #expect(set != .listedOnly)
        }
    }

    /// No text, or one refused, with every fact true: the listed commands
    /// alone.
    @Test func noTextOrARefusedOneGivesTheListedCommandsAlone() {
        #expect(Self.effectiveWithEveryFact(nil, pairingInForce: Self.pairing) == .listedOnly)
        #expect(Self.effectiveWithEveryFact(nil, pairingInForce: nil) == .listedOnly)
        for row in Self.refusedRows {
            #expect(Self.effectiveWithEveryFact(row.bytes, pairingInForce: Self.pairing) == .listedOnly, "\(row.name)")
        }
    }

    /// Nine effective sets exist: the listed commands alone, and the
    /// everyday kinds with each of the eight combinations.
    @Test func thereAreNineEffectiveSets() {
        var sets: [ApprovalForwardingSet] = [.listedOnly]
        for (_, policy) in Self.generated {
            for facts in Self.factCombinations {
                for pairingInForce in Self.pairingsInForce {
                    let set = ApprovalForwardingPolicy.effective(stored: ApprovalForwardingPolicy.text(of: policy),
                                                                 pairingInForce: pairingInForce, mainSwitchOn: facts[0],
                                                                 peerCodeConfirmed: facts[1], promptsMacSigned: facts[2],
                                                                 protectedStoreAvailable: facts[3])
                    if !sets.contains(set) { sets.append(set) }
                }
            }
        }
        #expect(sets.count == 9)
        #expect(Set(sets.map(\.riskyKinds)).count == 8, "the eight combinations, the listed-only set's empty one among them")
        #expect(sets.filter { $0.kinds != Set(ApprovalPromptKind.allCases) } == [.listedOnly])
    }

    /// The decision table, row by row: the facts, what is stored, and the
    /// pairing in force, to the effective set.
    struct Decision: Sendable, CustomTestStringConvertible {
        let name: String
        let facts: [Bool]
        let stored: [UInt8]?
        let pairingInForce: [UInt8]?
        /// nil: the listed commands alone.
        let wider: Set<ApprovalRiskyKind>?
        var testDescription: String { name }
    }

    static let everyFact: [Bool] = [true, true, true, true]

    static let decisionRows: [Decision] = [
        Decision(name: "everything holds, no risky kind on", facts: everyFact, stored: canonicalText, pairingInForce: pairing, wider: []),
        Decision(name: "everything holds, secrets on", facts: everyFact, stored: text(lines(secrets: "on phone 5")),
                 pairingInForce: pairing, wider: [.secrets]),
        Decision(name: "everything holds, all three on", facts: everyFact,
                 stored: text(lines(privileged: "on mac 1", claudeConfig: "on phone 2", secrets: "on mac 3")),
                 pairingInForce: pairing, wider: [.privileged, .claudeConfig, .secrets]),
        Decision(name: "phoneSwitch off changes nothing", facts: everyFact, stored: text(lines(privileged: "on mac 1", phoneSwitch: "off")),
                 pairingInForce: pairing, wider: [.privileged]),
        Decision(name: "the main switch off", facts: [false, true, true, true], stored: canonicalText, pairingInForce: pairing, wider: nil),
        Decision(name: "the peer not code-confirmed", facts: [true, false, true, true], stored: canonicalText, pairingInForce: pairing,
                 wider: nil),
        Decision(name: "prompts not Mac-signed", facts: [true, true, false, true], stored: canonicalText, pairingInForce: pairing, wider: nil),
        Decision(name: "the protected store unavailable", facts: [true, true, true, false], stored: canonicalText, pairingInForce: pairing,
                 wider: nil),
        Decision(name: "no stored text", facts: everyFact, stored: nil, pairingInForce: pairing, wider: nil),
        Decision(name: "a refused text", facts: everyFact, stored: admin("on mac"), pairingInForce: pairing, wider: nil),
        Decision(name: "a newer format", facts: everyFact, stored: replacing(0, with: "napcat-forwarding-v2"), pairingInForce: pairing,
                 wider: nil),
        Decision(name: "a text from another pairing", facts: everyFact, stored: canonicalText, pairingInForce: otherPairing, wider: nil),
        Decision(name: "no pairing in force", facts: everyFact, stored: canonicalText, pairingInForce: nil, wider: nil),
        Decision(name: "developer off with secrets on", facts: everyFact, stored: text(lines(developer: "off", secrets: "on mac 1")),
                 pairingInForce: pairing, wider: nil),
    ]

    @Test(arguments: decisionRows)
    func theDecisionTable(_ row: Decision) {
        let set = ApprovalForwardingPolicy.effective(stored: row.stored, pairingInForce: row.pairingInForce, mainSwitchOn: row.facts[0],
                                                     peerCodeConfirmed: row.facts[1], promptsMacSigned: row.facts[2],
                                                     protectedStoreAvailable: row.facts[3])
        if let wider = row.wider {
            #expect(set.kinds == Set(ApprovalPromptKind.allCases))
            #expect(set.riskyKinds == wider)
        } else {
            #expect(set == .listedOnly)
        }
    }

    // MARK: - What a set admits

    /// The listed-only set holds the listed commands and no risky kind.
    @Test func theListedOnlySetIsTodaysSet() {
        #expect(ApprovalForwardingSet.listedOnly.kinds == [.listedCommand])
        #expect(ApprovalForwardingSet.listedOnly.riskyKinds.isEmpty)
    }

    /// A prompt is admitted only when its kind and every risky kind it
    /// carries are in the set: for each of the nine sets, every kind and
    /// every combination of risky kinds.
    @Test func aSetAdmitsAPromptOnlyWhenItHoldsItsKindAndEveryRiskyKind() {
        var sets: [(name: String, set: ApprovalForwardingSet, risky: Set<ApprovalRiskyKind>?)] = [("listed only", .listedOnly, nil)]
        for mask in 0..<8 {
            let state = Self.switches(mask, origin: .mac)
            guard let policy = ApprovalStoredPolicy(pairing: Self.pairing, developer: true, privileged: state[0], claudeConfig: state[1],
                                                    secrets: state[2], phoneSwitch: true) else {
                Issue.record("mask \(mask) is no policy")
                continue
            }
            sets.append(("mask \(mask)", Self.effectiveWithEveryFact(ApprovalForwardingPolicy.text(of: policy),
                                                                     pairingInForce: Self.pairing), Self.onKinds(mask)))
        }
        #expect(sets.count == 9)
        var admitted = 0
        for (name, set, risky) in sets {
            for kind in ApprovalPromptKind.allCases {
                for carried in (0..<8).map(Self.onKinds) {
                    let expected = risky.map { carried.isSubset(of: $0) } ?? (kind == .listedCommand && carried.isEmpty)
                    #expect(set.admits(kind, carrying: carried) == expected, "\(name): \(kind) carrying \(carried)")
                    if expected { admitted += 1 }
                }
            }
        }
        #expect(admitted > 0 && admitted < 9 * 6 * 8, "vacuity: some prompts are admitted and some are not (\(admitted))")
    }

    // MARK: - The identity facts

    /// Neither identity piece exists, so both facts are false literals.
    @Test func theIdentityFactsAreFalse() {
        #expect(ApprovalForwardingPolicy.seamChecksPeerCode == false, "flips only with the seam's code identity check")
        #expect(ApprovalForwardingPolicy.macSignsPrompts == false, "flips only with Mac-signed prompts")
    }

    /// Under this build's identity facts, no stored value widens, whatever
    /// the other facts and the pairing are.
    @Test func underThisBuildsIdentityFactsNothingWidens() {
        var widened: [String] = []
        for (index, stored) in Self.storedSpread.enumerated() {
            for pairingInForce in Self.pairingsInForce {
                let set = ApprovalForwardingPolicy.effective(stored: stored, pairingInForce: pairingInForce, mainSwitchOn: true,
                                                             peerCodeConfirmed: ApprovalForwardingPolicy.seamChecksPeerCode,
                                                             promptsMacSigned: ApprovalForwardingPolicy.macSignsPrompts,
                                                             protectedStoreAvailable: true)
                if set != .listedOnly { widened.append("stored #\(index)") }
            }
        }
        #expect(widened.isEmpty, "\(widened.prefix(10))")
    }

    // MARK: - Structure

    static let policyPath = "Sources/NapCatWire/ApprovalForwardingPolicy.swift"
    static let policyFile = "ApprovalForwardingPolicy.swift"

    /// Every Swift source of the four Mac targets and the phone app, by
    /// path, comment-stripped.
    static func sources() throws -> Sources {
        try LidGuardStructureTests.rawScanSources().map { ($0.name, LidGuardStructureTests.codeOnly($0.text)) }
    }

    static func mutate(_ sources: Sources, _ name: String, _ transform: (String) -> String) -> Sources {
        ApprovalChannelStructureTests.mutate(sources, name, transform)
    }

    // MARK: Unwired

    /// The model's types, matched as whole words.
    static let policyTypes = ["ApprovalPromptKind", "ApprovalRiskyKind", "ApprovalSwitchOrigin", "ApprovalRiskySwitch",
                              "ApprovalStoredPolicy", "ApprovalForwardingSet", "ApprovalForwardingPolicy"]
    static let typePattern = #"\b(?:"# + policyTypes.joined(separator: "|") + #")\b"#

    /// Where a source other than the model's own file names its types, line
    /// by line: nowhere yet (#248 is unwired). Outside Sources/NapCatWire
    /// nothing may; a later slice that wires the model adds its lines here.
    static let wiredSites: [String: [String: Int]] = [:]

    static func unwiredFailures(_ sources: Sources) -> [String] {
        var failures = PairingStructureTests.appSiteFailures(typePattern, in: sources.filter { $0.name != policyPath }, allowed: wiredSites,
                                                             rule: "no source but the model's own file names its types (#248: unwired)")
        let own = ApprovalChannelStructureTests.text(policyPath, in: sources)
        for type in policyTypes where !own.contains("public enum " + type) && !own.contains("public struct " + type) {
            failures.append("\(type) is not declared in \(policyPath) — the lock would be vacuous")
        }
        return failures
    }

    @Test func noSourceButTheModelsOwnNamesItsTypes() throws {
        let sources = try Self.sources()
        #expect(Self.unwiredFailures(sources).isEmpty, "\(Self.unwiredFailures(sources))")
        #expect(sources.contains { $0.name.hasPrefix("ios/NapCatPhone/NapCatPhone/") }, "vacuity: the phone app is read")
        #expect(sources.contains { $0.name == "Sources/NapCat/ApprovalIntake.swift" }, "vacuity: the app is read")
        #expect(sources.contains { $0.name == Self.policyPath }, "vacuity: the model is read")
        let mutants: [(String, Sources)] = [
            ("the app names the set", Self.mutate(sources, "Sources/NapCat/ApprovalIntake.swift") {
                $0 + "\nlet zzSet = ApprovalForwardingSet.listedOnly" }),
            ("the gate calls the function", Self.mutate(sources, "Sources/NapCatWire/ApprovalClassification.swift") {
                $0 + "\nlet zzSet = ApprovalForwardingPolicy.effective(stored: nil, pairingInForce: nil, mainSwitchOn: true, "
                    + "peerCodeConfirmed: true, promptsMacSigned: true, protectedStoreAvailable: true)" }),
            ("the phone names a risky kind", Self.mutate(sources, "ios/NapCatPhone/NapCatPhone/Model/RequestInbox.swift") {
                $0 + "\nlet zzKind: ApprovalRiskyKind = .secrets" }),
            ("the seam names the stored policy, module-qualified", Self.mutate(sources, "Sources/NapCatSeam/SeamSocket.swift") {
                $0 + "\nfunc zz(_ p: NapCatWire . ApprovalStoredPolicy) {}" }),
            ("the channel names a kind behind backticks", Self.mutate(sources, "Sources/NapCatChannel/ChannelRelay.swift") {
                $0 + "\nlet zzKind: `ApprovalPromptKind` = .shell" }),
            ("the app extends the set", Self.mutate(sources, "Sources/NapCat/NapCatApp.swift") {
                $0 + "\nextension ApprovalForwardingSet {}" }),
            ("the app names a switch", Self.mutate(sources, "Sources/NapCat/MenuStateModel.swift") {
                $0 + "\nlet zzSwitch = ApprovalRiskySwitch.off, zzOrigin = ApprovalSwitchOrigin.mac" }),
            ("a type no longer declared", Self.mutate(sources, Self.policyPath) {
                $0.replacingOccurrences(of: "public enum ApprovalSwitchOrigin", with: "public enum ApprovalSwitchSource") }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.unwiredFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: a comment naming a type, and names that only
        // contain one.
        let controls = Self.mutate(sources, "Sources/NapCat/ApprovalIntake.swift") {
            $0 + LidGuardStructureTests.codeOnly("\n// A later slice hands the gate an ApprovalForwardingSet.\n")
                + "\nlet zzApprovalRiskyKind = 1, approvalForwardingSetNote = 2, ApprovalPromptKinds = 3\n"
        }
        #expect(controls.map { $0.text } != sources.map { $0.text }, "the controls applied")
        #expect(Self.unwiredFailures(controls).isEmpty, "over-match: \(Self.unwiredFailures(controls))")
    }

    // MARK: The identity facts' literals

    /// Each fact as declared: a constant, false.
    static let peerLiteral = "public static let seamChecksPeerCode = false"
    static let signedLiteral = "public static let macSignsPrompts = false"

    /// Each literal is declared once, false, in the model's file, and named
    /// nowhere else in any source, the model's own file included: nothing
    /// reads it yet, so it cannot be flipped, shadowed or read another way
    /// without this lock seeing it.
    static func literalFailures(_ sources: Sources) -> [String] {
        PairingStructureTests.appSiteFailures(#"\bseamChecksPeerCode\b"#, in: sources, allowed: [policyPath: [peerLiteral: 1]],
                                              rule: "the code-identity fact is declared false once and read nowhere yet (#248)")
            + PairingStructureTests.appSiteFailures(#"\bmacSignsPrompts\b"#, in: sources, allowed: [policyPath: [signedLiteral: 1]],
                                                    rule: "the signed-prompts fact is declared false once and read nowhere yet (#248)")
    }

    @Test func theIdentityLiteralsAreDeclaredOnceFalseAndReadNowhere() throws {
        let sources = try Self.sources()
        #expect(Self.literalFailures(sources).isEmpty, "\(Self.literalFailures(sources))")
        let own = ApprovalChannelStructureTests.text(Self.policyPath, in: sources)
        #expect(ApprovalChannelStructureTests.count(Self.peerLiteral, in: own) == 1, "vacuity: the first literal is in the model")
        #expect(ApprovalChannelStructureTests.count(Self.signedLiteral, in: own) == 1, "vacuity: the second literal is in the model")
        let literalMutant: (String, String) -> Sources = { old, new in
            Self.mutate(sources, Self.policyPath) { $0.replacingOccurrences(of: old, with: new) }
        }
        var mutants: [(String, Sources)] = []
        for (literal, name) in [(Self.peerLiteral, "seamChecksPeerCode"), (Self.signedLiteral, "macSignsPrompts")] {
            mutants += [
                ("\(name) flipped to true", literalMutant(literal, "public static let \(name) = true")),
                ("\(name) made a variable", literalMutant(literal, "public static var \(name) = false")),
                ("\(name) made computed", literalMutant(literal, "public static var \(name): Bool { true }")),
                ("\(name)'s value hidden behind an expression", literalMutant(literal, "public static let \(name) = false || true")),
                ("\(name) declared twice behind #if", literalMutant(literal, "#if DEBUG\n    public static let \(name) = true\n    #else\n    "
                    + literal + "\n    #endif")),
                ("\(name) shadowed in the app", Self.mutate(sources, "Sources/NapCat/ApprovalIntake.swift") {
                    $0 + "\nextension ApprovalForwardingPolicy { static var \(name): Bool { true } }" }),
                ("\(name) read in the app", Self.mutate(sources, "Sources/NapCat/RemoteApprovalsController.swift") {
                    $0 + "\nlet zzFact = ApprovalForwardingPolicy.\(name) || true" }),
                ("\(name) read on the phone", Self.mutate(sources, "ios/NapCatPhone/NapCatPhone/Model/RequestInbox.swift") {
                    $0 + "\nlet zzFact = ApprovalForwardingPolicy.\(name)" }),
            ]
        }
        mutants.append(("a literal read by the effective set", literalMutant(
            "guard mainSwitchOn, peerCodeConfirmed, promptsMacSigned,", "guard mainSwitchOn, peerCodeConfirmed || seamChecksPeerCode, promptsMacSigned,")))
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.literalFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: blanks around a declaration, and names that
        // only contain a literal's.
        let controls = Self.mutate(literalMutant(Self.peerLiteral, "\t" + Self.peerLiteral + "   "), "Sources/NapCat/ApprovalIntake.swift") {
            $0 + "\nlet zzSeamChecksPeerCodeCount = 0, macSignsPromptsLater = 1"
        }
        #expect(controls.map { $0.text } != sources.map { $0.text }, "the controls applied")
        #expect(Self.literalFailures(controls).isEmpty, "over-match: \(Self.literalFailures(controls))")
    }

    // MARK: One way to a wider set

    static let setDeclaration = "public struct ApprovalForwardingSet: Equatable, Sendable {"
    static let listedOnlyLine = "public static let listedOnly = ApprovalForwardingSet(developerWithRisky: nil)"
    static let widenedLine = "return ApprovalForwardingSet(developerWithRisky: policy.riskyKindsOn)"
    static let setInitLine = "fileprivate init(developerWithRisky risky: Set<ApprovalRiskyKind>?) {"
    static let storedInitLine =
        "public init?(pairing: [UInt8], developer: Bool, privileged: ApprovalRiskySwitch, claudeConfig: ApprovalRiskySwitch,"
    /// The set's storage, as declared, and every line that names it.
    static let storageSites: [String: Int] = [
        "private let developerRisky: Set<ApprovalRiskyKind>?": 1,
        "developerRisky = risky": 1,
        "developerRisky == nil ? [.listedCommand] : Set(ApprovalPromptKind.allCases)": 1,
        "public var riskyKinds: Set<ApprovalRiskyKind> { developerRisky ?? [] }": 1,
    ]
    /// The effective function's guard, every condition, and the wider
    /// return right after it.
    static let effectiveGuard = "        guard mainSwitchOn, peerCodeConfirmed, promptsMacSigned, protectedStoreAvailable,\n"
        + "              let stored, let policy = read(stored), let pairingInForce, policy.pairing == pairingInForce,\n"
        + "              policy.developer else { return .listedOnly }\n"
        + "        " + widenedLine + "\n"

    /// The set's body, from its declaration to its closing brace.
    static func setBody(_ code: String) -> String? {
        guard let start = code.range(of: setDeclaration),
              let end = code.range(of: "\n}\n", range: start.upperBound..<code.endIndex) else { return nil }
        return String(code[start.lowerBound..<end.upperBound])
    }

    /// The effective set has one way to a wider value: the type is built in
    /// two places, the listed-only constant and the effective function's
    /// return right after the guard of every condition; its one initializer
    /// is file-private; its storage is a private constant; its only static
    /// member is the constant; it conforms to no protocol that brings an
    /// initializer; and nothing reaches the initializer unnamed (an unapplied
    /// `init`, the metatype, an alias, an extension, a subclass, a generic
    /// bound, an implicit `.init` or `Self(`).
    static func constructorFailures(_ code: String) -> [String] {
        guard let body = setBody(code) else { return ["'\(setDeclaration)' not found in \(policyFile) — the lock would be vacuous"] }
        var failures: [String] = []
        for copy in LidGuardStructureTests.constructorScanCopies(code) {
            failures += RecordPath.siteFailures(RecordPath.constructionPattern("ApprovalForwardingSet"), in: copy, file: policyFile,
                                                allowed: [listedOnlyLine: 1, widenedLine: 1],
                                                rule: "the set is built twice: the listed-only constant and the effective function's one wider return")
            failures += RecordPath.siteFailures(#"\binit\b"#, in: copy, file: policyFile, allowed: [setInitLine: 1, storedInitLine: 1],
                                                rule: "two initializers: the set's file-private one and the stored policy's")
            failures += RecordPath.siteFailures(#"\bstruct\s+ApprovalForwardingSet\b"#, in: copy, file: policyFile,
                                                allowed: [setDeclaration: 1], rule: "the set conforms to Equatable and Sendable alone")
            failures += RecordPath.siteFailures(#"\bdeveloperRisky\b"#, in: copy, file: policyFile, allowed: storageSites,
                                                rule: "the set's storage is a private constant that its initializer alone sets")
            if RecordPath.hits(RecordPath.indirectConstructionPattern("ApprovalForwardingSet"), in: copy) {
                failures.append("the set's initializer is reached unnamed in \(policyFile)")
            }
            if RecordPath.hits(RecordPath.implicitInit, in: copy) || RecordPath.hits(#"\bSelf\s*(?:\.\s*init\b\s*)?\("#, in: copy) {
                failures.append("an implicit `.init` or a `Self(` in \(policyFile) — every construction names its type")
            }
        }
        if ApprovalChannelStructureTests.count(effectiveGuard, in: code) != 1 {
            failures.append("the wider return must follow the guard of every condition directly, once")
        }
        if ApprovalChannelStructureTests.count("static", in: body) != 1 {
            failures.append("the set's only static member is the listed-only constant")
        }
        return RecordPath.unique(failures)
    }

    @Test func theEffectiveSetHasOneWayToAWiderValue() throws {
        let code = try WireContractTests.wireCode(Self.policyFile)
        #expect(Self.constructorFailures(code).isEmpty, "\(Self.constructorFailures(code))")
        for anchor in [Self.setDeclaration, Self.listedOnlyLine, Self.widenedLine, Self.setInitLine, Self.storedInitLine, Self.effectiveGuard] {
            #expect(ApprovalChannelStructureTests.count(anchor, in: code) == 1, "vacuity: '\(anchor.prefix(50))' is in the model once")
        }
        let replacing: (String, String) -> String = { old, new in code.replacingOccurrences(of: old, with: new) }
        let mutants: [(String, String)] = [
            ("a public initializer added", replacing(Self.setInitLine,
                "public init() { developerRisky = Set(ApprovalRiskyKind.allCases) }\n    " + Self.setInitLine)),
            ("the initializer made public", replacing(Self.setInitLine, "public init(developerWithRisky risky: Set<ApprovalRiskyKind>?) {")),
            ("the initializer made internal", replacing(Self.setInitLine, "init(developerWithRisky risky: Set<ApprovalRiskyKind>?) {")),
            ("a second constant", replacing(Self.listedOnlyLine, Self.listedOnlyLine
                + "\n    public static let everything = ApprovalForwardingSet(developerWithRisky: Set(ApprovalRiskyKind.allCases))")),
            ("a computed static", replacing(Self.listedOnlyLine, Self.listedOnlyLine
                + "\n    public static var wide: ApprovalForwardingSet { ApprovalForwardingPolicy.widen() }")),
            ("an extension in the file", code + "\nextension ApprovalForwardingSet {\n    public static var all: ApprovalForwardingSet { .listedOnly }\n}\n"),
            ("a protocol that brings an initializer", replacing(Self.setDeclaration,
                "public struct ApprovalForwardingSet: Equatable, Sendable, Decodable {")),
            ("the storage made a variable", replacing("private let developerRisky:", "private var developerRisky:")),
            ("a mutating widener", replacing(Self.setInitLine,
                "public mutating func widen() { developerRisky = Set(ApprovalRiskyKind.allCases) }\n    " + Self.setInitLine)),
            ("the wider return through .init", replacing(Self.widenedLine, "return .init(developerWithRisky: policy.riskyKindsOn)")),
            ("the constant through Self(", replacing(Self.listedOnlyLine, "public static let listedOnly = Self(developerWithRisky: nil)")),
            ("an unapplied initializer", code + "\nlet zzMake = ApprovalForwardingSet.init\n"),
            ("the metatype", code + "\nlet zzType = ApprovalForwardingSet.self\n"),
            ("an alias", code + "\ntypealias ZZWide = ApprovalForwardingSet\n"),
            ("a condition dropped from the guard", replacing("peerCodeConfirmed, promptsMacSigned,", "peerCodeConfirmed,")),
            ("the pairing check dropped", replacing(" policy.pairing == pairingInForce,", "")),
            ("an early wider return", replacing("        guard mainSwitchOn,",
                "        if mainSwitchOn { return ApprovalForwardingSet(developerWithRisky: []) }\n        guard mainSwitchOn,")),
        ]
        for (name, mutant) in mutants {
            #expect(mutant != code, "canary '\(name)' did not apply")
            #expect(!Self.constructorFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: a static member of another type, a name that
        // only contains the set's or `init`'s, and a comment naming them.
        let controls = LidGuardStructureTests.codeOnly(code
            + "\n// ApprovalForwardingSet(developerWithRisky: []) is built by effective alone; init( is file-private.\n"
            + "enum ZZNotes {\n    static let initialCount = 0\n    static let note = ApprovalForwardingSetNote(1)\n}\n")
        #expect(controls != code, "the controls applied")
        #expect(Self.constructorFailures(controls).isEmpty, "over-match: \(Self.constructorFailures(controls))")
    }

    // MARK: Pure

    /// Beyond the wire's own I/O tokens: logging, the keychain, local
    /// authentication and the process's environment. (The keychain token is
    /// split, as the other locks split it.)
    static let extraTokens = ["Logger", "os_log", "NSLog", "print(", "LAContext", "LocalAuthentication", "kSec", "Key" + "chain",
                              "key" + "chain", "ProcessInfo", "Bundle"]

    @Test func theModelIsPureAndImportFree() throws {
        #expect(WireContractTests.pureFiles.contains(Self.policyFile), "the model joins the wire's pure files and their locks")
        let code = try WireContractTests.wireCode(Self.policyFile)
        #expect(WireContractTests.importLines(code).isEmpty, "\(WireContractTests.importLines(code))")
        for token in WireContractTests.ioTokens + Self.extraTokens {
            #expect(!code.contains(token), "'\(token)' in \(Self.policyFile) — the model performs no I/O")
        }
        #expect(code.contains("\"napcat-forwarding-v1\""), "vacuity: the scan reads the string literals")
        let planted = code + "\nlet zzNow = Date()\nlet zzLog = Logger()\n"
        #expect((WireContractTests.ioTokens + Self.extraTokens).filter { planted.contains($0) } == ["Date(", "Logger"])
    }
}
