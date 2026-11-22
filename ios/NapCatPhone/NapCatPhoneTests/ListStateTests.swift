import Foundation
@testable import NapCatPhone
import Testing
import UIKit

/// What the receiver screen says about its list (#118), over the whole
/// matrix: connection state × how the last query went × whether rows are
/// already listed. The good outcome ("No alerts. Your Mac hasn't needed
/// you.") needs a usable account AND a query that came back empty; every
/// other cell says what is known instead, and a list that could not be
/// checked stays on screen with one line saying so.
@Suite struct ListStateTests {
    struct Cell: CustomTestStringConvertible, Sendable {
        let connection: ConnectionState
        let fetch: FetchStatus
        let listed: Bool
        let expected: ListState

        var testDescription: String {
            "\(connection) × \(fetch) × \(listed ? "rows listed" : "nothing listed") → \(expected)"
        }
    }

    /// THE TABLE, one line per (connection, fetch): what the screen shows
    /// with nothing listed, then with rows already listed.
    static let table: [(ConnectionState, FetchStatus, nothingListed: ListState, rowsListed: ListState)] = [
        (.checking, .pending, .empty(.checking), .rows),
        (.checking, .fetched, .empty(.checking), .rows),
        (.checking, .failed, .empty(.checking), .staleRows),
        (.connected, .pending, .empty(.checking), .rows),
        (.connected, .fetched, .empty(.noAlerts), .rows),
        (.connected, .failed, .empty(.couldNotCheck), .staleRows),
        (.notificationsOff, .pending, .empty(.checking), .rows),
        (.notificationsOff, .fetched, .empty(.noAlerts), .rows),
        (.notificationsOff, .failed, .empty(.couldNotCheck), .staleRows),
        (.pushNotSetUp, .pending, .empty(.checking), .rows),
        (.pushNotSetUp, .fetched, .empty(.noAlerts), .rows),
        (.pushNotSetUp, .failed, .empty(.couldNotCheck), .staleRows),
        (.iCloudUnavailable, .pending, .empty(.iCloudUnavailable), .staleRows),
        (.iCloudUnavailable, .fetched, .empty(.iCloudUnavailable), .staleRows),
        (.iCloudUnavailable, .failed, .empty(.iCloudUnavailable), .staleRows),
    ]

    static let cells: [Cell] = table.flatMap { row in
        [Cell(connection: row.0, fetch: row.1, listed: false, expected: row.nothingListed),
         Cell(connection: row.0, fetch: row.1, listed: true, expected: row.rowsListed)]
    }

    static let row = PhoneAlert(body: "A Claude session finished after 8 min — none still working", lane: .session,
                                firedAt: Date(timeIntervalSince1970: 1_790_000_000), recordName: "session-1")

    /// The state the screen itself derives, exactly as `ReceiverRoot` builds it.
    @MainActor
    static func screenState(_ connection: ConnectionState, _ fetch: FetchStatus, listed: Bool) -> ListState {
        ReceiverScreen(alerts: listed ? [row] : [], connection: connection, fetch: fetch).list
    }

    @Test func theTableCoversEveryCellExactlyOnce() {
        let keys = Self.cells.map { "\($0.connection)/\($0.fetch)/\($0.listed)" }
        #expect(Set(keys).count == keys.count)
        #expect(keys.count == ConnectionState.allCases.count * FetchStatus.allCases.count * 2)
    }

    @Test(arguments: cells)
    @MainActor
    func eachCellShowsItsState(_ cell: Cell) {
        #expect(ListState(connection: cell.connection, fetch: cell.fetch, hasAlerts: cell.listed) == cell.expected)
        #expect(Self.screenState(cell.connection, cell.fetch, listed: cell.listed) == cell.expected)
    }

    /// The acceptance rule, over the implementation (not the table): the
    /// good outcome shows exactly when nothing is listed, the account works
    /// and a query has answered.
    @Test @MainActor func theGoodOutcomeNeedsAWorkingAccountAndAnAnsweredQuery() {
        let canFetch: Set<ConnectionState> = [.connected, .notificationsOff, .pushNotSetUp]
        for connection in ConnectionState.allCases {
            for fetch in FetchStatus.allCases {
                for listed in [false, true] {
                    let claims = Self.screenState(connection, fetch, listed: listed) == .empty(.noAlerts)
                    #expect(claims == (!listed && fetch == .fetched && canFetch.contains(connection)),
                            "\(connection) \(fetch) listed=\(listed)")
                }
            }
        }
    }

    /// The audit's cells, by name.
    @Test @MainActor func theAuditsCellsAreHonest() {
        // A live launch's first frame: nothing is known yet.
        #expect(Self.screenState(.checking, .pending, listed: false) == .empty(.checking))
        // A long or hung first query: the account answered, the query has not.
        #expect(Self.screenState(.connected, .pending, listed: false) == .empty(.checking))
        #expect(Self.screenState(.pushNotSetUp, .pending, listed: false) == .empty(.checking))
        // A failed query with nothing listed (airplane mode on a first
        // launch): never the good outcome, whichever pill the probe gave.
        #expect(Self.screenState(.pushNotSetUp, .failed, listed: false) == .empty(.couldNotCheck))
        #expect(Self.screenState(.connected, .failed, listed: false) == .empty(.couldNotCheck))
        #expect(Self.screenState(.iCloudUnavailable, .failed, listed: false) == .empty(.iCloudUnavailable))
        // A failed query with rows listed: the list stays, marked stale.
        #expect(Self.screenState(.connected, .failed, listed: true) == .staleRows)
        #expect(Self.screenState(.iCloudUnavailable, .fetched, listed: true) == .staleRows)
    }

    // MARK: Copy

    @Test func eachHeroSaysExactlyThis() {
        #expect(EmptyHero.checking.message == "Checking for alerts…")
        #expect(EmptyHero.iCloudUnavailable.message == "iCloud unavailable. Alerts can't arrive without it.")
        #expect(EmptyHero.couldNotCheck.message == "Couldn't check for alerts just now. Pull down to try again.")
        #expect(EmptyHero.noAlerts.message == "No alerts. Your Mac hasn't needed you.")
    }

    /// A quiet note: a glyph and text (never color alone), the state word
    /// first, and VoiceOver hears "Note" first.
    @Test func theStaleLineIsANoteWithAGlyph() throws {
        let line = ListState.staleLine
        #expect(line == PhoneLine(text: "Couldn't check just now — showing earlier alerts.", severity: .info))
        #expect(line.spoken == "Note: Couldn't check just now — showing earlier alerts.")
        let glyph = try #require(line.severity.symbol)
        #expect(UIImage(systemName: glyph) != nil)
        #expect(UIImage(systemName: "\(glyph).fill") != nil)
    }

    /// Every distinct state reads differently in words alone: no two heroes
    /// share a sentence, and a stale list carries a line a current one does
    /// not.
    @Test func everyStateReadsDifferentlyWithoutColor() {
        func words(_ state: ListState) -> String {
            switch state {
            case .empty(let hero): return hero.message
            case .rows: return ""
            case .staleRows: return ListState.staleLine.text
            }
        }
        let states = EmptyHero.allCases.map(ListState.empty) + [.rows, .staleRows]
        #expect(Set(states.map(words)).count == states.count)
        for cell in Self.cells {
            #expect(states.contains(cell.expected), "\(cell.testDescription)")
        }
    }

    // MARK: The screen takes its hero from the list state

    static let screenFile = "\(CloudKitStructureTests.appDir)/Screen/ReceiverScreen.swift"
    static let heroSite = "switch list { case .empty(let hero): EmptyStateView(hero: hero)"

    static func heroFailures(_ app: [CloudKitStructureTests.Source]) -> [String] {
        var failures: [String] = []
        let builders = app.filter { CloudKitStructureTests.codeOnly($0.text).contains("EmptyStateView(") }.map(\.path)
        if builders != [screenFile] { failures.append("EmptyStateView is built in \(builders)") }
        let screen = SettingsReachabilityTests.flat(app.first { $0.path == screenFile }?.text ?? "")
        if !screen.contains(heroSite) { failures.append("missing: \(heroSite)") }
        if CloudKitStructureTests.occurrences(of: "EmptyStateView(", in: screen) != 1 {
            failures.append("the screen builds more than one hero")
        }
        return failures
    }

    @Test func theHeroComesOnlyFromTheListState() throws {
        let app = try CloudKitStructureTests.swiftFiles(under: CloudKitStructureTests.appDir)
        #expect(Self.heroFailures(app).isEmpty, "\(Self.heroFailures(app))")
        let mutants = [
            "EmptyStateView(hero: hero)": "EmptyStateView(hero: .noAlerts)",
            "switch list {": "switch ListState.rows {",
        ]
        for (from, to) in mutants {
            let mutated = app.map { source -> CloudKitStructureTests.Source in
                source.path == Self.screenFile
                    ? (source.path, source.text.replacingOccurrences(of: from, with: to))
                    : source
            }
            #expect(mutated.map(\.text) != app.map(\.text), "a mutation did not apply: \(from)")
            #expect(!Self.heroFailures(mutated).isEmpty, "missed: \(to)")
        }
    }
}
