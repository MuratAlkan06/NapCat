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

    static func session(firstSeen: Int, exact: Bool, lastTs: Int, lastEvent: String = ups,
                        buzzed: Bool = false) -> TrackedSession {
        TrackedSession(firstSeen: firstSeen, exactStart: exact, lastTs: lastTs, lastEvent: lastEvent,
                       waitingBuzzed: buzzed)
    }

    // MARK: - Tunables (user rulings are code constants)

    @Test func tunablesAreTheContractValues() {
        #expect(FinishAlertTuning.minimumRunSeconds == 30)
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
            DisappearRow(id: "D2", gone: session(firstSeen: t0 - 29, exact: true, lastTs: t0 - 29),
                         events: [], suppressed: [.underMinimumRun]),
            DisappearRow(id: "D3", gone: session(firstSeen: t0 - 30, exact: true, lastTs: t0 - 30),
                         events: [.finished(minutes: nil)], suppressed: []),
            DisappearRow(id: "D4", gone: session(firstSeen: t0 - 31, exact: true, lastTs: t0 - 31),
                         events: [.finished(minutes: nil)], suppressed: []),
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
            // MARK: FA-5 — a newer UserPromptSubmit is a new turn, never a finish
            Scenario(id: "R1", note: "debounce-window recreate: newer UPS ts ⇒ no finish, anchor reset",
                     baseline: nil, steps: [
                        Step(m1(t, ups), now: t + 2),
                        Step(m1(t + 600, ups), now: t + 602),          // cleared + recreated in one window
                        Step([], now: t + 610, suppressed: [.underMinimumRun]),   // 10 s from the NEW anchor
                     ]),
            Scenario(id: "R2", note: "same id, same ts ⇒ nothing",
                     baseline: nil, steps: [
                        Step(m1(t, ups), now: t + 2),
                        Step(m1(t, ups), now: t + 300),
                        Step(m1(t, ups), now: t + 900),
                     ]),
            Scenario(id: "R3", note: "bg-running keep (Stop) then a newer UPS ⇒ new exact turn",
                     baseline: nil, steps: [
                        Step(m1(t, "Stop"), now: t + 2),                 // first seen as a keep: inexact
                        Step(m1(t + 100, ups), now: t + 102),
                        Step([], now: t + 100 + 180, [.finished(minutes: 3)]),
                     ]),
            Scenario(id: "R4", note: "UPS with ts == lastTs is not a newer turn",
                     baseline: nil, steps: [
                        Step(m1(t, ups), now: t + 2),
                        Step(m1(t + 50, "Stop"), now: t + 52),
                        Step(m1(t + 50, ups), now: t + 54),
                        Step([], now: t + 120, [.finished(minutes: 2)]),   // anchored at t, not t+50
                     ]),
            Scenario(id: "R5", note: "new turn after a long turn: finish minutes measure the LAST turn only",
                     baseline: nil, steps: [
                        Step(m1(t, ups), now: t + 2),
                        Step(m1(t + 3_000, ups), now: t + 3_002),
                        Step([], now: t + 3_000 + 120, [.finished(minutes: 2)]),
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
            Scenario(id: "W5", note: "a newer UPS clears the dedupe (and resets the anchor)",
                     baseline: nil, steps: [
                        Step(m1(t, ups), now: t + 2),
                        Step(m1(t + 300, w), now: t + 302, [.waiting(minutes: 5)]),
                        Step(m1(t + 400, ups), now: t + 402),
                        Step(m1(t + 520, w), now: t + 520, [.waiting(minutes: 2)]),
                     ]),
            Scenario(id: "W6", note: "floor: waiting 10 s in ⇒ suppressed; later rewrites never buzz the episode",
                     baseline: nil, steps: [
                        Step(m1(t, ups), now: t + 2),
                        Step(m1(t + 10, w), now: t + 10, suppressed: [.underMinimumRun]),
                        Step(m1(t + 100, w), now: t + 100),
                        Step(m1(t + 200, w), now: t + 200),
                     ]),
            Scenario(id: "W7", note: "floor boundary: 29 s ⇒ suppressed",
                     baseline: nil, steps: [
                        Step(m1(t, ups), now: t + 2),
                        Step(m1(t + 29, w), now: t + 29, suppressed: [.underMinimumRun]),
                     ]),
            Scenario(id: "W8", note: "floor boundary: 30 s ⇒ sent (exact but under a minute ⇒ minutes nil)",
                     baseline: nil, steps: [
                        Step(m1(t, ups), now: t + 2),
                        Step(m1(t + 30, w), now: t + 30, [.waiting(minutes: nil)]),
                     ]),
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

    /// FA-5: the anchor really moves (not just "no event") and becomes exact.
    @Test func newerUserPromptSubmitResetsTheAnchor() {
        let previous = [Self.s1: Self.session(firstSeen: Self.t0 - 600, exact: false, lastTs: Self.t0 - 300,
                                              lastEvent: Self.waiting, buzzed: true)]
        let observation = FinishAlertPolicy.observe(previous: previous,
                                                    current: Self.m1(Self.t0 - 1, Self.ups), now: Self.t0)
        #expect(observation.events.isEmpty && observation.suppressed.isEmpty)
        #expect(observation.tracked[Self.s1] == Self.session(firstSeen: Self.t0 - 1, exact: true,
                                                             lastTs: Self.t0 - 1, lastEvent: Self.ups, buzzed: false))
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
}
