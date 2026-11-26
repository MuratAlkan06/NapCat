// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat
@testable import NapCatWire

/// F4 slice S2: the remote-approvals toggle and its kill switch as pure state
/// (`RemoteApprovalsState`). Default off; only a stored `true` turns it on;
/// turning it off — from any on phase — is the kill switch, every time; a
/// quit is final.
struct RemoteApprovalsPolicyTests {
    // MARK: - The stored toggle

    struct StoredRow: Sendable, CustomTestStringConvertible {
        let note: String
        let stored: StoredValue
        let enabled: Bool
        var testDescription: String { note }
    }

    /// Sendable stand-ins for what `UserDefaults.object(forKey:)` can return.
    enum StoredValue: Sendable {
        case absent, bool(Bool), int(Int), double(Double), string(String), array

        var value: Any? {
            switch self {
            case .absent: return nil
            case .bool(let flag): return NSNumber(value: flag)
            case .int(let number): return NSNumber(value: number)
            case .double(let number): return NSNumber(value: number)
            case .string(let text): return text as NSString
            case .array: return [true] as NSArray
            }
        }
    }

    static let storedRows: [StoredRow] = [
        StoredRow(note: "unset — the default is off", stored: .absent, enabled: false),
        StoredRow(note: "stored true", stored: .bool(true), enabled: true),
        StoredRow(note: "stored false", stored: .bool(false), enabled: false),
        StoredRow(note: "defaults write -int 1 reads as the Bool it bridges to", stored: .int(1), enabled: true),
        StoredRow(note: "an integer other than 0/1 is junk", stored: .int(2), enabled: false),
        StoredRow(note: "a fraction is junk", stored: .double(0.5), enabled: false),
        StoredRow(note: "a string is junk, even YES", stored: .string("YES"), enabled: false),
        StoredRow(note: "a string is junk, even true", stored: .string("true"), enabled: false),
        StoredRow(note: "an array is junk", stored: .array, enabled: false),
    ]

    /// With nothing outranking it, the search list reads the app's own value.
    @Test(arguments: storedRows)
    func onlyAStoredTrueTurnsItOn(_ row: StoredRow) {
        #expect(RemoteApprovalsPolicy.enabled(stored: row.stored.value, searched: row.stored.value) == row.enabled)
    }

    struct SearchRow: Sendable, CustomTestStringConvertible {
        let note: String
        /// What the app's own persistent domain holds.
        let stored: StoredValue
        /// What the defaults search list reads.
        let searched: StoredValue
        let enabled: Bool
        var testDescription: String { note }
    }

    /// #205: the app's own domain must hold a Bool `true`, and the search
    /// list must read one too. A `true` only elsewhere (a launch argument,
    /// the global domain, a registered default: all read through the search
    /// list) never turns it on; a value that outranks the app's own and is
    /// anything but a Bool `true` turns it off.
    static let searchRows: [SearchRow] = [
        SearchRow(note: "the app's own true, read through the search list", stored: .bool(true), searched: .bool(true),
                  enabled: true),
        SearchRow(note: "a true elsewhere, the app's own unset", stored: .absent, searched: .bool(true), enabled: false),
        SearchRow(note: "a true elsewhere, the app's own false", stored: .bool(false), searched: .bool(true), enabled: false),
        SearchRow(note: "a true elsewhere, the app's own junk", stored: .string("YES"), searched: .bool(true), enabled: false),
        SearchRow(note: "an outranking false vetoes the app's own true", stored: .bool(true), searched: .bool(false),
                  enabled: false),
        SearchRow(note: "an outranking string disagrees, even YES", stored: .bool(true), searched: .string("YES"),
                  enabled: false),
        SearchRow(note: "an outranking junk number disagrees", stored: .bool(true), searched: .int(2), enabled: false),
        SearchRow(note: "an outranking 1 is the Bool it bridges to", stored: .bool(true), searched: .int(1), enabled: true),
        SearchRow(note: "a search list that reads nothing disagrees", stored: .bool(true), searched: .absent, enabled: false),
    ]

    @Test(arguments: searchRows)
    func anOutsideValueCanTurnItOffButNeverOn(_ row: SearchRow) {
        #expect(RemoteApprovalsPolicy.enabled(stored: row.stored.value, searched: row.searched.value) == row.enabled)
    }

    @Test func theKeyIsItsOwn() {
        #expect(DefaultsKey.remoteApprovalsEnabled == "remoteApprovalsEnabled")
    }

    // MARK: - What holds remote answers (#205)

    struct HoldRow: Sendable, CustomTestStringConvertible {
        let enabled: Bool
        let paired: Bool
        let recordPath: Bool
        let hold: RemoteApprovalsHold?
        var testDescription: String { "enabled \(enabled), paired \(paired), record path \(recordPath)" }
    }

    /// The whole truth table: nothing holds only when all three do;
    /// otherwise the first that fails, in order — the toggle, the pairing,
    /// the record path.
    static let holdRows: [HoldRow] = [
        HoldRow(enabled: false, paired: false, recordPath: false, hold: .off),
        HoldRow(enabled: false, paired: false, recordPath: true, hold: .off),
        HoldRow(enabled: false, paired: true, recordPath: false, hold: .off),
        HoldRow(enabled: false, paired: true, recordPath: true, hold: .off),
        HoldRow(enabled: true, paired: false, recordPath: false, hold: .notPaired),
        HoldRow(enabled: true, paired: false, recordPath: true, hold: .notPaired),
        HoldRow(enabled: true, paired: true, recordPath: false, hold: .noRecordPath),
        HoldRow(enabled: true, paired: true, recordPath: true, hold: nil),
    ]

    @Test(arguments: holdRows)
    func remoteAnswersAreHeldUnlessAllThreeHold(_ row: HoldRow) {
        #expect(RemoteApprovalsPolicy.hold(enabled: row.enabled, paired: row.paired, recordPath: row.recordPath) == row.hold)
    }

    /// Vacuity: eight rows, each combination once, and exactly one holds nothing.
    @Test func theHoldTableIsTheWholeTruthTable() {
        let combinations: Set<String> = Set(Self.holdRows.map { "\($0.enabled) \($0.paired) \($0.recordPath)" })
        #expect(Self.holdRows.count == 8 && combinations.count == 8)
        #expect(Self.holdRows.filter { $0.hold == nil }.count == 1)
    }

    // MARK: - The state machine

    @Test func theDefaultIsOffWithNothingRunning() {
        let state = RemoteApprovalsState()
        #expect(state.phase == .off)
        #expect(!state.enabled)
        #expect(state.finding == nil)
        #expect(!state.shutDown)
    }

    /// A state in each phase, reached through the machine itself.
    static func state(_ phase: RemoteApprovalsPhase, finding: ChannelPolicyFinding? = nil) -> RemoteApprovalsState {
        var state = RemoteApprovalsState()
        guard phase != .off else { return state }
        _ = state.apply(.toggle(true))
        _ = state.apply(.listened(phase == .listening))
        if let finding { _ = state.apply(.probed(finding)) }
        #expect(state.phase == phase, "fixture: \(phase)")
        return state
    }

    struct TransitionRow: Sendable, CustomTestStringConvertible {
        let from: RemoteApprovalsPhase
        let event: RemoteApprovalsEvent
        let to: RemoteApprovalsPhase
        let effects: [RemoteApprovalsEffect]
        var testDescription: String { "\(from) + \(event) → \(to)" }
    }

    /// Every event in every phase.
    static let transitions: [TransitionRow] = [
        // Turning on: pessimistic until the listen is confirmed.
        TransitionRow(from: .off, event: .toggle(true), to: .unavailable, effects: [.startListening, .probe]),
        TransitionRow(from: .listening, event: .toggle(true), to: .listening, effects: []),
        TransitionRow(from: .unavailable, event: .toggle(true), to: .unavailable, effects: []),
        // Turning off is the kill switch, from either on phase.
        TransitionRow(from: .off, event: .toggle(false), to: .off, effects: []),
        TransitionRow(from: .listening, event: .toggle(false), to: .off, effects: [.stopListening]),
        TransitionRow(from: .unavailable, event: .toggle(false), to: .off, effects: [.stopListening]),
        // The listen's outcome; a late one after the kill switch is dropped.
        TransitionRow(from: .unavailable, event: .listened(true), to: .listening, effects: []),
        TransitionRow(from: .unavailable, event: .listened(false), to: .unavailable, effects: []),
        TransitionRow(from: .listening, event: .listened(true), to: .listening, effects: []),
        TransitionRow(from: .listening, event: .listened(false), to: .unavailable, effects: []),
        TransitionRow(from: .off, event: .listened(true), to: .off, effects: []),
        TransitionRow(from: .off, event: .listened(false), to: .off, effects: []),
        // A policy reading changes no phase.
        TransitionRow(from: .listening, event: .probed(.noFilePolicy), to: .listening, effects: []),
        TransitionRow(from: .unavailable, event: .probed(.unreadable), to: .unavailable, effects: []),
        TransitionRow(from: .off, event: .probed(.noFilePolicy), to: .off, effects: []),
        // Refresh: nothing while off; re-read while on; retry a failed listen.
        TransitionRow(from: .off, event: .refresh, to: .off, effects: []),
        TransitionRow(from: .listening, event: .refresh, to: .listening, effects: [.probe]),
        TransitionRow(from: .unavailable, event: .refresh, to: .unavailable, effects: [.startListening, .probe]),
        // Quitting is a hard stop.
        TransitionRow(from: .off, event: .shutdown, to: .off, effects: []),
        TransitionRow(from: .listening, event: .shutdown, to: .off, effects: [.stopListening]),
        TransitionRow(from: .unavailable, event: .shutdown, to: .off, effects: [.stopListening]),
    ]

    @Test(arguments: transitions)
    func everyEventInEveryPhase(_ row: TransitionRow) {
        var state = Self.state(row.from)
        #expect(state.apply(row.event) == row.effects)
        #expect(state.phase == row.to)
        #expect(state.enabled == (row.to != .off))
    }

    /// Vacuity: the table covers the whole event × phase grid.
    @Test func theTableCoversEveryEventInEveryPhase() {
        let events: [RemoteApprovalsEvent] = [.toggle(true), .toggle(false), .listened(true), .listened(false),
                                              .probed(.noFilePolicy), .refresh, .shutdown]
        func kind(_ event: RemoteApprovalsEvent) -> String {
            switch event {
            case .toggle(let on): return "toggle(\(on))"
            case .listened(let ok): return "listened(\(ok))"
            case .probed: return "probed"
            case .refresh: return "refresh"
            case .shutdown: return "shutdown"
            }
        }
        for phase in [RemoteApprovalsPhase.off, .listening, .unavailable] {
            for event in events {
                #expect(Self.transitions.contains { $0.from == phase && kind($0.event) == kind(event) },
                        "no row for \(phase) + \(kind(event))")
            }
        }
    }

    // MARK: - The kill switch

    /// Off from any on phase stops listening and forgets the policy reading;
    /// a second off does nothing more.
    @Test(arguments: [RemoteApprovalsPhase.listening, .unavailable])
    func theKillSwitchStopsEverythingAndForgetsTheReading(_ phase: RemoteApprovalsPhase) {
        var state = Self.state(phase, finding: .defaultAllowlist)
        #expect(state.finding == .defaultAllowlist)
        #expect(state.apply(.toggle(false)) == [.stopListening])
        #expect(state.phase == .off)
        #expect(state.finding == nil, "a reading from the last on period is gone")
        #expect(state.apply(.toggle(false)) == [], "already off: nothing more to stop")
        #expect(state.apply(.refresh) == [], "off: no probe, no listen")
    }

    /// Off, then on again: a fresh start with its own listen and probe.
    @Test func onAgainAfterTheKillSwitchStartsAfresh() {
        var state = Self.state(.listening, finding: .noFilePolicy)
        _ = state.apply(.toggle(false))
        #expect(state.apply(.toggle(true)) == [.startListening, .probe])
        #expect(state.phase == .unavailable, "never claims a socket before it is confirmed")
        #expect(state.finding == nil)
        _ = state.apply(.listened(true))
        #expect(state.phase == .listening)
    }

    /// Quitting is final: once shut down, no event starts anything.
    @Test(arguments: [RemoteApprovalsPhase.off, .listening, .unavailable])
    func aQuitIsAHardStopThatNothingUndoes(_ phase: RemoteApprovalsPhase) {
        var state = Self.state(phase)
        _ = state.apply(.shutdown)
        #expect(state.shutDown)
        #expect(state.phase == .off)
        for event: RemoteApprovalsEvent in [.toggle(true), .refresh, .listened(true), .probed(.noFilePolicy),
                                            .toggle(false), .shutdown] {
            #expect(state.apply(event) == [], "\(event) after the quit")
            #expect(state.phase == .off)
        }
    }

    /// A reading lands only while on, and every reading is kept as is.
    @Test(arguments: ChannelPolicyFinding.allCases)
    func aReadingIsKeptOnlyWhileOn(_ finding: ChannelPolicyFinding) {
        var on = Self.state(.listening)
        _ = on.apply(.probed(finding))
        #expect(on.finding == finding)
        var off = RemoteApprovalsState()
        _ = off.apply(.probed(finding))
        #expect(off.finding == nil)
    }
}
