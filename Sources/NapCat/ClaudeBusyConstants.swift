import Foundation

/// Single Swift source of truth for the constants shared with the companion
/// hook script (scripts/claude-busy-hook.sh) and its installer. A PARITY LINT
/// (ClaudeBusyHookScriptTests) byte-matches the marker-dir path, the
/// session-id regex, the marker-line grammar tokens, the six registered hook
/// event names, (Track C, C1) the Notification-type classes plus the synthetic
/// `waiting` event token, (B-2) the synthetic `waiting-after-stop` token
/// and the two marker-phase token lists, and (S7) the hook version stamp
/// between this file and the shell script — the watchdog byte-match precedent
/// (WatchdogControllerTests) applied to Track B.
///
/// The marker side is Claude-scoped and one-way: NapCat only READS the markers
/// this hook writes (and MAY write its own kill-switch flag inside the marker
/// dir); it never writes a marker and never writes under ~/.claude — its one
/// read there is the first KiB of the installed hook copy, for the version
/// stamp (S7, `MarkerDirectoryStore.installedHookVersion`). The app DOES
/// send ntfy pushes (the B2 lid alert, the Track C session alerts), but from
/// its own state in a closed vocabulary — nothing in this file sends, and no
/// marker content ever reaches a message.
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
    /// The REGISTRATION list of reconcile events (turn ended / idle prompt /
    /// session gone / a subagent ended). None of them is an unconditional
    /// clear any more: `Notification` is reconciled by its
    /// `notification_type` (C1 — keep-on-wait, keep-on-resume, otherwise the
    /// B3 background-task check and then clear), and `SubagentStop` (B3,
    /// phase-aware since B-2) KEEPS a marker whose main turn is still in
    /// flight. The parity lints byte-match these names against the shell
    /// script and set-match them against the installer's and uninstaller's
    /// printed registration lists.
    static let clearEvents = ["Stop", "StopFailure", "SessionEnd", "Notification", "SubagentStop"]
    /// All six events the hook is registered for.
    static var allEvents: [String] { [setEvent] + clearEvents }

    /// Synthetic marker event token (C1): a Notification of a WAITING type
    /// rewrites the marker as `event=waiting` (never the raw "Notification"),
    /// so a reader can tell "Claude is waiting on the user" apart from a
    /// background-task or resume keep without new marker grammar. MUST
    /// byte-match the shell `WAITING_EVENT` (parity lint).
    static let waitingEventToken = "waiting"

    /// Synthetic marker event token (B-2): the same WAITING class as
    /// `waitingEventToken`, written when the main turn had ALREADY ENDED (the
    /// marker was post-Stop), so the phase survives the wait. The app treats
    /// both tokens as waiting. MUST byte-match the shell
    /// `WAITING_AFTER_STOP_EVENT` (parity lint).
    static let waitingAfterStopEventToken = "waiting-after-stop"

    /// B-2 marker PHASE, encoded in the marker's `event` token: the main turn
    /// is still IN FLIGHT. MUST byte-match the shell `marker_phase` case
    /// pattern, in order (parity lint).
    static let inFlightEventTokens = ["UserPromptSubmit", "Notification", "waiting"]

    /// B-2 marker PHASE: the main turn has ENDED (only background work keeps
    /// the marker). MUST byte-match the shell `marker_phase` case pattern, in
    /// order (parity lint). An absent / unparseable marker, or a token in
    /// neither list, is phase "none". `SessionEnd` (S11) is written only when
    /// background work outlived the session — the main turn is over, so the
    /// last subagent ending must clear it like any post-Stop marker.
    static let postStopEventTokens = ["Stop", "StopFailure", "SessionEnd", "SubagentStop", "waiting-after-stop"]

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

    /// Track C (risk F12): read cap for ONE marker file. A real marker line is
    /// ~60 bytes; anything larger than this is not a marker the hook wrote and
    /// is skipped WITHOUT being read in full (the store checks the size before
    /// opening and reads at most `maxMarkerBytes + 1` bytes). App-side only —
    /// the shell hook never writes anything near this size.
    static let maxMarkerBytes = 4096

    /// Stable installed hook path, relative to home. The installer copies the
    /// script here (NOT under dist/, so `make clean` never removes it). Only
    /// BusyMarkerStore.swift may resolve it (structure lint).
    static let installedHookRelativePath = ".claude/hooks/napcat-busy-hook.sh"

    /// S7 — the version of the hook script THIS build expects. MUST equal the
    /// shell script's `# napcat-hook-version: N` stamp (parity lint); bump
    /// both whenever the hook's behavior changes, so an installed copy left
    /// behind by an earlier install reads as out of date in the menu.
    static let hookVersion = 4

    /// The stamp line's fixed prefix; the rest of the line is the decimal
    /// version. It must sit within the first `installedHookReadBytes` bytes.
    static let hookVersionStampPrefix = "# napcat-hook-version: "

    /// Read cap for the installed hook copy: only this many leading bytes are
    /// ever read (the stamp is on line 2).
    static let installedHookReadBytes = 1024

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
