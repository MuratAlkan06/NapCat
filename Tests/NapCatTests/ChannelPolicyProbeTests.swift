// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat
@testable import NapCatWire

/// F4 slice S1: the managed-settings channel allowlist probe. The reading
/// (`ChannelPolicy`) is table-tested on synthetic documents; the file access
/// (`ChannelPolicyProbe`) only ever reads a scratch directory here, never the
/// real system directory.
struct ChannelPolicyProbeTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let documents: [String]
        let finding: ChannelPolicyFinding
        let note: String
        var testDescription: String { note }
    }

    static let napcat = #"{"marketplace":"napcat","plugin":"napcat"}"#
    static let telegram = #"{"marketplace":"claude-plugins-official","plugin":"telegram"}"#

    static let rows: [Row] = [
        Row(documents: [], finding: .noFilePolicy, note: "no file tier at all"),
        Row(documents: ["{}"], finding: .channelsNotEnabled, note: "an empty policy"),
        Row(documents: [#"{"channelsEnabled":false}"#], finding: .channelsNotEnabled, note: "channels off"),
        Row(documents: [#"{"allowedChannelPlugins":[\#(napcat)]}"#], finding: .channelsNotEnabled,
            note: "the allowlist needs channelsEnabled"),
        Row(documents: [#"{"channelsEnabled":true}"#], finding: .defaultAllowlist, note: "Anthropic's list applies"),
        Row(documents: [#"{"channelsEnabled":true,"allowedChannelPlugins":[]}"#], finding: .allowlistOmitsNapCat,
            note: "an empty list blocks every plugin"),
        Row(documents: [#"{"channelsEnabled":true,"allowedChannelPlugins":[\#(telegram)]}"#], finding: .allowlistOmitsNapCat,
            note: "another plugin only"),
        Row(documents: [#"{"channelsEnabled":true,"allowedChannelPlugins":[{"marketplace":"elsewhere","plugin":"napcat"}]}"#],
            finding: .allowlistOmitsNapCat, note: "the same name from another marketplace is not NapCat's"),
        Row(documents: [#"{"channelsEnabled":true,"allowedChannelPlugins":[\#(telegram),\#(napcat)]}"#],
            finding: .allowlistNamesNapCat, note: "NapCat on the organization's list"),
        // The file tier merges: single values, the later file wins; lists combine.
        Row(documents: [#"{"channelsEnabled":true}"#, #"{"allowedChannelPlugins":[\#(napcat)]}"#],
            finding: .allowlistNamesNapCat, note: "a drop-in adds the list"),
        Row(documents: [#"{"channelsEnabled":true,"allowedChannelPlugins":[\#(napcat)]}"#, #"{"channelsEnabled":false}"#],
            finding: .channelsNotEnabled, note: "a later drop-in turns channels off"),
        Row(documents: [#"{"channelsEnabled":true,"allowedChannelPlugins":[\#(napcat)]}"#, #"{"allowedChannelPlugins":[\#(telegram)]}"#],
            finding: .allowlistNamesNapCat, note: "lists combine across files"),
        // Unreadable: never a guess.
        Row(documents: ["not json"], finding: .unreadable, note: "not JSON"),
        Row(documents: ["[]"], finding: .unreadable, note: "not an object"),
        Row(documents: [#"{"channelsEnabled":true,"channelsEnabled":true}"#], finding: .unreadable, note: "a duplicate key"),
        Row(documents: [#"{"channelsEnabled":"true"}"#], finding: .unreadable, note: "channelsEnabled not a boolean"),
        Row(documents: [#"{"channelsEnabled":true,"allowedChannelPlugins":{"plugin":"napcat"}}"#], finding: .unreadable,
            note: "the list not an array"),
        Row(documents: [#"{"channelsEnabled":true,"allowedChannelPlugins":["napcat"]}"#], finding: .unreadable,
            note: "an entry not an object"),
        Row(documents: [#"{"channelsEnabled":true,"allowedChannelPlugins":[{"plugin":"napcat"}]}"#], finding: .unreadable,
            note: "an entry without its marketplace"),
        Row(documents: [#"{"channelsEnabled":true,"allowedChannelPlugins":[{"marketplace":"napcat","plugin":"napcat","v":1}]}"#],
            finding: .unreadable, note: "an entry with an extra key"),
        Row(documents: [#"{"channelsEnabled":true}"#, "{"], finding: .unreadable, note: "one unreadable drop-in"),
    ]

    @Test(arguments: rows)
    func theFileTierReadsToOneFinding(_ row: Row) {
        #expect(ChannelPolicy.finding(documents: row.documents) == row.finding)
    }

    @Test func onlyAnAllowlistNamingNapCatRemovesTheFlag() {
        for finding in ChannelPolicyFinding.allCases {
            #expect(finding.developmentFlagNeeded == (finding != .allowlistNamesNapCat), "\(finding)")
        }
        #expect(ChannelPolicyFinding.allCases.count == 6)
    }

    @Test func theProbesNamesArePinned() {
        #expect(ChannelPolicyProbe.systemDirectory == "/Library/Application Support/ClaudeCode")
        #expect(ChannelPolicyProbe.settingsFileName == "managed-settings.json")
        #expect(ChannelPolicyProbe.dropInDirectoryName == "managed-settings.d")
        #expect(ChannelPolicy.channelsEnabledKey == "channelsEnabled")
        #expect(ChannelPolicy.allowedChannelPluginsKey == "allowedChannelPlugins")
        #expect(ChannelPolicy.pluginName == "napcat")
        #expect(ChannelPolicy.marketplaceName == "napcat")
    }

    // MARK: - Reading a scratch file tier

    final class Tier {
        let root: URL

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("ncp-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        var path: String { root.path }

        func write(_ relative: String, _ text: String) throws { try write(relative, Data(text.utf8)) }

        func write(_ relative: String, _ data: Data) throws {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
    }

    @Test func anEmptyDirectoryHasNoFilePolicy() throws {
        let tier = try Tier()
        #expect(ChannelPolicyProbe.probe(directory: tier.path) == .noFilePolicy)
        #expect(ChannelPolicyProbe.probe(directory: tier.path + "/absent") == .noFilePolicy)
    }

    @Test func theSettingsFileThenTheDropInsByName() throws {
        let tier = try Tier()
        try tier.write("managed-settings.json", #"{"channelsEnabled":false}"#)
        try tier.write("managed-settings.d/20-channels.json", #"{"channelsEnabled":true}"#)
        try tier.write("managed-settings.d/10-list.json", #"{"allowedChannelPlugins":[\#(Self.napcat)]}"#)
        try tier.write("managed-settings.d/.hidden.json", "not json")
        try tier.write("managed-settings.d/notes.txt", "not json")
        #expect(ChannelPolicyProbe.documents(in: tier.path) == [
            #"{"channelsEnabled":false}"#, #"{"allowedChannelPlugins":[\#(Self.napcat)]}"#, #"{"channelsEnabled":true}"#,
        ], "hidden and non-JSON files are ignored, the rest sorted by name")
        #expect(ChannelPolicyProbe.probe(directory: tier.path) == .allowlistNamesNapCat)
        try tier.write("managed-settings.d/30-off.json", #"{"channelsEnabled":false}"#)
        #expect(ChannelPolicyProbe.probe(directory: tier.path) == .channelsNotEnabled, "the last drop-in wins")
    }

    @Test func aLinkedDocumentIsFollowedLikeClaudeCodeDoes() throws {
        let tier = try Tier()
        try tier.write("elsewhere/policy.json", #"{"channelsEnabled":true}"#)
        try FileManager.default.createSymbolicLink(atPath: tier.path + "/managed-settings.json",
                                                   withDestinationPath: tier.path + "/elsewhere/policy.json")
        #expect(ChannelPolicyProbe.probe(directory: tier.path) == .defaultAllowlist)
    }

    @Test func aDocumentThatCannotBeReadIsUnreadable() throws {
        let tier = try Tier()
        try FileManager.default.createDirectory(atPath: tier.path + "/managed-settings.json", withIntermediateDirectories: true)
        #expect(ChannelPolicyProbe.probe(directory: tier.path) == .unreadable, "a directory where the file belongs")

        let invalid = try Tier()
        try invalid.write("managed-settings.json", Data([0x7B, 0xFF, 0x7D]))
        #expect(ChannelPolicyProbe.probe(directory: invalid.path) == .unreadable, "invalid UTF-8")

        let large = try Tier()
        try large.write("managed-settings.json", #"{"channelsEnabled":true}"# + String(repeating: " ", count: ChannelPolicyProbe.maxDocumentBytes))
        #expect(ChannelPolicyProbe.probe(directory: large.path) == .unreadable, "past the size cap")

        let file = try Tier()
        try file.write("managed-settings.d", "a file where the directory belongs")
        #expect(ChannelPolicyProbe.probe(directory: file.path) == .unreadable)
    }
}
