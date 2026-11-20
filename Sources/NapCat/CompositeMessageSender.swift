import Foundation
import os

/// What the panel may know about the phone transport: the toggle, whether
/// this build can use it, and the last CloudKit attempt's outcome + time.
/// Fixed vocabulary only — never a record, a body or an address.
struct PhoneTransportSnapshot: Equatable, Sendable {
    /// The `phoneTransportEnabled` toggle.
    let enabled: Bool
    /// The entitlement probe's answer. Only consulted while `enabled` (false
    /// when off), so a switched-off toggle evaluates nothing at all.
    let available: Bool
    /// The last CloudKit attempt since launch (in-memory, like the lid
    /// guard's last outcome); nil = none yet.
    let lastOutcome: MessageSendOutcome?
    let lastOutcomeAt: Double?
}

/// F3 stage 1: the COMPOSITE behind the unchanged, byte-locked
/// `MessageSender` seam — the one sender the lid guard and the session alerts
/// share. It owns no transport of its own; it chooses between two:
///
/// - PHONE FIRST iff the `phoneTransportEnabled` toggle is on AND this process
///   is entitled for iCloud (`CloudKitEntitlementProbe` — checked BEFORE the
///   CloudKit sender is asked anything, so an unentitled build never builds a
///   container). The CloudKit sender itself then requires an available iCloud
///   account before it saves.
/// - Otherwise STRAIGHT TO NTFY, byte-for-byte today's path: the call is
///   handed to the ntfy sender unchanged, no claim, no hop, no probe — so with
///   the toggle off NapCat behaves exactly as it did before this type existed
///   (`CompositeMessageSenderTests` locks that).
///
/// FALLBACK RULE (frozen F3 ADR): ntfy is tried after the phone ONLY when the
/// CloudKit attempt is a DEFINITIVE failure — `sendFailed`, meaning nothing
/// was committed (no network, iCloud unreachable, no account, rate-limited,
/// container or entitlement problems). NEVER after `timedOutUnconfirmed`: the
/// record may have landed and the phone may already be buzzing, so a second
/// copy over ntfy would be a double buzz. The caller sees the outcome of the
/// transport that answered last: the phone's, or — after a fallback — ntfy's.
///
/// PER-LANE SINGLE FLIGHT carries over unchanged: on the phone path the lane
/// is claimed for the WHOLE chain (phone, then any fallback), so a second
/// alert in the same lane is refused inline exactly as the ntfy sender would
/// refuse it, and can never slip out over ntfy while the first is still in
/// flight to iCloud. The other lane is never blocked.
///
/// The body is never built here: both transports derive it from the closed
/// kind through `LidGuardPolicy.messageBody`.
final class CompositeMessageSender: MessageSender, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.muratalkan.napcat", category: "phone")

    /// The inline refusal for a busy lane — the ntfy sender's own wording.
    static let busyLaneText = "another message is still being sent"

    private let ntfy: any MessageSender
    private let phone: any MessageSender
    private let defaults: UserDefaults
    private let isEntitled: @Sendable () -> Bool
    private let now: @Sendable () -> Double

    private let lock = NSLock()
    private var sending: [NtfySendLane: Bool] = [:]
    private var generation: [NtfySendLane: UInt64] = [:]
    private var lastPhoneOutcome: MessageSendOutcome?
    private var lastPhoneOutcomeAt: Double?

    /// `isEntitled` and `now` are TEST SEAMS (production: the cached probe
    /// and the wall clock).
    init(
        ntfy: any MessageSender,
        phone: any MessageSender,
        defaults: UserDefaults,
        isEntitled: @escaping @Sendable () -> Bool = { CloudKitEntitlementProbe.isEntitled },
        now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) {
        self.ntfy = ntfy
        self.phone = phone
        self.defaults = defaults
        self.isEntitled = isEntitled
        self.now = now
    }

    /// The ONE construction site of the composite and of its CloudKit sender,
    /// wrapping the shared ntfy sender. Nil exactly when that is nil
    /// (debugBattery mode — `LidGuardController.makeSharedSender`), so the
    /// debug simulator never holds a CloudKit sender either. Building the
    /// CloudKit sender does no I/O: its store is created lazily, behind the
    /// entitlement probe, on the first phone-path send.
    static func makeIfEnabled(wrapping ntfy: (any MessageSender)?, defaults: UserDefaults) -> CompositeMessageSender? {
        guard let ntfy else { return nil }
        return CompositeMessageSender(ntfy: ntfy, phone: CloudKitMessageSender(), defaults: defaults)
    }

    // MARK: - Toggle (DefaultsKey.phoneTransportEnabled, default false)

    /// Read LIVE at every send, so flipping it applies to the next alert.
    var phoneTransportEnabled: Bool { defaults.bool(forKey: DefaultsKey.phoneTransportEnabled) }

    func setPhoneTransportEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: DefaultsKey.phoneTransportEnabled)
    }

    var phoneSnapshot: PhoneTransportSnapshot {
        let enabled = phoneTransportEnabled
        let available = enabled && isEntitled()
        lock.lock()
        defer { lock.unlock() }
        return PhoneTransportSnapshot(enabled: enabled, available: available,
                                      lastOutcome: lastPhoneOutcome, lastOutcomeAt: lastPhoneOutcomeAt)
    }

    // MARK: - Send

    func send(
        _ kind: LidGuardMessageKind,
        to destination: NtfyDestination,
        at firedAt: Date,
        completion: @escaping @Sendable (MessageSendOutcome) -> Void
    ) {
        // Toggle off, or a build that cannot use iCloud: today's path, as is.
        // (`&&` order matters: with the toggle off the probe is not consulted.)
        guard phoneTransportEnabled, isEntitled() else {
            ntfy.send(kind, to: destination, at: firedAt, completion: completion)
            return
        }

        // Phone path: claim the lane for the whole chain.
        let lane = LidGuardPolicy.lane(for: kind)
        lock.lock()
        guard !sending[lane, default: false] else {
            lock.unlock()
            completion(.sendFailed(Self.busyLaneText))
            return
        }
        sending[lane] = true
        let claim = generation[lane, default: 0] &+ 1
        generation[lane] = claim
        lock.unlock()

        let ntfy = self.ntfy
        phone.send(kind, to: destination, at: firedAt) { [weak self] outcome in
            self?.recordPhoneOutcome(outcome)
            let fields = LidGuardPolicy.outcomeLogFields(outcome)
            guard Self.fallsBack(after: outcome) else {
                Self.logger.notice("phone: iCloud outcome \(fields.publicCategory, privacy: .public) — no ntfy fallback")
                self?.clear(claim, on: lane)
                completion(outcome)
                return
            }
            Self.logger.notice("phone: iCloud outcome \(fields.publicCategory, privacy: .public) — \(fields.privateDetail ?? "", privacy: .private); falling back to ntfy")
            ntfy.send(kind, to: destination, at: firedAt) { [weak self] fallback in
                self?.clear(claim, on: lane)
                completion(fallback)
            }
        }
    }

    /// THE fallback rule: only a definitive failure — nothing was committed —
    /// may be retried over ntfy. `timedOutUnconfirmed` (it may have landed),
    /// `accepted` and `rejected` never are.
    static func fallsBack(after outcome: MessageSendOutcome) -> Bool {
        if case .sendFailed = outcome { return true }
        return false
    }

    private func recordPhoneOutcome(_ outcome: MessageSendOutcome) {
        let at = now()
        lock.lock()
        lastPhoneOutcome = outcome
        lastPhoneOutcomeAt = at
        lock.unlock()
    }

    /// Releases `lane`'s claim ONLY when `claim` is still that lane's live one.
    private func clear(_ claim: UInt64, on lane: NtfySendLane) {
        lock.lock()
        if generation[lane] == claim { sending[lane] = false }
        lock.unlock()
    }
}
