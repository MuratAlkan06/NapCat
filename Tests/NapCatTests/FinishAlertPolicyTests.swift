// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// Truth tables for the pure Track C finish-alert policy (PLAN.md Track C,
/// slice C3; verification matrix rows FA-1, FA-5, FA-7, FA-11). Row ids are
/// LOCKED — a changed rule changes a row, never silently a test.
struct FinishAlertPolicyTests {
    // MARK: Fixtures

    static let t0 = 1_800_000_000
    static let s1 = "aaaa0001-0000-4abc-8def-000000000001"
    static let s2 = "bbbb0002-0000-4abc-8def-000000000002"
    static let s3 = "cccc0003-0000-4abc-8def-000000000003"
    static let s4 = "dddd0004-0000-4abc-8def-000000000004"
    static let s5 = "eeee0005-0000-4abc-8def-000000000005"
    static let ups = ClaudeBusyConstants.setEvent
    static let waiting = ClaudeBusyConstants.waitingEventToken
    static let cap = ClaudeBusyConstants.freshnessCapSeconds

    static func marker(_ id: String, _ ts: Int, _ event: String) -> IdentifiedBusyMarker {
        IdentifiedBusyMarker(sessionID: id, marker: BusyMarker(ts: ts, event: event, pid: 1, src: "unknown"))
    }

    /// A hook v7 marker: the same, plus the RAW `ep` text (nil = a v6 marker).
    static func marker(_ id: String, _ ts: Int, _ event: String, ep: String?) -> IdentifiedBusyMarker {
        IdentifiedBusyMarker(sessionID: id, marker: BusyMarker(ts: ts, event: event, pid: 1, src: "unknown", ep: ep))
    }

    static func session(firstSeen: Int, exact: Bool, lastTs: Int, lastEvent: String = ups,
                        buzzed: Bool = false) -> TrackedSession {
        TrackedSession(firstSeen: firstSeen, exactStart: exact, lastTs: lastTs, lastEvent: lastEvent,
                       waitingBuzzed: buzzed)
    }

    // MARK: - Tunables (user rulings are code constants)

    @Test func tunablesAreTheContractValues() {
        // The run floor's DEFAULT (30 → 60: user ruling 2026-10-23); since
        // issue #34 the live floor is the user's setting, clamped to 30–600.
        #expect(FinishAlertTuning.minimumRunSeconds == 60)
        #expect(FinishAlertTuning.minimumRunSecondsRange == 30...600)
        #expect(FinishAlertTuning.minimumRunSecondsRange.contains(FinishAlertTuning.minimumRunSeconds))
        #expect(FinishAlertTuning.debounceSeconds == 2)
        #expect(FinishAlertTuning.batchWindowSeconds == 30)
        #expect(FinishAlertTuning.retryDelaySeconds == 30)
        #expect(FinishAlertTuning.retryMaxAgeSeconds == 300)
        #expect(FinishAlertTuning.rateLimitHoldSeconds == 600)
        #expect(FinishAlertTuning.staleCapSeconds == 43_200)
        #expect(FinishAlertTuning.staleCapSeconds == ClaudeBusyConstants.freshnessCapSeconds)
    }

    @Test func constructionIsAbsentInDebugSimulatorMode() {
        #expect(!FinishAlertPolicy.finishAlertMayBeConstructed(debugBattery: true))
        #expect(FinishAlertPolicy.finishAlertMayBeConstructed(debugBattery: false))
    }

    // MARK: - FA-1 disappearance: staleness, floor, clock jump

    struct DisappearRow: Sendable, CustomTestStringConvertible {
        let id: String
        let gone: TrackedSession
        let events: [FinishAlertEvent]
        let suppressed: [FinishAlertSuppression]
        var testDescription: String { "\(id): \(gone) → \(events) / \(suppressed)" }
    }

    /// One session, present in `previous`, absent from `current`, observed at t0.
    static let disappearRows: [DisappearRow] = {
        let t0 = Self.t0, cap = Self.cap
        return [
            DisappearRow(id: "D1", gone: session(firstSeen: t0 - 2_520, exact: true, lastTs: t0 - 100),
                         events: [.finished(minutes: 42)], suppressed: []),
            // D2–D4 (the hard-coded 59 / 60 / 61 s floor rows) moved to
            // `floorRows` (issue #34): the boundary is checked at several
            // floors there, the finish and the waiting buzz alike.
            DisappearRow(id: "D5", gone: session(firstSeen: t0 - cap, exact: true, lastTs: t0 - cap),
                         events: [.finished(minutes: 720)], suppressed: []),
            DisappearRow(id: "D6", gone: session(firstSeen: t0 - cap - 1, exact: true, lastTs: t0 - cap - 1),
                         events: [], suppressed: [.stale]),
            DisappearRow(id: "D7", gone: session(firstSeen: t0 + 10, exact: true, lastTs: t0 + 10),
                         events: [], suppressed: [.clockJump]),
            DisappearRow(id: "D8", gone: session(firstSeen: t0 - 3_600, exact: false, lastTs: t0 - 60,
                                                 lastEvent: "Stop"),
                         events: [.finished(minutes: nil)], suppressed: []),
            DisappearRow(id: "D9", gone: session(firstSeen: t0 - 60, exact: true, lastTs: t0 - 60),
                         events: [.finished(minutes: 1)], suppressed: []),
            DisappearRow(id: "D10", gone: session(firstSeen: t0 - 50_000, exact: true, lastTs: t0 - 50_000),
                         events: [], suppressed: [.stale]),
            DisappearRow(id: "D11", gone: session(firstSeen: t0 - 50_000, exact: true, lastTs: t0 - 600,
                                                  lastEvent: "Stop"),
                         events: [.finished(minutes: 833)], suppressed: []),
            DisappearRow(id: "D12", gone: session(firstSeen: t0 - 600, exact: true, lastTs: t0 - 300,
                                                  lastEvent: waiting, buzzed: true),
                         events: [.finished(minutes: 10)], suppressed: []),
        ]
    }()

    @Test(arguments: disappearRows)
    func disappearanceTable(_ row: DisappearRow) {
        let observation = FinishAlertPolicy.observe(previous: [Self.s1: row.gone], current: [], now: Self.t0)
        #expect(observation.events == row.events, "\(row.id)")
        #expect(observation.suppressed == row.suppressed, "\(row.id)")
        #expect(observation.tracked.isEmpty, "\(row.id): a disappeared session is never tracked again")
        #expect(observation.stillWorking == 0, "\(row.id)")
    }

    // MARK: - FA-1 transition detection

    @Test func presentToAbsentEmitsExactlyOneFinish() {
        let start = FinishAlertPolicy.observe(previous: [:], current: [Self.marker(Self.s1, Self.t0, Self.ups)],
                                              now: Self.t0 + 2)
        #expect(start.events.isEmpty && start.suppressed.isEmpty, "appearing is never an alert")
        #expect(start.tracked[Self.s1] == Self.session(firstSeen: Self.t0, exact: true, lastTs: Self.t0))
        #expect(start.stillWorking == 1)

        let unchanged = FinishAlertPolicy.observe(previous: start.tracked,
                                                  current: [Self.marker(Self.s1, Self.t0, Self.ups)],
                                                  now: Self.t0 + 100)
        #expect(unchanged.events.isEmpty && unchanged.suppressed.isEmpty)
        #expect(unchanged.tracked == start.tracked, "present → present with the same marker changes nothing")

        let finish = FinishAlertPolicy.observe(previous: unchanged.tracked, current: [], now: Self.t0 + 600)
        #expect(finish.events == [.finished(minutes: 10)])
        #expect(finish.tracked.isEmpty)

        let after = FinishAlertPolicy.observe(previous: finish.tracked, current: [], now: Self.t0 + 900)
        #expect(after.events.isEmpty && after.suppressed.isEmpty, "absent → absent never re-alerts")
    }

    @Test func eachDisappearanceIsReportedAndOrderIsWaitingThenFinishedById() {
        let previous: [String: TrackedSession] = [
            Self.s2: Self.session(firstSeen: Self.t0 - 600, exact: true, lastTs: Self.t0 - 600),
            Self.s1: Self.session(firstSeen: Self.t0 - 120, exact: true, lastTs: Self.t0 - 120),
            Self.s3:
                Self.session(firstSeen: Self.t0 - 900, exact: true, lastTs: Self.t0 - 900),
        ]
        let current = [Self.marker(Self.s3, Self.t0 - 1, Self.waiting)]
        let observation = FinishAlertPolicy.observe(previous: previous, current: current, now: Self.t0)
        #expect(observation.events == [.waiting(minutes: 15), .finished(minutes: 2), .finished(minutes: 10)],
                "waiting (present ids) first, then finishes sorted by session id")
        #expect(observation.stillWorking == 1, "the waiting session still has its marker")
    }

    /// stillWorking = tracked sessions whose last ts is FRESH under the same
    /// rule as the B1/B2 busy count (stale and future-dated are not).
    @Test func stillWorkingCountsFreshTrackedSessionsOnly() {
        let current = [
            Self.marker(Self.s1, Self.t0 - 10, Self.ups),
            Self.marker(Self.s2, Self.t0 - 20, Self.waiting),
            Self.marker(Self.s3, Self.t0 - Self.cap, "Stop"),
            Self.marker(Self.s4, Self.t0 - Self.cap - 1, "Stop"),
            Self.marker(Self.s5, Self.t0 + 60, Self.ups),
        ]
        let observation = FinishAlertPolicy.observe(previous: [:], current: current, now: Self.t0)
        #expect(observation.tracked.count == 5, "every present marker is tracked, fresh or not")
        #expect(observation.stillWorking == 3, "fresh: s1, s2 (waiting), and the exactly-at-cap one")
    }

    @Test func baselineTracksEverythingAndEmitsNothing() {
        let current = [
            Self.marker(Self.s1, Self.t0 - 600, Self.ups),
            Self.marker(Self.s2, Self.t0 - 300, Self.waiting),
            Self.marker(Self.s3, Self.t0 - 50_000, "Stop"),
        ]
        let baseline = FinishAlertPolicy.baseline(current: current, now: Self.t0)
        #expect(baseline == [
            Self.s1: Self.session(firstSeen: Self.t0 - 600, exact: true, lastTs: Self.t0 - 600),
            Self.s2: Self.session(firstSeen: Self.t0 - 300, exact: false, lastTs: Self.t0 - 300, lastEvent: Self.waiting),
            Self.s3: Self.session(firstSeen: Self.t0 - 50_000, exact: false, lastTs: Self.t0 - 50_000, lastEvent: "Stop"),
        ])
        // A stale baseline marker that is later swept reads as a sweep, never a finish.
        let swept = FinishAlertPolicy.observe(previous: baseline, current: Array(current.prefix(2)), now: Self.t0)
        #expect(swept.events.isEmpty)
        #expect(swept.suppressed == [.stale])
    }

    @Test func duplicateIdsKeepTheNewestMarker() {
        let observation = FinishAlertPolicy.observe(
            previous: [:],
            current: [Self.marker(Self.s1, Self.t0 - 5, Self.ups), Self.marker(Self.s1, Self.t0 - 50, "Stop")],
            now: Self.t0)
        #expect(observation.tracked[Self.s1] == Self.session(firstSeen: Self.t0 - 5, exact: true, lastTs: Self.t0 - 5))
    }

    // MARK: - Rule 5: minutes

    @Test(arguments: [
        // (id, duration, exact, expected)
        ("M1", 45, true, nil),
        ("M2", 59, true, nil),
        ("M3", 60, true, 1),
        ("M4", 119, true, 1),
        ("M5", 2_520, true, 42),
        ("M6", 2_520, false, nil),
        ("M7", 60, false, nil),
        ("M8", 0, true, nil),
        ("M9", -120, true, nil),
    ] as [(String, Int, Bool, Int?)])
    func minutesTable(_ id: String, _ duration: Int, _ exact: Bool, _ expected: Int?) {
        #expect(FinishAlertPolicy.minutes(duration: duration, exact: exact) == expected, "\(id)")
    }

    // MARK: - Multi-step scenarios (FA-5 + FA-11)

    struct Step: Sendable {
        let markers: [IdentifiedBusyMarker]
        let now: Int
        let events: [FinishAlertEvent]
        let suppressed: [FinishAlertSuppression]
        init(_ markers: [IdentifiedBusyMarker], now: Int, _ events: [FinishAlertEvent] = [],
             suppressed: [FinishAlertSuppression] = []) {
            self.markers = markers; self.now = now; self.events = events; self.suppressed = suppressed
        }
    }

    struct Scenario: Sendable, CustomTestStringConvertible {
        let id: String
        let note: String
        /// nil = start from an empty map (watcher armed with no markers);
        /// otherwise the arm-time baseline of these markers.
        let baseline: [IdentifiedBusyMarker]?
        let steps: [Step]
        var testDescription: String { "\(id): \(note)" }
    }

    static func run(_ scenario: Scenario) -> [FinishAlertObservation] {
        var tracked = scenario.baseline.map { FinishAlertPolicy.baseline(current: $0, now: t0) } ?? [:]
        var observations: [FinishAlertObservation] = []
        for step in scenario.steps {
            let observation = FinishAlertPolicy.observe(previous: tracked, current: step.markers, now: step.now)
            observations.append(observation)
            tracked = observation.tracked
        }
        return observations
    }

    static func m1(_ ts: Int, _ event: String) -> [IdentifiedBusyMarker] { [marker(s1, ts, event)] }

    static let scenarios: [Scenario] = {
        let t = Self.t0, ups = Self.ups, w = Self.waiting, was = ClaudeBusyConstants.waitingAfterStopEventToken
        return [
            // MARK: FA-5 — a newer UserPromptSubmit is never a finish, and (C3
            // rule 2 AMENDED 2026-10-27) never moves the EPISODE anchor either
            Scenario(id: "R1", note: "debounce-window recreate: newer UPS ts ⇒ no finish; the episode anchor holds",
                     baseline: nil, steps: [
                        Step(m1(t, ups), now: t + 2),
                        Step(m1(t + 600, ups), now: t + 602),          // cleared + recreated in one window
                        // The watcher never saw the id disappear: one episode, anchored at t.
                        Step([], now: t + 610, [.finished(minutes: 10)]),
                     ]),
            Scenario(id: "R2", note: "same id, same ts ⇒ nothing",
                     baseline: nil, steps: [
                        Step(m1(t, ups), now: t + 2),
                        Step(m1(t, ups), now: t + 300),
                        Step(m1(t, ups), now: t + 900),
                     ]),
            Scenario(id: "R3", note: "bg-running keep (Stop) then a newer UPS ⇒ the inexact first-seen anchor holds",
                     baseline: nil, steps: [
                        Step(m1(t, "Stop"), now: t + 2),                 // first seen as a keep: inexact
                        Step(m1(t + 100, ups), now: t + 102),            // never upgrades to exact mid-episode
                        Step([], now: t + 100 + 180, [.finished(minutes: nil)]),
                     ]),
            Scenario(id: "R4", note: "a UPS rewrite (here ts == lastTs) never moves the anchor",
                     baseline: nil, steps: [
                        Step(m1(t, ups), now: t + 2),
                        Step(m1(t + 50, "Stop"), now: t + 52),
                        Step(m1(t + 50, ups), now: t + 54),
                        Step([], now: t + 120, [.finished(minutes: 2)]),   // anchored at t, not t+50
                     ]),
            Scenario(id: "R5", note: "a later UPS mid-episode: finish minutes span the WHOLE episode, not the last prompt",
                     baseline: nil, steps: [
                        Step(m1(t, ups), now: t + 2),
                        Step(m1(t + 3_000, ups), now: t + 3_002),
                        Step([], now: t + 3_000 + 120, [.finished(minutes: 52)]),
                     ]),
            // MARK: C3 rule 2 AMENDED — the anchor is the EPISODE start
            // (UserPromptSubmit also fires for scheduled tasks, background
            // subagent report-backs and cross-session messages)
            Scenario(id: "E1", note: "keeps every ~31 s + automated UPS rewrites at t+300 / t+340 ⇒ ONE finish of 6 min",
                     baseline: nil, steps: [Step(m1(t, ups), now: t + 2)]
                        + ([(31, "Notification"), (62, "Notification"), (93, "Stop"), (124, "SubagentStop"),
                            (155, "SubagentStop"), (186, "Stop"), (217, "SubagentStop"), (248, "Notification"),
                            (279, "SubagentStop")] as [(Int, String)])
                            .map { (offset: Int, token: String) -> Step in Step(m1(t + offset, token), now: t + offset + 1) }
                        + [
                            Step(m1(t + 300, ups), now: t + 301),
                            Step(m1(t + 310, "SubagentStop"), now: t + 311),
                            Step(m1(t + 340, ups), now: t + 341),
                            Step([], now: t + 360, [.finished(minutes: 6)]),   // from t, not from t + 340
                        ]),
            Scenario(id: "E2", note: "a waiting transition late in a long episode reports the EPISODE minutes",
                     baseline: nil, steps: [
                        Step(m1(t, ups), now: t + 2),
                        Step(m1(t + 600, "Stop"), now: t + 602),
                        Step(m1(t + 1_200, ups), now: t + 1_202),        // a background subagent reported back
                        Step(m1(t + 1_500, w), now: t + 1_502, [.waiting(minutes: 25)]),
                     ]),
            Scenario(id: "E3", note: "an episode boundary still re-anchors: disappear ⇒ finish; reappear as UPS ⇒ new exact anchor",
                     baseline: nil, steps: [
                        Step(m1(t, ups), now: t + 2),
                        Step(m1(t + 300, ups), now: t + 302),
                        Step([], now: t + 600, [.finished(minutes: 10)]),
                        Step(m1(t + 700, ups), now: t + 702),
                        Step(m1(t + 880, w), now: t + 882, [.waiting(minutes: 3)]),   // from t + 700, exact
                        Step([], now: t + 1_000, [.finished(minutes: 5)]),
                     ]),
            Scenario(id: "E4", note: "waiting → UPS (the user answered) clears the dedupe, keeps the anchor; a 2nd wait buzzes with episode minutes",
                     baseline: nil, steps: [
                        Step(m1(t, ups), now: t + 2),
                        Step(m1(t + 300, w), now: t + 302, [.waiting(minutes: 5)]),
                        Step(m1(t + 360, ups), now: t + 362),
                        Step(m1(t + 600, "Notification"), now: t + 602),
                        Step(m1(t + 900, w), now: t + 902, [.waiting(minutes: 15)]),
                        Step(m1(t + 960, w), now: t + 962),
                        Step([], now: t + 1_200, [.finished(minutes: 20)]),
                     ]),
            // MARK: FA-11 — waiting buzz
            Scenario(id: "W1", note: "UPS → waiting ⇒ exactly one buzz",
                     baseline: nil, steps: [
                        Step(m1(t, ups), now: t + 2),
                        Step(m1(t + 300, w), now: t + 302, [.waiting(minutes: 5)]),
                     ]),
            Scenario(id: "W2", note: "rewrite spam (waiting, newer ts) ⇒ no re-buzz",
                     baseline: nil, steps: [
                        Step(m1(t, ups), now: t + 2),
                        Step(m1(t + 300, w), now: t + 302, [.waiting(minutes: 5)]),
                        Step(m1(t + 400, w), now: t + 402),
                        Step(m1(t + 500, w), now: t + 502),
                     ]),
            Scenario(id: "W3", note: "dedupe cleared by disappearance; the id's next turn is a new episode",
                     baseline: nil, steps: [
                        Step(m1(t, ups), now: t + 2),
                        Step(m1(t + 300, w), now: t + 302, [.waiting(minutes: 5)]),
                        Step([], now: t + 600, [.finished(minutes: 10)]),
                        Step(m1(t + 700, ups), now: t + 702),
                        Step(m1(t + 800, w), now: t + 802, [.waiting(minutes: 1)]),
                     ]),
            Scenario(id: "W4", note: "waiting → Notification → waiting ⇒ second buzz",
                     baseline: nil, steps: [
                        Step(m1(t, ups), now: t + 2),
                        Step(m1(t + 300, w), now: t + 302, [.waiting(minutes: 5)]),
                        Step(m1(t + 400, "Notification"), now: t + 402),
                        Step(m1(t + 600, w), now: t + 602, [.waiting(minutes: 10)]),
                     ]),
            Scenario(id: "W5", note: "a newer UPS clears the dedupe (leaving waiting) but keeps the episode anchor",
                     baseline: nil, steps: [
                        Step(m1(t, ups), now: t + 2),
                        Step(m1(t + 300, w), now: t + 302, [.waiting(minutes: 5)]),
                        Step(m1(t + 400, ups), now: t + 402),
                        Step(m1(t + 520, w), now: t + 520, [.waiting(minutes: 8)]),
                     ]),
            Scenario(id: "W6", note: "floor: waiting 10 s in ⇒ suppressed; later rewrites never buzz the episode",
                     baseline: nil, steps: [
                        Step(m1(t, ups), now: t + 2),
                        Step(m1(t + 10, w), now: t + 10, suppressed: [.underMinimumRun]),
                        Step(m1(t + 100, w), now: t + 100),
                        Step(m1(t + 200, w), now: t + 200),
                     ]),
            // W7–W8 (the hard-coded 59 / 60 s waiting-floor rows) moved to
            // `floorRows` (issue #34), checked at several floors.
            Scenario(id: "W9", note: "bg-running / resume keeps are never waiting",
                     baseline: nil, steps: [
                        Step(m1(t, ups), now: t + 2),
                        Step(m1(t + 600, "Stop"), now: t + 602),
                        Step(m1(t + 1_200, "SubagentStop"), now: t + 1_202),
                        Step(m1(t + 1_800, "StopFailure"), now: t + 1_802),
                        Step(m1(t + 2_400, "Notification"), now: t + 2_402),
                     ]),
            Scenario(id: "W10", note: "new id first seen as waiting, fresh ⇒ inexact anchor, suppressed by the floor",
                     baseline: nil, steps: [
                        Step(m1(t, w), now: t + 2, suppressed: [.underMinimumRun]),
                        Step(m1(t + 100, w), now: t + 102),
                     ]),
            Scenario(id: "W11", note: "new id first seen as waiting, older ts ⇒ buzz with minutes nil (inexact)",
                     baseline: nil, steps: [
                        Step(m1(t, w), now: t + 600, [.waiting(minutes: nil)]),
                     ]),
            Scenario(id: "W12", note: "already waiting at arm time ⇒ no buzz for that episode",
                     baseline: m1(t, w), steps: [
                        Step(m1(t + 300, w), now: t + 302),
                        Step(m1(t + 400, "Notification"), now: t + 402),
                        Step(m1(t + 500, w), now: t + 502, [.waiting(minutes: nil)]),   // anchor from a waiting marker
                     ]),
            Scenario(id: "W13", note: "negative run (clock went back) ⇒ clockJump, no buzz",
                     baseline: nil, steps: [
                        Step(m1(t + 1_000, ups), now: t),
                        Step(m1(t + 5, w), now: t + 5, suppressed: [.clockJump]),
                     ]),
            Scenario(id: "W14", note: "baseline disappearances are alerted only after arming",
                     baseline: m1(t, ups), steps: [
                        Step([], now: t + 900, [.finished(minutes: 15)]),
                     ]),
            // MARK: B-2 — the post-Stop waiting token is the same waiting class
            Scenario(id: "W15", note: "post-Stop keep → waiting-after-stop ⇒ exactly one buzz; rewrites never re-buzz",
                     baseline: nil, steps: [
                        Step(m1(t, ups), now: t + 2),
                        Step(m1(t + 600, "Stop"), now: t + 602),
                        Step(m1(t + 660, was), now: t + 662, [.waiting(minutes: 11)]),
                        Step(m1(t + 720, was), now: t + 722),
                     ]),
            Scenario(id: "W16", note: "waiting → waiting-after-stop is NOT a new episode (no second buzz)",
                     baseline: nil, steps: [
                        Step(m1(t, ups), now: t + 2),
                        Step(m1(t + 300, w), now: t + 302, [.waiting(minutes: 5)]),
                        Step(m1(t + 400, was), now: t + 402),
                        Step(m1(t + 500, w), now: t + 502),
                     ]),
            Scenario(id: "W17", note: "waiting-after-stop → Stop clears the dedupe; the next wait buzzes again",
                     baseline: nil, steps: [
                        Step(m1(t, ups), now: t + 2),
                        Step(m1(t + 600, "Stop"), now: t + 602),
                        Step(m1(t + 660, was), now: t + 662, [.waiting(minutes: 11)]),
                        Step(m1(t + 700, "Stop"), now: t + 702),
                        Step(m1(t + 900, was), now: t + 902, [.waiting(minutes: 15)]),
                     ]),
            Scenario(id: "W18", note: "B-2 hook keep: waiting → Notification (subagent ended mid-turn) → waiting ⇒ second buzz",
                     baseline: nil, steps: [
                        Step(m1(t, ups), now: t + 2),
                        Step(m1(t + 300, w), now: t + 302, [.waiting(minutes: 5)]),
                        Step(m1(t + 360, "Notification"), now: t + 362),
                        Step(m1(t + 480, w), now: t + 482, [.waiting(minutes: 8)]),
                     ]),
        ]
    }()

    @Test(arguments: scenarios)
    func scenarioTable(_ scenario: Scenario) {
        let observations = Self.run(scenario)
        for (index, (step, observation)) in zip(scenario.steps, observations).enumerated() {
            #expect(observation.events == step.events, "\(scenario.id) step \(index + 1): events")
            #expect(observation.suppressed == step.suppressed, "\(scenario.id) step \(index + 1): suppressed")
        }
    }

    /// FA-5 × C3 rule 2 AMENDED (2026-10-27): a newer UserPromptSubmit
    /// updates only lastTs/lastEvent — the episode anchor and its exactness
    /// never move (not just "no event"); leaving waiting still clears the
    /// dedupe, once, through the leaving-waiting rule.
    @Test func aMidEpisodeUserPromptSubmitNeverMovesTheAnchor() {
        let previous = [Self.s1: Self.session(firstSeen: Self.t0 - 600, exact: false, lastTs: Self.t0 - 300,
                                              lastEvent: Self.waiting, buzzed: true)]
        let observation = FinishAlertPolicy.observe(previous: previous,
                                                    current: Self.m1(Self.t0 - 1, Self.ups), now: Self.t0)
        #expect(observation.events.isEmpty && observation.suppressed.isEmpty)
        #expect(observation.tracked[Self.s1] == Self.session(firstSeen: Self.t0 - 600, exact: false,
                                                             lastTs: Self.t0 - 1, lastEvent: Self.ups, buzzed: false))

        let exactPrevious = [Self.s1: Self.session(firstSeen: Self.t0 - 900, exact: true, lastTs: Self.t0 - 100,
                                                   lastEvent: "Stop")]
        let rewritten = FinishAlertPolicy.observe(previous: exactPrevious,
                                                  current: Self.m1(Self.t0, Self.ups), now: Self.t0 + 1)
        #expect(rewritten.events.isEmpty && rewritten.suppressed.isEmpty)
        #expect(rewritten.tracked[Self.s1] == Self.session(firstSeen: Self.t0 - 900, exact: true,
                                                           lastTs: Self.t0, lastEvent: Self.ups))
    }

    /// FA-11: a suppressed transition leaves the dedupe flag FALSE; a sent one sets it.
    @Test func waitingBuzzedFlagFollowsTheOutcome() {
        let start = [Self.s1: Self.session(firstSeen: Self.t0, exact: true, lastTs: Self.t0)]
        let early = FinishAlertPolicy.observe(previous: start, current: Self.m1(Self.t0 + 10, Self.waiting),
                                              now: Self.t0 + 10)
        #expect(early.tracked[Self.s1]?.waitingBuzzed == false)
        #expect(early.tracked[Self.s1]?.lastEvent == Self.waiting)
        let late = FinishAlertPolicy.observe(previous: start, current: Self.m1(Self.t0 + 60, Self.waiting),
                                             now: Self.t0 + 60)
        #expect(late.tracked[Self.s1]?.waitingBuzzed == true)
        #expect(late.tracked[Self.s1]?.firstSeen == Self.t0, "a waiting rewrite never moves the anchor")
        let resumed = FinishAlertPolicy.observe(previous: late.tracked, current: Self.m1(Self.t0 + 90, "Notification"),
                                                now: Self.t0 + 90)
        #expect(resumed.tracked[Self.s1]?.waitingBuzzed == false, "leaving waiting ends the episode")
    }

    /// B-2: the dedupe flag treats BOTH waiting tokens as one episode — a
    /// `waiting` → `waiting-after-stop` rewrite keeps it set (no new buzz),
    /// and only a NON-waiting token (here the post-Stop `Stop` a resume
    /// writes) clears it.
    @Test func waitingAfterStopSharesTheWaitingEpisode() {
        let afterStop = ClaudeBusyConstants.waitingAfterStopEventToken
        let start = [Self.s1: Self.session(firstSeen: Self.t0, exact: true, lastTs: Self.t0)]
        let buzzed = FinishAlertPolicy.observe(previous: start, current: Self.m1(Self.t0 + 60, afterStop),
                                               now: Self.t0 + 60)
        #expect(buzzed.events == [.waiting(minutes: 1)], "a transition into waiting-after-stop buzzes")
        #expect(buzzed.tracked[Self.s1]?.waitingBuzzed == true)

        let swapped = FinishAlertPolicy.observe(previous: buzzed.tracked, current: Self.m1(Self.t0 + 90, Self.waiting),
                                                now: Self.t0 + 90)
        #expect(swapped.events.isEmpty, "a change between the two waiting tokens is not a new episode")
        #expect(swapped.tracked[Self.s1]?.waitingBuzzed == true)

        let back = FinishAlertPolicy.observe(previous: swapped.tracked, current: Self.m1(Self.t0 + 120, afterStop),
                                             now: Self.t0 + 120)
        #expect(back.events.isEmpty)
        let resumed = FinishAlertPolicy.observe(previous: back.tracked, current: Self.m1(Self.t0 + 150, "Stop"),
                                                now: Self.t0 + 150)
        #expect(resumed.events.isEmpty)
        #expect(resumed.tracked[Self.s1]?.waitingBuzzed == false, "leaving waiting-after-stop ends the episode")
    }

    // MARK: - Issue #34: the adjustable run floor (finish AND waiting)

    /// One run, measured from an EXACT anchor, judged against one floor —
    /// passed to `observe` the way the controller passes the user's setting.
    /// They replace the hard-coded 59 / 60 / 61 s rows (D2–D4, W7–W8): the
    /// boundary (one second under / exactly / one second over) is checked at
    /// the lower bound, the default, a raised floor and the upper bound.
    /// `minutes` is what a SENT run reads: under a full minute it is unknown
    /// (rule 5), even though the run qualifies. Row ids are LOCKED.
    struct FloorRow: Sendable, CustomTestStringConvertible {
        let id: String
        let floor: Int
        let run: Int
        let sent: Bool
        let minutes: Int?
        var testDescription: String { "\(id): floor \(floor) s, run \(run) s → \(sent ? "sent" : "suppressed")" }
    }

    static let floorRows: [FloorRow] = [
        FloorRow(id: "F30a", floor: 30, run: 29, sent: false, minutes: nil),
        FloorRow(id: "F30b", floor: 30, run: 30, sent: true, minutes: nil),
        FloorRow(id: "F30c", floor: 30, run: 31, sent: true, minutes: nil),
        FloorRow(id: "F60a", floor: 60, run: 59, sent: false, minutes: nil),
        FloorRow(id: "F60b", floor: 60, run: 60, sent: true, minutes: 1),
        FloorRow(id: "F60c", floor: 60, run: 61, sent: true, minutes: 1),
        FloorRow(id: "F120a", floor: 120, run: 119, sent: false, minutes: nil),
        FloorRow(id: "F120b", floor: 120, run: 120, sent: true, minutes: 2),
        FloorRow(id: "F120c", floor: 120, run: 121, sent: true, minutes: 2),
        FloorRow(id: "F600a", floor: 600, run: 599, sent: false, minutes: nil),
        FloorRow(id: "F600b", floor: 600, run: 600, sent: true, minutes: 10),
        FloorRow(id: "F600c", floor: 600, run: 601, sent: true, minutes: 10),
    ]

    /// The default floor's rows must also hold WITHOUT the argument: the
    /// parameter's default is the 60 s constant.
    static func expectTheDefaultFloorMatches(_ row: FloorRow, _ observation: FinishAlertObservation,
                                             _ observeWithTheDefault: () -> FinishAlertObservation) {
        guard row.floor == FinishAlertTuning.minimumRunSeconds else { return }
        #expect(observeWithTheDefault() == observation, "\(row.id): the default floor is the 60 s constant")
    }

    /// Rule 3 (a disappearance) at the given floor.
    @Test(arguments: floorRows)
    func theFinishFloorFollowsTheSetting(_ row: FloorRow) {
        let gone = [Self.s1: Self.session(firstSeen: Self.t0 - row.run, exact: true, lastTs: Self.t0 - row.run)]
        let observation = FinishAlertPolicy.observe(previous: gone, current: [], now: Self.t0,
                                                    minimumRunSeconds: row.floor)
        #expect(observation.events == (row.sent ? [.finished(minutes: row.minutes)] : []), "\(row.id)")
        #expect(observation.suppressed == (row.sent ? [] : [.underMinimumRun]), "\(row.id)")
        #expect(observation.tracked.isEmpty, "\(row.id)")
        Self.expectTheDefaultFloorMatches(row, observation) {
            FinishAlertPolicy.observe(previous: gone, current: [], now: Self.t0)
        }
    }

    /// Rule 4 (a waiting transition) at the SAME floor: the knob governs the
    /// waiting buzz too. A suppressed transition leaves the dedupe flag false.
    @Test(arguments: floorRows)
    func theWaitingFloorFollowsTheSetting(_ row: FloorRow) {
        let busy = [Self.s1: Self.session(firstSeen: Self.t0 - row.run, exact: true, lastTs: Self.t0 - row.run)]
        let waiting = Self.m1(Self.t0, Self.waiting)
        let observation = FinishAlertPolicy.observe(previous: busy, current: waiting, now: Self.t0,
                                                    minimumRunSeconds: row.floor)
        #expect(observation.events == (row.sent ? [.waiting(minutes: row.minutes)] : []), "\(row.id)")
        #expect(observation.suppressed == (row.sent ? [] : [.underMinimumRun]), "\(row.id)")
        #expect(observation.tracked[Self.s1]?.waitingBuzzed == row.sent, "\(row.id)")
        Self.expectTheDefaultFloorMatches(row, observation) {
            FinishAlertPolicy.observe(previous: busy, current: waiting, now: Self.t0)
        }
    }

    /// One diff, one floor: a waiting buzz under it and a finish over it are
    /// judged against the same value; a negative run is still a clock jump,
    /// whatever the floor.
    @Test func oneFloorGovernsBothRulesInOneDiff() {
        let t = Self.t0
        let previous = [
            Self.s1: Self.session(firstSeen: t - 119, exact: true, lastTs: t - 119),
            Self.s2: Self.session(firstSeen: t - 121, exact: true, lastTs: t - 121),
            Self.s3: Self.session(firstSeen: t + 10, exact: true, lastTs: t + 10),
        ]
        let observation = FinishAlertPolicy.observe(previous: previous, current: Self.m1(t, Self.waiting), now: t,
                                                    minimumRunSeconds: 120)
        #expect(observation.events == [.finished(minutes: 2)], "s2 finished over the floor")
        #expect(observation.suppressed == [.underMinimumRun, .clockJump], "s1 waiting under it; s3 a clock jump")
    }

    /// The ONE clamp rule for a stored `finishAlertMinimumRunSeconds` value:
    /// missing or not an integer ⇒ the 60 s default; outside 30–600 ⇒ the
    /// nearer bound (29 → 30, 601 → 600).
    @Test func aStoredFloorIsClampedAndJunkReadsAsTheDefault() {
        let rows: [(id: String, stored: Any?, expected: Int)] = [
            ("missing", nil, 60),
            ("29 clamps up", 29, 30),
            ("the lower bound", 30, 30),
            ("31", 31, 31),
            ("the default", 60, 60),
            ("120", 120, 120),
            ("599", 599, 599),
            ("the upper bound", 600, 600),
            ("601 clamps down", 601, 600),
            ("zero", 0, 30),
            ("negative", -120, 30),
            ("Int.min", Int.min, 30),
            ("Int.max", Int.max, 600),
            ("a plist integer", NSNumber(value: 120), 120),
            ("a plist fraction", NSNumber(value: 120.5), 60),
            ("a plist Bool (reads as 1)", NSNumber(value: true), 30),
            ("a string", "junk", 60),
            ("a numeric string", "120", 60),
            ("an array", [1, 2], 60),
        ]
        for row in rows {
            #expect(FinishAlertPolicy.minimumRunSeconds(stored: row.stored) == row.expected, "\(row.id)")
        }
    }

    // MARK: - Hook v7: the episode start (`ep`), validated here only

    struct EpisodeStartRow: Sendable, CustomTestStringConvertible {
        let id: String
        let raw: String?
        let expected: EpisodeStartReading
        var testDescription: String { "\(id): \(raw.map { String($0.prefix(24)) } ?? "nil") → \(expected)" }
    }

    /// Judged at `t0`. Row ids are LOCKED.
    static let episodeStartRows: [EpisodeStartRow] = {
        let t0 = Self.t0, cap = Self.cap
        return [
            EpisodeStartRow(id: "P1 absent (hook v6)", raw: nil, expected: .absent),
            EpisodeStartRow(id: "P2 valid", raw: String(t0 - 600), expected: .valid(t0 - 600)),
            EpisodeStartRow(id: "P3 exactly now", raw: String(t0), expected: .valid(t0)),
            EpisodeStartRow(id: "P4 exactly the 12 h horizon", raw: String(t0 - cap), expected: .valid(t0 - cap)),
            EpisodeStartRow(id: "P5 one second past the horizon", raw: String(t0 - cap - 1), expected: .invalid),
            EpisodeStartRow(id: "P6 one second in the future", raw: String(t0 + 1), expected: .invalid),
            EpisodeStartRow(id: "P7 empty", raw: "", expected: .invalid),
            EpisodeStartRow(id: "P8 zero", raw: "0", expected: .invalid),
            // Signs, letters, spaces and non-ASCII digits fail the ASCII-digit
            // check (Int alone would accept a sign).
            EpisodeStartRow(id: "P9 negative", raw: "-600", expected: .invalid),
            EpisodeStartRow(id: "P10 plus sign", raw: "+179999940", expected: .invalid),
            EpisodeStartRow(id: "P11 letters", raw: "abc", expected: .invalid),
            EpisodeStartRow(id: "P12 hex", raw: "0x6b49d200", expected: .invalid),
            EpisodeStartRow(id: "P13 trailing junk", raw: "179999940s", expected: .invalid),
            EpisodeStartRow(id: "P14 inner space", raw: "17999 9940", expected: .invalid),
            EpisodeStartRow(id: "P15 non-ASCII digits", raw: "١٢٣٤٥", expected: .invalid),
            EpisodeStartRow(id: "P16 fullwidth digits", raw: "１２３", expected: .invalid),
            // Eleven characters that WOULD convert to a valid, fresh Int: only
            // the length check (run before the conversion) rejects them.
            EpisodeStartRow(id: "P17 11 chars, leading zero", raw: "0\(t0 - 600)", expected: .invalid),
            EpisodeStartRow(id: "P18 past Int.max", raw: "99999999999999999999", expected: .invalid),
            EpisodeStartRow(id: "P19 huge", raw: String(repeating: "9", count: 100_000), expected: .invalid),
            EpisodeStartRow(id: "P20 10 digits, leading zero, too old", raw: "0001800000", expected: .invalid),
            EpisodeStartRow(id: "P21 NUL inside", raw: "17999\u{0}9400", expected: .invalid),
        ]
    }()

    @Test(arguments: episodeStartRows)
    func episodeStartTable(_ row: EpisodeStartRow) {
        #expect(FinishAlertPolicy.episodeStart(row.raw, now: Self.t0) == row.expected, "\(row.id)")
    }

    @Test func episodeStartDigitBoundIsTheParityConstant() {
        #expect(ClaudeBusyConstants.episodeStartMaxDigits == 10)
        // The largest 10-digit value parses; it is only too far in the future.
        #expect(FinishAlertPolicy.episodeStart("9999999999", now: 9_999_999_999) == .valid(9_999_999_999))
        #expect(FinishAlertPolicy.episodeStart("1", now: 1) == .valid(1), "a 1-digit start at the same now")
    }

    /// The anchor of an id seen for the FIRST time — at the arm-time baseline
    /// or in a diff — prefers a valid `ep` (exact, whatever the token); an
    /// absent `ep` keeps the pre-v7 rule; a rejected one falls back to it AND
    /// is counted (counts only — the reading never carries the raw value).
    @Test func aFirstSightingPrefersAValidEpisodeStart() {
        let t = Self.t0
        let current = [
            Self.marker(Self.s1, t - 60, "Stop", ep: String(t - 1_800)),          // valid: exact from ep
            Self.marker(Self.s2, t - 60, "Stop", ep: nil),                         // v6: ts, inexact
            Self.marker(Self.s3, t - 60, Self.ups, ep: "abc"),                    // invalid: ts, exact (UPS)
            Self.marker(Self.s4, t - 30, Self.waiting, ep: String(t + 60)),       // future: ts, inexact
            Self.marker(Self.s5, t - 60, "Stop", ep: String(t - Self.cap - 1)),   // too old: ts, inexact
        ]
        let expected: [String: TrackedSession] = [
            Self.s1: Self.session(firstSeen: t - 1_800, exact: true, lastTs: t - 60, lastEvent: "Stop"),
            Self.s2: Self.session(firstSeen: t - 60, exact: false, lastTs: t - 60, lastEvent: "Stop"),
            Self.s3: Self.session(firstSeen: t - 60, exact: true, lastTs: t - 60),
            Self.s4: Self.session(firstSeen: t - 30, exact: false, lastTs: t - 30, lastEvent: Self.waiting),
            Self.s5: Self.session(firstSeen: t - 60, exact: false, lastTs: t - 60, lastEvent: "Stop"),
        ]
        #expect(FinishAlertPolicy.baseline(current: current, now: t) == expected)
        #expect(FinishAlertPolicy.invalidEpisodeStartCount(in: current, now: t) == 3, "abc, future, too old")

        let observation = FinishAlertPolicy.observe(previous: [:], current: current, now: t)
        #expect(observation.tracked == expected, "a new id in a diff follows the same rule as the baseline")
        #expect(observation.invalidEpisodeStarts == 3)
        #expect(observation.suppressed == [.underMinimumRun], "s4: new id already waiting, 60 s floor not met")
        #expect(observation.events.isEmpty)

        // Counted once, at first sight: the same markers again count nothing.
        let again = FinishAlertPolicy.observe(previous: observation.tracked, current: current, now: t + 30)
        #expect(again.invalidEpisodeStarts == 0)
        #expect(FinishAlertPolicy.invalidEpisodeStartCount(in: [], now: t) == 0)
        #expect(FinishAlertPolicy.invalidEpisodeStartCount(in: [Self.marker(Self.s1, t, Self.ups)], now: t) == 0,
                "an absent ep (hook v6) is the normal fallback, never counted")
    }

    /// Rule 2 holds for `ep` too: an id already tracked never adopts a later
    /// marker's `ep` — a hook v6 → v7 swap mid-episode writes a FRESH, later
    /// one, which would under-count the run.
    @Test func aTrackedIdNeverAdoptsALaterEpisodeStart() {
        let t = Self.t0
        let start = FinishAlertPolicy.observe(previous: [:], current: [Self.marker(Self.s1, t, Self.ups)], now: t + 2)
        let swapped = FinishAlertPolicy.observe(previous: start.tracked,
                                                current: [Self.marker(Self.s1, t + 600, "Notification", ep: String(t + 600))],
                                                now: t + 602)
        #expect(swapped.tracked[Self.s1]?.firstSeen == t, "the anchor taken at first sight stands")
        #expect(swapped.invalidEpisodeStarts == 0)
        let finish = FinishAlertPolicy.observe(previous: swapped.tracked, current: [], now: t + 1_800)
        #expect(finish.events == [.finished(minutes: 30)], "not 20")
    }

    /// Issue #24 — the restart-survival scenario. ONE episode: a prompt at
    /// t, then keeps, an automated prompt and more keeps, finished at
    /// t + 1 800. Each `restartAt` drops the app-side anchor there — the new
    /// process starts from a baseline of the marker on disk at that moment —
    /// and replays the rest. With hook v7 markers (every write carries
    /// `ep=t`) the reported minutes are the uninterrupted 30 at EVERY restart
    /// point; with hook v6 markers the old re-anchoring stays as it was.
    @Test func aRestartMidEpisodeNoLongerChangesTheReportedMinutes() {
        let t = Self.t0
        let writes: [(ts: Int, event: String)] = [
            (t, Self.ups), (t + 300, "Notification"), (t + 600, "Stop"), (t + 900, Self.ups),
            (t + 1_100, "SubagentStop"), (t + 1_500, "Stop"),
        ]
        func finish(restartAt: Int?, ep: String?) -> [FinishAlertEvent] {
            var tracked: [String: TrackedSession] = [:]
            var restarted = restartAt == nil
            // NapCat relaunched: in-memory state gone, baseline from disk.
            func restart(at moment: Int) {
                let onDisk = writes.last { $0.ts <= moment }.map { [Self.marker(Self.s1, $0.ts, $0.event, ep: ep)] } ?? []
                tracked = FinishAlertPolicy.baseline(current: onDisk, now: moment)
                restarted = true
            }
            for write in writes {
                if !restarted, let restartAt, write.ts > restartAt { restart(at: restartAt) }
                tracked = FinishAlertPolicy.observe(previous: tracked,
                                                    current: [Self.marker(Self.s1, write.ts, write.event, ep: ep)],
                                                    now: write.ts + 2).tracked
            }
            if !restarted, let restartAt { restart(at: restartAt) }   // after the last write
            #expect(restarted)
            return FinishAlertPolicy.observe(previous: tracked, current: [], now: t + 1_800).events
        }

        let v7 = String(t)
        #expect(finish(restartAt: nil, ep: v7) == [.finished(minutes: 30)], "uninterrupted")
        #expect(finish(restartAt: nil, ep: nil) == [.finished(minutes: 30)], "uninterrupted, hook v6")
        for restartAt in [t + 100, t + 450, t + 700, t + 1_000, t + 1_200, t + 1_600] {
            #expect(finish(restartAt: restartAt, ep: v7) == [.finished(minutes: 30)],
                    "hook v7, restart at t+\(restartAt - t): the minutes must not change")
        }
        // Hook v6 (no ep): unchanged fallback — the documented under-count.
        #expect(finish(restartAt: t + 1_000, ep: nil) == [.finished(minutes: 15)], "re-anchored at the t+900 prompt")
        #expect(finish(restartAt: t + 1_200, ep: nil) == [.finished(minutes: nil)], "re-anchored at a keep: inexact")
    }

    /// The waiting buzz after a restart reports the episode minutes too.
    @Test func aWaitingBuzzAfterARestartUsesTheEpisodeStart() {
        let t = Self.t0
        let baseline = FinishAlertPolicy.baseline(current: [Self.marker(Self.s1, t + 600, "Stop", ep: String(t))],
                                                  now: t + 700)
        let observation = FinishAlertPolicy.observe(
            previous: baseline,
            current: [Self.marker(Self.s1, t + 1_500, ClaudeBusyConstants.waitingAfterStopEventToken, ep: String(t))],
            now: t + 1_502)
        #expect(observation.events == [.waiting(minutes: 25)])
    }

    /// Ids are internal keys: every event payload leaf is an Int (or nil).
    @Test func eventsCarryOnlyIntMinutes() {
        func leaves(_ value: Any) -> [Any] {
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional || mirror.displayStyle == .tuple {
                return mirror.children.flatMap { leaves($0.value) }
            }
            return [value]
        }
        let events: [(event: FinishAlertEvent, leafCount: Int)] = [
            (.finished(minutes: 3), 1), (.waiting(minutes: 7), 1),
            (.finished(minutes: nil), 0), (.waiting(minutes: nil), 0),
        ]
        for (event, leafCount) in events {
            let found = Mirror(reflecting: event).children.flatMap { leaves($0.value) }
            #expect(found.count == leafCount, "\(event): the payload walk must see every value (non-vacuous)")
            for leaf in found {
                #expect(leaf is Int, "\(event): only Int minutes may ride in an event — never a session id")
            }
            switch event { case .finished, .waiting: break }   // closed: a new case must be added here
        }
    }

    // MARK: - Digest (batch fold)

    @Test func threeFinishesFoldToOneMessage() {
        var digest = FinishAlertDigest()
        #expect(digest.isEmpty && digest.messages().isEmpty)
        digest.fold(.finished(minutes: 12), stillWorking: 2, at: 100)
        digest.fold(.finished(minutes: nil), stillWorking: 1, at: 110)
        digest.fold(.finished(minutes: 40), stillWorking: 0, at: 120)
        #expect(!digest.isEmpty)
        #expect(digest.messages() == [.sessionFinished(minutes: nil, folded: 3, stillWorking: 0)],
                "folded finishes omit minutes and carry the LATEST still-working count")
        #expect(digest.originatedAt == 100, "retry age anchors on the FIRST folded event")
        #expect(digest.firstFinishMinutes == 12, "the first minutes are kept")
    }

    @Test func oneFinishKeepsItsMinutes() {
        var digest = FinishAlertDigest()
        digest.fold(.finished(minutes: 42), stillWorking: 1, at: 500)
        #expect(digest.messages() == [.sessionFinished(minutes: 42, folded: 1, stillWorking: 1)])
        #expect(digest.originatedAt == 500)
    }

    @Test func waitingAndFinishGiveTwoMessagesWaitingFirst() {
        var digest = FinishAlertDigest()
        digest.fold(.finished(minutes: 9), stillWorking: 2, at: 10)
        digest.fold(.waiting(minutes: 4), stillWorking: 3, at: 20)
        #expect(digest.messages() == [
            .needsAttention(minutes: 4, stillWorking: 2),             // others = 3 − the waiting one
            .sessionFinished(minutes: 9, folded: 1, stillWorking: 3),
        ])
        #expect(digest.originatedAt == 10)
        #expect(digest.stillWorking == 3, "stillWorking is the latest")
    }

    @Test func waitingOthersExcludeTheWaitingSessionAndClampAtZero() {
        var alone = FinishAlertDigest()
        alone.fold(.waiting(minutes: 12), stillWorking: 1, at: 0)
        #expect(alone.messages() == [.needsAttention(minutes: 12, stillWorking: 0)])
        var none = FinishAlertDigest()
        none.fold(.waiting(minutes: nil), stillWorking: 0, at: 0)
        #expect(none.messages() == [.needsAttention(minutes: nil, stillWorking: 0)], "never negative")
        var two = FinishAlertDigest()
        two.fold(.waiting(minutes: 12), stillWorking: 2, at: 0)
        two.fold(.waiting(minutes: 30), stillWorking: 2, at: 5)
        #expect(two.messages() == [.needsAttention(minutes: nil, stillWorking: 1)],
                "two folded waits: minutes omitted (they differ per session)")
        #expect(two.firstWaitingMinutes == 12)
    }

    // MARK: - S10: absorbing a queued message back after a 429

    struct AbsorbRow: Sendable, CustomTestStringConvertible {
        let id: String
        /// Folded BEFORE the absorb, each at t = 200 with stillWorking 5.
        let prior: [FinishAlertEvent]
        let kind: LidGuardMessageKind
        let at: Double
        /// The digest's messages afterwards (the absorb passes stillWorking 3).
        let expected: [LidGuardMessageKind]
        /// nil ⇒ the absorb must leave the digest exactly as it was.
        let originatedAt: Double?
        var testDescription: String { id }
    }

    static let absorbRows: [AbsorbRow] = [
        AbsorbRow(id: "A1 one finish keeps its minutes; stillWorking is the caller's, not the message's",
                  prior: [], kind: .sessionFinished(minutes: 20, folded: 1, stillWorking: 9), at: 100,
                  expected: [.sessionFinished(minutes: 20, folded: 1, stillWorking: 3)], originatedAt: 100),
        AbsorbRow(id: "A2 a folded finish re-enters as that many finishes",
                  prior: [], kind: .sessionFinished(minutes: nil, folded: 3, stillWorking: 9), at: 100,
                  expected: [.sessionFinished(minutes: nil, folded: 3, stillWorking: 3)], originatedAt: 100),
        AbsorbRow(id: "A3 minutes on a multi-finish message are dropped",
                  prior: [], kind: .sessionFinished(minutes: 17, folded: 3, stillWorking: 0), at: 100,
                  expected: [.sessionFinished(minutes: nil, folded: 3, stillWorking: 3)], originatedAt: 100),
        AbsorbRow(id: "A4 a degenerate folded 0 still counts as one finish (never lost)",
                  prior: [], kind: .sessionFinished(minutes: 20, folded: 0, stillWorking: 0), at: 100,
                  expected: [.sessionFinished(minutes: 20, folded: 1, stillWorking: 3)], originatedAt: 100),
        AbsorbRow(id: "A5 a waiting buzz re-enters as one waiting event with its minutes",
                  prior: [], kind: .needsAttention(minutes: 12, stillWorking: 4), at: 100,
                  expected: [.needsAttention(minutes: 12, stillWorking: 2)], originatedAt: 100),
        AbsorbRow(id: "A6 a waiting buzz without minutes",
                  prior: [], kind: .needsAttention(minutes: nil, stillWorking: 0), at: 100,
                  expected: [.needsAttention(minutes: nil, stillWorking: 2)], originatedAt: 100),
        AbsorbRow(id: "A7 joins a folded finish: two finishes, minutes dropped, EARLIEST origin",
                  prior: [.finished(minutes: 9)], kind: .sessionFinished(minutes: 20, folded: 1, stillWorking: 1),
                  at: 100, expected: [.sessionFinished(minutes: nil, folded: 2, stillWorking: 3)], originatedAt: 100),
        AbsorbRow(id: "A8 joins a folded wait: two waits, minutes dropped",
                  prior: [.waiting(minutes: 4)], kind: .needsAttention(minutes: 12, stillWorking: 1), at: 100,
                  expected: [.needsAttention(minutes: nil, stillWorking: 2)], originatedAt: 100),
        AbsorbRow(id: "A9 a finish beside a folded wait: waiting first, both keep their minutes",
                  prior: [.waiting(minutes: 4)], kind: .sessionFinished(minutes: 20, folded: 1, stillWorking: 1),
                  at: 100, expected: [.needsAttention(minutes: 4, stillWorking: 2),
                                      .sessionFinished(minutes: 20, folded: 1, stillWorking: 3)], originatedAt: 100),
        AbsorbRow(id: "A10 a later origin never moves the anchor forward",
                  prior: [.finished(minutes: 9)], kind: .sessionFinished(minutes: 20, folded: 1, stillWorking: 1),
                  at: 300, expected: [.sessionFinished(minutes: nil, folded: 2, stillWorking: 3)], originatedAt: 200),
        AbsorbRow(id: "A11 a lid alert is ignored (empty digest stays empty)",
                  prior: [], kind: .lidAlert(busySessionCount: 2), at: 100, expected: [], originatedAt: nil),
        AbsorbRow(id: "A12 the test message is ignored",
                  prior: [], kind: .test, at: 100, expected: [], originatedAt: nil),
        AbsorbRow(id: "A13 a lid alert leaves a non-empty digest untouched (stillWorking too)",
                  prior: [.finished(minutes: 9)], kind: .lidAlert(busySessionCount: 1), at: 100,
                  expected: [.sessionFinished(minutes: 9, folded: 1, stillWorking: 5)], originatedAt: nil),
        AbsorbRow(id: "A14 the healing restore push is never folded (recomposed at the next flush)",
                  prior: [.finished(minutes: 9)],
                  kind: .connectionRestored(minutes: 14, deliveredLate: 1, dropped: 0, lidMissed: 0), at: 100,
                  expected: [.sessionFinished(minutes: 9, folded: 1, stillWorking: 5)], originatedAt: nil),
    ]

    @Test(arguments: absorbRows)
    func absorbTable(_ row: AbsorbRow) {
        var digest = FinishAlertDigest()
        for event in row.prior { digest.fold(event, stillWorking: 5, at: 200) }
        let before = digest
        digest.absorb(row.kind, stillWorking: 3, at: row.at)
        #expect(digest.messages() == row.expected)
        if let originatedAt = row.originatedAt {
            #expect(digest.originatedAt == originatedAt)
            #expect(digest.stillWorking == 3)
        } else {
            #expect(digest == before, "an ignored kind must leave the digest exactly as it was")
        }
    }

    /// Round trip: absorbing a digest's OWN messages into an empty digest
    /// (with the same still-working count) rebuilds exactly those messages —
    /// nothing is lost or invented on the way back in.
    @Test func absorbingADigestsOwnMessagesRebuildsThem() {
        let shapes: [[FinishAlertEvent]] = [
            [.finished(minutes: 42)],
            [.finished(minutes: 12), .finished(minutes: nil), .finished(minutes: 40)],
            [.waiting(minutes: 4)],
            [.waiting(minutes: 4), .waiting(minutes: 30)],
            [.finished(minutes: 9), .waiting(minutes: 4)],
            [.finished(minutes: 9), .finished(minutes: 3), .waiting(minutes: nil), .waiting(minutes: 1)],
        ]
        for events in shapes {
            var original = FinishAlertDigest()
            for (index, event) in events.enumerated() { original.fold(event, stillWorking: 4, at: Double(index)) }
            var rebuilt = FinishAlertDigest()
            for kind in original.messages() { rebuilt.absorb(kind, stillWorking: original.stillWorking, at: 0) }
            #expect(rebuilt.messages() == original.messages(), "\(events)")
        }
    }

    // MARK: - Outbox decision

    @Test(arguments: [
        // (id, windowOpenUntil, sendInFlight, now, expected)
        ("O1", nil, false, 100.0, OutboxDecision.sendNow),
        ("O2", nil, true, 100.0, .holdForWindow),
        ("O3", 130.0, false, 100.0, .holdForWindow),
        ("O4", 130.0, false, 130.0, .sendNow),
        ("O5", 130.0, false, 131.0, .sendNow),
        ("O6", 130.0, true, 100.0, .holdForWindow),
        ("O7", 130.0, true, 131.0, .holdForWindow),
        ("O8", 130.0, true, 130.0, .holdForWindow),
    ] as [(String, Double?, Bool, Double, OutboxDecision)])
    func outboxTable(_ id: String, _ until: Double?, _ inFlight: Bool, _ now: Double, _ expected: OutboxDecision) {
        #expect(FinishAlertPolicy.outboxDecision(windowOpenUntil: until, sendInFlight: inFlight, now: now) == expected,
                "\(id)")
        // Not offline: exactly the pre-healing table.
        #expect(FinishAlertPolicy.outboxDecision(windowOpenUntil: until, sendInFlight: inFlight, offline: false,
                                                 now: now) == expected, "\(id)")
    }

    /// Alert healing: an OFFLINE lane holds open-ended in EVERY combination —
    /// past the window, nothing in flight — and nothing is scheduled for it.
    @Test(arguments: [
        ("O9", nil, false, 100.0),
        ("O10", nil, true, 100.0),
        ("O11", 130.0, false, 100.0),
        ("O12", 130.0, false, 131.0),
        ("O13", 130.0, true, 131.0),
    ] as [(String, Double?, Bool, Double)])
    func anOfflineLaneHoldsOpenEnded(_ id: String, _ until: Double?, _ inFlight: Bool, _ now: Double) {
        #expect(FinishAlertPolicy.outboxDecision(windowOpenUntil: until, sendInFlight: inFlight, offline: true,
                                                 now: now) == .holdOffline, "\(id)")
    }

    // MARK: - FA-7 retry table

    @Test(arguments: [
        // (id, outcome, attempt, expected)
        ("F1", MessageSendOutcome.accepted, SendAttempt.first, RetryDecision.done),
        ("F2", .accepted, .retry, .done),
        ("F3", .rejected(429), .first, .done),
        ("F4", .rejected(429), .retry, .done),
        ("F5", .rejected(500), .first, .done),
        ("F6", .rejected(403), .retry, .done),
        ("F7", .timedOutUnconfirmed, .first, .done),
        ("F8", .timedOutUnconfirmed, .retry, .done),
        ("F9", .sendFailed("offline"), .first, .retryAfter(30)),
        ("F10", .sendFailed("offline"), .retry, .done),
        ("F11", .sendFailed("busy"), .first, .retryAfter(30)),
        ("F12", .sendFailed("busy"), .retry, .done),
    ] as [(String, MessageSendOutcome, SendAttempt, RetryDecision)])
    func retryTable(_ id: String, _ outcome: MessageSendOutcome, _ attempt: SendAttempt, _ expected: RetryDecision) {
        #expect(FinishAlertPolicy.retryDecision(outcome: outcome, attempt: attempt) == expected, "\(id)")
        // Exhaustive: a new outcome case will not compile until the table above covers it.
        switch outcome { case .accepted, .rejected, .timedOutUnconfirmed, .sendFailed: break }
    }

    // MARK: - B-1 rate-limit hold (window extension)

    /// Only a 429 holds the session lane, for `rateLimitHoldSeconds`; every
    /// other outcome — including every other refusal — leaves the window be.
    @Test(arguments: [
        // (id, outcome, expected)
        ("H1", MessageSendOutcome.rejected(429), TimeInterval?(600)),
        ("H2", .accepted, nil),
        ("H3", .timedOutUnconfirmed, nil),
        ("H4", .sendFailed("offline"), nil),
        ("H5", .sendFailed("lane busy"), nil),
        ("H6", .rejected(400), nil),
        ("H7", .rejected(401), nil),
        ("H8", .rejected(403), nil),
        ("H9", .rejected(404), nil),
        ("H10", .rejected(500), nil),
        ("H11", .rejected(503), nil),
        ("H12", .rejected(428), nil),
        ("H13", .rejected(430), nil),
    ] as [(String, MessageSendOutcome, TimeInterval?)])
    func windowExtensionTable(_ id: String, _ outcome: MessageSendOutcome, _ expected: TimeInterval?) {
        #expect(FinishAlertPolicy.windowExtension(after: outcome) == expected, "\(id)")
        // Exhaustive: a new outcome case will not compile until the table above covers it.
        switch outcome { case .accepted, .rejected, .timedOutUnconfirmed, .sendFailed: break }
    }

    @Test func theRateLimitHoldIsTheTunableAndNeverARetry() {
        #expect(FinishAlertPolicy.windowExtension(after: .rejected(429)) == FinishAlertTuning.rateLimitHoldSeconds)
        #expect(FinishAlertPolicy.retryDecision(outcome: .rejected(429), attempt: .first) == .done,
                "the hold replaces nothing: a 429 is still never retried")
    }

    @Test func retryDelayIsTheTunable() {
        #expect(FinishAlertPolicy.retryDecision(outcome: .sendFailed("x"), attempt: .first)
                == .retryAfter(FinishAlertTuning.retryDelaySeconds))
    }

    /// FA-7 × security review M1, END TO END through the real classifier: a
    /// transport failure that can strike AFTER ntfy already has the message
    /// (or whose phase is unknown) is never retried — no duplicate push; a
    /// provably pre-connect failure is retried once.
    @Test(arguments: [
        // (id, transport code, expected first-attempt decision)
        ("FC1 badServerResponse", URLError.badServerResponse.rawValue, RetryDecision.done),
        ("FC2 zeroByteResource", URLError.zeroByteResource.rawValue, .done),
        ("FC3 cannotDecodeRawData", URLError.cannotDecodeRawData.rawValue, .done),
        ("FC4 cannotDecodeContentData", URLError.cannotDecodeContentData.rawValue, .done),
        ("FC5 cannotParseResponse", URLError.cannotParseResponse.rawValue, .done),
        ("FC6 dataLengthExceedsMaximum", URLError.dataLengthExceedsMaximum.rawValue, .done),
        ("FC7 requestBodyStreamExhausted", URLError.requestBodyStreamExhausted.rawValue, .done),
        ("FC8 unknown code", -9999, .done),
        ("FC9 no response and no error", nil, .done),
        ("FC10 timedOut", URLError.timedOut.rawValue, .done),
        ("FC11 notConnectedToInternet", URLError.notConnectedToInternet.rawValue, .retryAfter(30)),
        ("FC12 cannotFindHost", URLError.cannotFindHost.rawValue, .retryAfter(30)),
        ("FC13 serverCertificateHasUnknownRoot", URLError.serverCertificateHasUnknownRoot.rawValue, .retryAfter(30)),
    ] as [(String, Int?, RetryDecision)])
    func retryTableThroughTheClassifier(_ id: String, _ code: Int?, _ expected: RetryDecision) {
        let outcome = LidGuardPolicy.classifySend(statusCode: nil, transportErrorCode: code)
        #expect(FinishAlertPolicy.retryDecision(outcome: outcome, attempt: .first) == expected, "\(id)")
        #expect(FinishAlertPolicy.retryDecision(outcome: outcome, attempt: .retry) == .done, "\(id): one retry at most")
    }

    /// The whole pre-connect allow-list retries once — and nothing outside it
    /// does (sampled across the URLError range, which covers every code above).
    @Test func onlyThePreConnectAllowListIsRetried() {
        for code in LidGuardPolicy.preConnectTransportErrorCodes {
            let outcome = LidGuardPolicy.classifySend(statusCode: nil, transportErrorCode: code)
            #expect(FinishAlertPolicy.retryDecision(outcome: outcome, attempt: .first) == .retryAfter(30), "\(code)")
        }
        var retried = 0
        for code in -3_100 ... 0 {
            let outcome = LidGuardPolicy.classifySend(statusCode: nil, transportErrorCode: code)
            if FinishAlertPolicy.retryDecision(outcome: outcome, attempt: .first) != .done {
                retried += 1
                #expect(LidGuardPolicy.preConnectTransportErrorCodes.contains(code), "\(code) must not be retried")
            }
        }
        #expect(retried == LidGuardPolicy.preConnectTransportErrorCodes.count)
    }

    @Test(arguments: [
        // (id, armed, paused, dirExists, age, expected)
        ("G1", true, false, true, 0.0, true),
        ("G2", true, false, true, 299.0, true),
        ("G3", true, false, true, 300.0, true),
        ("G4", true, false, true, 301.0, false),
        ("G5", false, false, true, 0.0, false),
        ("G6", true, true, true, 0.0, false),
        ("G7", true, false, false, 0.0, false),
        ("G8", false, true, false, 0.0, false),
        ("G9", false, false, true, 299.0, false),
        ("G10", true, true, true, 299.0, false),
        ("G11", true, false, false, 299.0, false),
        ("G12", false, true, false, 301.0, false),
    ] as [(String, Bool, Bool, Bool, Double, Bool)])
    func retryMayFireTable(_ id: String, _ armed: Bool, _ paused: Bool, _ dirExists: Bool,
                           _ age: Double, _ expected: Bool) {
        let originatedAt = 1_800_000_000.0
        #expect(FinishAlertPolicy.retryMayFire(armed: armed, paused: paused, markerDirExists: dirExists,
                                               originatedAt: originatedAt, now: originatedAt + age) == expected,
                "\(id)")
    }

    // MARK: - Arming + display (F3: never "armed" without a watchable dir)

    @Test(arguments: [
        // (id, armingState, paused, dirExists, expected)
        ("A1", LidGuardArmingState.off, false, true, FinishAlertDisplayState.off),
        ("A2", .off, false, false, .off),
        ("A3", .off, true, true, .off),
        ("A4", .off, true, false, .off),
        ("A5", .needsTopic, false, true, .needsTopic),
        ("A6", .needsTopic, false, false, .needsTopic),
        ("A7", .needsTopic, true, true, .needsTopic),
        ("A8", .needsTopic, true, false, .needsTopic),
        ("A9", .needsTestSend, false, true, .needsTestSend),
        ("A10", .needsTestSend, false, false, .needsTestSend),
        ("A11", .needsTestSend, true, true, .needsTestSend),
        ("A12", .needsTestSend, true, false, .needsTestSend),
        ("A13", .armed, false, true, .armed),
        ("A14", .armed, false, false, .hookNotInstalled),
        ("A15", .armed, true, true, .paused),
        ("A16", .armed, true, false, .paused),
    ] as [(String, LidGuardArmingState, Bool, Bool, FinishAlertDisplayState)])
    func displayTable(_ id: String, _ state: LidGuardArmingState, _ paused: Bool, _ dirExists: Bool,
                      _ expected: FinishAlertDisplayState) {
        #expect(FinishAlertPolicy.displayState(armingState: state, detectionPaused: paused,
                                               markerDirExists: dirExists) == expected, "\(id)")
        // The watcher arms in EXACTLY the one row whose caption says "armed".
        #expect(FinishAlertPolicy.finishAlertMayArm(armingState: state, detectionPaused: paused,
                                                    markerDirExists: dirExists) == (id == "A13"), "\(id)")
    }

    // MARK: - Alert-channel healing (issue #23): tunables

    @Test func healingTunablesAreTheContractValues() {
        #expect(AlertHealingTuning.pathDebounceSeconds == 2)
        #expect(AlertHealingTuning.minimumOutageSeconds == 60)
        #expect(AlertHealingTuning.heldDigestMaxAgeSeconds == 43_200, "12 h")
        #expect(AlertHealingTuning.heldDigestMaxAgeSeconds != FinishAlertTuning.retryMaxAgeSeconds,
                "the single retry's 5 min max age must never cap an outage hold")
    }

    // MARK: - Healing: the state table (row ids LOCKED)

    struct HealingStep: Sendable {
        let input: AlertHealingInput
        let at: Double
        let lidMisses: Int
        let effects: [AlertHealingEffect]
    }

    struct HealingRow: Sendable, CustomTestStringConvertible {
        let id: String
        let steps: [HealingStep]
        let phase: AlertHealingPhase
        /// The open outage's ORIGINAL anchor (nil = no outage).
        let anchor: Double?
        /// When the current flush attempt began (nil = none).
        var flushStartedAt: Double? = nil
        var testDescription: String { id }
    }

    static func step(_ input: AlertHealingInput, _ at: Double, _ effects: [AlertHealingEffect] = [],
                     lid: Int = 0) -> HealingStep {
        HealingStep(input: input, at: at, lidMisses: lid, effects: effects)
    }

    /// Every armed row starts here: DISARMED → ONLINE at t = 1000.
    static let armAt1000 = step(.arm, 1000, [.startMonitor])
    /// ONLINE → OFFLINE through a sustained path loss at 1000 (anchor 1000).
    static let offlineByPath = [armAt1000, step(.path(.unsatisfied), 1000, [.scheduleDebounce]),
                                step(.pathDebounceFired, 1002, [.holdSessionLane])]
    /// ONLINE → OFFLINE on a satisfied path, by a send failure at 1010.
    static let offlineByCaptivePortal = [armAt1000, step(.path(.satisfied), 1000),
                                         step(.sessionSendFailed, 1010, [.holdSessionLane])]

    static let healingRows: [HealingRow] = [
        HealingRow(id: "H1 arm: DISARMED → ONLINE, the path monitor starts",
                   steps: [armAt1000], phase: .online, anchor: nil),
        HealingRow(id: "H2 captive portal: a satisfied path + a pre-connect send failure ⇒ OFFLINE",
                   steps: offlineByCaptivePortal, phase: .offline, anchor: 1010),
        HealingRow(id: "H3 a flap shorter than the debounce ⇒ no transition",
                   steps: [armAt1000, step(.path(.unsatisfied), 1000, [.scheduleDebounce]),
                           step(.path(.satisfied), 1001, [.cancelDebounce]), step(.pathDebounceFired, 1002)],
                   phase: .online, anchor: nil),
        HealingRow(id: "H4 a sustained unsatisfied path ⇒ OFFLINE, anchored when the path went down",
                   steps: offlineByPath, phase: .offline, anchor: 1000),
        HealingRow(id: "H5 repeated unsatisfied updates arm ONE debounce",
                   steps: [armAt1000, step(.path(.unsatisfied), 1000, [.scheduleDebounce]),
                           step(.path(.unsatisfied), 1001), step(.pathDebounceFired, 1002, [.holdSessionLane])],
                   phase: .offline, anchor: 1000),
        HealingRow(id: "H6 a send failure inside the debounce: OFFLINE at once, anchored at the path loss",
                   steps: [armAt1000, step(.path(.unsatisfied), 1000, [.scheduleDebounce]),
                           step(.sessionSendFailed, 1001, [.cancelDebounce, .holdSessionLane])],
                   phase: .offline, anchor: 1000),
        HealingRow(id: "H7 a debounce that fires early re-arms itself instead of holding",
                   steps: [armAt1000, step(.path(.unsatisfied), 1000, [.scheduleDebounce]),
                           step(.pathDebounceFired, 1001.5, [.scheduleDebounce])],
                   phase: .online, anchor: nil),
        HealingRow(id: "H8 path unsatisfied → satisfied while OFFLINE ⇒ FLUSHING (one flush)",
                   steps: offlineByPath + [step(.path(.satisfied), 1100, [.flush])],
                   phase: .flushing, anchor: 1000, flushStartedAt: 1100),
        HealingRow(id: "H9 captive portal: a REPEATED satisfied path is no restore",
                   steps: offlineByCaptivePortal + [step(.path(.satisfied), 1020)],
                   phase: .offline, anchor: 1010),
        HealingRow(id: "H10 a session event while OFFLINE ⇒ FLUSHING",
                   steps: offlineByCaptivePortal + [step(.flushTrigger(.sessionEvent), 1100, [.flush])],
                   phase: .flushing, anchor: 1010, flushStartedAt: 1100),
        HealingRow(id: "H11 the menu opening while OFFLINE ⇒ FLUSHING",
                   steps: offlineByCaptivePortal + [step(.flushTrigger(.menuOpen), 1100, [.flush])],
                   phase: .flushing, anchor: 1010, flushStartedAt: 1100),
        HealingRow(id: "H12 simultaneous triggers coalesce into ONE attempt",
                   steps: offlineByPath + [step(.path(.satisfied), 1100, [.flush]),
                                           step(.flushTrigger(.menuOpen), 1100),
                                           step(.flushTrigger(.sessionEvent), 1100),
                                           step(.path(.satisfied), 1100)],
                   phase: .flushing, anchor: 1000, flushStartedAt: 1100),
        HealingRow(id: "H13 a pre-connect failure during the flush ⇒ OFFLINE keeping the ORIGINAL anchor",
                   steps: offlineByPath + [step(.path(.satisfied), 1100, [.flush]),
                                           step(.sessionSendFailed, 1101, [.holdSessionLane])],
                   phase: .offline, anchor: 1000),
        HealingRow(id: "H14 a completed flush ⇒ ONLINE, the outage closed",
                   steps: offlineByPath + [step(.path(.satisfied), 1100, [.flush]), step(.flushCompleted, 1105)],
                   phase: .online, anchor: nil),
        HealingRow(id: "H15 healed while the path reads down ⇒ a fresh debounce from the heal",
                   steps: offlineByCaptivePortal + [step(.flushTrigger(.menuOpen), 1100, [.flush]),
                                                    step(.path(.unsatisfied), 1101),
                                                    step(.flushCompleted, 1102, [.scheduleDebounce]),
                                                    step(.pathDebounceFired, 1104, [.holdSessionLane])],
                   phase: .offline, anchor: 1102),
        HealingRow(id: "H16 a send failure while already OFFLINE changes nothing",
                   steps: offlineByPath + [step(.sessionSendFailed, 1050)], phase: .offline, anchor: 1000),
        HealingRow(id: "H17 triggers and completions while ONLINE do nothing",
                   steps: [armAt1000, step(.flushTrigger(.menuOpen), 1001), step(.flushTrigger(.sessionEvent), 1001),
                           step(.flushCompleted, 1002)],
                   phase: .online, anchor: nil),
        HealingRow(id: "H18 FLUSHING ignores the path debounce and further triggers",
                   steps: offlineByPath + [step(.path(.satisfied), 1100, [.flush]), step(.path(.unsatisfied), 1101),
                                           step(.pathDebounceFired, 1104), step(.flushTrigger(.menuOpen), 1104)],
                   phase: .flushing, anchor: 1000, flushStartedAt: 1100),
        HealingRow(id: "H19 disarm from OFFLINE drops everything and stops the monitor",
                   steps: offlineByPath + [step(.disarm, 1200, [.cancelDebounce, .stopMonitor])],
                   phase: .disarmed, anchor: nil),
        HealingRow(id: "H20 DISARMED ignores every input but arm",
                   steps: [step(.path(.unsatisfied), 1000), step(.pathDebounceFired, 1002),
                           step(.sessionSendFailed, 1003), step(.flushTrigger(.menuOpen), 1004),
                           step(.flushCompleted, 1005), step(.disarm, 1006)],
                   phase: .disarmed, anchor: nil),
        HealingRow(id: "H21 arming an armed machine is a no-op",
                   steps: offlineByPath + [step(.arm, 1100)], phase: .offline, anchor: 1000),
        HealingRow(id: "H22 re-arming after a disarm starts afresh",
                   steps: offlineByPath + [step(.disarm, 1200, [.cancelDebounce, .stopMonitor]),
                                           step(.arm, 1300, [.startMonitor])],
                   phase: .online, anchor: nil),
    ]

    @Test(arguments: healingRows)
    func healingStateTable(_ row: HealingRow) {
        var state = AlertHealingState()
        for (index, step) in row.steps.enumerated() {
            let effects = state.apply(step.input, now: step.at, lidMisses: step.lidMisses)
            #expect(effects == step.effects, "\(row.id) — step \(index) (\(step.input))")
        }
        #expect(state.phase == row.phase, "\(row.id)")
        #expect(state.outage?.startedAt == row.anchor, "\(row.id)")
        #expect(state.outage?.flushStartedAt == row.flushStartedAt, "\(row.id)")
        #expect(state.isArmed == (row.phase != .disarmed))
    }

    /// The lid-miss baseline is taken when the outage BEGINS and survives a
    /// failed flush; a fresh outage takes a fresh one.
    @Test func theLidMissBaselineIsTakenWhenTheOutageBegins() {
        var state = AlertHealingState()
        _ = state.apply(.arm, now: 1000, lidMisses: 4)
        _ = state.apply(.sessionSendFailed, now: 1010, lidMisses: 5)
        #expect(state.outage?.lidMissBaseline == 5)
        _ = state.apply(.flushTrigger(.menuOpen), now: 1100, lidMisses: 7)
        _ = state.apply(.sessionSendFailed, now: 1101, lidMisses: 8)
        #expect(state.outage?.lidMissBaseline == 5, "a failed flush keeps the outage — baseline included")
        _ = state.apply(.flushTrigger(.menuOpen), now: 1200, lidMisses: 8)
        _ = state.apply(.flushCompleted, now: 1201, lidMisses: 8)
        _ = state.apply(.sessionSendFailed, now: 1300, lidMisses: 9)
        #expect(state.outage?.lidMissBaseline == 9)
        #expect(state.outage?.startedAt == 1300)
    }

    // MARK: - Healing: the restore push

    struct RestoreRow: Sendable, CustomTestStringConvertible {
        let id: String
        let startedAt: Double
        let flushStartedAt: Double?
        let deliveredLate: Int
        let dropped: Int
        let lidBaseline: Int
        let lidNow: Int
        let expected: LidGuardMessageKind?
        var testDescription: String { id }
    }

    static let restoreRows: [RestoreRow] = [
        RestoreRow(id: "R1 59 s outage ⇒ suppressed (under the floor)", startedAt: 1000, flushStartedAt: 1059,
                   deliveredLate: 2, dropped: 0, lidBaseline: 0, lidNow: 1, expected: nil),
        RestoreRow(id: "R2 exactly 60 s ⇒ sent, 1 min", startedAt: 1000, flushStartedAt: 1060,
                   deliveredLate: 1, dropped: 0, lidBaseline: 0, lidNow: 0,
                   expected: .connectionRestored(minutes: 1, deliveredLate: 1, dropped: 0, lidMissed: 0)),
        RestoreRow(id: "R3 61 s ⇒ 2 min (rounded UP)", startedAt: 1000, flushStartedAt: 1061,
                   deliveredLate: 1, dropped: 0, lidBaseline: 0, lidNow: 0,
                   expected: .connectionRestored(minutes: 2, deliveredLate: 1, dropped: 0, lidMissed: 0)),
        RestoreRow(id: "R4 120 s ⇒ 2 min", startedAt: 1000, flushStartedAt: 1120,
                   deliveredLate: 3, dropped: 0, lidBaseline: 0, lidNow: 0,
                   expected: .connectionRestored(minutes: 2, deliveredLate: 3, dropped: 0, lidMissed: 0)),
        RestoreRow(id: "R5 121 s ⇒ 3 min", startedAt: 1000, flushStartedAt: 1121,
                   deliveredLate: 3, dropped: 0, lidBaseline: 0, lidNow: 0,
                   expected: .connectionRestored(minutes: 3, deliveredLate: 3, dropped: 0, lidMissed: 0)),
        RestoreRow(id: "R6 a long outage with NOTHING to report ⇒ suppressed", startedAt: 1000, flushStartedAt: 9000,
                   deliveredLate: 0, dropped: 0, lidBaseline: 2, lidNow: 2, expected: nil),
        RestoreRow(id: "R7 lid misses alone ⇒ sent, counted as the delta since the outage began",
                   startedAt: 1000, flushStartedAt: 1600, deliveredLate: 0, dropped: 0, lidBaseline: 3, lidNow: 5,
                   expected: .connectionRestored(minutes: 10, deliveredLate: 0, dropped: 0, lidMissed: 2)),
        RestoreRow(id: "R8 a lid counter below its baseline (cannot happen) counts as none",
                   startedAt: 1000, flushStartedAt: 1600, deliveredLate: 0, dropped: 0, lidBaseline: 5, lidNow: 3,
                   expected: nil),
        RestoreRow(id: "R9 no flush begun ⇒ nothing to report yet", startedAt: 1000, flushStartedAt: nil,
                   deliveredLate: 4, dropped: 1, lidBaseline: 0, lidNow: 1, expected: nil),
        RestoreRow(id: "R10 a clock jump backwards ⇒ suppressed", startedAt: 5000, flushStartedAt: 1000,
                   deliveredLate: 1, dropped: 0, lidBaseline: 0, lidNow: 0, expected: nil),
        RestoreRow(id: "R11 a 12 h+ outage that dropped its digest ⇒ 'dropped', nothing delivered late",
                   startedAt: 1000, flushStartedAt: 1000 + 43_260, deliveredLate: 0, dropped: 3, lidBaseline: 0,
                   lidNow: 0, expected: .connectionRestored(minutes: 721, deliveredLate: 0, dropped: 3, lidMissed: 0)),
        RestoreRow(id: "R12 every segment at once", startedAt: 1000, flushStartedAt: 1840,
                   deliveredLate: 2, dropped: 1, lidBaseline: 1, lidNow: 2,
                   expected: .connectionRestored(minutes: 14, deliveredLate: 2, dropped: 1, lidMissed: 1)),
    ]

    @Test(arguments: restoreRows)
    func restorePushTable(_ row: RestoreRow) {
        var outage = AlertOutage(startedAt: row.startedAt, lidMissBaseline: row.lidBaseline)
        outage.deliveredLate = row.deliveredLate
        outage.dropped = row.dropped
        outage.flushStartedAt = row.flushStartedAt
        #expect(FinishAlertPolicy.restoreMessage(for: outage, lidMisses: row.lidNow) == row.expected, "\(row.id)")
    }

    @Test(arguments: [
        // (seconds, minutes) — rounded UP, never 0
        (0.0, 1), (1.0, 1), (59.0, 1), (60.0, 1), (60.5, 2), (61.0, 2), (3_600.0, 60), (3_601.0, 61),
        (43_200.0, 720), (-30.0, 1),
    ] as [(TimeInterval, Int)])
    func outageMinutesRoundUpAndNeverReadZero(_ seconds: TimeInterval, _ minutes: Int) {
        #expect(FinishAlertPolicy.outageMinutes(seconds) == minutes, "\(seconds) s")
    }

    /// A failed flush keeps the ORIGINAL anchor, so the push that finally
    /// goes out measures the WHOLE outage — not the time since the retry.
    @Test func theRestorePushMeasuresTheOutageFromTheOriginalAnchor() throws {
        var state = AlertHealingState()
        _ = state.apply(.arm, now: 1000, lidMisses: 0)
        _ = state.apply(.path(.unsatisfied), now: 1000, lidMisses: 0)
        _ = state.apply(.pathDebounceFired, now: 1002, lidMisses: 0)
        _ = state.apply(.path(.satisfied), now: 1100, lidMisses: 0)        // flush attempt 1
        _ = state.apply(.sessionSendFailed, now: 1101, lidMisses: 0)       // …fails pre-connect
        _ = state.apply(.path(.unsatisfied), now: 1102, lidMisses: 0)
        _ = state.apply(.path(.satisfied), now: 1400, lidMisses: 0)        // flush attempt 2
        state.recordDeliveredLate(2)
        let outage = try #require(state.outage)
        #expect(outage.startedAt == 1000)
        #expect(FinishAlertPolicy.restoreMessage(for: outage, lidMisses: 0)
                == .connectionRestored(minutes: 7, deliveredLate: 2, dropped: 0, lidMissed: 0),
                "400 s from the ORIGINAL anchor ⇒ 7 min")
    }

    @Test func deliveredLateIsCountedOnlyInsideAnOutage() {
        var state = AlertHealingState()
        _ = state.apply(.arm, now: 1000, lidMisses: 0)
        state.recordDeliveredLate(3)
        #expect(state.outage == nil, "ONLINE: nothing to count")
        _ = state.apply(.sessionSendFailed, now: 1010, lidMisses: 0)
        state.recordDeliveredLate(0)
        state.recordDeliveredLate(-2)
        state.recordDeliveredLate(2)
        state.recordDeliveredLate(1)
        #expect(state.outage?.deliveredLate == 3)
    }

    // MARK: - Healing: the held digest's 12 h max age

    @Test(arguments: [
        // (age, expired) — exactly the max age is still delivered
        (0.0, false), (43_199.0, false), (43_200.0, false), (43_200.5, true), (43_201.0, true), (90_000.0, true),
    ] as [(Double, Bool)])
    func theHeldDigestMaxAgeBoundary(_ age: Double, _ expired: Bool) {
        let originatedAt = 1_800_000_000.0
        #expect(FinishAlertPolicy.heldDigestExpired(originatedAt: originatedAt, now: originatedAt + age) == expired,
                "\(age) s")
    }

    /// At the max age the held digest collapses to COUNTS: its events are
    /// dropped (counted), the digest empties, and the restore push then says
    /// "dropped" — never "delivered late" for the same alerts. One second
    /// earlier nothing expires and they are still delivered.
    @Test func atTheMaxAgeTheDigestCollapsesAndDroppedWinsOverDeliveredLate() throws {
        let t = 1_800_000_000.0
        var digest = FinishAlertDigest()
        digest.fold(.finished(minutes: 30), stillWorking: 0, at: t)
        digest.fold(.finished(minutes: 12), stillWorking: 0, at: t + 60)
        digest.fold(.waiting(minutes: 4), stillWorking: 0, at: t + 120)
        var state = AlertHealingState()
        _ = state.apply(.arm, now: t - 10, lidMisses: 0)
        _ = state.apply(.sessionSendFailed, now: t, lidMisses: 0)

        // Exactly the max age: nothing expires.
        #expect(state.expireHeldDigest(&digest, now: t + AlertHealingTuning.heldDigestMaxAgeSeconds) == 0)
        #expect(digest.eventCount == 3)
        #expect(state.outage?.dropped == 0)

        // One second past it: all three are dropped, the digest is empty.
        #expect(state.expireHeldDigest(&digest, now: t + AlertHealingTuning.heldDigestMaxAgeSeconds + 1) == 3)
        #expect(digest.isEmpty && digest.messages().isEmpty, "nothing left to deliver late")
        #expect(state.outage?.dropped == 3)
        #expect(state.expireHeldDigest(&digest, now: t + 90_000) == 0, "an empty digest has nothing to drop")

        _ = state.apply(.flushTrigger(.menuOpen), now: t + 43_260, lidMisses: 0)
        let outage = try #require(state.outage)
        let push = try #require(FinishAlertPolicy.restoreMessage(for: outage, lidMisses: 0))
        #expect(push == .connectionRestored(minutes: 721, deliveredLate: 0, dropped: 3, lidMissed: 0))
        let body = LidGuardPolicy.messageBody(kind: push, clockTime: "22:49")
        #expect(body == "Connection was down 721 min. 3 session alerts dropped.")
        #expect(!body.contains("delivered late"), "dropped wins over delivered-late")
    }

    @Test func onlyAnOpenOutageExpiresAHeldDigest() {
        let t = 1_800_000_000.0
        var digest = FinishAlertDigest()
        digest.fold(.finished(minutes: 30), stillWorking: 0, at: t)
        var state = AlertHealingState()
        #expect(state.expireHeldDigest(&digest, now: t + 90_000) == 0, "disarmed")
        _ = state.apply(.arm, now: t, lidMisses: 0)
        #expect(state.expireHeldDigest(&digest, now: t + 90_000) == 0, "online: the batch window is not a hold")
        #expect(digest.eventCount == 1)
    }

    @Test func outageContentIsDeliveredLateDroppedOrLidMisses() {
        var state = AlertHealingState()
        #expect(!state.outageHasContent(lidMisses: 9), "no outage, no content")
        _ = state.apply(.arm, now: 1000, lidMisses: 2)
        _ = state.apply(.sessionSendFailed, now: 1010, lidMisses: 2)
        #expect(!state.outageHasContent(lidMisses: 2))
        #expect(state.outageHasContent(lidMisses: 3), "a lid miss since the outage began")
        state.recordDeliveredLate(1)
        #expect(state.outageHasContent(lidMisses: 2))
    }

    // MARK: - Healing: the digest's per-message event counts

    @Test func eachFlushedMessageCarriesItsEventCount() {
        var digest = FinishAlertDigest()
        #expect(digest.eventCount == 0 && digest.messagesWithEventCounts().isEmpty)
        for event in [FinishAlertEvent.finished(minutes: 1), .waiting(minutes: 2), .finished(minutes: nil),
                      .waiting(minutes: nil), .finished(minutes: 9)] {
            digest.fold(event, stillWorking: 2, at: 0)
        }
        #expect(digest.eventCount == 5)
        let pairs = digest.messagesWithEventCounts()
        #expect(pairs.map(\.kind) == digest.messages())
        #expect(pairs.map(\.events) == [2, 3], "waiting first, then the finish")
    }

    // MARK: - Healing: arming (code constants only — no toggle, no key)

    @Test(arguments: [
        // (id, destination, session armed, lid armed, stay awake, tracked, holding, expected)
        ("HA1 nothing configured", false, false, false, true, 3, true, false),
        ("HA2 no destination, even with everything else", false, true, true, true, 3, true, false),
        ("HA3 destination but no feature sends to it", true, false, false, true, 3, true, false),
        ("HA4 session alerts + Stay Awake", true, true, false, true, 0, false, true),
        ("HA5 lid alert + Stay Awake", true, false, true, true, 0, false, true),
        ("HA6 session alerts tracking one session", true, true, false, false, 1, false, true),
        ("HA7 session alerts tracking none, Stay Awake off ⇒ zero footprint", true, true, false, false, 0, false,
         false),
        ("HA8 lid-only, Stay Awake off, no sessions ⇒ zero footprint", true, false, true, false, 0, false, false),
        ("HA9 lid-only never counts tracked sessions (no watcher)", true, false, true, false, 2, false, false),
        ("HA10 the lane still holds an alert ⇒ stays armed", true, true, false, false, 0, true, true),
        ("HA11 an outage holding lid misses keeps lid-only armed", true, false, true, false, 0, true, true),
        ("HA12 everything", true, true, true, true, 4, true, true),
    ] as [(String, Bool, Bool, Bool, Bool, Int, Bool, Bool)])
    func healingArmingTable(_ id: String, _ destination: Bool, _ session: Bool, _ lid: Bool, _ stayAwake: Bool,
                            _ tracked: Int, _ holding: Bool, _ expected: Bool) {
        #expect(FinishAlertPolicy.healingMayArm(destinationValid: destination, sessionAlertsArmed: session,
                                                lidAlertArmed: lid, stayAwakeOn: stayAwake,
                                                trackedSessions: tracked, sessionLaneHolding: holding) == expected,
                "\(id)")
    }
}
