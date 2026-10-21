import Foundation

/// Single Swift source of truth for the constants shared with the companion
/// hook script (scripts/claude-busy-hook.sh) and its installer. A PARITY LINT
/// (ClaudeBusyHookScriptTests) byte-matches the marker-dir path, the
/// session-id regex, the marker-line grammar tokens, the five hook event
/// names and (Track C, C1) the Notification-type classes plus the synthetic
/// `waiting` event token between this file and the shell script — the
/// watchdog byte-match precedent (WatchdogControllerTests) applied to Track B.
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
    /// The B1-era REGISTRATION list of reconcile events (turn ended / idle
    /// prompt / session gone). Since Track C slice C1, `Notification` is NOT
    /// an unconditional clear: it is reconciled by its `notification_type` —
    /// keep-on-wait (`waitingNotificationTypes`), keep-on-resume
    /// (`resumeNotificationTypes`), otherwise the B3 background-task check and
    /// then clear. The array itself is unchanged (the parity lint byte-matches
    /// these event names against the shell script).
    static let clearEvents = ["Stop", "StopFailure", "SessionEnd", "Notification"]
    /// All five events the hook is registered for.
    static var allEvents: [String] { [setEvent] + clearEvents }

    /// Synthetic marker event token (C1): a Notification of a WAITING type
    /// rewrites the marker as `event=waiting` (never the raw "Notification"),
    /// so a reader can tell "Claude is waiting on the user" apart from a
    /// background-task or resume keep without new marker grammar. MUST
    /// byte-match the shell `WAITING_EVENT` (parity lint).
    static let waitingEventToken = "waiting"

    /// `notification_type` values that mean Claude is BLOCKED on the user: the
    /// hook KEEPS the marker, rewritten with `waitingEventToken`. MUST
    /// byte-match the shell case pattern, in order (parity lint).
    /// `quota_auto_resume_disabled` belongs here: Claude Code ended a
    /// usage-limit wait WITHOUT continuing, so nothing proceeds until the user
    /// acts — the same shape as a permission wait.
    static let waitingNotificationTypes = [
        "permission_prompt",
        "elicitation_dialog",
        "elicitation_url_dialog",
        "agent_needs_input",
        "quota_auto_resume_stale",
        "quota_auto_resume_disabled",
    ]

    /// `notification_type` values that mean work CONTINUES: the hook KEEPS the
    /// marker with the real event name (`Notification`). MUST byte-match the
    /// shell case pattern, in order (parity lint).
    static let resumeNotificationTypes = [
        "quota_auto_resume_fired",
        "elicitation_complete",
        "elicitation_response",
    ]

    /// The documented `notification_type` values that CLEAR the marker
    /// (unless a background task is still running — B3). Documentation and
    /// parity only: the hook has no clear list — ANY type outside the two keep
    /// lists (unknown, missing, non-string, malformed) clears.
    static let clearNotificationTypes = [
        "idle_prompt",
        "auth_success",
        "agent_completed",
    ]

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
