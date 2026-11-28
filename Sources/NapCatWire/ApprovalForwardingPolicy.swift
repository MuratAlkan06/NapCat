// NapCatWire — F4 remote approvals: the forwarding policy model (#248).
// Which kinds of permission prompt may be sent to the paired iPhone: the
// everyday kinds, and three riskier kinds that each stay on the Mac unless
// their own switch is on.
//
// PURE — no imports, no I/O, no clock: the caller reads the stored text and
// every fact this file decides on, and hands them in. UNWIRED: no source
// but this file names its types (lint-locked in
// ApprovalForwardingPolicyTests), so nothing calls it yet and nothing
// changes: what may leave the Mac is still decided by the gate alone
// (ApprovalClassification.swift), and only the listed commands can.
//
// One function gives the effective set, and it fails closed: unless every
// one of its conditions holds, it gives the listed commands alone
// (`ApprovalForwardingSet.listedOnly`), whatever is stored. That constant
// and that function are the only ways to obtain a set.

/// What a permission prompt is, for forwarding. A prompt is exactly one of
/// these kinds, and may also carry any of the risky kinds
/// (`ApprovalRiskyKind`). The types only: nothing sorts a prompt into a
/// kind yet.
public enum ApprovalPromptKind: CaseIterable, Sendable {
    /// A Bash prompt whose whole command is one of the listed commands
    /// (`ApprovalGate.bashCommands`): the one kind that can be sent today.
    case listedCommand
    /// Any other shell command.
    case shell
    /// A file edit: Write, Edit or NotebookEdit.
    case fileEdit
    /// A web fetch or a web search.
    case web
    /// A read of a file outside the project.
    case outsideRead
    /// A connector (MCP) tool call.
    case connector
}

/// The riskier kinds. A prompt that carries one stays on the Mac unless that
/// kind's switch is on, whatever its own kind is. The raw value names the
/// kind's line in the stored text.
public enum ApprovalRiskyKind: String, CaseIterable, Sendable {
    /// Privileged commands: sudo and its relatives, and system locations.
    case privileged
    /// Claude's configuration and hooks, and the other places whose
    /// contents run as code later: git hooks and config, shell startup
    /// files, launch agents.
    case claudeConfig
    /// Credentials: token and key files, and prompts whose text holds
    /// one.
    case secrets
}

/// Where a risky kind's switch was turned on.
public enum ApprovalSwitchOrigin: String, CaseIterable, Sendable {
    /// At the Mac.
    case mac
    /// From the paired iPhone.
    case phone
}

/// One risky kind's stored switch.
public enum ApprovalRiskySwitch: Equatable, Sendable {
    case off
    /// On: turned on from `origin`, at `at` in whole unix seconds.
    case on(origin: ApprovalSwitchOrigin, at: Int)
}

/// The stored policy: the owner's choice as its one text spells it
/// (`ApprovalForwardingPolicy.read` and `text(of:)`). Every value the
/// initializer or the reader gives has a text, which reads back as that
/// same value.
public struct ApprovalStoredPolicy: Equatable, Sendable {
    /// The digest of the pairing the choice was made under: 32 bytes. The
    /// choice counts only while that same pairing is in force.
    public let pairing: [UInt8]
    /// Whether the everyday kinds may be sent.
    public let developer: Bool
    public let privileged: ApprovalRiskySwitch
    public let claudeConfig: ApprovalRiskySwitch
    public let secrets: ApprovalRiskySwitch
    /// Whether the paired iPhone may ask for a risky switch to be turned
    /// on. It plays no part in the effective set.
    public let phoneSwitch: Bool

    /// nil unless `pairing` is exactly 32 bytes and every switch that is on
    /// names a time from 0 to `ApprovalForwardingPolicy.latestTime`.
    public init?(pairing: [UInt8], developer: Bool, privileged: ApprovalRiskySwitch, claudeConfig: ApprovalRiskySwitch,
                 secrets: ApprovalRiskySwitch, phoneSwitch: Bool) {
        guard pairing.count == ApprovalSigning.digestByteCount,
              [privileged, claudeConfig, secrets].allSatisfy(ApprovalForwardingPolicy.namesATimeInRange) else { return nil }
        self.pairing = pairing
        self.developer = developer
        self.privileged = privileged
        self.claudeConfig = claudeConfig
        self.secrets = secrets
        self.phoneSwitch = phoneSwitch
    }

    /// The switch of `kind`.
    public func state(of kind: ApprovalRiskyKind) -> ApprovalRiskySwitch {
        switch kind {
        case .privileged: return privileged
        case .claudeConfig: return claudeConfig
        case .secrets: return secrets
        }
    }

    /// The risky kinds whose switch is on.
    public var riskyKindsOn: Set<ApprovalRiskyKind> {
        Set(ApprovalRiskyKind.allCases.filter { state(of: $0) != .off })
    }
}

/// The effective set: which prompts may be sent to the paired iPhone. It has
/// one of two shapes: the listed commands alone, or every everyday kind
/// with the risky kinds whose switch is on (nine sets in all). Only
/// `listedOnly` and `ApprovalForwardingPolicy.effective` give one, and the
/// function is the one way to a wider set: the initializer is file-private
/// (lint-locked).
public struct ApprovalForwardingSet: Equatable, Sendable {
    /// The listed commands alone, with no risky kind: today's set, and what
    /// `ApprovalForwardingPolicy.effective` gives in every case it does not
    /// widen.
    public static let listedOnly = ApprovalForwardingSet(developerWithRisky: nil)

    /// nil for the listed commands alone; otherwise every everyday kind, and
    /// these risky kinds.
    private let developerRisky: Set<ApprovalRiskyKind>?

    fileprivate init(developerWithRisky risky: Set<ApprovalRiskyKind>?) {
        developerRisky = risky
    }

    /// The prompt kinds in the set.
    public var kinds: Set<ApprovalPromptKind> {
        developerRisky == nil ? [.listedCommand] : Set(ApprovalPromptKind.allCases)
    }

    /// The risky kinds in the set.
    public var riskyKinds: Set<ApprovalRiskyKind> { developerRisky ?? [] }

    /// Whether a prompt of `kind` that carries `risky` may be sent: its kind
    /// and every risky kind it carries are in the set.
    public func admits(_ kind: ApprovalPromptKind, carrying risky: Set<ApprovalRiskyKind>) -> Bool {
        kinds.contains(kind) && risky.isSubset(of: riskyKinds)
    }
}

/// The stored text's reader and writer, the effective set, and the two
/// identity facts.
public enum ApprovalForwardingPolicy {
    // MARK: - The identity facts

    /// Whether the seam confirms which program its peer is, by its code
    /// identity, and not only that it runs as this user. False: the seam
    /// checks the user alone. It flips only in the slice that adds that
    /// check (lint-locked: declared once, false, and read nowhere yet).
    public static let seamChecksPeerCode = false

    /// Whether the Mac signs every prompt it writes, with a key of its own
    /// that the paired iPhone checks. False: the Mac holds no private key.
    /// It flips only in the slice that adds signed prompts (lint-locked:
    /// declared once, false, and read nowhere yet).
    public static let macSignsPrompts = false

    // MARK: - The stored text

    /// The text's first line. Another format gets another header, never a
    /// variant of this text, so this build reads it as nothing.
    public static let header = "napcat-forwarding-v1"

    /// The names of the lines after the header, in their one order: each
    /// line is the name, a colon, then the value.
    public static let lineNames: [String] = ["pairing", "developer"] + ApprovalRiskyKind.allCases.map(\.rawValue) + ["phoneSwitch"]

    /// The latest time a switch may name: 2^53 seconds, the latest whole
    /// second a Double still holds exactly (the decision verifier's bound
    /// on a decision's time).
    public static let latestTime = 9_007_199_254_740_992

    /// The stored policy `text` spells, read strictly: exactly these seven
    /// lines, in this order, each ending in a line feed (the last one too)
    /// and nothing after the last:
    ///
    ///     napcat-forwarding-v1
    ///     pairing:<64 lowercase hex digits>
    ///     developer:on|off
    ///     privileged:off|on mac <seconds>|on phone <seconds>
    ///     claudeConfig:off|on mac <seconds>|on phone <seconds>
    ///     secrets:off|on mac <seconds>|on phone <seconds>
    ///     phoneSwitch:on|off
    ///
    /// `<seconds>` is a unix time in base 10, with no leading zeros and at
    /// most `latestTime`, and one space stands before the origin and one
    /// before the time. Anything else is nil: another header or none; a line
    /// unknown, repeated, missing or out of order; a value outside its
    /// alphabet; any byte the lines above do not spell, such as a space, a
    /// tab, a carriage return, a byte order mark or a byte outside ASCII; an
    /// empty line, a missing last line feed, or anything after it. Nothing
    /// is repaired.
    public static func read(_ text: [UInt8]) -> ApprovalStoredPolicy? {
        guard text.last == ApprovalSigning.lineFeed else { return nil }
        let lines = text.dropLast().split(separator: ApprovalSigning.lineFeed, omittingEmptySubsequences: false)
        guard lines.count == 1 + lineNames.count, lines[0].elementsEqual(header.utf8) else { return nil }
        var values: [ArraySlice<UInt8>] = []
        for (line, name) in zip(lines.dropFirst(), lineNames) {
            let prefix = Array((name + ":").utf8)
            guard line.starts(with: prefix) else { return nil }
            values.append(line.dropFirst(prefix.count))
        }
        guard let pairing = digest(values[0]), let developer = flag(values[1]), let privileged = state(values[2]),
              let claudeConfig = state(values[3]), let secrets = state(values[4]), let phoneSwitch = flag(values[5]) else {
            return nil
        }
        return ApprovalStoredPolicy(pairing: pairing, developer: developer, privileged: privileged, claudeConfig: claudeConfig,
                                    secrets: secrets, phoneSwitch: phoneSwitch)
    }

    /// The one text of `policy`: the seven lines `read` takes, which it reads
    /// back as `policy`.
    public static func text(of policy: ApprovalStoredPolicy) -> [UInt8] {
        let values: [String] = [ApprovalSigning.lowercaseHex(policy.pairing), word(policy.developer)]
            + ApprovalRiskyKind.allCases.map { spelling(policy.state(of: $0)) } + [word(policy.phoneSwitch)]
        let lines: [String] = [header] + zip(lineNames, values).map { $0 + ":" + $1 }
        return lines.flatMap { Array($0.utf8) + [ApprovalSigning.lineFeed] }
    }

    // MARK: - The effective set

    /// The effective set: every everyday kind and the risky kinds whose
    /// switch is on, only when all of these hold:
    ///
    /// - `mainSwitchOn`: Remote approvals is switched on;
    /// - `peerCodeConfirmed`: this connection's peer was confirmed by its
    ///   code identity;
    /// - `promptsMacSigned`: the prompts the Mac writes are signed by it;
    /// - `protectedStoreAvailable`: the store that holds the text could be
    ///   read;
    /// - `stored` is present and `read` takes it;
    /// - its pairing equals `pairingInForce`;
    /// - its `developer` line is `on`.
    ///
    /// In every other case it is `ApprovalForwardingSet.listedOnly`: so for
    /// no text, one it refuses, one in another format, or one from another
    /// pairing. Nothing is written back.
    public static func effective(stored: [UInt8]?, pairingInForce: [UInt8]?, mainSwitchOn: Bool, peerCodeConfirmed: Bool,
                                 promptsMacSigned: Bool, protectedStoreAvailable: Bool) -> ApprovalForwardingSet {
        guard mainSwitchOn, peerCodeConfirmed, promptsMacSigned, protectedStoreAvailable,
              let stored, let policy = read(stored), let pairingInForce, policy.pairing == pairingInForce,
              policy.developer else { return .listedOnly }
        return ApprovalForwardingSet(developerWithRisky: policy.riskyKindsOn)
    }

    // MARK: - Spelling

    /// Whether `state` names no time outside 0 to `latestTime`.
    fileprivate static func namesATimeInRange(_ state: ApprovalRiskySwitch) -> Bool {
        guard case .on(_, let at) = state else { return true }
        return at >= 0 && at <= latestTime
    }

    private static func word(_ flag: Bool) -> String { flag ? "on" : "off" }

    private static func spelling(_ state: ApprovalRiskySwitch) -> String {
        switch state {
        case .off: return "off"
        case .on(let origin, let at): return "on " + origin.rawValue + " " + String(at)
        }
    }

    /// `on` or `off`, exactly.
    private static func flag(_ value: ArraySlice<UInt8>) -> Bool? {
        if value.elementsEqual("on".utf8) { return true }
        if value.elementsEqual("off".utf8) { return false }
        return nil
    }

    /// `off`, or `on`, an origin and a time, one space before each.
    private static func state(_ value: ArraySlice<UInt8>) -> ApprovalRiskySwitch? {
        if value.elementsEqual("off".utf8) { return .off }
        let words = value.split(separator: UInt8(ascii: " "), omittingEmptySubsequences: false)
        guard words.count == 3, words[0].elementsEqual("on".utf8),
              let origin = ApprovalSwitchOrigin.allCases.first(where: { words[1].elementsEqual($0.rawValue.utf8) }),
              let at = seconds(words[2]) else { return nil }
        return .on(origin: origin, at: at)
    }

    /// Base-10 digits with no leading zero (`0` alone aside), no more of
    /// them than `latestTime` has. (The stored policy's initializer refuses
    /// a time past `latestTime`.)
    private static func seconds(_ digits: ArraySlice<UInt8>) -> Int? {
        let zero = UInt8(ascii: "0")
        guard !digits.isEmpty, digits.count <= String(latestTime).utf8.count,
              digits.allSatisfy({ $0 >= zero && $0 <= UInt8(ascii: "9") }),
              digits.first != zero || digits.count == 1 else { return nil }
        return digits.reduce(0) { $0 * 10 + Int($1 - zero) }
    }

    /// 64 lowercase hex digits, as the 32 bytes they spell.
    private static func digest(_ hex: ArraySlice<UInt8>) -> [UInt8]? {
        guard hex.count == 2 * ApprovalSigning.digestByteCount else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            guard let high = nibble(hex[index]), let low = nibble(hex[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        return bytes
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        default: return nil
        }
    }
}
