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
struct LaunchOptions: Equatable, Sendable {
    static let fixtureKey = "NapCatFixture"
    static let connectionKey = "NapCatConnection"
    static let screenKey = "NapCatScreen"

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
    }

    static func fromLaunchArguments(_ defaults: UserDefaults = .standard) -> LaunchOptions {
        LaunchOptions { defaults.string(forKey: $0) }
    }
}
