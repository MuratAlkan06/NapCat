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
    }
}
