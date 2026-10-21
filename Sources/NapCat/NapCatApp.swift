import AppKit
import os

/// App delegate. Owns the controllers for the lifetime of the app and
/// implements crash-failsafe layer (a) plus launch reconciliation (ADR §6).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "com.muratalkan.napcat", category: "app")

    private let defaults = UserDefaults.standard
    private let sleepController = SleepStateController()
    private let watchdogController = WatchdogController()
    private var powerSource: PowerInterface?
    private var chargeLimiter: ChargeLimiter?
    private var statusItemController: StatusItemController?
    private var lidGuard: LidGuardController?
    /// The ONE ntfy sender, shared by the lid guard and (Track C) the finish
    /// alert. Nil in debugBattery mode.
    private var ntfySender: NtfyMessageSender?
    /// Track C finish alert + waiting buzz; nil in debugBattery mode. Watches
    /// the marker dir only while armed.
    private var finishAlert: FinishAlertController?
    private var signalSources: [DispatchSourceSignal] = []
    private var didRevertOnShutdown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-braces alongside LSUIElement=true in Info.plist:
        // never show a Dock icon or app menu.
        NSApp.setActivationPolicy(.accessory)

        // Retired keys first: `lidGuardRecipient` held the user's own phone
        // number / Apple ID before the B4 ntfy swap, and `menuPanelStyle` was
        // the redesign's curation-only variant picker (retired at the design
        // freeze). Nothing reads either any more, so they are deleted rather
        // than left sitting in the preferences plist. Names only are logged —
        // never the value.
        let removedKeys = DefaultsMigration.removeRetiredKeys(in: defaults)
        if !removedKeys.isEmpty {
            Self.logger.notice("startup migration: removed \(removedKeys.joined(separator: ", "), privacy: .public) — retired key(s), value not read")
        }

        // Order matters: reap any stale watchdog BEFORE anything could spawn
        // a fresh one (kill-9 → relaunch → enable race), then reconcile
        // observed state, then build the menu from the reconciled state.
        watchdogController.reapStaleWatchdog()
        reconcileAtLaunch()
        installTerminationSignalHandlers()

        // ADR §8: debugBattery swaps the ENTIRE power interface at startup.
        // In simulated mode IOKitPowerSource is never constructed, so no smc
        // probe and no subprocess can ever run from the battery path.
        let isDebugBattery = defaults.bool(forKey: DefaultsKey.debugBattery)
        let simulator: DebugPowerSimulator?
        let power: PowerInterface
        if isDebugBattery {
            let debugSimulator = DebugPowerSimulator(batteryPercent: 80, adapterConnected: true)
            simulator = debugSimulator
            power = debugSimulator
            Self.logger.notice("debugBattery mode: DebugPowerSimulator active — no IOKit reads, no smc")
        } else {
            simulator = nil
            power = IOKitPowerSource()
        }
        let limiter = ChargeLimiter(power: power, defaults: defaults)
        powerSource = power
        chargeLimiter = limiter

        // Track B (READ-ONLY detection). Constructed only outside debugBattery
        // mode — the single gate is the wiring predicate, so in simulated mode
        // no proc enumeration / IOKit assertion read exists (ADR §8 mirror).
        let detection = ClaudeActivityController.makeIfEnabled(debugBattery: isDebugBattery)

        // Track B / B2 (lid-close alert). Same wiring-predicate gate: nothing
        // in this subsystem exists in debugBattery mode, so no IOKit power
        // registration and no network request is reachable there. The IOKit
        // registration itself happens only when the feature is ARMED
        // (refreshArming below and on every menu open). The ntfy sender is
        // built ONCE behind the same gate and injected, so the lid guard and
        // the Track C finish alert share one instance (per-kind lanes inside).
        let sender = LidGuardController.makeSharedSender(debugBattery: isDebugBattery)
        ntfySender = sender
        let lidGuard = LidGuardController.makeIfEnabled(
            debugBattery: isDebugBattery,
            defaults: defaults,
            stayAwakeMirror: sleepController.observedMirror,
            detection: detection,
            sender: sender
        )
        self.lidGuard = lidGuard

        // Track C (finish alert + waiting buzz). Same wiring-predicate gate;
        // shares the lid guard's destination/priming and the ONE sender. The
        // kqueue watcher exists only while armed. Every lid-guard arming
        // refresh (toggle / topic / server / priming — the last one completes
        // off the main thread) re-runs the finish-alert reconciliation on main.
        let finishAlert = FinishAlertController.makeIfEnabled(
            debugBattery: isDebugBattery,
            lidGuard: lidGuard,
            sender: sender
        )
        self.finishAlert = finishAlert
        lidGuard?.setArmingRefreshHook { [weak finishAlert] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { finishAlert?.reconcile() }
            }
        }

        statusItemController = StatusItemController(
            menuContent: MenuContentView(
                sleep: sleepController,
                watchdog: watchdogController,
                power: power,
                limiter: limiter,
                simulator: simulator,
                detection: detection,
                lidGuard: lidGuard,
                finishAlert: finishAlert,
                defaults: defaults
            )
        )
        // reconcileAtLaunch() has already refreshed the observed sleep state,
        // so the mirror the fire gate reads is primed before we may arm.
        lidGuard?.refreshArming()
        finishAlert?.reconcile()
        // After the menu is wired (limiter.onChange set) so the first
        // evaluation is already visible in the UI.
        limiter.start()
    }

    // Crash-failsafe layer (a), clean path.
    func applicationWillTerminate(_ notification: Notification) {
        revertStayAwakeIfNeeded()
    }

    /// Launch reconciliation (ADR §6): render OBSERVED state; never
    /// auto-enable. Stored intent is used only to detect that a previous
    /// session ended without a clean disable — in that case revert.
    private func reconcileAtLaunch() {
        let observed = sleepController.refreshObservedState()
        guard defaults.bool(forKey: DefaultsKey.stayAwakeIntent) else { return }
        Self.logger.notice("launch reconciliation: stay-awake intent survived a previous session — reverting (the app never auto-enables at launch)")
        if observed == true {
            // Best effort — may be sudo-denied if setup was removed; the
            // menu will render whatever state is actually observed.
            _ = sleepController.setStayAwake(false)
        }
        defaults.set(false, forKey: DefaultsKey.stayAwakeIntent)
    }

    /// Idempotent shutdown revert shared by applicationWillTerminate and the
    /// SIGTERM/SIGINT handlers. Only reverts what NapCat itself enabled
    /// (intent flag / an active charging pause) — externally-set state is
    /// left alone.
    private func revertStayAwakeIfNeeded() {
        guard !didRevertOnShutdown else { return }
        didRevertOnShutdown = true
        if defaults.bool(forKey: DefaultsKey.stayAwakeIntent) {
            _ = sleepController.setStayAwake(false)
            defaults.set(false, forKey: DefaultsKey.stayAwakeIntent)
        }
        // Never leave charging inhibited after a clean quit (P3b).
        chargeLimiter?.releasePauseForShutdown()
        // Drop the IOKit power-notification registration (B2) so a quitting
        // NapCat leaves no sleep-path footprint at all.
        lidGuard?.disarmForShutdown()
        // Track C: stop watching the marker dir; cancel any pending debounce,
        // flush or retry.
        finishAlert?.disarmForShutdown()
        watchdogController.stop()
    }

    /// Crash-failsafe layer (a), signal path: SIGTERM/SIGINT via
    /// DispatchSource on the main queue; the raw disposition is set to
    /// SIG_IGN so the default handler cannot kill us before the source fires.
    private func installTerminationSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                // Delivered on the main queue; no isolated state is captured.
                MainActor.assumeIsolated {
                    guard let delegate = NSApp.delegate as? AppDelegate else {
                        NSApp.terminate(nil)
                        return
                    }
                    delegate.revertStayAwakeIfNeeded()
                    NSApp.terminate(nil)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}

/// Entry point. Plain NSApplication + AppDelegate (no SwiftUI App lifecycle)
/// so we keep full control of the NSStatusItem.
@main
@MainActor
enum NapCatApp {
    // Strong reference; NSApplication.delegate is weak.
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}
