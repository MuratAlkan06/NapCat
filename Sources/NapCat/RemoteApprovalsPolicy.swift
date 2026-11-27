import NapCatWire

// F4 slice S2: the Mac's remote-approvals toggle and its kill switch, as pure
// state. Design: design/remote-approvals.md (opt-in on both sides, the kill
// switch). I/O-free — no socket, no defaults, no clock, no logging: the
// controller (RemoteApprovalsController) feeds it events and performs the
// effects it returns, so every rule here is a table row in
// RemoteApprovalsPolicyTests.
//
// Fail-dark: nothing in this slice can forward a prompt. Listening only
// means NapCat hears a wired session's prompts and keeps them local, because
// no build arms forwarding: arming is the Mac's decision, and it waits on
// the Mac's live record path and the seam's check of which program listens
// (#221), among the items owed before arming.

/// Where the Mac side of remote approvals stands.
enum RemoteApprovalsPhase: Equatable, Sendable {
    /// Switched off — the default. Nothing exists: no socket, no probe, no
    /// listener, so a wired session finds nothing of NapCat's to connect to
    /// (the seam checks the listener's user, not which program it is).
    case off
    /// Switched on and listening on the seam: prompts are classified and
    /// audited, and stay on this Mac.
    case listening
    /// Switched on, but the seam's socket could not be opened (or has not
    /// been confirmed yet): nothing listens and every prompt stays local.
    case unavailable
}

/// What one transition asks the controller to do.
enum RemoteApprovalsEffect: Equatable, Sendable {
    /// Build the seam host if there is none yet and start listening; report
    /// the outcome back as `.listened(_:)`.
    case startListening
    /// The kill switch: every open prompt is withdrawn, every channel server
    /// is disconnected, and the socket is removed.
    case stopListening
    /// Read the managed-settings channel policy, and report it back as
    /// `.probed(_:)`.
    case probe
}

/// What can happen to the toggle.
enum RemoteApprovalsEvent: Equatable, Sendable {
    /// The stored toggle as read: at launch, on every menu or Settings open,
    /// and after the user flips it.
    case toggle(Bool)
    /// The outcome of a `.startListening`.
    case listened(Bool)
    /// The outcome of a `.probe`.
    case probed(ChannelPolicyFinding)
    /// The menu or the Settings window opened: while on, the policy is read
    /// again and a socket that could not be opened is tried again.
    case refresh
    /// NapCat is quitting: a hard stop, final.
    case shutdown
}

/// The toggle's state machine. Default OFF; only a stored `true` turns it on.
struct RemoteApprovalsState: Equatable, Sendable {
    private(set) var phase: RemoteApprovalsPhase = .off
    /// The last policy reading, while on (cleared by the kill switch).
    private(set) var finding: ChannelPolicyFinding?
    /// After `.shutdown` nothing starts again.
    private(set) var shutDown = false

    var enabled: Bool { phase != .off }

    /// Turning on is pessimistic: the phase reads `.unavailable` until the
    /// listen is confirmed, so nothing ever claims a socket that is not
    /// there. Turning off — from either on phase — is the kill switch, every
    /// time; turning off what is already off does nothing.
    mutating func apply(_ event: RemoteApprovalsEvent) -> [RemoteApprovalsEffect] {
        guard !shutDown else { return [] }
        switch (event, phase) {
        case (.toggle(true), .off):
            phase = .unavailable
            return [.startListening, .probe]
        case (.toggle(true), _):
            return []
        case (.toggle(false), .off):
            return []
        case (.toggle(false), _):
            return killSwitch()
        case (.listened, .off):
            // A late outcome for a listen the kill switch already undid.
            return []
        case (.listened(let started), _):
            phase = started ? .listening : .unavailable
            return []
        case (.probed, .off):
            return []
        case (.probed(let reading), _):
            finding = reading
            return []
        case (.refresh, .off):
            return []
        case (.refresh, .listening):
            return [.probe]
        case (.refresh, .unavailable):
            return [.startListening, .probe]
        case (.shutdown, .off):
            shutDown = true
            return []
        case (.shutdown, _):
            shutDown = true
            return killSwitch()
        }
    }

    private mutating func killSwitch() -> [RemoteApprovalsEffect] {
        phase = .off
        finding = nil
        return [.stopListening]
    }
}

/// What keeps the answer to a prompt on this Mac instead of letting the
/// paired iPhone give it: the first of the three conditions that fails
/// (`RemoteApprovalsPolicy.hold`).
enum RemoteApprovalsHold: Equatable, Sendable {
    /// The toggle is off.
    case off
    /// The toggle is on, but no iPhone is paired.
    case notPaired
    /// On and paired, but no live record path reaches the iPhone (none
    /// exists in this build).
    case noRecordPath
}

enum RemoteApprovalsPolicy {
    /// In debugBattery mode the feature is STRUCTURALLY absent (the shape of
    /// `LidGuardPolicy.lidGuardMayBeConstructed`): no toggle, no socket.
    static func remoteApprovalsMayBeConstructed(debugBattery: Bool) -> Bool {
        !debugBattery
    }

    /// Whether remote answers are held, and why: nil only when the toggle is
    /// on, an iPhone is paired and the live record path exists; otherwise the
    /// first of those that fails, in that order. The caller reads each fact.
    /// In this build the answer only shapes what the toggle row says: nothing
    /// is handed to the seam host, which stays unarmed.
    static func hold(enabled: Bool, paired: Bool, recordPath: Bool) -> RemoteApprovalsHold? {
        guard enabled else { return .off }
        guard paired else { return .notPaired }
        guard recordPath else { return .noRecordPath }
        return nil
    }

    /// `remoteApprovalsEnabled` as stored, read twice (#205): `stored` is
    /// what the app's OWN persistent domain holds, `searched` what the
    /// defaults search list reads — where a launch argument, a managed
    /// setting or a per-host value (`defaults -currentHost`) outranks the
    /// app's domain, and the global domain and the registered defaults sit
    /// below it. ON only when both are a Bool `true`: unset, `false`, or
    /// anything else — a hand-written string, a number other than 0/1 —
    /// reads as OFF, so a junk value never arms a remote-control feature. A
    /// value outside the app's own domain can turn it off (one that outranks
    /// it disagrees) but never on (the app's own domain does not hold it).
    static func enabled(stored: Any?, searched: Any?) -> Bool {
        (stored as? Bool) == true && (searched as? Bool) == true
    }
}
