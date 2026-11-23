import Foundation
@testable import NapCatPhone
import Testing
import UIKit

/// What the receiver screen says about its list (#118), over the whole
/// matrix: connection state × how the last query went × whether rows are
/// already listed. The good outcome ("No alerts. Your Mac hasn't needed
/// you.") needs a usable account AND a query that came back empty; every
/// other cell says what is known instead, and a list that could not be
/// checked stays on screen with one line saying why: a passing failure or
/// the lasting one (no iCloud).
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
        (.checking, .failed, .empty(.checking), .staleRows(.couldNotCheck)),
        (.connected, .pending, .empty(.checking), .rows),
        (.connected, .fetched, .empty(.noAlerts), .rows),
        (.connected, .failed, .empty(.couldNotCheck), .staleRows(.couldNotCheck)),
        (.notificationsOff, .pending, .empty(.checking), .rows),
        (.notificationsOff, .fetched, .empty(.noAlerts), .rows),
        (.notificationsOff, .failed, .empty(.couldNotCheck), .staleRows(.couldNotCheck)),
        (.pushNotSetUp, .pending, .empty(.checking), .rows),
        (.pushNotSetUp, .fetched, .empty(.noAlerts), .rows),
        (.pushNotSetUp, .failed, .empty(.couldNotCheck), .staleRows(.couldNotCheck)),
        (.iCloudUnavailable, .pending, .empty(.iCloudUnavailable), .staleRows(.iCloudUnavailable)),
        (.iCloudUnavailable, .fetched, .empty(.iCloudUnavailable), .staleRows(.iCloudUnavailable)),
        (.iCloudUnavailable, .failed, .empty(.iCloudUnavailable), .staleRows(.iCloudUnavailable)),
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
        // A failed query with rows listed: the list stays, marked stale,
        // and the note gives the cause: a passing failure, or no iCloud
        // (lasting, so never "just now").
        #expect(Self.screenState(.connected, .failed, listed: true) == .staleRows(.couldNotCheck))
        #expect(Self.screenState(.iCloudUnavailable, .fetched, listed: true) == .staleRows(.iCloudUnavailable))
        #expect(Self.screenState(.iCloudUnavailable, .failed, listed: true) == .staleRows(.iCloudUnavailable))
    }

    // MARK: Copy

    @Test func eachHeroSaysExactlyThis() {
        #expect(EmptyHero.checking.message == "Checking for alerts…")
        #expect(EmptyHero.iCloudUnavailable.message == "iCloud unavailable. Alerts can't arrive without it.")
        #expect(EmptyHero.couldNotCheck.message == "Couldn't check for alerts just now. Pull down to check again.")
        #expect(EmptyHero.noAlerts.message == "No alerts. Your Mac hasn't needed you.")
    }

    /// Each stale note gives its own cause. Only the failed query is
    /// passing ("just now"); no iCloud is said as the cause it is.
    @Test func eachStaleNoteSaysExactlyThis() {
        #expect(StaleReason.couldNotCheck.line
            == PhoneLine(text: "Stale — couldn't check for new alerts just now", severity: .info))
        #expect(StaleReason.iCloudUnavailable.line
            == PhoneLine(text: "Stale — iCloud unavailable, so new alerts can't arrive", severity: .info))
        #expect(StaleReason.couldNotCheck.line.spoken == "Note: Stale — couldn't check for new alerts just now")
        #expect(StaleReason.iCloudUnavailable.line.spoken == "Note: Stale — iCloud unavailable, so new alerts can't arrive")
        #expect(StaleReason.iCloudUnavailable.line.text.contains("iCloud unavailable"))
        #expect(!StaleReason.iCloudUnavailable.line.text.contains("just now"))
        // The screen's note is the reason's line, and only stale rows have one.
        for reason in StaleReason.allCases {
            #expect(ListState.staleRows(reason).note == reason.line)
        }
        #expect(([ListState.rows] + EmptyHero.allCases.map(ListState.empty)).allSatisfy { $0.note == nil })
    }

    /// A quiet note: a glyph and text (never color alone), and VoiceOver
    /// hears "Note" first.
    @Test(arguments: StaleReason.allCases)
    func eachStaleNoteIsANoteWithAGlyph(_ reason: StaleReason) throws {
        let line = reason.line
        #expect(line.spoken == "Note: \(line.text)")
        let glyph = try #require(line.severity.symbol)
        #expect(UIImage(systemName: glyph) != nil)
        #expect(UIImage(systemName: "\(glyph).fill") != nil)
    }

    /// The Mac panel's caption register: ONE state word, an em dash, the
    /// explanation, no closing period ("Held — …", "Offline — …").
    static func captionRegisterFailures(_ text: String) -> [String] {
        var failures: [String] = []
        let parts = text.components(separatedBy: " — ")
        if parts.count != 2 { failures.append("not one state word and one em dash: \(text)") }
        if parts[0].range(of: #"^\p{Lu}\p{Ll}+$"#, options: .regularExpression) == nil {
            failures.append("the state is not one word: \(parts[0])")
        }
        if let last = text.last, ".!?…".contains(last) { failures.append("closing punctuation: \(text)") }
        return failures
    }

    @Test func everyStaleNoteIsInTheCaptionRegister() {
        for line in StaleReason.allCases.map(\.line) {
            #expect(Self.captionRegisterFailures(line.text).isEmpty, "\(Self.captionRegisterFailures(line.text))")
        }
        // Not vacuous: the old note and near misses fail it.
        for old in ["Couldn't check just now — showing earlier alerts.", "Stale — couldn't check.",
                    "Stale: couldn't check", "Not checked — couldn't check"] {
            #expect(!Self.captionRegisterFailures(old).isEmpty, "missed: \(old)")
        }
    }

    /// Every distinct state reads differently in words alone: no two heroes
    /// share a sentence, and a stale list carries a line a current one does
    /// not.
    @Test func everyStateReadsDifferentlyWithoutColor() {
        func words(_ state: ListState) -> String {
            switch state {
            case .empty(let hero): return hero.message
            case .rows: return ""
            case .staleRows(let reason): return reason.line.text
            }
        }
        let states = EmptyHero.allCases.map(ListState.empty) + [.rows] + StaleReason.allCases.map(ListState.staleRows)
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
