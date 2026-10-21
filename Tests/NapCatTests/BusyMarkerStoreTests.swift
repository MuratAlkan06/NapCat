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

    private func withTempDir(_ body: (URL) -> Void) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("napcat-b1-store-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        body(root)
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
}
