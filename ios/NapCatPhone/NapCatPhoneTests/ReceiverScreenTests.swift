import Foundation
import NapCatWire
@testable import NapCatPhone
import Testing
import UIKit

/// The screen's fixed copy, cadence and state mappings.
@Suite struct ReceiverScreenTests {
    @Test func theEmptyStateSaysExactlyThis() {
        #expect(EmptyStateView.message == "No alerts. Your Mac hasn't needed you.")
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
