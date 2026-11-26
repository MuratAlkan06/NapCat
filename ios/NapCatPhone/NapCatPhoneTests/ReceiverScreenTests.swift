import Foundation
import NapCatWire
@testable import NapCatPhone
import SwiftUI
import Testing
import UIKit

/// The screen's fixed copy, cadence and state mappings.
@Suite struct ReceiverScreenTests {
    /// The good outcome's sentence is unchanged; `ListStateTests` pins the
    /// others and when each shows.
    @Test func theEmptyStateSaysExactlyThis() {
        #expect(EmptyHero.noAlerts.message == "No alerts. Your Mac hasn't needed you.")
    }

    // MARK: Stagger (charter: 40 ms per row, first eight rows)

    @Test func theStaggerStepsFortyMillisecondsOverTheFirstEightRows() {
        let delays = (0..<StaggerTiming.staggeredRows).map(StaggerTiming.delay(forIndex:))
        let expected = (0..<8).map { Double($0) * 0.040 }
        #expect(StaggerTiming.staggeredRows == 8)
        for (delay, want) in zip(delays, expected) {
            #expect(abs(delay - want) < 1e-9)
        }
    }

    @Test(arguments: [8, 9, 20, 500])
    func laterRowsShareTheEighthRowsDelay(_ index: Int) {
        #expect(StaggerTiming.delay(forIndex: index) == StaggerTiming.delay(forIndex: 7))
    }

    @Test func aNegativeIndexHasNoDelay() {
        #expect(StaggerTiming.delay(forIndex: -1) == 0)
    }

    /// The whole entrance finishes within the last step plus one curve.
    @Test(arguments: ThemeID.allCases)
    func theWholeEntranceIsOverInUnderSixTenths(_ id: ThemeID) {
        #expect(StaggerTiming.delay(forIndex: .max) + id.theme.entranceDuration <= 0.6)
    }

    // MARK: The cap

    /// The cap is said once the list is full, and only then, in words
    /// built from the limit and in the caption register. A nominal line:
    /// VoiceOver reads it as written.
    @Test func theCapIsSaidOnceTheListIsFull() throws {
        for count in [0, 1, AlertFeed.listLimit - 1] {
            #expect(ReceiverScreen.capLine(rowCount: count) == nil, "\(count) rows")
        }
        let line = try #require(ReceiverScreen.capLine(rowCount: AlertFeed.listLimit))
        #expect(AlertFeed.listLimit == 50)
        #expect(line == PhoneLine(text: "Capped — the list keeps the latest 50 alerts", severity: .nominal))
        #expect(line.spoken == line.text)
        #expect(ReceiverScreen.capLine(rowCount: AlertFeed.listLimit + 1) == line)
        #expect(ListStateTests.captionRegisterFailures(line.text).isEmpty,
                "\(ListStateTests.captionRegisterFailures(line.text))")
        #expect(!ListStateTests.captionRegisterFailures("Last 50 alerts — older ones aren't shown.").isEmpty)
    }

    /// Words that would claim alerts exist beyond the list.
    static func claimsMoreAlerts(_ text: String) -> Bool {
        ["older", "aren't shown", "hidden", "more"].contains { text.localizedCaseInsensitiveContains($0) }
    }

    /// At exactly the limit there may be nothing older (the query asks for
    /// at most that many), so the cap never claims older alerts exist.
    @Test func theCapNeverClaimsOlderAlertsExist() throws {
        let line = try #require(ReceiverScreen.capLine(rowCount: AlertFeed.listLimit))
        #expect(!Self.claimsMoreAlerts(line.text))
        // Not vacuous: the old line made the claim.
        #expect(Self.claimsMoreAlerts("Last 50 alerts — older ones aren't shown."))
    }

    /// A feed that fills up ends on the cap: 60 records fetched, 50 listed.
    @Test @MainActor func aFullFeedEndsOnTheCapLine() async {
        let many = (0..<60).map { AlertFeedTests.alert("session-\($0)", minutesAgo: Double($0)) }
        let feed = AlertFeed(source: ScriptedSource(account: .available, alerts: many),
                             notifications: FixedNotificationGate(connection: .connected), isLive: true)
        await feed.refresh()
        #expect(feed.alerts.count == AlertFeed.listLimit)
        #expect(ReceiverScreen.capLine(rowCount: feed.alerts.count) != nil)
    }

    // MARK: Pull to refresh

    /// AMENDED (#194): the screen is handed the prompts waiting here and the
    /// way to open one, and the pull reads the prompts too, after the feed's
    /// pass, with the owner's switch.
    static let pull = "ReceiverScreen(alerts: feed.alerts, connection: feed.connection, fetch: feed.fetch, "
        + "requests: inbox.pendingRequests, open: { shownRequest = $0 }) "
        + ".refreshable { await feed.pullToRefresh() await inbox.syncPrompts(switchedOn: approvals) }"

    /// The list pulls down to refresh, through the feed's waiting pull (a
    /// plain refresh can return before anything is checked, ending the
    /// system's spinner early). SwiftUI composition cannot be driven
    /// headlessly, so this locks the source, and runs against mutants.
    @Test func theListPullsToRefreshThroughTheFeed() throws {
        let root = try SettingsReachabilityTests.rootCode()
        #expect(SettingsReachabilityTests.flat(root).contains(Self.pull))
        let mutants = [
            root.replacingOccurrences(of: "                .refreshable {\n", with: "                .task {\n"),
            root.replacingOccurrences(of: "await feed.pullToRefresh()", with: "await feed.refresh()"),
            root.replacingOccurrences(of: "                    await inbox.syncPrompts(switchedOn: approvals)\n                }\n",
                                      with: "                }\n"),
            root.replacingOccurrences(of: "requests: inbox.pendingRequests,", with: "requests: inbox.requests,"),
        ]
        for mutant in mutants {
            #expect(mutant != root, "a mutation did not apply")
            #expect(!SettingsReachabilityTests.flat(mutant).contains(Self.pull))
        }
    }

    // MARK: Waiting rows (F4, #194)

    static let ageStart = Date(timeIntervalSince1970: 1_800_000_000)

    static func waiting(_ tool: String, project: String, minutesAgo: Double) -> PendingRequest {
        let created: Date = ageStart.addingTimeInterval(-minutesAgo * 60)
        return PendingRequest(id: RequestFixtures.id(UInt64(tool.count) + 1), toolName: tool, inputPreview: "{}", projectLabel: project,
                              createdAt: created, expiresAt: created.addingTimeInterval(PendingRequest.timeToLive))!
    }

    /// #194 design review: a waiting row says how long ago its prompt came,
    /// in the alert rows' words, and VoiceOver hears it after the tool and
    /// the project ("Bash permission prompt, project napcat, 2 minutes ago");
    /// a Mac clock running ahead reads as now, never in the future.
    @Test func aWaitingRowSaysHowLongAgoItsPromptCame() {
        let now: Date = Self.ageStart
        let bash: PendingRequest = Self.waiting("Bash", project: "napcat", minutesAgo: 2)
        let read: PendingRequest = Self.waiting("Read", project: "", minutesAgo: 2)
        let full: String = AlertRow.relative(bash.createdAt, to: now, style: .full)
        #expect(ReceiverScreen.age(of: bash, at: now, style: .short) == AlertRow.relative(bash.createdAt, to: now, style: .short))
        #expect(ReceiverScreen.age(of: bash, at: now, style: .full) == full)
        #expect(ReceiverScreen.spoken(bash, at: now) == "Bash permission prompt, project napcat, \(full)")
        #expect(ReceiverScreen.spoken(read, at: now) == "Read permission prompt, \(full)")
        if Locale.current.language.languageCode == .english {
            #expect(ReceiverScreen.spoken(bash, at: now) == "Bash permission prompt, project napcat, 2 minutes ago")
        }
        let ahead: PendingRequest = Self.waiting("Edit", project: "napcat", minutesAgo: -3)
        #expect(ReceiverScreen.age(of: ahead, at: now, style: .full) == AlertRow.relative(now, to: now, style: .full))
        #expect(!ReceiverScreen.spoken(bash, at: now).contains(bash.inputPreview), "nothing of the input")
    }

    /// The whole card is the tap target: at least the theme's touch target
    /// tall in every theme, with a project line or without one.
    @MainActor
    @Test(arguments: ThemeID.allCases)
    func aWaitingCardIsAtLeastATouchTargetTall(_ id: ThemeID) throws {
        let theme: Theme = id.theme
        for project in ["napcat", ""] {
            let card = WaitingCard(request: Self.waiting("Bash", project: project, minutesAgo: 2), now: Self.ageStart)
                .environment(\.theme, theme)
            let renderer = ImageRenderer(content: card)
            renderer.proposedSize = ProposedViewSize(width: 343, height: nil)
            renderer.scale = 1
            let image: UIImage = try #require(renderer.uiImage)
            #expect(image.size.height >= theme.minTouchTarget, "\(id), project '\(project)': \(image.size.height)")
        }
    }

    /// The waiting row's composition (#194 design review), as its source
    /// says it: the card is its button's whole label (so all of it is the
    /// tap target and all of it dims as pressed), its own touch target tall;
    /// the age sits on the tool name's line in the alert rows' timestamp
    /// type; the chevron is centred on the card; VoiceOver hears the row
    /// with its age, under the minute's redraw the alert rows use.
    static let waitingShapes: [String] = [
        "TimelineView(.periodic(from: .now, by: 60)) { context in Button { open(request) } label: { "
            + "WaitingCard(request: request, now: context.date) } .buttonStyle(.plain) .accessibilityElement(children: .ignore) "
            + ".accessibilityLabel(Self.spoken(request, at: context.date)) .accessibilityHint(Self.openHint) "
            + ".accessibilityAddTraits(.isButton) }",
        "var body: some View { HStack(alignment: .center, spacing: theme.innerGap * 2) { "
            + "HStack(alignment: .firstTextBaseline, spacing: theme.innerGap * 2) {",
        "Text(verbatim: request.toolName) .font(theme.metaFont) .foregroundStyle(theme.ink) Spacer(minLength: theme.innerGap) "
            + "Text(ReceiverScreen.age(of: request, at: now, style: .short)) .font(theme.timestampFont) .foregroundStyle(theme.inkSecondary) }",
        "} } } Image(systemName: ReceiverScreen.openSymbol) .font(theme.detailFont) .foregroundStyle(theme.inkSecondary) } "
            + ".themedCard() .frame(minHeight: theme.minTouchTarget) .contentShape(Rectangle()) }",
    ]

    static func waitingFailures(_ screen: String) -> [String] {
        let code: String = SettingsReachabilityTests.flat(screen)
        var failures: [String] = waitingShapes.filter { !code.contains($0) }.map { "the waiting row lost '\($0)'" }
        if CloudKitStructureTests.occurrences(of: ".themedCard()", in: code) != 3 {
            failures.append("three cards: the permission row, an alert and a waiting prompt (inside its button)")
        }
        return failures
    }

    @Test func theWholeWaitingCardOpensItsPrompt() throws {
        let app: [CloudKitStructureTests.Source] = try CloudKitStructureTests.swiftFiles(under: CloudKitStructureTests.appDir)
        let screen: String = try #require(app.first { $0.path == ListStateTests.screenFile }).text
        #expect(Self.waitingFailures(screen).isEmpty, "\(Self.waitingFailures(screen))")
        #expect(UIImage(systemName: ReceiverScreen.openSymbol) != nil)
        let mutants: [(String, String)] = [
            ("the card outside the label", screen
                .replacingOccurrences(of: "                                .buttonStyle(.plain)\n",
                                      with: "                                .buttonStyle(.plain)\n                                .themedCard()\n")
                .replacingOccurrences(of: "        .themedCard()\n        .frame(minHeight: theme.minTouchTarget)\n",
                                      with: "        .frame(minHeight: theme.minTouchTarget)\n")),
            ("a second card around the button", screen.replacingOccurrences(
                of: "                                .accessibilityAddTraits(.isButton)\n",
                with: "                                .accessibilityAddTraits(.isButton)\n                                .themedCard()\n")),
            ("no touch-target floor", screen.replacingOccurrences(of: "        .frame(minHeight: theme.minTouchTarget)\n", with: "")),
            ("the chevron on the first line", screen.replacingOccurrences(
                of: "HStack(alignment: .center, spacing: theme.innerGap * 2) {\n            HStack(alignment: .firstTextBaseline",
                with: "HStack(alignment: .firstTextBaseline, spacing: theme.innerGap * 2) {\n            HStack(alignment: .firstTextBaseline")),
            ("no age", screen.replacingOccurrences(
                of: "                        Text(ReceiverScreen.age(of: request, at: now, style: .short))\n", with: "")),
            ("VoiceOver without the age", screen.replacingOccurrences(
                of: ".accessibilityLabel(Self.spoken(request, at: context.date))", with: ".accessibilityLabel(request.toolName)")),
            ("the age frozen at launch", screen.replacingOccurrences(
                of: "TimelineView(.periodic(from: .now, by: 60)) { context in", with: "Group {")),
        ]
        for (name, mutant) in mutants {
            #expect(mutant != screen, "canary '\(name)' did not apply")
            #expect(!Self.waitingFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: Check again (the pull's single-step twin, WCAG 2.5.1)

    /// Offered exactly where the screen says it couldn't get alerts: the
    /// couldn't-check and iCloud heroes, and every stale note.
    @Test func checkAgainIsOfferedWhereTheScreenCouldNotGetAlerts() {
        #expect(CheckAgainAction.name == "Check again")
        let states = EmptyHero.allCases.map(ListState.empty) + [.rows] + StaleReason.allCases.map(ListState.staleRows)
        #expect(states.filter(\.offersCheckAgain) == [
            .empty(.iCloudUnavailable), .empty(.couldNotCheck), .staleRows(.couldNotCheck), .staleRows(.iCloudUnavailable),
        ])
    }

    static let checkAgainFile = "\(CloudKitStructureTests.appDir)/Screen/CheckAgainAction.swift"
    static let checkAgainAction =
        "content.accessibilityActions { if offered, let refresh { Button(Self.name) { Task { await refresh() } } } }"
    /// The screen reads the pull's action itself (inside the scroll view it
    /// is nil: seen on the simulator) and hands it to the hero and the note.
    static let checkAgainSites = [
        "@Environment(\\.refresh) private var refresh",
        "EmptyStateView(hero: hero) .checkAgainAction(offered: list.offersCheckAgain, refresh: refresh)",
        "CaptionLine(line: note) .checkAgainAction(offered: list.offersCheckAgain, refresh: refresh)",
    ]

    static func checkAgainFailures(root: String, screen: String, action: String) -> [String] {
        var failures: [String] = []
        if !SettingsReachabilityTests.flat(root).contains(pull) { failures.append("the pull is not the feed's pullToRefresh()") }
        if !SettingsReachabilityTests.flat(action).contains(checkAgainAction) { failures.append("missing: \(checkAgainAction)") }
        let screenCode = SettingsReachabilityTests.flat(screen)
        failures += checkAgainSites.filter { !screenCode.contains($0) }.map { "missing: \($0)" }
        return failures
    }

    /// The action runs the screen's refresh action: the very one the root's
    /// pull sets to `feed.pullToRefresh()`, so it is the same full pass. It
    /// sits on the hero and on the note. SwiftUI's accessibility tree cannot
    /// be driven headlessly, so this locks the source, and runs against
    /// mutants.
    @Test func checkAgainRunsThePullsFullPass() throws {
        let app = try CloudKitStructureTests.swiftFiles(under: CloudKitStructureTests.appDir)
        let root = try SettingsReachabilityTests.rootCode()
        let screen = try #require(app.first { $0.path == ListStateTests.screenFile }).text
        let action = try #require(app.first { $0.path == Self.checkAgainFile }).text
        #expect(Self.checkAgainFailures(root: root, screen: screen, action: action).isEmpty,
                "\(Self.checkAgainFailures(root: root, screen: screen, action: action))")
        let mutants = [
            (root.replacingOccurrences(of: "await feed.pullToRefresh()", with: "await feed.refresh()"), screen, action),
            (root, screen.replacingOccurrences(
                of: "EmptyStateView(hero: hero)\n                        .checkAgainAction(offered: list.offersCheckAgain, refresh: refresh)",
                with: "EmptyStateView(hero: hero)"), action),
            (root, screen.replacingOccurrences(
                of: "CaptionLine(line: note)\n                            .checkAgainAction(offered: list.offersCheckAgain, refresh: refresh)",
                with: "CaptionLine(line: note)"), action),
            (root, screen.replacingOccurrences(of: "refresh: refresh)", with: "refresh: nil)"), action),
            (root, screen.replacingOccurrences(
                of: "@Environment(\\.refresh) private var refresh", with: "private let refresh: RefreshAction? = nil"), action),
            (root, screen, action.replacingOccurrences(of: "await refresh()", with: "_ = refresh")),
        ]
        for (mutantRoot, mutantScreen, mutantAction) in mutants {
            #expect(mutantRoot != root || mutantScreen != screen || mutantAction != action, "a mutation did not apply")
            #expect(!Self.checkAgainFailures(root: mutantRoot, screen: mutantScreen, action: mutantAction).isEmpty)
        }
    }

    // MARK: Connection pill

    @Test func theConnectionStatesReadAsTheirSeverity() {
        #expect(ConnectionState.checking.line == PhoneLine(text: "Checking…", severity: .nominal))
        #expect(ConnectionState.connected.line == PhoneLine(text: "Connected", severity: .nominal))
        #expect(ConnectionState.iCloudUnavailable.line == PhoneLine(text: "iCloud unavailable", severity: .error))
        #expect(ConnectionState.notificationsOff.line == PhoneLine(text: "Notifications off", severity: .warning))
        #expect(ConnectionState.pushNotSetUp.line == PhoneLine(text: "Connected — no push", severity: .warning))
        #expect(ConnectionState.checking.line.spoken == "Checking…")
        #expect(ConnectionState.notificationsOff.line.spoken == "Warning: Notifications off")
        #expect(ConnectionState.iCloudUnavailable.line.spoken == "Error: iCloud unavailable")
        #expect(ConnectionState.pushNotSetUp.line.spoken == "Warning: Connected — no push")
    }

    /// Never color alone: a non-nominal pill shows its severity's glyph. A
    /// nominal pill shows the iCloud check only once something is confirmed.
    @Test(arguments: ConnectionState.allCases)
    func thePillGlyphIsTheSeverityGlyphAndResolves(_ state: ConnectionState) {
        if let severityGlyph = state.line.severity.symbol {
            #expect(state.symbol == severityGlyph)
        } else {
            #expect(state.symbol == (state == .checking ? "icloud" : "checkmark.icloud"))
        }
        #expect(UIImage(systemName: state.symbol) != nil)
    }

    /// Only a confirmed state reads "Connected" on its own: never while
    /// checking, and never while nothing would be pushed.
    @Test func onlyTheConfirmedStateReadsPlainlyConnected() {
        #expect(ConnectionState.allCases.filter { $0.line.text == "Connected" } == [.connected])
        #expect(ConnectionState.allCases.filter { $0.symbol == "checkmark.icloud" } == [.connected])
    }

    @Test func onlyNotificationsOffShowsThePermissionRow() {
        #expect(ConnectionState.allCases.filter(\.showsPermissionRow) == [.notificationsOff])
        #expect(UIImage(systemName: PermissionRow.actionSymbol) != nil)
    }

    // MARK: Lanes

    /// The glyphs are the Mac panel's (`PanelSymbol.lidAlert`, `.sessionAlerts`).
    @Test func eachLanePresentsWithTheMacPanelsGlyph() {
        #expect(AlertWire.Lane.lid.title == "Lid alert")
        #expect(AlertWire.Lane.lid.symbol == "bell")
        #expect(AlertWire.Lane.lid.severity == .warning)
        #expect(AlertWire.Lane.session.title == "Session alert")
        #expect(AlertWire.Lane.session.symbol == "flag.checkered")
        #expect(AlertWire.Lane.session.severity == .nominal)
        for lane in AlertWire.Lane.allCases {
            #expect(UIImage(systemName: lane.symbol) != nil)
        }
    }

    // MARK: Launch options

    @Test func missingLaunchArgumentsGiveTheDefaults() {
        let options = LaunchOptions { _ in nil }
        #expect(options == LaunchOptions())
        #expect(options.fixture == .populated && options.connection == .connected)
    }

    @Test func launchArgumentsPickTheFixtureAndConnection() {
        let values = ["NapCatFixture": "empty", "NapCatConnection": "notificationsOff"]
        let options = LaunchOptions { values[$0] }
        #expect(options.fixture == .empty)
        #expect(options.connection == .notificationsOff)
    }

    @Test func unknownLaunchArgumentsFallBack() {
        let values = ["NapCatFixture": "lots", "NapCatConnection": "maybe"]
        #expect(LaunchOptions { values[$0] } == LaunchOptions())
    }

    /// Every probed state can be asked for; `checking` (no probe's answer)
    /// falls back like an unknown value.
    @Test func theConnectionArgumentTakesTheProbedStatesOnly() {
        for state in ConnectionState.probed {
            #expect(LaunchOptions { $0 == "NapCatConnection" ? state.rawValue : nil }.connection == state)
        }
        #expect(LaunchOptions { $0 == "NapCatConnection" ? "pushNotSetUp" : nil }.connection == .pushNotSetUp)
        #expect(LaunchOptions { $0 == "NapCatConnection" ? "checking" : nil } == LaunchOptions())
    }
}
