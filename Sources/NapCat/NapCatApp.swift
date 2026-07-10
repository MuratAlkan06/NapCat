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
    private var statusItemController: StatusItemController?
    private var signalSources: [DispatchSourceSignal] = []
    private var didRevertOnShutdown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-braces alongside LSUIElement=true in Info.plist:
        // never show a Dock icon or app menu.
        NSApp.setActivationPolicy(.accessory)

        // Order matters: reap any stale watchdog BEFORE anything could spawn
        // a fresh one (kill-9 → relaunch → enable race), then reconcile
        // observed state, then build the menu from the reconciled state.
        watchdogController.reapStaleWatchdog()
        reconcileAtLaunch()
        installTerminationSignalHandlers()
        statusItemController = StatusItemController(
            menuContent: MenuContentView(
                sleep: sleepController,
                watchdog: watchdogController,
                defaults: defaults
            )
        )
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
    /// (intent flag) — an externally-set disablesleep is left alone.
    private func revertStayAwakeIfNeeded() {
        guard !didRevertOnShutdown else { return }
        didRevertOnShutdown = true
        if defaults.bool(forKey: DefaultsKey.stayAwakeIntent) {
            _ = sleepController.setStayAwake(false)
            defaults.set(false, forKey: DefaultsKey.stayAwakeIntent)
        }
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
