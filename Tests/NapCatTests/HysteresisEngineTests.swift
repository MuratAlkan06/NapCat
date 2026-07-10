import Testing
@testable import NapCat

/// Table-driven tests generated from the normative transition table in
/// PLAN.md ("Hysteresis transition table"). Every markdown row appears here
/// as one `Row` with the same ID and the same argument values — keep the two
/// in lockstep.
struct HysteresisEngineTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let id: String
        let state: ChargingControlState
        let enabled: Bool
        let adapter: Bool
        let percent: Int?
        let limit: Int
        let expected: ChargeCommand
        let rationale: String

        var testDescription: String {
            "\(id): \(state), enabled=\(enabled), adapter=\(adapter), "
                + "%=\(percent.map(String.init) ?? "nil"), limit=\(limit) → \(expected)"
        }
    }

    static let table: [Row] = [
        // MARK: normal
        Row(id: "N1", state: .normal, enabled: true, adapter: true, percent: 89, limit: 90,
            expected: .none, rationale: "below limit — keep charging"),
        Row(id: "N2", state: .normal, enabled: true, adapter: true, percent: 90, limit: 90,
            expected: .disableCharging, rationale: "boundary: percent >= limit pauses (also replug at limit)"),
        Row(id: "N3", state: .normal, enabled: true, adapter: true, percent: 91, limit: 90,
            expected: .disableCharging, rationale: "above limit"),
        Row(id: "N4", state: .normal, enabled: true, adapter: true, percent: 85, limit: 90,
            expected: .none, rationale: "percent == limit-5: resume threshold irrelevant in normal"),
        Row(id: "N5", state: .normal, enabled: true, adapter: false, percent: 95, limit: 90,
            expected: .none, rationale: "no adapter — cannot charge, no pointless write"),
        Row(id: "N6", state: .normal, enabled: false, adapter: true, percent: 95, limit: 90,
            expected: .none, rationale: "feature disabled — engine inert"),
        Row(id: "N7", state: .normal, enabled: true, adapter: true, percent: nil, limit: 90,
            expected: .none, rationale: "unknown percent — take no action"),
        Row(id: "N8", state: .normal, enabled: true, adapter: true, percent: 100, limit: 100,
            expected: .none, rationale: "limit 100 = uncapped: never pause, even at full"),
        Row(id: "N9", state: .normal, enabled: true, adapter: true, percent: 100, limit: 90,
            expected: .disableCharging, rationale: "fully charged past a real limit"),
        Row(id: "N10", state: .normal, enabled: true, adapter: true, percent: 50, limit: 50,
            expected: .disableCharging, rationale: "minimum slider value boundary"),
        Row(id: "N11", state: .normal, enabled: true, adapter: true, percent: 87, limit: 90,
            expected: .none, rationale: "replug inside band: band applies only while paused"),
        // MARK: paused
        Row(id: "P1", state: .paused, enabled: true, adapter: true, percent: 90, limit: 90,
            expected: .none, rationale: "at limit — hold pause"),
        Row(id: "P2", state: .paused, enabled: true, adapter: true, percent: 92, limit: 90,
            expected: .none, rationale: "above limit while paused — hold pause"),
        Row(id: "P3", state: .paused, enabled: true, adapter: true, percent: 86, limit: 90,
            expected: .none, rationale: "inside band, just above threshold — hold pause"),
        Row(id: "P4", state: .paused, enabled: true, adapter: true, percent: 85, limit: 90,
            expected: .enableCharging, rationale: "boundary: percent <= limit-5 resumes"),
        Row(id: "P5", state: .paused, enabled: true, adapter: true, percent: 84, limit: 90,
            expected: .enableCharging, rationale: "below threshold"),
        Row(id: "P6", state: .paused, enabled: false, adapter: true, percent: 90, limit: 90,
            expected: .enableCharging, rationale: "toggle-off-while-paused releases the pause"),
        Row(id: "P7", state: .paused, enabled: false, adapter: false, percent: nil, limit: 90,
            expected: .enableCharging, rationale: "all exit conditions at once — one explicit enable"),
        Row(id: "P8", state: .paused, enabled: true, adapter: false, percent: 90, limit: 90,
            expected: .enableCharging, rationale: "unplug at limit — never inhibited on battery"),
        Row(id: "P9", state: .paused, enabled: true, adapter: false, percent: 88, limit: 90,
            expected: .enableCharging, rationale: "unplug inside band"),
        Row(id: "P10", state: .paused, enabled: true, adapter: true, percent: nil, limit: 90,
            expected: .enableCharging, rationale: "percent unreadable while paused — fail open"),
        Row(id: "P11", state: .paused, enabled: true, adapter: true, percent: 90, limit: 100,
            expected: .enableCharging, rationale: "limit raised to 100 while paused — uncapped releases"),
        Row(id: "P12", state: .paused, enabled: true, adapter: true, percent: 90, limit: 96,
            expected: .enableCharging, rationale: "limit raised beyond band (90 <= 96-5)"),
        Row(id: "P13", state: .paused, enabled: true, adapter: true, percent: 90, limit: 93,
            expected: .none, rationale: "limit raised within band (90 > 88) — stays paused"),
        Row(id: "P14", state: .paused, enabled: true, adapter: true, percent: 88, limit: 80,
            expected: .none, rationale: "limit lowered below percent while paused — stays paused"),
        Row(id: "P15", state: .paused, enabled: true, adapter: true, percent: 100, limit: 100,
            expected: .enableCharging, rationale: "full at 100 with limit 100 — uncapped never pauses"),
    ]

    @Test(arguments: table)
    func transitionTableRow(_ row: Row) {
        let command = HysteresisEngine.decide(
            percent: row.percent,
            adapterConnected: row.adapter,
            limit: row.limit,
            enabled: row.enabled,
            currentState: row.state
        )
        #expect(command == row.expected, "\(row.id): \(row.rationale)")
    }

    /// The table must cover every row ID exactly once (guards copy-paste
    /// drift between PLAN.md and this file).
    @Test func tableRowIDsAreUnique() {
        let ids = Self.table.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.count == 26)
    }

    // MARK: nextState

    @Test func disableCommandLeadsToPaused() {
        #expect(HysteresisEngine.nextState(after: .disableCharging, from: .normal) == .paused)
        #expect(HysteresisEngine.nextState(after: .disableCharging, from: .paused) == .paused)
    }

    @Test func enableCommandLeadsToNormal() {
        #expect(HysteresisEngine.nextState(after: .enableCharging, from: .paused) == .normal)
        #expect(HysteresisEngine.nextState(after: .enableCharging, from: .normal) == .normal)
    }

    @Test func noCommandKeepsState() {
        #expect(HysteresisEngine.nextState(after: .none, from: .normal) == .normal)
        #expect(HysteresisEngine.nextState(after: .none, from: .paused) == .paused)
    }

    /// PLAN.md §7: the resume band is fixed at 5 points.
    @Test func resumeDeltaIsFive() {
        #expect(HysteresisEngine.resumeDelta == 5)
    }
}
