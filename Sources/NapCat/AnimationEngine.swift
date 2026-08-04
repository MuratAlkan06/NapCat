import AppKit
import os

/// The three pixel-art icon animations (PLAN.md ADR §10). Frame PNGs live in
/// the app bundle under Resources/frames/ and are rendered from in-code
/// grids by scripts/render_frames.swift (`make frames`).
enum FrameSet: String, CaseIterable, Sendable {
    case run
    case sleep
    case sit

    var frameCount: Int {
        switch self {
        case .run: return 5
        case .sleep: return 3
        case .sit: return 2
        }
    }

    /// Pixel height of the @1x frame PNG for this set (the @2x asset is exactly
    /// twice this). run/sit are 18px on-grid pixel art; sleep is the processed
    /// hand-drawn grooming cat rendered at iconPointHeight = 21px
    /// (decision log 2026-07-11). All frames are square.
    var baseDimension: Int {
        switch self {
        case .run, .sit: return 18
        case .sleep: return 21
        }
    }

    /// Base names of the frame files on disk ("run0" → run0.png + run0@2x.png).
    var frameNames: [String] {
        (0..<frameCount).map { "\(rawValue)\($0)" }
    }
}

/// Drives the animated status-item icon: a pure state → (frame set, fps)
/// mapping plus a main-runloop timer that advances the frame index and
/// reports each frame through `onFrame` (PLAN.md ADR §10).
///
/// Locked mapping (user decision 2026-07-09):
///   stay-awake ON            → run   @ 10 fps
///   else charging paused     → sit   @  1 fps
///   else                     → sleep @ 0.5 fps
///   screens asleep           → nil   (timer stopped)
///
/// Sleep runs at 0.5 fps: the three sleep frames are byte-identical copies of
/// one static processed grooming cat (the user rejected the synthetic head-bob,
/// decision log 2026-07-11), so the cadence is moot — 0.5 fps just minimizes
/// timer wakeups. The upcoming hand-drawn 17-frame set will animate the SIT
/// state instead.
///
/// PRIORITY: stay-awake beats charge-paused — while both are true the cat
/// runs, because running signals "an awake purpose is active"; the sit pose
/// returns as soon as stay-awake turns off while the pause holds.
///
/// The timer restarts cleanly on any state change (frame index reset to 0);
/// a no-op state update never resets the phase. `tickCount` is cumulative
/// and is logged when the screens sleep and when the animation resumes, so
/// the morning `pmset displaysleepnow` check can prove the timer stopped
/// (identical counts across the dark window).
@MainActor
final class AnimationEngine: NSObject {
    private static let logger = Logger(subsystem: "com.muratalkan.napcat", category: "animation")

    // MARK: Inputs

    private(set) var stayAwakeOn = false
    private(set) var chargePaused = false
    /// Tracked from NSWorkspace.screensDidSleep/DidWake once `start()` ran.
    private(set) var screenAwake = true

    // MARK: Outputs / state

    /// nil while the animation is stopped (screens asleep).
    private(set) var currentSet: FrameSet?
    private(set) var currentFPS: Double = 0
    private(set) var frameIndex = 0
    /// Cumulative timer fires — the hook for the display-sleep pause check.
    private(set) var tickCount = 0

    /// Receives every frame to display (set + index). StatusItemController
    /// maps this to statusItem.button?.image.
    var onFrame: ((FrameSet, Int) -> Void)?

    var isAnimating: Bool { currentSet != nil }

    /// Tests pass false so no real Timer ever lands on the main runloop
    /// (they drive `tick()` manually); production uses the default.
    private let schedulesTimers: Bool
    private var timer: Timer?

    init(schedulesTimers: Bool = true) {
        self.schedulesTimers = schedulesTimers
        super.init()
    }

    // MARK: - Pure mapping (unit-tested; the locked table above)

    nonisolated static func frameSet(
        stayAwakeOn: Bool,
        chargePaused: Bool,
        screenAwake: Bool
    ) -> (set: FrameSet, fps: Double)? {
        guard screenAwake else { return nil }
        if stayAwakeOn { return (.run, 10) }
        if chargePaused { return (.sit, 1) }
        return (.sleep, 0.5)
    }

    /// Pure restart decision: any change of set or fps (including to/from
    /// stopped) restarts the animation at frame 0; identical selections keep
    /// the current phase.
    nonisolated static func shouldRestart(
        from old: (set: FrameSet, fps: Double)?,
        to new: (set: FrameSet, fps: Double)?
    ) -> Bool {
        old?.set != new?.set || old?.fps != new?.fps
    }

    // MARK: - Lifecycle

    /// Registers the screen sleep/wake observers and applies the current
    /// state. Mirrors the ChargeLimiter.start() pattern.
    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(screensDidSleepNotification(_:)),
                           name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(screensDidWakeNotification(_:)),
                           name: NSWorkspace.screensDidWakeNotification, object: nil)
        apply()
    }

    /// App-state inputs come from the SAME observed state the menu renders
    /// (MenuStateModel mirrors): observed pmset state and
    /// ChargeLimiter.featureState == .paused.
    func setAppState(stayAwakeOn: Bool, chargePaused: Bool) {
        self.stayAwakeOn = stayAwakeOn
        self.chargePaused = chargePaused
        apply()
    }

    // MARK: - Screen sleep / wake (ADR §10)

    @objc private func screensDidSleepNotification(_ notification: Notification) {
        handleScreensDidSleep()
    }

    @objc private func screensDidWakeNotification(_ notification: Notification) {
        handleScreensDidWake()
    }

    /// Internal (not private) so tests can drive the transition directly.
    func handleScreensDidSleep() {
        screenAwake = false
        apply()
    }

    func handleScreensDidWake() {
        screenAwake = true
        apply()
    }

    // MARK: - Timer

    /// One animation step. Called by the repeating timer; internal so tests
    /// can advance frames without real time.
    func tick() {
        guard let set = currentSet else { return }
        tickCount += 1
        frameIndex = (frameIndex + 1) % set.frameCount
        onFrame?(set, frameIndex)
    }

    @objc private func timerFired(_ timer: Timer) {
        tick()
    }

    private func apply() {
        let target = Self.frameSet(
            stayAwakeOn: stayAwakeOn,
            chargePaused: chargePaused,
            screenAwake: screenAwake
        )
        let current: (set: FrameSet, fps: Double)? = currentSet.map { (set: $0, fps: currentFPS) }
        guard Self.shouldRestart(from: current, to: target) else { return }

        timer?.invalidate()
        timer = nil

        guard let target else {
            currentSet = nil
            currentFPS = 0
            Self.logger.notice("animation paused (screens asleep) tickCount=\(self.tickCount)")
            return
        }

        currentSet = target.set
        currentFPS = target.fps
        frameIndex = 0
        onFrame?(target.set, 0)

        if schedulesTimers {
            let interval = 1.0 / target.fps
            let newTimer = Timer(
                timeInterval: interval,
                target: self,
                selector: #selector(timerFired(_:)),
                userInfo: nil,
                repeats: true
            )
            newTimer.tolerance = interval / 10
            // .common so the animation keeps running while the menu is open
            // (menu tracking runs the runloop in event-tracking mode).
            RunLoop.main.add(newTimer, forMode: .common)
            timer = newTimer
        }
        Self.logger.notice("animation → \(target.set.rawValue, privacy: .public) @ \(target.fps, privacy: .public) fps, tickCount=\(self.tickCount)")
    }
}
