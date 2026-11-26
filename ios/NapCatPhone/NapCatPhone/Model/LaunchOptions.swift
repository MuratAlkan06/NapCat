import Foundation

/// Launch arguments (the `UserDefaults` argument domain), so a simulator run
/// can show any state, for example
/// `xcrun simctl launch booted com.muratalkan.napcat.phone -NapCatFixture empty`.
/// Unknown or missing values fall back to the defaults below.
///
/// A recognised `-NapCatFixture` value also forces the fixture source on a
/// device build (screenshots, demos); without one, a device build shows the
/// alerts it receives (`AlertSourceKind.select`). `-NapCatConnection` only
/// applies to fixtures: a live pill is probed, never chosen. It takes the
/// probed states only; `checking` is a live launch's pre-probe state and
/// falls back like an unknown value. `-NapCatScreen settings` opens the
/// launch on Settings (screenshots); it does not force fixtures.
/// `-NapCatRequest pending|expired|withdrawn|unpaired|changed` opens the
/// launch on a fixture permission prompt in that state (F4, slice S3; the
/// last two since S-PAIR-B: the phone unpaired, or its biometrics changed
/// since pairing), answered by a fixture writer and signed by a fixture
/// key; it leaves the alert list's source alone.
/// `-NapCatPairing scan|camera|cameraOff|code|stray|taken|noCamera` opens the
/// launch on the pairing screen (F4, slice S-PAIR-B) over a fixture ceremony: a
/// software key in memory, a fixture writer, a fixture camera (the
/// simulator has none) and the real biometric gate; nothing leaves the
/// phone. It is the pairing screen's only way in until the pairing record
/// path exists. One fixture at a time: a request fixture is not combined
/// with it.
struct LaunchOptions: Equatable, Sendable {
    static let fixtureKey = "NapCatFixture"
    static let connectionKey = "NapCatConnection"
    static let screenKey = "NapCatScreen"
    static let requestKey = "NapCatRequest"
    static let pairingKey = "NapCatPairing"

    /// The screen a launch opens on.
    enum Screen: String, Sendable {
        case receiver
        case settings
    }

    var fixture: FixtureSet = .populated
    var connection: ConnectionState = .connected
    /// Whether a recognised fixture value was passed.
    var fixtureRequested = false
    var screen: Screen = .receiver
    /// The fixture permission prompt to open on, if any.
    var request: FixtureRequestState?
    /// The fixture pairing to open on, if any.
    var pairing: FixturePairingState?

    init() {}

    /// `value(key)` returns the raw string for a key, or nil.
    init(value: (String) -> String?) {
        if let raw = value(Self.fixtureKey), let fixture = FixtureSet(rawValue: raw) {
            self.fixture = fixture
            self.fixtureRequested = true
        }
        if let raw = value(Self.connectionKey), let connection = ConnectionState(rawValue: raw),
           ConnectionState.probed.contains(connection) {
            self.connection = connection
        }
        if let raw = value(Self.screenKey), let screen = Screen(rawValue: raw) {
            self.screen = screen
        }
        if let raw = value(Self.requestKey), let request = FixtureRequestState(rawValue: raw) {
            self.request = request
        }
        if let raw = value(Self.pairingKey), let pairing = FixturePairingState(rawValue: raw) {
            self.pairing = pairing
        }
    }

    static func fromLaunchArguments(_ defaults: UserDefaults = .standard) -> LaunchOptions {
        LaunchOptions { defaults.string(forKey: $0) }
    }
}
