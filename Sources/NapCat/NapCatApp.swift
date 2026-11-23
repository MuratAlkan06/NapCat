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
    /// The ONE ntfy sender. Nil in debugBattery mode.
    private var ntfySender: NtfyMessageSender?
    /// F3 stage 1: the composite wrapping `ntfySender` — the sender the lid
    /// guard and (Track C) the finish alert share. Phone first only when its
    /// toggle is on in an iCloud-entitled build; otherwise exactly the ntfy
    /// path. Nil in debugBattery mode.
    private var alertSender: CompositeMessageSender?
    /// Track C finish alert + waiting buzz; nil in debugBattery mode. Watches
    /// the marker dir only while armed.
    private var finishAlert: FinishAlertController?
    /// F4 slice S2: the remote-approvals toggle and kill switch; nil in
    /// debugBattery mode. Off (the default), nothing of it runs.
    private var remoteApprovals: RemoteApprovalsController?
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
        // never the value. The retired ntfy-topic key is NOT in this sweep:
        // it is deleted only by its keychain move, after a verified write,
        // when the lid guard is built below — after the crash-failsafe
        // reconciliation, because a keychain call can wait on a dialog.
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
        // The topic lives in the login keychain (issue #103): the lid guard's
        // construction moves a plaintext one there and reads it once; in
        // debugBattery mode nothing here is built, so the keychain is never
        // touched.
        let ntfy = LidGuardController.makeSharedSender(debugBattery: isDebugBattery)
        ntfySender = ntfy
        // F3 stage 1: that one instance is wrapped by the composite, which is
        // what both features get. Same gate (nil in debugBattery mode); with
        // the phone toggle off it hands every call to `ntfy` unchanged.
        let sender = CompositeMessageSender.makeIfEnabled(wrapping: ntfy, defaults: defaults)
        alertSender = sender
        let lidGuard = LidGuardController.makeIfEnabled(
            debugBattery: isDebugBattery,
            defaults: defaults,
            stayAwakeMirror: sleepController.observedMirror,
            detection: detection,
            sender: sender,
            topicStore: KeychainTopicStore.loginKeychain
        )
        self.lidGuard = lidGuard

        // F4 slice S2 (remote approvals). Same wiring-predicate gate, and it
        // needs the lid guard (which holds the alert topic, a secret the
        // category gate keeps on the Mac). Construction does no I/O: the seam
        // host is built and the policy probed only once the stored toggle is
        // on (`reconcile()` below), and nothing is ever forwarded in this
        // slice.
        let approvals = RemoteApprovalsController.makeIfEnabled(
            debugBattery: isDebugBattery,
            lidGuard: lidGuard,
            defaults: defaults
        )
        remoteApprovals = approvals

        // Track C (finish alert + waiting buzz). Same wiring-predicate gate;
        // shares the lid guard's destination/priming and the ONE sender. The
        // kqueue watcher exists only while armed. Every lid-guard arming
        // refresh (toggle / topic / server / priming — the last one completes
        // off the main thread) re-runs the finish-alert reconciliation on main.
        // Alert healing (issue #23): the connectivity startup swap — in
        // debugBattery mode the real path monitor is never constructed (the
        // simulator stands in, and the finish alert itself is absent). The
        // monitor observes only while healing is armed.
        let finishAlert = FinishAlertController.makeIfEnabled(
            debugBattery: isDebugBattery,
            lidGuard: lidGuard,
            sender: sender,
            connectivity: ConnectivityWiring.makeInterface(debugBattery: isDebugBattery),
            stayAwakeMirror: sleepController.observedMirror
        )
        self.finishAlert = finishAlert
        lidGuard?.setArmingRefreshHook { [weak finishAlert] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { finishAlert?.reconcile() }
            }
        }

        // Issue #111 (update check). Same wiring-predicate gate: absent in
        // debugBattery mode. Nothing is checked at launch — only on a user
        // action (the Settings button, or opening the menu or Settings at
        // most once a day).
        let updateCheck = UpdateCheckController.makeIfEnabled(
            debugBattery: isDebugBattery,
            runningVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            defaults: defaults
        )

        let menuContent = MenuContentView(
            sleep: sleepController,
            watchdog: watchdogController,
            power: power,
            limiter: limiter,
            simulator: simulator,
            detection: detection,
            lidGuard: lidGuard,
            finishAlert: finishAlert,
            phoneTransport: sender,
            updateCheck: updateCheck,
            remoteApprovals: approvals,
            defaults: defaults
        )
        statusItemController = StatusItemController(menuContent: menuContent)
        // Never shown (an accessory app owns no menu bar), but its key
        // equivalents work whenever NapCat is active: ⌘, opens Settings from
        // anywhere outside the status menu (slice W). The status item keeps
        // `menuContent` alive; menu item targets are weak.
        NSApp.mainMenu = AppMainMenu.make(settingsTarget: menuContent)
        // reconcileAtLaunch() has already refreshed the observed sleep state,
        // so the mirror the fire gate reads is primed before we may arm.
        lidGuard?.refreshArming()
        finishAlert?.reconcile()
        // F4: listen only if the stored toggle is on.
        approvals?.reconcile()
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
        // F4: quitting is a hard stop — the kill switch, final: every open
        // prompt withdrawn, every channel server disconnected, the socket
        // removed.
        remoteApprovals?.shutdown()
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
