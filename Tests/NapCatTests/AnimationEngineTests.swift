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
            rationale: "idle → static grooming cat @0.5fps (frames identical; slow tick, 2026-07-11)"),
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

    /// run/sit are 18px on-grid pixel art (@2x = 36); sleep is the processed
    /// grooming cat at iconPointHeight = 21px (@2x = 42) — see FrameSet
    /// .baseDimension (decision log 2026-07-11).
    @Test(arguments: FrameSet.allCases)
    func frameAssetsExistAsValidPNGsWithCorrectDimensions(set: FrameSet) throws {
        for name in set.frameNames {
            for (suffix, expectedPixels) in [("", set.baseDimension), ("@2x", set.baseDimension * 2)] {
                let url = Self.framesDirectory.appendingPathComponent("\(name)\(suffix).png")
                let data = try #require(try? Data(contentsOf: url), "missing \(url.lastPathComponent)")
                #expect(data.prefix(8) == Self.pngSignature, "\(url.lastPathComponent): not a PNG")
                let rep = try #require(NSBitmapImageRep(data: data), "\(url.lastPathComponent): undecodable")
                #expect(rep.pixelsWide == expectedPixels, "\(url.lastPathComponent)")
                #expect(rep.pixelsHigh == expectedPixels, "\(url.lastPathComponent)")
            }
        }
    }

    /// The sleep state is a STILL processed grooming cat: all three frames are
    /// byte-identical copies of the one rest pose (the user rejected the
    /// synthetic head-bob, decision log 2026-07-11). This guards against a
    /// regression that re-introduces motion, and confirms the single frame is a
    /// real cutout cat (non-blank, not fully opaque — the interior cutouts and
    /// breathing margin survived the pipeline).
    @Test func sleepFramesAreStaticIdenticalCopies() throws {
        func data(_ name: String) throws -> Data {
            let url = Self.framesDirectory.appendingPathComponent("\(name).png")
            return try #require(try? Data(contentsOf: url), "missing \(name).png")
        }
        // @1x and @2x: sleep0/1/2 must be byte-identical (no animation).
        for suffix in ["", "@2x"] {
            let s0 = try data("sleep0\(suffix)")
            let s1 = try data("sleep1\(suffix)")
            let s2 = try data("sleep2\(suffix)")
            #expect(s0 == s1, "sleep0\(suffix) and sleep1\(suffix) must be identical (static sleep)")
            #expect(s1 == s2, "sleep1\(suffix) and sleep2\(suffix) must be identical (static sleep)")
        }
        // The frame must actually contain the cat: a non-trivial opaque area
        // (not blank) with cutouts/margin intact (not fully opaque).
        for name in FrameSet.sleep.frameNames {
            let rep = try #require(NSBitmapImageRep(data: try data(name)))
            var opaque = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
                    opaque += 1
                }
            }
            let total = rep.pixelsHigh * rep.pixelsWide
            #expect(opaque > total / 6, "\(name): too few opaque pixels — frame looks blank")
            #expect(opaque < total, "\(name): fully opaque — cutout/margin lost")
        }
    }

    /// ORIENTATION LOCK (regression guard, 2026-07-11). A sitting/curled cat is
    /// bottom-heavy: its seated base — haunches and folded paws — fills the lower
    /// half of the frame, while the ears and head leave the upper half sparser.
    /// So the bottom half of the rendered sleep silhouette must hold MORE opaque
    /// pixels than the top half. The groom pipeline decodes the source via
    /// CoreGraphics; a stray vertical flip at that row-order boundary once
    /// rendered the sleep cat upside down (top-heavy). A flip swaps the two
    /// half-masses exactly, so `bottom > top` trips immediately if it returns.
    /// Deliberately a mass-distribution check (not a pixel hash) so it stays
    /// valid for any future seated/curled cat art — all of which are bottom-heavy.
    @Test(arguments: ["sleep0", "sleep0@2x"])
    func sleepFrameIsBottomHeavyNotUpsideDown(_ name: String) throws {
        let url = Self.framesDirectory.appendingPathComponent("\(name).png")
        let data = try #require(try? Data(contentsOf: url), "missing \(name).png")
        let rep = try #require(NSBitmapImageRep(data: data), "\(name): undecodable")
        let height = rep.pixelsHigh, width = rep.pixelsWide
        // colorAt(x:y:) uses a top-left origin (y = 0 is the top row). Compare
        // two SYMMETRIC bands of floor(height/2) rows each; for an odd height
        // (21px @1x) the exact center row is excluded so the bands are equal —
        // otherwise the extra row biases "bottom" and a flip could still pass.
        let half = height / 2
        var top = 0, bottom = 0
        for y in 0..<height {
            for x in 0..<width where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
                if y < half { top += 1 } else if y >= height - half { bottom += 1 }
            }
        }
        #expect(bottom > top,
            "\(name): sleep cat must be bottom-heavy (seated base below, ears above) — top=\(top) bottom=\(bottom). top-heavy means the groom pipeline flipped it vertically.")
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

    /// Integration-level load: every frame becomes an iconPointHeight-tall
    /// template image with both representations; a missing directory falls
    /// back to nil (StatusItemController then keeps the placeholder icon).
    @Test func frameLibraryLoadsTemplateImagesAndFailsClosedWhenMissing() throws {
        let frames = try #require(StatusItemController.loadFrameImages(from: Self.framesDirectory))
        for set in FrameSet.allCases {
            let images = try #require(frames[set])
            #expect(images.count == set.frameCount)
            for image in images {
                #expect(image.isTemplate, "menu bar frames must be template images")
                // All frames are square (run/sit 18px, sleep 21px), so width
                // == height at the render size; non-square art would scale
                // width proportionally.
                #expect(image.size == NSSize(
                    width: StatusItemController.iconPointHeight,
                    height: StatusItemController.iconPointHeight
                ))
                #expect(image.representations.count == 2, "@1x + @2x reps")
            }
        }
        let missing = StatusItemController.loadFrameImages(
            from: URL(fileURLWithPath: "/nonexistent-napcat-frames", isDirectory: true)
        )
        #expect(missing == nil)
    }
}
