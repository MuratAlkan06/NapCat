// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat
@testable import NapCatWire

/// The managed-settings probe reads with a bound: only a regular file, its
/// size checked on the open file before a byte is read, the read itself
/// capped, and nothing at the path can make it wait. Scratch directories only
/// — never the real system directory.
struct ChannelPolicyProbeBoundsTests {
    typealias Tier = ChannelPolicyProbeTests.Tier

    /// Runs the probe off this thread; nil if it has not answered in time.
    static func probe(_ directory: String, within seconds: Double) -> ChannelPolicyFinding? {
        let answer = ApprovalsInbox<ChannelPolicyFinding>()
        Thread.detachNewThread { answer.put(ChannelPolicyProbe.probe(directory: directory)) }
        return answer.next(within: seconds)
    }

    /// A FIFO where the settings file belongs: refused at once — never a
    /// read that waits for a writer that may never come.
    @Test func aFIFOIsRefusedWithoutWaiting() throws {
        let tier = try Tier()
        let fifo = tier.path + "/" + ChannelPolicyProbe.settingsFileName
        try #require(mkfifo(fifo, 0o600) == 0)
        let finding = Self.probe(tier.path, within: ApprovalsInbox<ChannelPolicyFinding>.arrivalSeconds)
        if finding == nil {
            // Release a probe stuck on the FIFO so the test run can end.
            let writer = open(fifo, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
        }
        #expect(finding == .unreadable, "the probe must not wait on a FIFO")
    }

    /// The same for a drop-in.
    @Test func aFIFODropInIsRefusedWithoutWaiting() throws {
        let tier = try Tier()
        try tier.write(ChannelPolicyProbe.dropInDirectoryName + "/10-ok.json", #"{"channelsEnabled":true}"#)
        let fifo = tier.path + "/" + ChannelPolicyProbe.dropInDirectoryName + "/20-pipe.json"
        try #require(mkfifo(fifo, 0o600) == 0)
        let finding = Self.probe(tier.path, within: ApprovalsInbox<ChannelPolicyFinding>.arrivalSeconds)
        if finding == nil {
            let writer = open(fifo, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
        }
        #expect(finding == .unreadable)
    }

    /// Exactly the cap is read; one byte more is not — and a huge file is
    /// refused from its size alone (a sparse file: nothing is ever read).
    @Test func theCapIsCheckedBeforeReading() throws {
        let cap = ChannelPolicyProbe.maxDocumentBytes
        let body = #"{"channelsEnabled":true}"#
        let exact = try Tier()
        try exact.write(ChannelPolicyProbe.settingsFileName, body + String(repeating: " ", count: cap - body.utf8.count))
        #expect(ChannelPolicyProbe.probe(directory: exact.path) == .defaultAllowlist, "exactly the cap is read")

        let over = try Tier()
        try over.write(ChannelPolicyProbe.settingsFileName, body + String(repeating: " ", count: cap - body.utf8.count + 1))
        #expect(ChannelPolicyProbe.probe(directory: over.path) == .unreadable)

        let huge = try Tier()
        let path = huge.path + "/" + ChannelPolicyProbe.settingsFileName
        try huge.write(ChannelPolicyProbe.settingsFileName, body)
        let descriptor = open(path, O_WRONLY)
        try #require(descriptor >= 0)
        try #require(ftruncate(descriptor, 8 * 1_024 * 1_024 * 1_024) == 0, "an 8 GiB sparse file")
        close(descriptor)
        let started = Date()
        #expect(ChannelPolicyProbe.read(path) == nil)
        #expect(Date().timeIntervalSince(started) < 1, "refused from its size, not read")
    }

    /// Only a regular file is a document: a directory ending in .json, or a
    /// link to a device, is unreadable. (A link to a regular file is still
    /// followed, as Claude Code does — ChannelPolicyProbeTests.)
    @Test func onlyARegularFileIsADocument() throws {
        let tier = try Tier()
        try FileManager.default.createDirectory(atPath: tier.path + "/" + ChannelPolicyProbe.dropInDirectoryName
                                                    + "/10-dir.json", withIntermediateDirectories: true)
        #expect(ChannelPolicyProbe.probe(directory: tier.path) == .unreadable, "a directory named like a drop-in")

        let device = try Tier()
        try FileManager.default.createSymbolicLink(atPath: device.path + "/" + ChannelPolicyProbe.settingsFileName,
                                                   withDestinationPath: "/dev/null")
        #expect(Self.probe(device.path, within: ApprovalsInbox<ChannelPolicyFinding>.arrivalSeconds) == .unreadable,
                "a device is not a document")
    }
}
