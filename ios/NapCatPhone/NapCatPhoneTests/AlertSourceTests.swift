import Foundation
@testable import NapCatPhone
import Testing
import UserNotifications

/// Which source a launch uses, the fixture conformance, and how a probe
/// becomes the connection pill. Nothing here touches iCloud or the
/// notification center.
@Suite struct AlertSourceTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: Selection

    @Test func aDeviceBuildWithoutAFixtureArgumentGoesLive() {
        #expect(AlertSourceKind.select(options: LaunchOptions(), liveCapable: true) == .cloudKit)
    }

    @Test func aBuildThatCannotHoldTheEntitlementShowsFixtures() {
        #expect(AlertSourceKind.select(options: LaunchOptions(), liveCapable: false) == .fixture)
    }

    @Test(arguments: FixtureSet.allCases)
    func aFixtureArgumentAlwaysWins(_ set: FixtureSet) {
        let options = LaunchOptions { $0 == LaunchOptions.fixtureKey ? set.rawValue : nil }
        #expect(options.fixtureRequested)
        #expect(AlertSourceKind.select(options: options, liveCapable: true) == .fixture)
    }

    /// Only a RECOGNISED fixture value counts as asking for fixtures.
    @Test func anUnknownFixtureValueIsNotARequest() {
        let options = LaunchOptions { $0 == LaunchOptions.fixtureKey ? "lots" : nil }
        #expect(!options.fixtureRequested)
        #expect(AlertSourceKind.select(options: options, liveCapable: true) == .cloudKit)
    }

    /// The test host is a simulator build, so it can never go live: this is
    /// what keeps every test (and every unsigned run) away from CloudKit.
    @Test func thisSimulatorBuildIsNotLiveCapable() {
        #expect(!LiveCapability.isAvailable)
        #expect(CloudKitAlertSource.makeLive() == nil)
    }

    /// Even asked to go live, a build without `LiveCapability` gets fixtures.
    @Test(.enabled(if: !LiveCapability.isAvailable))
    @MainActor
    func askedToGoLiveASimulatorBuildStillShowsFixtures() {
        let feed = AlertFeed.make(options: LaunchOptions(), now: Self.now, liveCapable: true)
        #expect(!feed.isLive)
        #expect(feed.alerts == FixtureSet.populated.alerts(now: Self.now))
    }

    /// A fixture feed shows its list and pill from the first frame, exactly
    /// as before there was a live source.
    @Test(arguments: FixtureSet.allCases, ConnectionState.probed)
    @MainActor
    func aFixtureFeedStartsOnItsFixtures(_ set: FixtureSet, _ connection: ConnectionState) {
        let values = [LaunchOptions.fixtureKey: set.rawValue, LaunchOptions.connectionKey: connection.rawValue]
        let feed = AlertFeed.make(options: LaunchOptions { values[$0] }, now: Self.now, liveCapable: false)
        #expect(!feed.isLive)
        #expect(feed.alerts == set.alerts(now: Self.now))
        #expect(feed.connection == connection)
    }

    /// A fixture feed's first frame already has the fetch status a refresh
    /// of it reads: answered, except without an account. So the empty
    /// fixture shows the good outcome only where a live feed would.
    @Test(arguments: FixtureSet.allCases, ConnectionState.probed)
    @MainActor
    func aFixtureFeedStartsOnTheFetchStatusARefreshReads(_ set: FixtureSet, _ connection: ConnectionState) async {
        let values = [LaunchOptions.fixtureKey: set.rawValue, LaunchOptions.connectionKey: connection.rawValue]
        let feed = AlertFeed.make(options: LaunchOptions { values[$0] }, now: Self.now, liveCapable: false)
        let first = feed.fetch
        #expect(first == (connection == .iCloudUnavailable ? .failed : .fetched))
        await feed.refresh()
        #expect(feed.fetch == first)
    }

    // MARK: The fixture conformance

    /// The fixture source and gate reproduce the fixture's pill exactly.
    @Test(arguments: ConnectionState.probed)
    func theFixtureProbeRoundTripsTheConnectionState(_ connection: ConnectionState) async {
        let source = FixtureAlertSource(set: .populated, connection: connection, now: Self.now)
        let gate = await FixedNotificationGate(connection: connection)
        let probed = ConnectionState(account: await source.connect(), alertsAllowed: await gate.alertsAllowed())
        #expect(probed == connection)
    }

    /// Every fetch returns the same records, so a refresh never adds rows.
    @Test func theFixtureSourceReturnsTheSameRecordsEveryTime() async throws {
        let source = FixtureAlertSource(set: .populated, connection: .connected, now: Self.now)
        let first = try await source.fetchRecent()
        let second = try await source.fetchRecent()
        #expect(first == second)
        #expect(first == FixtureSet.populated.alerts(now: Self.now))
    }

    /// Fixtures get no pushes, and a direct fetch finds only their own rows.
    @Test func theFixtureSourceNamesNoPushAndFetchesItsOwnRows() async throws {
        let source = FixtureAlertSource(set: .populated, connection: .connected, now: Self.now)
        let first = try #require(source.alerts.first)
        #expect(source.pushedRecordName(in: ["aps": ["alert": "x"]]) == nil)
        #expect(try await source.fetchAlert(named: first.id) == first)
        #expect(try await source.fetchAlert(named: "session-0") == nil)
    }

    // MARK: The pill, probed

    @Test func theProbedPillPutsTheAccountFirst() {
        #expect(ConnectionState(account: .unavailable, alertsAllowed: true) == .iCloudUnavailable)
        #expect(ConnectionState(account: .unavailable, alertsAllowed: false) == .iCloudUnavailable)
        #expect(ConnectionState(account: .available, alertsAllowed: false) == .notificationsOff)
        #expect(ConnectionState(account: .available, alertsAllowed: true) == .connected)
        // Notifications off (the owner can fix it in Settings) shows first;
        // with them on, a missing subscription is never "Connected".
        #expect(ConnectionState(account: .availableWithoutPush, alertsAllowed: false) == .notificationsOff)
        #expect(ConnectionState(account: .availableWithoutPush, alertsAllowed: true) == .pushNotSetUp)
    }

    /// `checking` is the live pre-probe state only: no probe answers it, and
    /// every other state is some probe's answer.
    @Test func everyStateButCheckingIsAProbesAnswer() {
        let answers = Set(AccountAvailability.allCases.flatMap { account in
            [true, false].map { ConnectionState(account: account, alertsAllowed: $0) }
        })
        #expect(answers == Set(ConnectionState.probed))
        #expect(ConnectionState.probed == ConnectionState.allCases.filter { $0 != .checking })
    }

    @Test func onlyAnUnavailableAccountCannotFetch() {
        #expect(AccountAvailability.allCases.filter { !$0.canFetch } == [.unavailable])
    }

    /// Only full authorization buzzes; anything else reads "Notifications off".
    @Test func onlyFullAuthorizationCountsAsNotificationsOn() {
        #expect(SystemNotificationGate.allowsAlerts(.authorized))
        #expect(SystemNotificationGate.allowsAlerts(.ephemeral))
        #expect(!SystemNotificationGate.allowsAlerts(.denied))
        #expect(!SystemNotificationGate.allowsAlerts(.notDetermined))
        #expect(!SystemNotificationGate.allowsAlerts(.provisional))
    }

    /// The prompt asks for alerts and sound: badges are never set.
    @Test func thePromptAsksForAlertsAndSoundOnly() {
        #expect(SystemNotificationGate.requestedOptions == [.alert, .sound])
    }
}
