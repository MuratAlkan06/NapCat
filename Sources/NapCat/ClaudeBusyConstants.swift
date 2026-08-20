import Foundation

/// Single Swift source of truth for the constants shared with the companion
/// hook script (scripts/claude-busy-hook.sh) and its installer. A PARITY LINT
/// (ClaudeBusyHookScriptTests) byte-matches the marker-dir path, the
/// session-id regex, the marker-line grammar tokens, and the five hook event
/// names between this file and the shell script — the watchdog byte-match
/// precedent (WatchdogControllerTests) applied to Track B.
///
/// Track B is READ-ONLY and Claude-scoped: nothing here sends a message, runs
/// osascript, touches Messages, registers an IOKit sleep notification, or adds
/// a UserDefaults key (all deferred to B2). NapCat only READS the markers this
/// hook writes and MAY write its own kill-switch flag inside the marker dir.
enum ClaudeBusyConstants {
    /// Marker directory, relative to the user's home. MUST byte-match the
    /// `$HOME/…` path the shell hook uses (parity lint).
    static let markerDirRelativePath = "Library/Application Support/NapCat/claude-busy"

    /// Kill-switch flag file (Layer 6): present ⇒ the hook no-ops and NapCat
    /// shows "detection paused". NapCat writes its OWN state dir here — never
    /// ~/.claude/settings.json.
    static let disabledFlagName = "DISABLED"

    /// The hook's private diagnostics log; its presence is NapCat's
    /// "has the hook ever run" liveness signal. Its name is not session-id
    /// shaped, so the sweep never touches it.
    static let logFileName = "hook.log"

    /// Session-id shape. MUST byte-match the shell `SESSION_RE` (parity lint):
    /// lowercase-hex-and-dash, 8–64 chars, first char hex. Path-traversal and
    /// newline guard — only files matching this are ever read or swept.
    static let sessionIDRegex = "^[0-9a-f][0-9a-f-]{7,63}$"

    /// Marker version tag (first token of a marker line).
    static let markerVersion = "v1"

    /// Ordered token prefixes after the version tag — the grammar
    /// `v1 ts=… event=… pid=… src=…`. MUST byte-match the shell `printf`
    /// (parity lint). `src` is DEBUG-ONLY and never a policy input.
    static let markerTokenPrefixes = ["ts=", "event=", "pid=", "src="]

    /// UserPromptSubmit sets the marker (a turn is in flight).
    static let setEvent = "UserPromptSubmit"
    /// Any of these clears it (turn ended / idle prompt / session gone).
    static let clearEvents = ["Stop", "StopFailure", "SessionEnd", "Notification"]
    /// All five events the hook is registered for.
    static var allEvents: [String] { [setEvent] + clearEvents }

    /// Freshness / sweep cap: a marker older than 12h is never counted busy
    /// and is swept. MUST match the shell `CAP`.
    static let freshnessCapSeconds = 43_200

    /// Stable installed hook path, relative to home. The installer copies the
    /// script here (NOT under dist/, so `make clean` never removes it).
    static let installedHookRelativePath = ".claude/hooks/napcat-busy-hook.sh"

    /// Absolute marker directory for the current user.
    static var markerDirURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(markerDirRelativePath)
    }

    /// Whole-string session-id validation, matching the shell hook exactly:
    /// reject any newline/CR first (path-traversal / log-forgery guard), then
    /// require the anchored regex. Used to filter which files in the marker
    /// dir are ever parsed or swept.
    static func isValidSessionID(_ candidate: String) -> Bool {
        if candidate.contains("\n") || candidate.contains("\r") { return false }
        return candidate.range(of: sessionIDRegex, options: .regularExpression) != nil
    }
}
