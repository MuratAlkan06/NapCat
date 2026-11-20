import CloudKit
import Foundation
import NapCatWire
import os
import Security

/// SECOND SANCTIONED NETWORKING FILE (F3 stage 1, deliberate lint amendment):
/// the ONLY file that may import CloudKit or name a CloudKit symbol, and the
/// only one that reads this process's own entitlements. HTTP stays where it
/// was — `URLSession`/`URLRequest` remain confined to NtfyMessageSender.swift
/// (`LidGuardStructureTests` enforces both).
///
/// It writes one alert as one record into the owner's PRIVATE CloudKit
/// database (default zone of `AlertWire.containerIdentifier`):
///
///     record type  Alert
///     record name  <lane>-<epoch milliseconds>     (deterministic)
///     body         <the app-generated message>     String
///     lane         lid | session                   String
///     firedAt      <event time>                    Date
///
/// Nothing else: no session id, no ntfy topic, no ntfy server, no text from a
/// Claude session. `body` is built here by `LidGuardPolicy.messageBody` — the
/// very path NtfyMessageSender uses — from the closed `LidGuardMessageKind`,
/// so the phone receives byte-for-byte the text ntfy would have carried.
///
/// ENTITLEMENT GATE (spike-proven 2026-11-20): `CKContainer(identifier:)` does
/// not return an error in a process that lacks the iCloud entitlement — it
/// TRAPS (SIGTRAP, exit 133). Ad-hoc `make` builds are unentitled by design
/// (AMFI kills ad-hoc + restricted entitlements), so the container is built
/// in exactly ONE place, `makeLiveStore()`, behind
/// `CloudKitEntitlementProbe.isEntitled`, which reads the running process's
/// own entitlements and needs none itself. An unentitled process never
/// constructs a container.
///
/// OUTCOMES (frozen F3 ADR), in the shared `MessageSendOutcome` vocabulary:
/// - save committed → `accepted` (durably in iCloud; the push is async);
/// - a DEFINITIVE failure — nothing was committed and the composite may fall
///   back to ntfy without risking a double buzz → `sendFailed(<fixed text>)`:
///   no network, iCloud unreachable, not signed in / account unavailable,
///   container or entitlement problems, and — for this attempt — iCloud
///   rate-limiting or temporarily unavailable;
/// - a timeout, a lost response, or anything not listed → `timedOutUnconfirmed`
///   (the record may have landed; never retried, never fallen back).
///
/// PER-LANE SINGLE FLIGHT, mirroring NtfyMessageSender: a busy lane refuses a
/// second send inline; the other lane is unaffected.
///
/// UNPRIVILEGED — no sudo, no PLAN §4 command, no subprocess.
final class CloudKitMessageSender: MessageSender, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.muratalkan.napcat", category: "phone")

    // MARK: Fixed failure vocabulary (never an error's own message)

    static let notEntitledText = "this NapCat build is not entitled to use iCloud"
    static let storeUnavailableText = "iCloud is not available to this NapCat build"
    static let noInternetText = "this Mac had no internet connection"
    static let unreachableText = "iCloud could not be reached"
    static let notSignedInText = "this Mac is not signed in to iCloud"
    static let restrictedText = "iCloud is restricted on this Mac"
    static let accountUnavailableText = "the iCloud account is temporarily unavailable"
    static let accountUncheckedText = "the iCloud account could not be checked"
    static let containerText = "the NapCat iCloud container is not set up"
    static let rateLimitedText = "iCloud is rate-limiting this Mac"
    static let serviceUnavailableText = "iCloud is temporarily unavailable"
    static let busyLaneText = "another message is still being sent"

    private let isEntitled: @Sendable () -> Bool
    private let makeStore: @Sendable () -> (any CloudKitAlertStore)?
    private let lock = NSLock()
    /// Built lazily on the first entitled send, then reused.
    private var store: (any CloudKitAlertStore)?
    private var sending: [NtfySendLane: Bool] = [:]
    private var generation: [NtfySendLane: UInt64] = [:]

    /// Both parameters are TEST SEAMS. Production uses the cached probe and
    /// the probe-gated live store; a test injects a fixture store (and a probe
    /// answer) so no CloudKit object that talks to iCloud is ever built.
    init(
        isEntitled: @escaping @Sendable () -> Bool = { CloudKitEntitlementProbe.isEntitled },
        makeStore: @escaping @Sendable () -> (any CloudKitAlertStore)? = { CloudKitMessageSender.makeLiveStore() }
    ) {
        self.isEntitled = isEntitled
        self.makeStore = makeStore
    }

    /// THE ONE place a CKContainer is constructed — and only after the probe
    /// confirmed this process is entitled (an unentitled construction traps).
    /// `PhoneTransportStructureTests` locks both the single site and the
    /// guard in front of it.
    static func makeLiveStore() -> (any CloudKitAlertStore)? {
        guard CloudKitEntitlementProbe.isEntitled else { return nil }
        return LiveCloudKitAlertStore(container: CKContainer(identifier: AlertWire.containerIdentifier))
    }

    // MARK: - Record construction (pure — unit-tested without iCloud)

    /// The wire value of a send lane.
    static func wireLane(_ lane: NtfySendLane) -> AlertWire.Lane {
        switch lane {
        case .lid: return .lid
        case .session: return .session
        }
    }

    /// Deterministic: `<lane>-<epoch milliseconds>`. A retry of the same
    /// message names the same record. Never a session id, never the topic.
    static func recordName(lane: AlertWire.Lane, firedAt: Date) -> String {
        let millis = Int64((firedAt.timeIntervalSince1970 * 1000).rounded(.down))
        return "\(lane.rawValue)-\(millis)"
    }

    /// The ONLY constructor of a `CloudKitAlertPayload`. The body comes from
    /// the same template NtfyMessageSender publishes — the closed kind plus
    /// the event clock time — so no caller text can reach a record.
    static func makePayload(kind: LidGuardMessageKind, firedAt: Date) -> CloudKitAlertPayload {
        let lane = wireLane(LidGuardPolicy.lane(for: kind))
        return CloudKitAlertPayload(
            recordName: recordName(lane: lane, firedAt: firedAt),
            body: LidGuardPolicy.messageBody(kind: kind, clockTime: LidGuardPolicy.clockTime(firedAt)),
            lane: lane,
            firedAt: firedAt
        )
    }

    /// The record for one payload: type `Alert`, the private database's
    /// DEFAULT zone, and exactly the three `AlertWire.Field`s.
    static func makeRecord(_ payload: CloudKitAlertPayload) -> CKRecord {
        let recordID = CKRecord.ID(recordName: payload.recordName, zoneID: CKRecordZone.ID.default)
        let record = CKRecord(recordType: AlertWire.recordType, recordID: recordID)
        record[AlertWire.Field.body.rawValue] = payload.body as NSString
        record[AlertWire.Field.lane.rawValue] = payload.lane.rawValue as NSString
        record[AlertWire.Field.firedAt.rawValue] = payload.firedAt as NSDate
        return record
    }

    // MARK: - Send

    func send(
        _ kind: LidGuardMessageKind,
        to destination: NtfyDestination,
        at firedAt: Date,
        completion: @escaping @Sendable (MessageSendOutcome) -> Void
    ) {
        // `destination` is the ntfy address. It is deliberately NOT used: an
        // iCloud record carries neither the topic nor the server.
        guard isEntitled() else {
            completion(.sendFailed(Self.notEntitledText))
            return
        }
        guard let store = resolvedStore() else {
            Self.logger.error("phone: the iCloud store could not be built")
            completion(.sendFailed(Self.storeUnavailableText))
            return
        }
        let payload = Self.makePayload(kind: kind, firedAt: firedAt)

        // SINGLE-FLIGHT PER LANE, exactly as the ntfy sender.
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

        // Account first: a save without an available account cannot succeed,
        // and NOTHING has left the Mac yet, so any refusal here is definitive.
        store.accountStatus { [weak self] status, error in
            if let refusal = Self.accountRefusal(status: status, error: error) {
                self?.clear(claim, on: lane)
                completion(refusal)
                return
            }
            store.save(payload) { [weak self] error in
                self?.clear(claim, on: lane)
                completion(Self.classifySave(error))
            }
        }
    }

    private func resolvedStore() -> (any CloudKitAlertStore)? {
        lock.lock()
        defer { lock.unlock() }
        if let store { return store }
        store = makeStore()
        return store
    }

    /// Releases `lane`'s claim ONLY when `claim` is still that lane's live one.
    private func clear(_ claim: UInt64, on lane: NtfySendLane) {
        lock.lock()
        if generation[lane] == claim { sending[lane] = false }
        lock.unlock()
    }

    // MARK: - Outcome classification (pure, fixture-tested)

    /// The account check, BEFORE anything is saved: `nil` = available, go
    /// ahead; anything else is a definitive `sendFailed` with a fixed text.
    static func accountRefusal(status: CKAccountStatus, error: (any Error)?) -> MessageSendOutcome? {
        if let error {
            if case .sendFailed(let detail) = classifySave(error) { return .sendFailed(detail) }
            return .sendFailed(accountUncheckedText)
        }
        switch status {
        case .available: return nil
        case .noAccount: return .sendFailed(notSignedInText)
        case .restricted: return .sendFailed(restrictedText)
        case .temporarilyUnavailable: return .sendFailed(accountUnavailableText)
        case .couldNotDetermine: return .sendFailed(accountUncheckedText)
        @unknown default: return .sendFailed(accountUncheckedText)
        }
    }

    /// One save's outcome (frozen F3 ADR):
    /// - no error → `accepted`;
    /// - a TIMEOUT-class transport error underneath (timed out, cancelled,
    ///   connection lost — `LidGuardPolicy.unconfirmedTransportErrorCodes`) →
    ///   `timedOutUnconfirmed`, whatever CloudKit code carries it: the record
    ///   may have landed, so it must never be fallen back from (double buzz);
    /// - a CloudKit code in the definitive list (`definitiveFailureText`) →
    ///   `sendFailed` with that code's fixed sentence;
    /// - anything else, any other error domain included → `timedOutUnconfirmed`.
    /// A one-record `partialFailure` is judged by the record's own error.
    static func classifySave(_ error: (any Error)?) -> MessageSendOutcome {
        guard let error else { return .accepted }
        let nsError = recordLevelError(error as NSError)
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSURLErrorDomain,
           LidGuardPolicy.unconfirmedTransportErrorCodes.contains(underlying.code) {
            return .timedOutUnconfirmed
        }
        guard nsError.domain == CKErrorDomain,
              let code = CKError.Code(rawValue: nsError.code),
              let detail = definitiveFailureText(code) else {
            return .timedOutUnconfirmed
        }
        return .sendFailed(detail)
    }

    /// The DEFINITIVE codes (nothing was committed), each with a fixed,
    /// secret-free sentence; nil for every other code.
    static func definitiveFailureText(_ code: CKError.Code) -> String? {
        switch code {
        case .networkUnavailable: return noInternetText
        case .networkFailure: return unreachableText
        case .notAuthenticated: return notSignedInText
        case .accountTemporarilyUnavailable: return accountUnavailableText
        case .badContainer: return containerText
        case .missingEntitlement: return notEntitledText
        case .requestRateLimited: return rateLimitedText
        case .serviceUnavailable: return serviceUnavailableText
        default: return nil
        }
    }

    /// A batch `partialFailure` around exactly ONE record error is that
    /// record's error; anything else is returned unchanged.
    static func recordLevelError(_ error: NSError) -> NSError {
        guard error.domain == CKErrorDomain, error.code == CKError.Code.partialFailure.rawValue,
              let partial = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Any],
              partial.count == 1, let only = partial.values.first as? NSError else {
            return error
        }
        return only
    }
}

// MARK: - The payload and the CloudKit seam

/// One alert on its way to iCloud. Built ONLY by
/// `CloudKitMessageSender.makePayload(kind:firedAt:)`; its fields map 1:1 onto
/// the three `AlertWire.Field`s (plus the record name), and nothing else.
struct CloudKitAlertPayload: Equatable, Sendable {
    let recordName: String
    let body: String
    let lane: AlertWire.Lane
    let firedAt: Date
}

/// THE seam over CloudKit I/O: the account check and the one-record save.
/// Production is `LiveCloudKitAlertStore` (probe-gated); tests inject a
/// fixture, so no test ever talks to iCloud or builds a container. The save
/// takes a payload — never a String.
protocol CloudKitAlertStore: AnyObject, Sendable {
    func accountStatus(completion: @escaping @Sendable (CKAccountStatus, (any Error)?) -> Void)
    func save(_ payload: CloudKitAlertPayload, completion: @escaping @Sendable ((any Error)?) -> Void)
}

/// The real store: the owner's private database, one record per save, with
/// the same request/resource ceiling as an ntfy publish and user-initiated
/// priority (a discretionary operation could be parked until some later
/// network — we want a fast, honest answer).
private final class LiveCloudKitAlertStore: CloudKitAlertStore, @unchecked Sendable {
    private let container: CKContainer
    private let database: CKDatabase

    init(container: CKContainer) {
        self.container = container
        self.database = container.privateCloudDatabase
    }

    func accountStatus(completion: @escaping @Sendable (CKAccountStatus, (any Error)?) -> Void) {
        container.accountStatus { status, error in completion(status, error) }
    }

    func save(_ payload: CloudKitAlertPayload, completion: @escaping @Sendable ((any Error)?) -> Void) {
        let operation = CKModifyRecordsOperation(
            recordsToSave: [CloudKitMessageSender.makeRecord(payload)],
            recordIDsToDelete: nil
        )
        // A new record only — never overwrite one that already exists.
        operation.savePolicy = .ifServerRecordUnchanged
        operation.isAtomic = true
        let configuration = CKOperation.Configuration()
        configuration.qualityOfService = .userInitiated
        configuration.isLongLived = false
        configuration.timeoutIntervalForRequest = LidGuardTuning.requestTimeout
        configuration.timeoutIntervalForResource = LidGuardTuning.requestTimeout
        operation.configuration = configuration
        let recordError = RecordErrorBox()
        operation.perRecordSaveBlock = { _, result in
            if case .failure(let error) = result { recordError.set(error) }
        }
        operation.modifyRecordsResultBlock = { result in
            switch result {
            case .success: completion(nil)
            case .failure(let error): completion(recordError.value ?? error)
            }
        }
        database.add(operation)
    }
}

/// Holds the one record's own error until the batch result arrives.
private final class RecordErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (any Error)?

    func set(_ error: any Error) {
        lock.lock()
        stored = error
        lock.unlock()
    }

    var value: (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

// MARK: - Entitlement probe

/// Reads THIS process's own iCloud entitlements — unprivileged, works in an
/// unentitled process, touches no daemon and no network. Entitled means BOTH
/// the CloudKit service and NapCat's container are granted; anything else
/// (ad-hoc `make` builds, the test runner) is unentitled.
enum CloudKitEntitlementProbe {
    static let servicesEntitlement = "com.apple.developer.icloud-services"
    static let containersEntitlement = "com.apple.developer.icloud-container-identifiers"
    static let cloudKitService = "CloudKit"

    /// Evaluated ONCE per process, on first use, then cached: a process's
    /// entitlements cannot change while it runs.
    static let isEntitled: Bool = grants(
        services: entitlementValue(servicesEntitlement),
        containers: entitlementValue(containersEntitlement)
    )

    /// Pure decision over the two raw entitlement values (table-tested).
    static func grants(services: Any?, containers: Any?) -> Bool {
        guard let services = services as? [String], services.contains(cloudKitService) else { return false }
        guard let containers = containers as? [String],
              containers.contains(AlertWire.containerIdentifier) else { return false }
        return true
    }

    private static func entitlementValue(_ key: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil)
    }
}
