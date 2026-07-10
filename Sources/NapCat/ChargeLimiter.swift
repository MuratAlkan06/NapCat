import AppKit
import os

/// What the charge-limit UI should render (PLAN.md ADR §12 + P3b).
/// Precedence: hidden > notSupported > setupRequired > off > error > paused/active.
enum ChargeLimitFeatureState: Equatable, Sendable {
    /// No battery (desktop Mac) — the section disappears entirely.
    case hidden
    /// Intel Mac — controls disabled with an explanation (locked decision).
    case notSupported
    /// smc helper or sudoers entries missing — user has not run setup.sh.
    case setupRequired
    /// Feature toggle is off.
    case off
    /// Enabled and monitoring; charging permitted.
    case active
    /// Enabled and holding charging inhibited at the limit.
    case paused
    /// A write or its verification failed — NEVER rendered as "paused"
    /// (ADR §2).
    case error(String)
}

/// Drives HysteresisEngine from power-source events, a 60-second re-assert
/// timer, and sleep/wake notifications (PLAN.md ADR §5/§7 + P3b slice).
///
/// State rules:
/// - `controlState` advances ONLY via `HysteresisEngine.nextState(after:from:)`
///   after a SUCCESSFUL write (write = privileged command + read-back inside
///   the PowerInterface implementation).
/// - A successful pause is additionally verified by watching IsCharging flip
///   within ≤60 s; no flip → visible `.error`, never a false "paused".
/// - Every transition is logged (subsystem com.muratalkan.napcat).
@MainActor
final class ChargeLimiter: NSObject {
    private static let logger = Logger(subsystem: "com.muratalkan.napcat", category: "chargelimit")

    nonisolated static let reassertInterval: TimeInterval = 60
    /// ADR §2: IsCharging must flip within this window after a pause.
    nonisolated static let chargingFlipTimeout: TimeInterval = 60
    nonisolated static let limitRange = 50...100
    nonisolated static let limitStep = 5
    nonisolated static let defaultLimit = 90

    enum Failure: Equatable, Sendable {
        /// sudoers entry missing → rendered as setup required.
        case sudoDenied
        case writeFailed(String)
        /// Write + read-back succeeded but IsCharging never flipped.
        case chargingDidNotStop
    }

    private let power: PowerInterface
    private let defaults: UserDefaults
    let isAppleSilicon: Bool
    /// Injectable clock for the flip-verification deadline (tests).
    var now: () -> Date = { Date() }

    private(set) var controlState: ChargingControlState = .normal
    private(set) var lastFailure: Failure?
    private var reassertTimer: Timer?
    private var pauseVerificationDeadline: Date?
    private var isEvaluating = false

    /// Fired on the main actor after every evaluation — the UI model
    /// re-reads everything (battery values, feature state) on this hook.
    var onChange: (() -> Void)?

    var reassertTimerActive: Bool { reassertTimer != nil }

    init(
        power: PowerInterface,
        isAppleSilicon: Bool = ChipInfo.isAppleSilicon,
        defaults: UserDefaults = .standard
    ) {
        self.power = power
        self.defaults = defaults
        self.isAppleSilicon = isAppleSilicon
        super.init()
    }

    // MARK: - Persistence (PLAN.md §11)

    /// 50–100, default 90; 100 renders/behaves as "uncapped".
    var limit: Int {
        guard let stored = defaults.object(forKey: DefaultsKey.limit) as? Int else {
            return Self.defaultLimit
        }
        return min(Self.limitRange.upperBound, max(Self.limitRange.lowerBound, stored))
    }

    var enabled: Bool { defaults.bool(forKey: DefaultsKey.limitEnabled) }

    func setLimit(_ newValue: Int) {
        let clamped = min(Self.limitRange.upperBound, max(Self.limitRange.lowerBound, newValue))
        guard clamped != limit else { return }
        defaults.set(clamped, forKey: DefaultsKey.limit)
        evaluate(reason: "limit changed to \(clamped)")
    }

    func setEnabled(_ newValue: Bool) {
        guard newValue != enabled else { return }
        defaults.set(newValue, forKey: DefaultsKey.limitEnabled)
        // Stale failures don't outlive a deliberate toggle; real conditions
        // re-surface on the next write attempt.
        lastFailure = nil
        evaluate(reason: newValue ? "limit enabled" : "limit disabled")
    }

    // MARK: - Lifecycle

    /// Wires power-change pushes, sleep/wake notifications, launch
    /// reconciliation, and runs the first evaluation.
    func start() {
        power.onPowerChange = { [weak self] in
            self?.evaluate(reason: "power change")
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(systemWillSleep(_:)),
                           name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(systemDidWake(_:)),
                           name: NSWorkspace.didWakeNotification, object: nil)

        // Launch reconciliation: a crash while paused leaves the SMC key
        // inhibited. Adopt the observed pause so the transition table
        // (P6–P15) releases or holds it correctly.
        if featureOperable, power.readChargingInhibited() == true {
            controlState = .paused
            Self.logger.notice("launch reconciliation: charging observed inhibited — adopting paused state")
        }
        evaluate(reason: "launch")
    }

    /// Clean-quit path: never leave charging inhibited behind (mirrors the
    /// stay-awake revert; uninstall.sh covers the app-not-running case).
    func releasePauseForShutdown() {
        guard controlState == .paused, featureOperable else { return }
        perform(.enableCharging, reason: "app quitting")
    }

    // MARK: - Evaluation

    /// The feature acts only when it can act: battery present, Apple
    /// Silicon, helper probed ready.
    private var featureOperable: Bool {
        power.hasBattery && isAppleSilicon && power.chargeControlReadiness == .ready
    }

    func evaluate(reason: String) {
        // Simulator writes push onPowerChange synchronously from inside
        // perform() — ignore the re-entrant call, state advances on return.
        guard !isEvaluating else { return }
        isEvaluating = true
        defer {
            isEvaluating = false
            updateReassertTimer()
            onChange?()
        }
        guard featureOperable else { return }
        checkPauseVerification()
        let command = HysteresisEngine.decide(
            percent: power.batteryPercent,
            adapterConnected: power.adapterConnected,
            limit: limit,
            enabled: enabled,
            currentState: controlState
        )
        guard command != .none else { return }
        perform(command, reason: reason)
    }

    /// 60-second tick (ADR §5): Sequoia/Tahoe field reports show charging
    /// re-enabling itself — while paused, re-assert the disable write.
    func reassertTick() {
        guard featureOperable, enabled, power.adapterConnected else { return }
        if controlState == .paused {
            perform(.disableCharging, reason: "60s re-assert")
        }
        evaluate(reason: "re-assert tick")
    }

    private func perform(_ command: ChargeCommand, reason: String) {
        let before = controlState
        let result = command == .disableCharging ? power.disableCharging() : power.enableCharging()
        switch result {
        case .success:
            controlState = HysteresisEngine.nextState(after: command, from: before)
            // Keep chargingDidNotStop until the flip is actually observed
            // (checkPauseVerification clears it) — a re-asserted write alone
            // is not evidence charging stopped.
            if lastFailure != .chargingDidNotStop { lastFailure = nil }
            switch command {
            case .disableCharging:
                if pauseVerificationDeadline == nil, power.isCharging {
                    pauseVerificationDeadline = now().addingTimeInterval(Self.chargingFlipTimeout)
                }
            case .enableCharging:
                pauseVerificationDeadline = nil
            case .none:
                break
            }
            Self.logger.notice("\(String(describing: command), privacy: .public) ok (\(reason, privacy: .public)): \(String(describing: before), privacy: .public) → \(String(describing: self.controlState), privacy: .public), %=\(self.power.batteryPercent.map(String.init) ?? "nil", privacy: .public), limit=\(self.limit)")
        case .sudoDenied:
            lastFailure = .sudoDenied
            Self.logger.error("\(String(describing: command), privacy: .public) denied (\(reason, privacy: .public)) — setup required; state stays \(String(describing: before), privacy: .public)")
        case .commandFailed(let exitStatus, let stderr):
            let detail = "charge write failed (exit \(exitStatus)): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            lastFailure = .writeFailed(detail)
            Self.logger.error("\(detail, privacy: .public) (\(reason, privacy: .public)); state stays \(String(describing: before), privacy: .public)")
        }
    }

    /// ADR §2 pause verification: while paused on AC, IsCharging must flip
    /// off within the timeout; recovery (flip observed later) clears the
    /// error again.
    private func checkPauseVerification() {
        guard controlState == .paused else {
            pauseVerificationDeadline = nil
            return
        }
        guard power.adapterConnected, power.isCharging else {
            // Flip observed (or nothing can charge) — verified.
            pauseVerificationDeadline = nil
            if lastFailure == .chargingDidNotStop {
                lastFailure = nil
                Self.logger.notice("pause verification recovered: charging stopped")
            }
            return
        }
        if pauseVerificationDeadline == nil {
            // Charging resumed behind our back — start a fresh window; the
            // re-assert tick rewrites the key.
            pauseVerificationDeadline = now().addingTimeInterval(Self.chargingFlipTimeout)
        } else if let deadline = pauseVerificationDeadline, now() >= deadline,
                  lastFailure != .chargingDidNotStop {
            lastFailure = .chargingDidNotStop
            Self.logger.error("pause verification FAILED: still charging \(Int(Self.chargingFlipTimeout))s after pausing")
        }
    }

    // MARK: - Re-assert timer (ADR §5)

    private func updateReassertTimer() {
        let shouldRun = featureOperable && enabled && power.adapterConnected
        if shouldRun, reassertTimer == nil {
            let timer = Timer(
                timeInterval: Self.reassertInterval,
                target: self,
                selector: #selector(reassertTimerFired(_:)),
                userInfo: nil,
                repeats: true
            )
            timer.tolerance = 5
            RunLoop.main.add(timer, forMode: .common)
            reassertTimer = timer
            Self.logger.debug("re-assert timer started")
        } else if !shouldRun, let timer = reassertTimer {
            timer.invalidate()
            reassertTimer = nil
            Self.logger.debug("re-assert timer stopped")
        }
    }

    @objc private func reassertTimerFired(_ timer: Timer) {
        reassertTick()
    }

    // MARK: - Sleep / wake (ADR §7 caller policy)

    @objc private func systemWillSleep(_ notification: Notification) {
        handleWillSleep()
    }

    @objc private func systemDidWake(_ notification: Notification) {
        handleDidWake()
    }

    /// Pre-sleep policy: the app cannot react while asleep, so if the
    /// battery could plausibly reach the limit (% ≥ limit−5), pause before
    /// sleeping — covers "plugged in while the lid is closed" too, which is
    /// why the adapter state is deliberately NOT checked.
    func handleWillSleep() {
        guard featureOperable, enabled, limit < 100, controlState == .normal,
              let percent = power.batteryPercent,
              percent >= limit - HysteresisEngine.resumeDelta
        else { return }
        perform(.disableCharging, reason: "pre-sleep (%=\(percent), limit=\(limit))")
        onChange?()
    }

    /// On wake the IOKit notification also fires; this explicit pass covers
    /// the case where power state did not change while asleep.
    func handleDidWake() {
        evaluate(reason: "wake")
    }

    // MARK: - Feature state (pure mapping, unit-tested)

    var featureState: ChargeLimitFeatureState {
        Self.featureState(
            hasBattery: power.hasBattery,
            isAppleSilicon: isAppleSilicon,
            readiness: power.chargeControlReadiness,
            enabled: enabled,
            controlState: controlState,
            failure: lastFailure
        )
    }

    nonisolated static func featureState(
        hasBattery: Bool,
        isAppleSilicon: Bool,
        readiness: ChargeControlReadiness,
        enabled: Bool,
        controlState: ChargingControlState,
        failure: Failure?
    ) -> ChargeLimitFeatureState {
        guard hasBattery else { return .hidden }
        guard isAppleSilicon else { return .notSupported }
        if readiness == .setupRequired || failure == .sudoDenied { return .setupRequired }
        if case .probeFailed(let message) = readiness {
            // Environment problem, like setupRequired — shown even when the
            // toggle is off so the user knows the feature cannot work.
            return .error("SMC key probe failed: \(message)")
        }
        guard enabled else { return .off }
        switch failure {
        case .writeFailed(let message):
            return .error(message)
        case .chargingDidNotStop:
            return .error("Charging did not stop within \(Int(chargingFlipTimeout)) seconds of pausing.")
        case .sudoDenied, .none:
            break
        }
        return controlState == .paused ? .paused : .active
    }
}
