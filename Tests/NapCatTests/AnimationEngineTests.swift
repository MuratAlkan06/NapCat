import AppKit
import Testing
@testable import NapCat

// NOTE: import AppKit (re-exports Foundation), never Foundation directly —
// the CLT toolchain lacks the _Testing_Foundation overlay (PLAN.md 2026-07-09).

/// Table-driven tests for the pure state → (frame set, fps) mapping
/// (PLAN.md ADR §10 + locked icon mapping 2026-07-09). All 8 combinations
/// of the three inputs are covered.
struct AnimationMappingTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let stayAwakeOn: Bool
        let chargePaused: Bool
        let screenAwake: Bool
        let expectedSet: FrameSet?
        let expectedFPS: Double?
        let rationale: String

        var testDescription: String {
            "stayAwake=\(stayAwakeOn), paused=\(chargePaused), screenAwake=\(screenAwake) → "
                + (expectedSet.map { "\($0)@\(expectedFPS ?? 0)fps" } ?? "nil (stopped)")
        }
    }

    static let table: [Row] = [
        Row(stayAwakeOn: true, chargePaused: true, screenAwake: true,
            expectedSet: .run, expectedFPS: 10,
            rationale: "PRIORITY: stay-awake beats charge-paused — run implies an awake purpose is active"),
        Row(stayAwakeOn: true, chargePaused: false, screenAwake: true,
            expectedSet: .run, expectedFPS: 10,
            rationale: "stay-awake ON → run @10fps"),
        Row(stayAwakeOn: false, chargePaused: true, screenAwake: true,
            expectedSet: .sit, expectedFPS: 1,
            rationale: "charge paused at limit → sit @1fps"),
        Row(stayAwakeOn: false, chargePaused: false, screenAwake: true,
            expectedSet: .sleep, expectedFPS: 0.5,
            rationale: "idle → sleeping kitten @0.5fps"),
        Row(stayAwakeOn: true, chargePaused: true, screenAwake: false,
            expectedSet: nil, expectedFPS: nil,
            rationale: "screens asleep → timer stopped regardless of app state"),
        Row(stayAwakeOn: true, chargePaused: false, screenAwake: false,
            expectedSet: nil, expectedFPS: nil,
            rationale: "screens asleep → stopped"),
        Row(stayAwakeOn: false, chargePaused: true, screenAwake: false,
            expectedSet: nil, expectedFPS: nil,
            rationale: "screens asleep → stopped"),
        Row(stayAwakeOn: false, chargePaused: false, screenAwake: false,
            expectedSet: nil, expectedFPS: nil,
            rationale: "screens asleep → stopped"),
    ]

    @Test(arguments: table)
    func mappingRow(_ row: Row) {
        let result = AnimationEngine.frameSet(
            stayAwakeOn: row.stayAwakeOn,
            chargePaused: row.chargePaused,
            screenAwake: row.screenAwake
        )
        #expect(result?.set == row.expectedSet, "\(row.rationale)")
        #expect(result?.fps == row.expectedFPS, "\(row.rationale)")
        if row.expectedSet == nil {
            #expect(result == nil, "\(row.rationale)")
        }
    }

    /// All 8 combinations of the 3 bools must appear exactly once.
    @Test func tableCoversAllEightCombinations() {
        let combos = Set(Self.table.map { "\($0.stayAwakeOn)-\($0.chargePaused)-\($0.screenAwake)" })
        #expect(combos.count == 8)
        #expect(Self.table.count == 8)
    }

    @Test func frameSetNamesMatchAssetNaming() {
        #expect(FrameSet.run.frameNames == ["run0", "run1", "run2", "run3", "run4"])
        #expect(FrameSet.sleep.frameNames == ["sleep0", "sleep1", "sleep2"])
        #expect(FrameSet.sit.frameNames == ["sit0", "sit1"])
    }

    // MARK: - Pure restart decision

    @Test func restartOnlyWhenSelectionChanges() {
        typealias Selection = (set: FrameSet, fps: Double)
        let run10: Selection = (.run, 10)
        // No change → keep the current phase.
        #expect(!AnimationEngine.shouldRestart(from: run10, to: (.run, 10)))
        #expect(!AnimationEngine.shouldRestart(from: nil, to: nil))
        // Any change of set, fps, or stopped-ness → restart at frame 0.
        #expect(AnimationEngine.shouldRestart(from: run10, to: (.sit, 1)))
        #expect(AnimationEngine.shouldRestart(from: run10, to: (.run, 5)))
        #expect(AnimationEngine.shouldRestart(from: run10, to: nil))
        #expect(AnimationEngine.shouldRestart(from: nil, to: run10))
    }
}

/// Timer-driver behavior. Engines are built with schedulesTimers: false so
/// no real Timer lands on the main runloop — tests drive tick() manually and
/// stay deterministic.
@MainActor
struct AnimationEngineBehaviorTests {
    private final class FrameRecorder {
        var events: [(set: FrameSet, index: Int)] = []
    }

    private func makeEngine() -> (AnimationEngine, FrameRecorder) {
        let engine = AnimationEngine(schedulesTimers: false)
        let recorder = FrameRecorder()
        engine.onFrame = { set, index in recorder.events.append((set, index)) }
        return (engine, recorder)
    }

    @Test func idleStateAnimatesSleepFromFrameZero() {
        let (engine, recorder) = makeEngine()
        engine.setAppState(stayAwakeOn: false, chargePaused: false)
        #expect(engine.currentSet == .sleep)
        #expect(engine.currentFPS == 0.5)
        #expect(engine.frameIndex == 0)
        #expect(engine.isAnimating)
        #expect(recorder.events.first?.set == .sleep)
        #expect(recorder.events.first?.index == 0)
    }

    @Test func tickAdvancesAndWrapsTheFrameIndex() {
        let (engine, recorder) = makeEngine()
        engine.setAppState(stayAwakeOn: true, chargePaused: false)
        #expect(engine.currentSet == .run)
        for _ in 0..<5 { engine.tick() }
        // 5 ticks through a 5-frame set → back to frame 0.
        #expect(engine.frameIndex == 0)
        #expect(engine.tickCount == 5)
        #expect(recorder.events.map(\.index) == [0, 1, 2, 3, 4, 0])
        #expect(recorder.events.allSatisfy { $0.set == .run })
    }

    @Test func sameStateUpdateKeepsTheCurrentPhase() {
        let (engine, _) = makeEngine()
        engine.setAppState(stayAwakeOn: true, chargePaused: false)
        engine.tick()
        engine.tick()
        #expect(engine.frameIndex == 2)
        // Re-publishing identical state (e.g. a menu-open refresh) must not
        // visibly restart the animation.
        engine.setAppState(stayAwakeOn: true, chargePaused: false)
        #expect(engine.frameIndex == 2)
        #expect(engine.currentSet == .run)
    }

    @Test func stateChangeRestartsAtFrameZero() {
        let (engine, recorder) = makeEngine()
        engine.setAppState(stayAwakeOn: true, chargePaused: true)
        #expect(engine.currentSet == .run, "priority: stay-awake beats paused")
        engine.tick()
        #expect(engine.frameIndex == 1)
        // Stay-awake turns off while the pause holds → sit, reset to 0.
        engine.setAppState(stayAwakeOn: false, chargePaused: true)
        #expect(engine.currentSet == .sit)
        #expect(engine.currentFPS == 1)
        #expect(engine.frameIndex == 0)
        #expect(recorder.events.last?.set == .sit)
        #expect(recorder.events.last?.index == 0)
    }

    @Test func screenSleepStopsTicksAndWakeResumesAtFrameZero() {
        let (engine, _) = makeEngine()
        engine.setAppState(stayAwakeOn: true, chargePaused: false)
        engine.tick()
        let ticksBeforeSleep = engine.tickCount

        engine.handleScreensDidSleep()
        #expect(!engine.isAnimating)
        #expect(engine.currentSet == nil)
        // Ticks while stopped are no-ops — the counter must not move
        // (this is the pmset displaysleepnow morning-check invariant).
        engine.tick()
        engine.tick()
        #expect(engine.tickCount == ticksBeforeSleep)

        engine.handleScreensDidWake()
        #expect(engine.isAnimating)
        #expect(engine.currentSet == .run)
        #expect(engine.frameIndex == 0)
        #expect(engine.tickCount == ticksBeforeSleep, "wake alone is not a tick")
    }

    @Test func appStateChangesWhileScreensAsleepApplyOnWake() {
        let (engine, _) = makeEngine()
        engine.setAppState(stayAwakeOn: true, chargePaused: false)
        engine.handleScreensDidSleep()
        engine.setAppState(stayAwakeOn: false, chargePaused: true)
        #expect(!engine.isAnimating, "still stopped while screens sleep")
        engine.handleScreensDidWake()
        #expect(engine.currentSet == .sit)
        #expect(engine.frameIndex == 0)
    }
}

/// Frame asset checks against the COMMITTED files in Resources/frames/
/// (located from this file's path — the SPM test bundle does not embed them).
@MainActor
struct FrameAssetTests {
    private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    private static var framesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // NapCatTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Resources/frames", isDirectory: true)
    }

    @Test(arguments: FrameSet.allCases)
    func frameAssetsExistAsValidPNGsWithCorrectDimensions(set: FrameSet) throws {
        for name in set.frameNames {
            for (suffix, expectedPixels) in [("", 18), ("@2x", 36)] {
                let url = Self.framesDirectory.appendingPathComponent("\(name)\(suffix).png")
                let data = try #require(try? Data(contentsOf: url), "missing \(url.lastPathComponent)")
                #expect(data.prefix(8) == Self.pngSignature, "\(url.lastPathComponent): not a PNG")
                let rep = try #require(NSBitmapImageRep(data: data), "\(url.lastPathComponent): undecodable")
                #expect(rep.pixelsWide == expectedPixels, "\(url.lastPathComponent)")
                #expect(rep.pixelsHigh == expectedPixels, "\(url.lastPathComponent)")
            }
        }
    }

    /// The directory contains exactly the 20 expected PNGs — no stale
    /// leftovers from renamed frames.
    @Test func framesDirectoryContainsExactlyTheExpectedFiles() throws {
        let contents = try #require(
            try? FileManager.default.contentsOfDirectory(atPath: Self.framesDirectory.path)
        )
        let pngs = Set(contents.filter { $0.hasSuffix(".png") })
        let expected = Set(FrameSet.allCases.flatMap { set in
            set.frameNames.flatMap { ["\($0).png", "\($0)@2x.png"] }
        })
        #expect(expected.count == 20)
        #expect(pngs == expected)
    }

    /// Integration-level load: every frame becomes an 18pt template image
    /// with both representations; a missing directory falls back to nil
    /// (StatusItemController then keeps the placeholder icon).
    @Test func frameLibraryLoadsTemplateImagesAndFailsClosedWhenMissing() throws {
        let frames = try #require(StatusItemController.loadFrameImages(from: Self.framesDirectory))
        for set in FrameSet.allCases {
            let images = try #require(frames[set])
            #expect(images.count == set.frameCount)
            for image in images {
                #expect(image.isTemplate, "menu bar frames must be template images")
                #expect(image.size == NSSize(width: 18, height: 18))
                #expect(image.representations.count == 2, "@1x + @2x reps")
            }
        }
        let missing = StatusItemController.loadFrameImages(
            from: URL(fileURLWithPath: "/nonexistent-napcat-frames", isDirectory: true)
        )
        #expect(missing == nil)
    }
}
