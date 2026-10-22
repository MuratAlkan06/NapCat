// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// Marker-line parsing (pure) + the real MarkerDirectoryStore against an
/// INJECTED temp dir (the production default root is never touched).
@MainActor
struct BusyMarkerStoreTests {

    // MARK: Marker line parsing

    @Test func validV1MarkerParses() {
        let marker = ClaudeActivityPolicy.parseMarker("v1 ts=1730000000 event=UserPromptSubmit pid=4321 src=unknown\n")
        #expect(marker == BusyMarker(ts: 1_730_000_000, event: "UserPromptSubmit", pid: 4321, src: "unknown"))
    }

    @Test func validMarkerWithScSource() {
        let marker = ClaudeActivityPolicy.parseMarker("v1 ts=42 event=UserPromptSubmit pid=7 src=sc")
        #expect(marker?.src == "sc")
    }

    @Test func malformedMarkersAreRejected() {
        let bad = [
            "v2 ts=1 event=UserPromptSubmit pid=1 src=sc",           // wrong version
            "v1 event=UserPromptSubmit pid=1 src=sc",                // missing ts (4 tokens)
            "v1 ts=abc event=UserPromptSubmit pid=1 src=sc",         // non-numeric ts
            "v1 ts=-5 event=UserPromptSubmit pid=1 src=sc",          // negative ts
            "v1 ts=1 event=UserPromptSubmit pid=xx src=sc",          // non-numeric pid
            "v1 ts=1 event= pid=1 src=sc",                           // empty event
            "v1 ts=1 event=UserPromptSubmit pid=1 src=sc extra",     // extra token (6)
            "v1 ts=1 event=UserPromptSubmit pid=1",                  // missing src (4 tokens)
            "",                                                      // empty
            "garbage",                                               // single token
        ]
        for line in bad {
            #expect(ClaudeActivityPolicy.parseMarker(line) == nil, "must reject: \(String(reflecting: line))")
        }
    }

    // MARK: Session-id shape (path-traversal / newline guard)

    @Test func sessionIDRegexAccepts() {
        #expect(ClaudeBusyConstants.isValidSessionID("deadbeef-0001-4abc-8def-000000000001"))
        #expect(ClaudeBusyConstants.isValidSessionID("abcd1234"), "minimum 8 chars, all hex")
        #expect(ClaudeBusyConstants.isValidSessionID("0a1b2c3d-4e5f"))
    }

    @Test func sessionIDRegexRejects() {
        let bad = [
            "abcd1234\n",        // newline (log-forgery / traversal)
            "abcd1234\r",        // CR
            "../etc/passwd",     // path traversal
            "ABCD1234",          // uppercase not allowed
            "abc",               // too short (<8)
            "-bcd1234",          // must start with a hex digit, not dash
            "abcd/1234",         // slash
            "hook.log",          // dot — the hook's own log is never marker-shaped
            "DISABLED",          // the kill-switch flag is never marker-shaped
            "",                  // empty
        ]
        for name in bad {
            #expect(!ClaudeBusyConstants.isValidSessionID(name), "must reject: \(String(reflecting: name))")
        }
    }

    // MARK: MarkerDirectoryStore against a temp dir

    private func withTempDir(_ body: (URL) throws -> Void) rethrows {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("napcat-b1-store-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test func storeReadsOnlySessionShapedParseableFiles() {
        withTempDir { root in
            let store = MarkerDirectoryStore(root: root)
            let now = Int(Date().timeIntervalSince1970)

            func write(_ name: String, _ contents: String) {
                try? contents.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            // A valid, session-shaped, parseable marker — counted.
            write("aaaa1111-0002-4abc-8def-000000000002",
                  "v1 ts=\(now) event=UserPromptSubmit pid=10 src=unknown\n")
            // Session-shaped name but malformed content — ignored.
            write("bbbb2222-0003-4abc-8def-000000000003", "not a marker\n")
            // Foreign (non-session) name with valid content — ignored (never opened).
            write("README.txt", "v1 ts=\(now) event=UserPromptSubmit pid=11 src=sc\n")
            // The hook's own log — ignored.
            write("hook.log", "some log line\n")

            let markers = store.markers()
            #expect(markers.count == 1, "only the one valid session-shaped marker is counted")
            #expect(markers.first?.pid == 10)

            // The store's markers feed the policy directly.
            let probe = ProcessProbe(enumerationSucceeded: false, confirmedCount: 0, inconclusiveCount: 0)
            #expect(ClaudeActivityPolicy.isTaskInFlight(markers: markers, now: now, proc: probe))
        }
    }

    @Test func storeLivenessSignals() {
        withTempDir { root in
            let store = MarkerDirectoryStore(root: root)
            #expect(store.markerDirExists())
            #expect(!store.hookLogExists())
            #expect(store.lastActivityEpoch() != nil)

            try? "log".write(to: root.appendingPathComponent(ClaudeBusyConstants.logFileName),
                             atomically: true, encoding: .utf8)
            #expect(store.hookLogExists())
        }
    }

    @Test func storeOnAbsentDirIsEmptyAndNotInstalled() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("napcat-b1-absent-\(UUID().uuidString)")
        let store = MarkerDirectoryStore(root: root)
        #expect(!store.markerDirExists())
        #expect(!store.hookLogExists())
        #expect(store.lastActivityEpoch() == nil)
        #expect(store.markers().isEmpty)
        #expect(store.identifiedMarkers().isEmpty)
    }

    // MARK: Track C — identified read (session id = file name) + F12 size cap

    private static let idA = "aaaa1111-0002-4abc-8def-000000000002"
    private static let idB = "bbbb2222-0003-4abc-8def-000000000003"
    private static let idOversized = "cccc3333-0004-4abc-8def-000000000004"
    private static let idAtCap = "dddd4444-0005-4abc-8def-000000000005"

    private static func write(_ root: URL, _ name: String, _ contents: String) {
        try? contents.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// A valid marker line padded with trailing spaces to exactly `bytes`
    /// bytes — it WOULD parse if read (whitespace adds no token), so only the
    /// size cap can reject it.
    private static func paddedMarker(pid: Int, bytes: Int) -> String {
        let line = "v1 ts=1730000000 event=UserPromptSubmit pid=\(pid) src=unknown"
        return line + String(repeating: " ", count: bytes - line.utf8.count)
    }

    @Test func identifiedMarkersCarryTheSessionIDAndFeedMarkers() {
        withTempDir { root in
            let store = MarkerDirectoryStore(root: root)
            Self.write(root, Self.idB, "v1 ts=200 event=waiting pid=20 src=sc\n")
            Self.write(root, Self.idA, "v1 ts=100 event=UserPromptSubmit pid=10 src=unknown\n")
            Self.write(root, "README.txt", "v1 ts=300 event=UserPromptSubmit pid=30 src=sc\n")    // foreign name
            Self.write(root, "eeee5555-0006-4abc-8def-000000000006", "not a marker\n")         // malformed

            let identified = store.identifiedMarkers()
            #expect(identified == [
                IdentifiedBusyMarker(sessionID: Self.idA,
                                     marker: BusyMarker(ts: 100, event: "UserPromptSubmit", pid: 10, src: "unknown")),
                IdentifiedBusyMarker(sessionID: Self.idB,
                                     marker: BusyMarker(ts: 200, event: "waiting", pid: 20, src: "sc")),
            ], "only session-shaped parseable files, keyed by file name, sorted by id")
            // One read path: markers() is exactly the identified read minus ids.
            #expect(store.markers() == identified.map(\.marker))
        }
    }

    @Test func oversizedMarkerIsSkippedByBothAPIs() {
        withTempDir { root in
            let store = MarkerDirectoryStore(root: root)
            let cap = ClaudeBusyConstants.maxMarkerBytes
            #expect(cap == 4096, "F12 cap is a few KB; a real marker is ~60 bytes")
            Self.write(root, Self.idA, "v1 ts=100 event=UserPromptSubmit pid=10 src=unknown\n")
            Self.write(root, Self.idOversized, Self.paddedMarker(pid: 66, bytes: cap + 1))
            Self.write(root, Self.idAtCap, Self.paddedMarker(pid: 44, bytes: cap))

            let identified = store.identifiedMarkers()
            #expect(identified.map(\.sessionID) == [Self.idA, Self.idAtCap],
                    "cap + 1 bytes is skipped; exactly the cap still parses")
            #expect(!identified.contains { $0.marker.pid == 66 })
            #expect(store.markers().map(\.pid) == [10, 44], "markers() applies the same cap")
        }
    }

    /// The hook writes markers with mktemp + mv — always a regular file. A
    /// session-shaped directory or symlink is never read (a FIFO could block).
    @Test func nonRegularSessionShapedEntriesAreSkipped() {
        withTempDir { root in
            let store = MarkerDirectoryStore(root: root)
            let elsewhere = root.appendingPathComponent("target.txt")
            try? "v1 ts=100 event=UserPromptSubmit pid=77 src=unknown\n"
                .write(to: elsewhere, atomically: true, encoding: .utf8)
            try? FileManager.default.createSymbolicLink(at: root.appendingPathComponent(Self.idA),
                                                        withDestinationURL: elsewhere)
            try? FileManager.default.createDirectory(at: root.appendingPathComponent(Self.idB),
                                                     withIntermediateDirectories: false)
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(Self.idA).path),
                    "setup: the symlink must exist")
            #expect(store.identifiedMarkers().isEmpty)
            #expect(store.markers().isEmpty)
        }
    }

    // MARK: Security review L1 — checks on the OPENED descriptor

    /// A session-shaped SYMLINK whose target is itself a valid, session-shaped
    /// REGULAR marker: the target is read under its own name, the link is
    /// refused by the open itself (`O_NOFOLLOW`) — never read through.
    @Test func aSessionShapedSymlinkToAValidMarkerIsRefusedByTheOpen() throws {
        try withTempDir { root in
            let store = MarkerDirectoryStore(root: root)
            Self.write(root, Self.idB, "v1 ts=200 event=UserPromptSubmit pid=20 src=sc\n")
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(Self.idA),
                                                       withDestinationURL: root.appendingPathComponent(Self.idB))
            let linkType = try FileManager.default.attributesOfItem(
                atPath: root.appendingPathComponent(Self.idA).path)[.type] as? FileAttributeType
            #expect(linkType == .typeSymbolicLink, "setup: idA must be a symlink")

            let identified = store.identifiedMarkers()
            #expect(identified == [IdentifiedBusyMarker(
                sessionID: Self.idB, marker: BusyMarker(ts: 200, event: "UserPromptSubmit", pid: 20, src: "sc"))],
                "only the regular file is read; the link to it is skipped")
            #expect(store.markers().map(\.pid) == [20])
        }
    }

    /// A session-shaped FIFO — and a session-shaped symlink to it — must be
    /// skipped WITHOUT blocking: `O_NONBLOCK` keeps the open from waiting for
    /// a writer and `fstat` of the descriptor refuses a non-regular file. A
    /// regression would hang here (hence the time limit), not fail quietly.
    @Test(.timeLimit(.minutes(1)))
    func aSessionShapedFifoIsSkippedWithoutBlocking() throws {
        try withTempDir { root in
            let store = MarkerDirectoryStore(root: root)
            let fifo = root.appendingPathComponent(Self.idB)
            try #require(mkfifo(fifo.path, 0o600) == 0, "setup: mkfifo failed (errno \(errno))")
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(Self.idOversized),
                                                       withDestinationURL: fifo)
            Self.write(root, Self.idA, "v1 ts=100 event=UserPromptSubmit pid=10 src=unknown\n")

            #expect(store.identifiedMarkers().map(\.sessionID) == [Self.idA],
                    "the FIFO and the link to it are skipped; the real marker still parses")
            #expect(store.markers().map(\.pid) == [10])
        }
    }

    // MARK: S7 — the installed hook copy's version stamp

    private static func stampLine(_ version: String) -> String {
        ClaudeBusyConstants.hookVersionStampPrefix + version
    }

    /// Pure parser, row by row: the FIRST stamp line decides; only 1–9 ASCII
    /// digits count; a line cut by the read cap never parses.
    @Test(arguments: [
        ("#!/bin/bash\n# napcat-hook-version: 4\n# rest\n", false, Optional(4)),
        ("#!/bin/bash\n# napcat-hook-version: 12\n", false, 12),
        ("# napcat-hook-version: 4", false, 4),                                   // whole file, no newline
        ("#!/bin/bash\n# napcat-hook-version: 4", true, nil),                    // cut: last line dropped
        ("#!/bin/bash\n# napcat-hook-version: 4\n", true, 4),                    // complete line before the cut
        ("#!/bin/bash\n# napcat-hook-version: 3\n# napcat-hook-version: 9\n", false, 3), // first wins
        ("#!/bin/bash\n# napcat-hook-version: \n", false, nil),                  // no digits
        ("#!/bin/bash\n# napcat-hook-version: 4a\n", false, nil),                // trailing junk
        ("#!/bin/bash\n# napcat-hook-version: 4\r\n", false, nil),               // CR is junk
        ("#!/bin/bash\n# napcat-hook-version: -4\n", false, nil),                // sign
        ("#!/bin/bash\n# napcat-hook-version: 1234567890\n", false, nil),        // over 9 digits
        ("#!/bin/bash\n#napcat-hook-version: 4\n", false, nil),                  // wrong prefix
        ("#!/bin/bash\n  # napcat-hook-version: 4\n", false, nil),               // indented
        ("#!/bin/bash\n# NapCat hook\n", false, nil),                            // no stamp
        ("", false, nil),
    ] as [(String, Bool, Int?)])
    func hookVersionStampParser(_ text: String, truncated: Bool, expected: Int?) {
        #expect(MarkerDirectoryStore.parseHookVersionStamp(Array(text.utf8), truncated: truncated) == expected,
                "\(String(reflecting: text)) truncated=\(truncated)")
    }

    /// Writes `contents` as the installed hook copy under a temp root and
    /// returns a store reading it (its marker root is the same temp dir).
    private func installedHookStore(_ root: URL, contents: Data?) throws -> MarkerDirectoryStore {
        let hook = root.appendingPathComponent("napcat-busy-hook.sh")
        if let contents { try contents.write(to: hook) }
        return MarkerDirectoryStore(root: root, installedHookURL: hook)
    }

    @Test func theShippedHookScriptReadsAsTheExpectedVersion() throws {
        let shipped = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/claude-busy-hook.sh")
        try withTempDir { root in
            let store = try installedHookStore(root, contents: try Data(contentsOf: shipped))
            #expect(store.installedHookVersion() == ClaudeBusyConstants.hookVersion,
                    "a fresh install of this checkout's hook must read as current")
        }
    }

    /// The version the store reads back after `contents` (nil = no file) is
    /// written as the installed copy.
    private func installedVersion(_ root: URL, _ contents: String?) throws -> Int? {
        try installedHookStore(root, contents: contents.map { Data($0.utf8) }).installedHookVersion()
    }

    @Test func installedHookVersionReadsTheStampOrNil() throws {
        try withTempDir { root in
            let absent = try installedVersion(root, nil)
            #expect(absent == nil, "absent ⇒ nil")
            let three = try installedVersion(root, "#!/bin/bash\n\(Self.stampLine("3"))\necho\n")
            #expect(three == 3)
            let unstamped = try installedVersion(root, "#!/bin/bash\n# an old install\n")
            #expect(unstamped == nil, "no stamp ⇒ nil")
            let empty = try installedVersion(root, "")
            #expect(empty == nil, "empty ⇒ nil")
        }
    }

    /// Only the first `installedHookReadBytes` bytes are read: a stamp that
    /// starts past them is never seen, and one cut by the cap never parses
    /// as a smaller number — while a big file with the stamp on line 2 reads.
    @Test func installedHookVersionReadsOnlyTheFirstKiB() throws {
        let cap = ClaudeBusyConstants.installedHookReadBytes
        #expect(cap == 1024)
        try withTempDir { root in
            let pad = "#!/bin/bash\n# " + String(repeating: "x", count: cap) + "\n"
            let late = try installedVersion(root, pad + Self.stampLine("4") + "\n")
            #expect(late == nil, "a stamp past the first KiB is never read")

            // "…version: 12" cut right after the "1" by the cap.
            let head = "#!/bin/bash\n"
            let filler = "# " + String(repeating: "y", count: cap - head.utf8.count - Self.stampLine("1").utf8.count - 3) + "\n"
            let cut = head + filler + Self.stampLine("12") + "\n"
            #expect(Array(cut.utf8)[cap - 1] == UInt8(ascii: "1"), "setup: the cap falls right after the 1")
            let cutVersion = try installedVersion(root, cut)
            #expect(cutVersion == nil, "a stamp cut by the cap must not read as 1")

            let big = try installedVersion(root, "#!/bin/bash\n" + Self.stampLine("4") + "\n"
                                           + String(repeating: "# body\n", count: 5000))
            #expect(big == 4)
        }
    }

    /// Same descriptor checks as a marker: a symlink (even to a valid hook),
    /// a directory and a FIFO are refused — the FIFO without blocking.
    @Test(.timeLimit(.minutes(1)))
    func installedHookVersionRefusesNonRegularFiles() throws {
        try withTempDir { root in
            let real = root.appendingPathComponent("real-hook.sh")
            try Data("#!/bin/bash\n\(Self.stampLine("4"))\n".utf8).write(to: real)
            let link = root.appendingPathComponent("link-hook.sh")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
            #expect(MarkerDirectoryStore(root: root, installedHookURL: real).installedHookVersion() == 4)
            #expect(MarkerDirectoryStore(root: root, installedHookURL: link).installedHookVersion() == nil,
                    "O_NOFOLLOW: a symlinked copy is never read through")

            let dir = root.appendingPathComponent("dir-hook.sh")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            #expect(MarkerDirectoryStore(root: root, installedHookURL: dir).installedHookVersion() == nil)

            let fifo = root.appendingPathComponent("fifo-hook.sh")
            try #require(mkfifo(fifo.path, 0o600) == 0, "setup: mkfifo failed (errno \(errno))")
            #expect(MarkerDirectoryStore(root: root, installedHookURL: fifo).installedHookVersion() == nil)
        }
    }

    /// The bounded read decodes strictly as UTF-8: invalid bytes are skipped
    /// (as before), an empty file is skipped, a normal marker parses.
    @Test func undecodableAndEmptyMarkersAreSkipped() throws {
        try withTempDir { root in
            let store = MarkerDirectoryStore(root: root)
            try Data([0x76, 0x31, 0x20, 0xFF, 0xFE]).write(to: root.appendingPathComponent(Self.idB))
            try Data().write(to: root.appendingPathComponent(Self.idOversized))
            Self.write(root, Self.idA, "v1 ts=100 event=UserPromptSubmit pid=10 src=unknown\n")
            #expect(store.identifiedMarkers() == [IdentifiedBusyMarker(
                sessionID: Self.idA, marker: BusyMarker(ts: 100, event: "UserPromptSubmit", pid: 10, src: "unknown"))])
        }
    }
}
