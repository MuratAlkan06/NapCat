// NapCatWire — F4 remote approvals: what Claude Code's managed settings say
// about NapCat's channel (slice S1, the managed-settings allowlist probe of
// the frozen design's preview posture). Design: design/remote-approvals.md.
//
// PURE — no imports, no I/O, no clock. The documents are read by the ONE
// strict reader (ApprovalPreview.swift); one it refuses, or a key of the wrong
// shape, makes the finding `unreadable`, never a guess. The file access is the
// app's (ChannelPolicyProbe.swift), read-only.

/// What the file tier of the managed settings says about running NapCat's
/// channel without the per-session development flag.
public enum ChannelPolicyFinding: String, CaseIterable, Sendable {
    /// No managed-settings file and no drop-in.
    case noFilePolicy
    /// A document that is not one strict JSON object, or one of the two keys
    /// in the wrong shape: unknown, so the flag is taken as still needed.
    case unreadable
    /// `channelsEnabled` is not true: on an organization plan every channel
    /// is blocked, the development flag included.
    case channelsNotEnabled
    /// Channels are enabled and no `allowedChannelPlugins` is set: Anthropic's
    /// list applies, and NapCat is not on it.
    case defaultAllowlist
    /// The organization's list does not name NapCat's plugin.
    case allowlistOmitsNapCat
    /// The organization's list names NapCat's plugin: on that organization's
    /// plan, `--channels` can register it without the development flag.
    case allowlistNamesNapCat

    /// Whether a session still needs `--dangerously-load-development-channels`.
    public var developmentFlagNeeded: Bool { self != .allowlistNamesNapCat }
}

public enum ChannelPolicy {
    /// The allowlist entry the probe looks for. PROVISIONAL: the install
    /// slice packages the server as this plugin in this local marketplace.
    public static let pluginName = "napcat"
    public static let marketplaceName = "napcat"

    public static let channelsEnabledKey = "channelsEnabled"
    public static let allowedChannelPluginsKey = "allowedChannelPlugins"

    /// Reads the file tier's documents in Claude Code's merge order
    /// (`managed-settings.json`, then the drop-ins by name): for
    /// `channelsEnabled` the later document wins, and the
    /// `allowedChannelPlugins` lists combine.
    public static func finding(documents: [String]) -> ChannelPolicyFinding {
        guard !documents.isEmpty else { return .noFilePolicy }
        var enabled: Bool?
        var namesNapCat: Bool?
        for document in documents {
            guard let members = ApprovalPreview.parseObject(document) else { return .unreadable }
            if let value = members.first(where: { $0.key == channelsEnabledKey })?.value {
                guard case .bool(let flag) = value else { return .unreadable }
                enabled = flag
            }
            if let value = members.first(where: { $0.key == allowedChannelPluginsKey })?.value {
                guard case .array(let entries) = value else { return .unreadable }
                var found = namesNapCat ?? false
                for entry in entries {
                    guard let named = namesNapCatPlugin(entry) else { return .unreadable }
                    found = found || named
                }
                namesNapCat = found
            }
        }
        guard enabled == true else { return .channelsNotEnabled }
        guard let namesNapCat else { return .defaultAllowlist }
        return namesNapCat ? .allowlistNamesNapCat : .allowlistOmitsNapCat
    }

    /// Whether one entry, exactly `{"marketplace": …, "plugin": …}` with two
    /// strings, is NapCat's; nil when it has any other shape.
    static func namesNapCatPlugin(_ entry: PreviewValue) -> Bool? {
        guard case .object(let fields) = entry, ApprovalChannel.hasExactly(["marketplace", "plugin"], fields),
              case .string(let marketplace)? = fields.first(where: { $0.key == "marketplace" })?.value,
              case .string(let plugin)? = fields.first(where: { $0.key == "plugin" })?.value else { return nil }
        return marketplace == marketplaceName && plugin == pluginName
    }
}
