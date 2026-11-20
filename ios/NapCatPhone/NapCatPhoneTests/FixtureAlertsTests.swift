import Foundation
import NapCatWire
@testable import NapCatPhone
import Testing

/// The fixtures are shaped exactly like the wire and speak only the Mac's
/// closed vocabulary (`LidGuardPolicy.messageBody`).
@Suite struct FixtureAlertsTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let alerts = FixtureSet.populated.alerts(now: now)

    /// Every body the Mac can generate, per lane.
    static var sessionTemplates: [Regex<AnyRegexOutput>] { [
        try! Regex(#"A Claude session finished( after [1-9][0-9]* min)? — (none|[1-9][0-9]*) still working"#),
        try! Regex(#"([2-9]|[1-9][0-9]+) Claude sessions finished — (none|[1-9][0-9]*) still working"#),
        try! Regex(#"Claude is waiting for you( — [1-9][0-9]* min in)?"#
            + #"( — 1 other still working| — ([2-9]|[1-9][0-9]+) others still working)?"#),
        try! Regex(#"Connection was down [1-9][0-9]* min\."#
            + #"( 1 session alert delivered late\.| ([2-9]|[1-9][0-9]+) session alerts delivered late\.)?"#
            + #"( 1 session alert dropped\.| ([2-9]|[1-9][0-9]+) session alerts dropped\.)?"#
            + #"( 1 lid alert missed\.| ([2-9]|[1-9][0-9]+) lid alerts missed\.)?"#),
    ] }
    static var lidTemplates: [Regex<AnyRegexOutput>] { [
        try! Regex(#"This Mac started going to sleep at [0-2][0-9]:[0-5][0-9] while "#
            + #"(a Claude Code task was|1 Claude Code task was|([2-9]|[1-9][0-9]+) Claude Code tasks were)"#
            + #" still running, and Stay Awake is off\."#),
    ] }

    @Test func thereAreMoreRowsThanTheStaggerSteps() {
        #expect(Self.alerts.count > StaggerTiming.staggeredRows)
    }

    @Test func bothLanesAppear() {
        #expect(Set(Self.alerts.map(\.lane)) == Set(AlertWire.Lane.allCases))
    }

    @Test func theListIsNewestFirstAndInThePast() {
        let times = Self.alerts.map(\.firedAt)
        #expect(times == times.sorted(by: >))
        #expect(Set(times).count == times.count)
        #expect(times.allSatisfy { $0 < Self.now })
    }

    /// The record name the Mac writes: `<lane>-<epoch milliseconds>`.
    @Test func idsAreWireRecordNames() throws {
        let recordName = try Regex(#"(lid|session)-[0-9]+"#)
        for alert in Self.alerts {
            #expect(alert.id.wholeMatch(of: recordName) != nil, "\(alert.id)")
            #expect(alert.id.hasPrefix("\(alert.lane.rawValue)-"))
        }
        #expect(Set(Self.alerts.map(\.id)).count == Self.alerts.count)
        #expect(PhoneAlert.recordName(lane: .session, firedAt: Date(timeIntervalSince1970: 1_700_000_000.123))
            == "session-1700000000123")
    }

    @Test func everyBodyIsInTheMacsClosedVocabularyForItsLane() {
        for alert in Self.alerts {
            let templates = alert.lane == .lid ? Self.lidTemplates : Self.sessionTemplates
            #expect(templates.contains { alert.body.wholeMatch(of: $0) != nil }, "\(alert.body)")
        }
    }

    /// A lid alert's clock time is its own firing time, as on the Mac.
    @Test func aLidAlertNamesItsOwnClockTime() {
        for alert in Self.alerts where alert.lane == .lid {
            #expect(alert.body.contains(" at \(FixtureAlerts.clockTime(alert.firedAt)) while "))
        }
    }

    /// Synthetic only: no URL, host, address, path, topic or server.
    @Test func noFixtureCarriesAnythingReal() {
        for alert in Self.alerts {
            let body = alert.body.lowercased()
            for fragment in ["://", "@", "ntfy", "topic", "server", "/users/", ".local", ".com"] {
                #expect(!body.contains(fragment), "\(fragment) in \(alert.body)")
            }
        }
    }

    @Test func theEmptySetIsEmpty() {
        #expect(FixtureSet.empty.alerts(now: Self.now).isEmpty)
    }
}
