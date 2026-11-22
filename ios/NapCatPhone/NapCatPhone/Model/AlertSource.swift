/// THE seam between the screen and where its alerts come from. Two
/// conformances exist: `FixtureAlertSource` (previews, tests, simulator
/// builds, screenshots) and `CloudKitAlertSource` (a device build reading the
/// owner's private iCloud database, the one the Mac writes). Nothing outside
/// `CloudKitAlertSource.swift` knows which one it is talking to.
protocol AlertSource: Sendable {
    /// Checks whether alerts can arrive at all (the iCloud account) and, for
    /// a live source, makes sure the one push subscription exists. Called on
    /// launch, on every foreground and on every push, so it must be cheap
    /// once set up and idempotent. Never throws: a failure is a state.
    func connect() async -> AccountAvailability

    /// The newest alerts, newest first. A failure leaves the list as it was.
    func fetchRecent() async throws -> [PhoneAlert]

    /// The record name a push's payload carries, when the push is this
    /// source's and names one; nil otherwise (the query alone then catches
    /// up). Synchronous and pure: it reads the payload, nothing else.
    func pushedRecordName(in userInfo: [AnyHashable: Any]) -> String?

    /// One alert by its record name, fetched directly rather than through
    /// the query, whose index can lag a record created moments ago. nil when
    /// the record is not a well-formed alert.
    func fetchAlert(named recordName: String) async throws -> PhoneAlert?
}

/// Whether alerts can reach this iPhone through iCloud: the account, and
/// whether new alerts are pushed.
enum AccountAvailability: Equatable, CaseIterable, Sendable {
    /// The account works and the push subscription exists.
    case available
    /// The account works, so alerts can be fetched, but the push
    /// subscription is not confirmed on the server, so none is pushed.
    case availableWithoutPush
    /// No usable account: nothing can be fetched or pushed.
    case unavailable

    /// Whether alerts can be fetched at all.
    var canFetch: Bool { self != .unavailable }
}

/// The notification side of "can alerts reach me": whether the iPhone may
/// show (and buzz for) an alert, plus the one-time permission prompt and the
/// remote-notification registration. Fixtures use a fixed answer; only the
/// live gate (`SystemNotificationGate`) touches the notification center.
@MainActor
protocol NotificationGate {
    /// Once per launch: ask for permission (the system shows the prompt at
    /// most once) and register for remote notifications.
    func prepare() async
    /// Re-read on every refresh: the owner may have changed Settings.
    func alertsAllowed() async -> Bool
}

/// Which source a launch uses.
enum AlertSourceKind: Equatable, Sendable {
    case fixture
    case cloudKit

    /// A recognised `-NapCatFixture` argument always wins; otherwise a build
    /// that can hold the iCloud entitlement goes live and any other build
    /// shows fixtures.
    static func select(options: LaunchOptions, liveCapable: Bool) -> AlertSourceKind {
        options.fixtureRequested || !liveCapable ? .fixture : .cloudKit
    }
}

/// Whether this build can talk to iCloud at all.
///
/// Simulator builds are fixture-only. The unsigned simulator path
/// (`CODE_SIGNING_ALLOWED=NO`, used for every test run) carries no
/// entitlements, and building a CloudKit container in an unentitled process
/// does not return an error: it traps (spike-proven on the Mac, 2026-11-20).
/// The simulator also only reaches CloudKit's Development environment, never
/// the Production one the Mac writes. A device build is always signed, with
/// the entitlements from project.yml. iOS has no public API for reading the
/// process's own entitlements, so the build destination is the gate.
enum LiveCapability {
    static let isAvailable: Bool = {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }()
}
