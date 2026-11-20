import Foundation

/// Part-1 scaffolding: the screen's inputs come from launch arguments (the
/// `UserDefaults` argument domain), so a simulator run can show any state,
/// for example
/// `xcrun simctl launch booted com.muratalkan.napcat.phone -NapCatFixture empty`.
/// Unknown or missing values fall back to the defaults below.
struct LaunchOptions: Equatable, Sendable {
    static let fixtureKey = "NapCatFixture"
    static let connectionKey = "NapCatConnection"

    var fixture: FixtureSet = .populated
    var connection: ConnectionState = .connected

    init() {}

    /// `value(key)` returns the raw string for a key, or nil.
    init(value: (String) -> String?) {
        if let raw = value(Self.fixtureKey), let fixture = FixtureSet(rawValue: raw) { self.fixture = fixture }
        if let raw = value(Self.connectionKey), let connection = ConnectionState(rawValue: raw) {
            self.connection = connection
        }
    }

    static func fromLaunchArguments(_ defaults: UserDefaults = .standard) -> LaunchOptions {
        LaunchOptions { defaults.string(forKey: $0) }
    }
}
