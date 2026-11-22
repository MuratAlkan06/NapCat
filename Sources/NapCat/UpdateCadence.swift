// UPDATE CHECK (issue #111), part 2: WHEN a check may run. PURE — no
// imports, no I/O, no clock (the caller passes `now`). Table-tested in
// UpdateCadenceTests.

/// The update check's cadence. There are NO timers anywhere in the feature:
/// a check only ever starts from a user action — the "Check for Updates…"
/// button (always allowed), or opening the menu or the Settings window,
/// which starts an OPPORTUNISTIC check only when automatic checks are on and
/// the last attempt is at least `interval` old. The attempt time is recorded
/// when a check starts, so a failed check waits out the interval too — a Mac
/// that is offline does not retry on every menu open.
enum UpdateCadence {
    /// The minimum gap between two opportunistic checks: 24 h.
    static let interval: Double = 24 * 60 * 60

    /// `updateCheckAutoEnabled` as stored. Unset ⇒ ON (the gate's default:
    /// flipping the feature to opt-in is this one line). A stored Bool is
    /// itself; anything else — a hand-written string, a number other than
    /// 0/1 — reads as OFF: a junk value most likely came from someone trying
    /// to turn the check off, so it never turns network traffic on.
    static func autoEnabled(stored: Any?) -> Bool {
        guard let stored else { return true }
        return (stored as? Bool) ?? false
    }

    /// `updateCheckLastAttempt` as stored: epoch seconds, or nil (never, or
    /// not a finite number).
    static func lastAttempt(stored: Any?) -> Double? {
        guard let seconds = stored as? Double, seconds.isFinite else { return nil }
        return seconds
    }

    /// Whether opening the menu or the Settings window may start a check.
    /// Never while automatic checks are off. Due when nothing was ever
    /// attempted, when the last attempt is at least `interval` old, or when
    /// it lies in the FUTURE (the clock was set back): waiting for the clock
    /// to catch up could otherwise silence the check for days.
    static func opportunisticCheckDue(autoEnabled: Bool, lastAttempt: Double?, now: Double) -> Bool {
        guard autoEnabled else { return false }
        guard let lastAttempt else { return true }
        return now < lastAttempt || now - lastAttempt >= interval
    }
}
