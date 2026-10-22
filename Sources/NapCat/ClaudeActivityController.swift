import Foundation

/// Owns the three READ-ONLY detection readers and holds a snapshot that the
/// menu renders. Sampling happens ONLY on `sample()` (called from
/// menuWillOpen) — there is NO background timer (B1 acceptance rule).
///
/// Debug-simulator isolation: constructed only when
/// `ClaudeActivityPolicy.detectionMayBeConstructed(debugBattery:)` is true, so
/// in debugBattery mode the whole subsystem — and every proc/IOKit read — is
/// structurally absent (`makeIfEnabled` returns nil). This mirrors how the
/// power interface is swapped for DebugPowerSimulator (ADR §8).
@MainActor
final class ClaudeActivityController {
    private let store: BusyMarkerStore
    private let prober: ClaudeProcessProber
    private let assertions: SleepAssertionReader
    private let markerDirURL: URL
    private let disabledFlagURL: URL

    // MARK: Sampled snapshot (read on menu open, published through MenuStateModel)

    private(set) var taskInFlight = false
    private(set) var claudeHoldingAwake = false
    private(set) var hookInstalled = false
    private(set) var hookEverSeen = false
    private(set) var lastSeenSeconds: Int?
    private(set) var detectionPaused = false
    /// S7: the installed hook copy's version stamp (nil = absent / no stamp).
    private(set) var installedHookVersion: Int?

    init(
        store: BusyMarkerStore,
        prober: ClaudeProcessProber,
        assertions: SleepAssertionReader,
        markerDirURL: URL = ClaudeBusyConstants.markerDirURL
    ) {
        self.store = store
        self.prober = prober
        self.assertions = assertions
        self.markerDirURL = markerDirURL
        self.disabledFlagURL = markerDirURL.appendingPathComponent(ClaudeBusyConstants.disabledFlagName)
    }

    /// The single construction site, gated by the debug-sim wiring predicate.
    /// Returns nil in debugBattery mode, so no reader is ever built there.
    static func makeIfEnabled(debugBattery: Bool) -> ClaudeActivityController? {
        guard ClaudeActivityPolicy.detectionMayBeConstructed(debugBattery: debugBattery) else { return nil }
        return ClaudeActivityController(
            store: MarkerDirectoryStore(),
            prober: LibprocProcessProber(),
            assertions: IOKitSleepAssertionReader()
        )
    }

    /// Re-read every source. Called from menuWillOpen — never on a timer.
    func sample() {
        detectionPaused = FileManager.default.fileExists(atPath: disabledFlagURL.path)
        let now = Int(Date().timeIntervalSince1970)
        let markers = store.markers()
        let probe = prober.probe()
        // While paused, detection is suspended (kill switch); the awake and
        // liveness lines still reflect reality.
        taskInFlight = detectionPaused
            ? false
            : ClaudeActivityPolicy.isTaskInFlight(markers: markers, now: now, proc: probe)
        claudeHoldingAwake = assertions.claudeIsHoldingAwake()
        hookInstalled = store.markerDirExists()
        hookEverSeen = store.hookLogExists()
        lastSeenSeconds = store.lastActivityEpoch().map { max(0, now - $0) }
        installedHookVersion = store.installedHookVersion()
    }

    /// FRESH busy reading for the B2 lid guard, taken at the instant the system
    /// announces sleep. Deliberately does NOT touch the published B1 snapshot:
    /// that one stays "sampled on menu open only". Reuses the same markers +
    /// fail-open prober + kill switch as `sample()`.
    func sampleBusyNow() -> LidGuardBusySample {
        guard !FileManager.default.fileExists(atPath: disabledFlagURL.path) else {
            return LidGuardBusySample(taskInFlight: false, sessionCount: 0)
        }
        let now = Int(Date().timeIntervalSince1970)
        let markers = store.markers()
        let probe = prober.probe()
        return LidGuardBusySample(
            taskInFlight: ClaudeActivityPolicy.isTaskInFlight(markers: markers, now: now, proc: probe),
            sessionCount: ClaudeActivityPolicy.freshMarkerCount(markers: markers, now: now)
        )
    }

    /// Kill switch: create/remove the DISABLED flag in NapCat's OWN state dir
    /// (never ~/.claude/settings.json). Creating it makes the hook no-op on
    /// its next run.
    func setPaused(_ paused: Bool) {
        if paused {
            try? FileManager.default.createDirectory(
                at: markerDirURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            FileManager.default.createFile(atPath: disabledFlagURL.path, contents: Data())
        } else {
            try? FileManager.default.removeItem(at: disabledFlagURL)
        }
        detectionPaused = paused
    }
}
