import AppKit
import os

/// What this session's last finished check said. In memory only — after a
/// relaunch only the attempt time and the latest tag are known.
enum UpdateCheckResult: Equatable, Sendable {
    /// The latest release is the running one (or older).
    case upToDate
    /// The latest release is newer than the running one.
    case available
    /// No answer: offline, refused, rate-limited, malformed…
    case failed
}

/// The update check's state and its three defaults keys (issue #111). It
/// never downloads or installs anything: it learns the latest release's tag,
/// remembers it, and — when the user asked (`checkNow`) and it is newer —
/// opens that release's page in the browser.
///
/// - A check starts ONLY from a user action: `checkNow` (the "Check for
///   Updates…" button — always, one at a time) or `checkIfDue` (opening the
///   menu or the Settings window — only while automatic checks are on and
///   the last attempt is 24 h old: `UpdateCadence`). No timer exists.
/// - The attempt time is recorded when a check STARTS, so a failure waits
///   out the interval as well.
/// - Only the latest release's validated tag is stored, and it is
///   re-validated against the running version at every read
///   (`knownNewer`), so the "Update available" line goes away by itself once
///   the app is upgraded.
/// - An opportunistic check never opens anything: only a manual check that
///   finds a newer release opens its page.
///
/// Constructed only through `makeIfEnabled` (absent in debugBattery mode,
/// like every other network-capable subsystem), which is also the one place
/// the real `GitHubReleaseChecker` is built. Everything it does on the
/// network goes through the injected `ReleaseChecking`, so tests drive it
/// with a scripted fake and never touch the network.
@MainActor
final class UpdateCheckController {
    private static let logger = Logger(subsystem: "com.muratalkan.napcat", category: "update")

    /// The running app's version (its `CFBundleShortVersionString`).
    let running: ReleaseVersion
    private let defaults: UserDefaults
    private let checker: any ReleaseChecking
    private let now: () -> Double
    private let openReleasePage: (URL) -> Void
    private var onChange: (() -> Void)?

    /// True while a check is out.
    private(set) var inFlight = false
    /// What this session's last finished check said; nil before the first.
    private(set) var lastResult: UpdateCheckResult?

    init(
        running: ReleaseVersion,
        defaults: UserDefaults,
        checker: any ReleaseChecking,
        now: @escaping () -> Double = { Date().timeIntervalSince1970 },
        openReleasePage: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.running = running
        self.defaults = defaults
        self.checker = checker
        self.now = now
        self.openReleasePage = openReleasePage
    }

    /// The wiring predicate: nil in debugBattery mode (no network-capable
    /// subsystem exists there), and nil when the running version does not
    /// parse (nothing to compare against). The real checker is built here
    /// and only here.
    static func makeIfEnabled(debugBattery: Bool, runningVersion: String?,
                              defaults: UserDefaults) -> UpdateCheckController? {
        guard !debugBattery, let text = runningVersion, let version = ReleaseVersion(bundleVersion: text) else {
            return nil
        }
        return UpdateCheckController(running: version, defaults: defaults,
                                     checker: GitHubReleaseChecker(running: version))
    }

    func setChangeHandler(_ handler: @escaping () -> Void) {
        onChange = handler
    }

    // MARK: Stored state (read live, never cached)

    /// `updateCheckAutoEnabled`: unset is ON (`UpdateCadence.autoEnabled`).
    var autoEnabled: Bool {
        UpdateCadence.autoEnabled(stored: defaults.object(forKey: DefaultsKey.updateCheckAutoEnabled))
    }

    /// `updateCheckLastAttempt`, epoch seconds; nil = never.
    var lastAttempt: Double? {
        UpdateCadence.lastAttempt(stored: defaults.object(forKey: DefaultsKey.updateCheckLastAttempt))
    }

    /// The stored latest tag, only while it is a release NEWER than the
    /// running app — re-validated on every read.
    var knownNewer: ReleaseVersion? {
        UpdateVersion.newerRelease(tag: defaults.object(forKey: DefaultsKey.updateCheckLatestTag), running: running)
    }

    func setAutoEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: DefaultsKey.updateCheckAutoEnabled)
        onChange?()
    }

    // MARK: Checks

    /// Opening the menu or the Settings window: a check only when the
    /// cadence says one is due.
    func checkIfDue() {
        guard UpdateCadence.opportunisticCheckDue(autoEnabled: autoEnabled, lastAttempt: lastAttempt, now: now()) else {
            return
        }
        start(manual: false)
    }

    /// The "Check for Updates…" button: always, one check at a time.
    func checkNow() {
        start(manual: true)
    }

    private func start(manual: Bool) {
        guard !inFlight else { return }
        inFlight = true
        // Recorded BEFORE the request goes out: a failed attempt counts too.
        defaults.set(now(), forKey: DefaultsKey.updateCheckLastAttempt)
        onChange?()
        checker.fetchLatest { [weak self] outcome in
            Task { @MainActor in self?.finish(outcome, manual: manual) }
        }
    }

    private func finish(_ outcome: ReleaseCheckOutcome, manual: Bool) {
        inFlight = false
        switch outcome {
        case .latest(let latest):
            // The tag as its validated numbers render it — never the raw text.
            defaults.set(latest.tag, forKey: DefaultsKey.updateCheckLatestTag)
            let newer = latest > running
            lastResult = newer ? .available : .upToDate
            Self.logger.notice("update check: latest \(latest.tag, privacy: .public), \(newer ? "newer" : "not newer", privacy: .public)")
            if manual, newer, let page = GitHubReleaseChecker.releasePageURL(for: latest) {
                openReleasePage(page)
            }
        case .failed(let failure):
            lastResult = .failed
            Self.logger.notice("update check: failed (\(Self.reason(failure), privacy: .public))")
        }
        onChange?()
    }

    /// Fixed words for the log: the failure category, and a status number.
    static func reason(_ failure: ReleaseCheckFailure) -> String {
        switch failure {
        case .transport: return "no response"
        case .redirected: return "redirected"
        case .httpStatus(let status): return "HTTP \(status)"
        case .oversize: return "oversize"
        case .malformed: return "malformed"
        case .missingTag: return "no tag"
        case .unusableTag: return "unusable tag"
        }
    }
}
