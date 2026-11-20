// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import CloudKit
import NapCatWire
import Testing
@testable import NapCat

/// Fixture store behind the CloudKit seam: records every account check and
/// save, answers from stubs, and can hold a save open (single-flight tests).
/// No container, no database, no iCloud — ever.
final class FakeAlertStore: CloudKitAlertStore, @unchecked Sendable {
    private let lock = NSLock()
    private var status: CKAccountStatus
    private var accountError: (any Error)?
    private var saveError: (any Error)?
    private var defersSaves = false
    private var savedPayloads: [CloudKitAlertPayload] = []
    private var checks = 0
    private var pending: [@Sendable ((any Error)?) -> Void] = []

    init(status: CKAccountStatus = .available, accountError: (any Error)? = nil, saveError: (any Error)? = nil) {
        self.status = status
        self.accountError = accountError
        self.saveError = saveError
    }

    var saved: [CloudKitAlertPayload] {
        lock.lock()
        defer { lock.unlock() }
        return savedPayloads
    }

    var accountChecks: Int {
        lock.lock()
        defer { lock.unlock() }
        return checks
    }

    func holdSaves() {
        lock.lock()
        defersSaves = true
        lock.unlock()
    }

    /// Completes the oldest held save.
    func completeHeldSave(with error: (any Error)? = nil) {
        lock.lock()
        let completion = pending.isEmpty ? nil : pending.removeFirst()
        lock.unlock()
        completion?(error)
    }

    func accountStatus(completion: @escaping @Sendable (CKAccountStatus, (any Error)?) -> Void) {
        lock.lock()
        checks += 1
        let answer = (status, accountError)
        lock.unlock()
        completion(answer.0, answer.1)
    }

    func save(_ payload: CloudKitAlertPayload, completion: @escaping @Sendable ((any Error)?) -> Void) {
        lock.lock()
        savedPayloads.append(payload)
        if defersSaves {
            pending.append(completion)
            lock.unlock()
            return
        }
        let error = saveError
        lock.unlock()
        completion(error)
    }
}

/// Thread-safe sink for completion outcomes.
final class OutcomeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [MessageSendOutcome] = []

    func append(_ outcome: MessageSendOutcome) {
        lock.lock()
        stored.append(outcome)
        lock.unlock()
    }

    var values: [MessageSendOutcome] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Counts how often a factory / probe closure ran.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func bump() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// F3 stage 1 — the CloudKit sender, fixture-driven end to end. No test here
/// (or anywhere) constructs a CKContainer or talks to iCloud: the store is a
/// `FakeAlertStore`, and the one test that touches the production defaults
/// first requires this process to be unentitled, where the probe stops
/// everything before a container could be built.
struct CloudKitMessageSenderTests {
    static let destination = NtfyDestination(server: "https://ntfy.sh", topic: "napcat-cloudkit-tests")
    static let firedAt = Date(timeIntervalSince1970: 1_800_000_123.5)

    static func ck(_ code: CKError.Code, underlying: (any Error)? = nil) -> NSError {
        var info: [String: Any] = [:]
        if let underlying { info[NSUnderlyingErrorKey] = underlying }
        return NSError(domain: CKErrorDomain, code: code.rawValue, userInfo: info)
    }

    static func partial(_ errors: [NSError]) -> NSError {
        var byID: [CKRecord.ID: NSError] = [:]
        for (index, error) in errors.enumerated() { byID[CKRecord.ID(recordName: "r\(index)")] = error }
        return NSError(domain: CKErrorDomain, code: CKError.Code.partialFailure.rawValue,
                       userInfo: [CKPartialErrorsByItemIDKey: byID])
    }

    static func url(_ code: URLError.Code) -> NSError {
        NSError(domain: NSURLErrorDomain, code: code.rawValue)
    }

    // MARK: - Outcome mapping (frozen F3 ADR)

    struct SaveRow: CustomTestStringConvertible, Sendable {
        let name: String
        let error: NSError?
        let expected: MessageSendOutcome
        var testDescription: String { name }
    }

    static let saveRows: [SaveRow] = [
        SaveRow(name: "saved", error: nil, expected: .accepted),
        // Definitive: nothing was committed — safe to fall back to ntfy.
        SaveRow(name: "networkUnavailable", error: ck(.networkUnavailable),
                expected: .sendFailed(CloudKitMessageSender.noInternetText)),
        SaveRow(name: "networkFailure", error: ck(.networkFailure),
                expected: .sendFailed(CloudKitMessageSender.unreachableText)),
        SaveRow(name: "notAuthenticated", error: ck(.notAuthenticated),
                expected: .sendFailed(CloudKitMessageSender.notSignedInText)),
        SaveRow(name: "accountTemporarilyUnavailable", error: ck(.accountTemporarilyUnavailable),
                expected: .sendFailed(CloudKitMessageSender.accountUnavailableText)),
        SaveRow(name: "badContainer", error: ck(.badContainer),
                expected: .sendFailed(CloudKitMessageSender.containerText)),
        SaveRow(name: "missingEntitlement", error: ck(.missingEntitlement),
                expected: .sendFailed(CloudKitMessageSender.notEntitledText)),
        // Rate limit / service down: definitive FOR THIS ATTEMPT.
        SaveRow(name: "requestRateLimited", error: ck(.requestRateLimited),
                expected: .sendFailed(CloudKitMessageSender.rateLimitedText)),
        SaveRow(name: "serviceUnavailable", error: ck(.serviceUnavailable),
                expected: .sendFailed(CloudKitMessageSender.serviceUnavailableText)),
        // Owner ruling (g), 2026-11-20: iCloud refusing the request outright is
        // definitive too — nothing was stored (live evidence: the spike's
        // quotaExceeded(25) burst).
        SaveRow(name: "quotaExceeded", error: ck(.quotaExceeded),
                expected: .sendFailed(CloudKitMessageSender.quotaExceededText)),
        SaveRow(name: "serverRejectedRequest", error: ck(.serverRejectedRequest),
                expected: .sendFailed(CloudKitMessageSender.serverRejectedText)),
        SaveRow(name: "permissionFailure", error: ck(.permissionFailure),
                expected: .sendFailed(CloudKitMessageSender.permissionText)),
        SaveRow(name: "partialFailure(quotaExceeded)", error: partial([ck(.quotaExceeded)]),
                expected: .sendFailed(CloudKitMessageSender.quotaExceededText)),
        // …but a timeout underneath still wins (double-buzz rule).
        SaveRow(name: "quotaExceeded over timedOut", error: ck(.quotaExceeded, underlying: url(.timedOut)),
                expected: .timedOutUnconfirmed),
        // A pre-connect transport error underneath keeps the code's verdict.
        SaveRow(name: "networkFailure over notConnectedToInternet",
                error: ck(.networkFailure, underlying: url(.notConnectedToInternet)),
                expected: .sendFailed(CloudKitMessageSender.unreachableText)),
        // Timeouts are UNCONFIRMED whatever code carries them (double-buzz rule).
        SaveRow(name: "networkFailure over timedOut", error: ck(.networkFailure, underlying: url(.timedOut)),
                expected: .timedOutUnconfirmed),
        SaveRow(name: "networkUnavailable over connectionLost",
                error: ck(.networkUnavailable, underlying: url(.networkConnectionLost)),
                expected: .timedOutUnconfirmed),
        SaveRow(name: "serviceUnavailable over cancelled", error: ck(.serviceUnavailable, underlying: url(.cancelled)),
                expected: .timedOutUnconfirmed),
        // Unknown / possibly-landed → unconfirmed, never fallen back from.
        SaveRow(name: "operationCancelled", error: ck(.operationCancelled), expected: .timedOutUnconfirmed),
        SaveRow(name: "serverResponseLost", error: ck(.serverResponseLost), expected: .timedOutUnconfirmed),
        SaveRow(name: "internalError", error: ck(.internalError), expected: .timedOutUnconfirmed),
        SaveRow(name: "zoneBusy (not in the ADR list)", error: ck(.zoneBusy), expected: .timedOutUnconfirmed),
        SaveRow(name: "serverRecordChanged", error: ck(.serverRecordChanged), expected: .timedOutUnconfirmed),
        SaveRow(name: "limitExceeded (not in the ADR list)", error: ck(.limitExceeded), expected: .timedOutUnconfirmed),
        SaveRow(name: "a CloudKit code this SDK does not know",
                error: NSError(domain: CKErrorDomain, code: 9_999), expected: .timedOutUnconfirmed),
        SaveRow(name: "a bare URL timeout", error: url(.timedOut), expected: .timedOutUnconfirmed),
        SaveRow(name: "a bare URL no-internet (not a CloudKit verdict)", error: url(.notConnectedToInternet),
                expected: .timedOutUnconfirmed),
        SaveRow(name: "another domain", error: NSError(domain: "com.example", code: 3), expected: .timedOutUnconfirmed),
        // One-record batch: judged by the record's own error.
        SaveRow(name: "partialFailure(networkUnavailable)", error: partial([ck(.networkUnavailable)]),
                expected: .sendFailed(CloudKitMessageSender.noInternetText)),
        SaveRow(name: "partialFailure(serverResponseLost)", error: partial([ck(.serverResponseLost)]),
                expected: .timedOutUnconfirmed),
        SaveRow(name: "partialFailure of two", error: partial([ck(.networkUnavailable), ck(.networkFailure)]),
                expected: .timedOutUnconfirmed),
    ]

    @Test(arguments: saveRows)
    func saveOutcomeTable(_ row: SaveRow) {
        #expect(CloudKitMessageSender.classifySave(row.error) == row.expected)
    }

    /// The definitive list is CLOSED: exactly these eleven codes are
    /// `sendFailed` — the ADR's eight plus owner ruling (g)'s three refusals
    /// (2026-11-20) — and every other code CloudKit can report is not.
    @Test func exactlyTheAdrCodesAreDefinitive() {
        let definitive: Set<Int> = Set([
            CKError.Code.networkUnavailable, .networkFailure, .notAuthenticated, .accountTemporarilyUnavailable,
            .badContainer, .missingEntitlement, .requestRateLimited, .serviceUnavailable,
            .quotaExceeded, .serverRejectedRequest, .permissionFailure,
        ].map(\.rawValue))
        #expect(definitive.count == 11)
        #expect(definitive.contains(25), "quotaExceeded is code 25 — the spike's live evidence")
        var checked = 0
        for raw in 0...64 {
            guard let code = CKError.Code(rawValue: raw) else { continue }
            checked += 1
            #expect((CloudKitMessageSender.definitiveFailureText(code) != nil) == definitive.contains(raw),
                    "CKError code \(raw)")
        }
        #expect(checked >= 36, "vacuity: the CloudKit code space was enumerated")
    }

    /// Ruling (g) widened the list by name, not by default: a code OUTSIDE
    /// it — one this SDK lists but the ADR does not, or one a future SDK adds
    /// — still classifies as unconfirmed (no ntfy fallback, so no double
    /// buzz), including inside a one-record batch and at the account check.
    @Test func anUnlistedCodeStaysUnconfirmed() {
        for code in [CKError.Code.zoneBusy, .limitExceeded, .serverRecordChanged, .changeTokenExpired] {
            #expect(CloudKitMessageSender.definitiveFailureText(code) == nil, "code \(code.rawValue)")
            #expect(CloudKitMessageSender.classifySave(Self.ck(code)) == .timedOutUnconfirmed, "code \(code.rawValue)")
        }
        // Far past every code CloudKit defines. An imported NS_ENUM accepts any
        // raw value, so the code reaches `definitiveFailureText` as an unknown case.
        let unknownRaw = 9_999
        #expect(CKError.Code(rawValue: unknownRaw).flatMap(CloudKitMessageSender.definitiveFailureText) == nil)
        let unknown = NSError(domain: CKErrorDomain, code: unknownRaw)
        #expect(CloudKitMessageSender.classifySave(unknown) == .timedOutUnconfirmed)
        #expect(CloudKitMessageSender.classifySave(Self.partial([unknown])) == .timedOutUnconfirmed)
        // Before anything is saved even an unknown error refuses, with the
        // generic account sentence — never a new code's own text.
        #expect(CloudKitMessageSender.accountRefusal(status: .available, error: unknown)
                == .sendFailed(CloudKitMessageSender.accountUncheckedText))
    }

    /// Every failure text is fixed, distinct where it should be, and free of
    /// anything resembling an address or a secret.
    @Test func theFailureVocabularyIsFixedText() {
        let texts = [CloudKitMessageSender.notEntitledText, CloudKitMessageSender.storeUnavailableText,
                     CloudKitMessageSender.noInternetText, CloudKitMessageSender.unreachableText,
                     CloudKitMessageSender.notSignedInText, CloudKitMessageSender.restrictedText,
                     CloudKitMessageSender.accountUnavailableText, CloudKitMessageSender.accountUncheckedText,
                     CloudKitMessageSender.containerText, CloudKitMessageSender.rateLimitedText,
                     CloudKitMessageSender.serviceUnavailableText, CloudKitMessageSender.quotaExceededText,
                     CloudKitMessageSender.serverRejectedText, CloudKitMessageSender.permissionText,
                     CloudKitMessageSender.busyLaneText]
        #expect(Set(texts).count == texts.count)
        for text in texts {
            #expect(!text.isEmpty)
            for token in ["http", "/", "topic", "iCloud.com", "%", "\\("] {
                #expect(!text.contains(token), "'\(token)' in '\(text)'")
            }
        }
    }

    struct AccountRow: CustomTestStringConvertible, Sendable {
        let name: String
        let status: CKAccountStatus
        let error: NSError?
        let expected: MessageSendOutcome?
        var testDescription: String { name }
    }

    static let accountRows: [AccountRow] = [
        AccountRow(name: "available", status: .available, error: nil, expected: nil),
        AccountRow(name: "noAccount", status: .noAccount, error: nil,
                   expected: .sendFailed(CloudKitMessageSender.notSignedInText)),
        AccountRow(name: "restricted", status: .restricted, error: nil,
                   expected: .sendFailed(CloudKitMessageSender.restrictedText)),
        AccountRow(name: "temporarilyUnavailable", status: .temporarilyUnavailable, error: nil,
                   expected: .sendFailed(CloudKitMessageSender.accountUnavailableText)),
        AccountRow(name: "couldNotDetermine", status: .couldNotDetermine, error: nil,
                   expected: .sendFailed(CloudKitMessageSender.accountUncheckedText)),
        AccountRow(name: "error: networkUnavailable", status: .couldNotDetermine, error: ck(.networkUnavailable),
                   expected: .sendFailed(CloudKitMessageSender.noInternetText)),
        // Nothing was saved yet, so even an "unknown" error is definitive here.
        AccountRow(name: "error: serverResponseLost", status: .couldNotDetermine, error: ck(.serverResponseLost),
                   expected: .sendFailed(CloudKitMessageSender.accountUncheckedText)),
        AccountRow(name: "error over a timeout", status: .available,
                   error: ck(.networkFailure, underlying: url(.timedOut)),
                   expected: .sendFailed(CloudKitMessageSender.accountUncheckedText)),
    ]

    @Test(arguments: accountRows)
    func accountCheckTable(_ row: AccountRow) {
        #expect(CloudKitMessageSender.accountRefusal(status: row.status, error: row.error) == row.expected)
    }

    // MARK: - The send path, through the seam

    static func sender(store: FakeAlertStore?, entitled: Bool = true,
                       builds: CallCounter = CallCounter()) -> CloudKitMessageSender {
        CloudKitMessageSender(isEntitled: { entitled }, makeStore: {
            builds.bump()
            return store
        })
    }

    @Test func aSavedRecordIsAcceptedAndCarriesTheTemplateBody() throws {
        let store = FakeAlertStore()
        let outcomes = OutcomeLog()
        let sender = Self.sender(store: store)
        let kind = LidGuardMessageKind.sessionFinished(minutes: 42, folded: 1, stillWorking: 1)
        sender.send(kind, to: Self.destination, at: Self.firedAt) { outcomes.append($0) }
        #expect(outcomes.values == [.accepted])
        #expect(store.accountChecks == 1)
        #expect(store.saved.count == 1)
        let payload = try #require(store.saved.first)
        #expect(payload.body == LidGuardPolicy.messageBody(kind: kind, clockTime: LidGuardPolicy.clockTime(Self.firedAt)))
        #expect(payload.lane == .session)
        #expect(payload.firedAt == Self.firedAt)
        #expect(payload.recordName == "session-1800000123500")
    }

    @Test func anUnavailableAccountIsDefinitiveAndNothingIsSaved() {
        for status: CKAccountStatus in [.noAccount, .restricted, .temporarilyUnavailable, .couldNotDetermine] {
            let store = FakeAlertStore(status: status)
            let outcomes = OutcomeLog()
            Self.sender(store: store).send(.test, to: Self.destination, at: Self.firedAt) { outcomes.append($0) }
            #expect(store.saved.isEmpty, "status \(status.rawValue): nothing may be saved")
            if case .sendFailed? = outcomes.values.first {} else {
                Issue.record("status \(status.rawValue) must be a definitive failure, got \(outcomes.values)")
            }
        }
    }

    @Test func aSaveErrorIsClassifiedThroughTheTable() {
        for row in Self.saveRows {
            let store = FakeAlertStore(saveError: row.error)
            let outcomes = OutcomeLog()
            Self.sender(store: store).send(.lidAlert(busySessionCount: 1), to: Self.destination,
                                           at: Self.firedAt) { outcomes.append($0) }
            #expect(outcomes.values == [row.expected], "\(row.name)")
        }
    }

    /// The probe gates EVERYTHING: an unentitled sender refuses inline and
    /// never even asks for a store, so no container can be built.
    @Test func anUnentitledSenderNeverBuildsAStore() {
        let builds = CallCounter()
        let store = FakeAlertStore()
        let outcomes = OutcomeLog()
        let sender = Self.sender(store: store, entitled: false, builds: builds)
        sender.send(.test, to: Self.destination, at: Self.firedAt) { outcomes.append($0) }
        #expect(outcomes.values == [.sendFailed(CloudKitMessageSender.notEntitledText)])
        #expect(builds.count == 0)
        #expect(store.accountChecks == 0 && store.saved.isEmpty)
    }

    @Test func aMissingStoreIsDefinitive() {
        let outcomes = OutcomeLog()
        Self.sender(store: nil).send(.test, to: Self.destination, at: Self.firedAt) { outcomes.append($0) }
        #expect(outcomes.values == [.sendFailed(CloudKitMessageSender.storeUnavailableText)])
    }

    @Test func theStoreIsBuiltOnceAndReused() {
        let builds = CallCounter()
        let store = FakeAlertStore()
        let sender = Self.sender(store: store, builds: builds)
        for second in 0..<3 {
            sender.send(.test, to: Self.destination, at: Self.firedAt.addingTimeInterval(Double(second))) { _ in }
        }
        #expect(builds.count == 1)
        #expect(store.saved.count == 3)
    }

    /// Per-lane single flight, mirroring the ntfy sender: a busy lane refuses
    /// inline, the other lane is unaffected, and the claim is released when
    /// the save completes.
    @Test func eachLaneIsSingleFlight() {
        let store = FakeAlertStore()
        store.holdSaves()
        let sender = Self.sender(store: store)
        let first = OutcomeLog()
        let second = OutcomeLog()
        let otherLane = OutcomeLog()
        sender.send(.needsAttention(minutes: 3, stillWorking: 0), to: Self.destination, at: Self.firedAt) {
            first.append($0)
        }
        sender.send(.sessionFinished(minutes: 4, folded: 1, stillWorking: 0), to: Self.destination,
                    at: Self.firedAt.addingTimeInterval(1)) { second.append($0) }
        #expect(second.values == [.sendFailed(CloudKitMessageSender.busyLaneText)], "same lane refused inline")
        sender.send(.lidAlert(busySessionCount: 1), to: Self.destination, at: Self.firedAt) { otherLane.append($0) }
        #expect(store.saved.count == 2, "the lid lane is not blocked by the session lane")
        store.completeHeldSave()
        store.completeHeldSave()
        #expect(first.values == [.accepted])
        #expect(otherLane.values == [.accepted])
        let third = OutcomeLog()
        store.completeHeldSave()
        sender.send(.sessionFinished(minutes: 5, folded: 1, stillWorking: 0), to: Self.destination,
                    at: Self.firedAt.addingTimeInterval(2)) { third.append($0) }
        #expect(store.saved.count == 3, "the session lane is free again")
        store.completeHeldSave()
        #expect(third.values == [.accepted])
    }

    // MARK: - Entitlement probe

    struct ProbeRow: CustomTestStringConvertible, Sendable {
        let name: String
        let services: [String]?
        let containers: [String]?
        let expected: Bool
        var testDescription: String { name }
    }

    static let probeRows: [ProbeRow] = [
        ProbeRow(name: "both granted", services: ["CloudKit"], containers: [AlertWire.containerIdentifier],
                 expected: true),
        ProbeRow(name: "among others", services: ["CloudDocuments", "CloudKit"],
                 containers: ["iCloud.com.example.other", AlertWire.containerIdentifier], expected: true),
        ProbeRow(name: "no services", services: nil, containers: [AlertWire.containerIdentifier], expected: false),
        ProbeRow(name: "no containers", services: ["CloudKit"], containers: nil, expected: false),
        ProbeRow(name: "documents only", services: ["CloudDocuments"], containers: [AlertWire.containerIdentifier],
                 expected: false),
        ProbeRow(name: "another container", services: ["CloudKit"], containers: ["iCloud.com.example.other"],
                 expected: false),
        ProbeRow(name: "empty", services: [], containers: [], expected: false),
        ProbeRow(name: "unentitled process", services: nil, containers: nil, expected: false),
    ]

    @Test(arguments: probeRows)
    func probeDecisionTable(_ row: ProbeRow) {
        // Entitlement values arrive as CF arrays — bridge them the same way.
        let services: Any? = row.services.map { $0 as NSArray }
        let containers: Any? = row.containers.map { $0 as NSArray }
        #expect(CloudKitEntitlementProbe.grants(services: services, containers: containers) == row.expected)
    }

    @Test func aNonArrayEntitlementValueIsNotAGrant() {
        #expect(!CloudKitEntitlementProbe.grants(services: "CloudKit" as NSString,
                                                 containers: [AlertWire.containerIdentifier] as NSArray))
        #expect(!CloudKitEntitlementProbe.grants(services: ["CloudKit"] as NSArray,
                                                 containers: AlertWire.containerIdentifier as NSString))
    }

    @Test func theProbeReadsThePinnedEntitlementKeys() {
        #expect(CloudKitEntitlementProbe.servicesEntitlement == "com.apple.developer.icloud-services")
        #expect(CloudKitEntitlementProbe.containersEntitlement == "com.apple.developer.icloud-container-identifiers")
        #expect(CloudKitEntitlementProbe.cloudKitService == "CloudKit")
    }

    /// LIVE, in this (unentitled) test process: the probe says no, the
    /// production store factory therefore returns nil without building a
    /// container (which would trap the whole test run), and a
    /// default-constructed sender refuses inline.
    @Test func inThisUnentitledProcessTheGateHolds() throws {
        try #require(!CloudKitEntitlementProbe.isEntitled,
                     "the test runner must be unentitled — otherwise the calls below would reach iCloud")
        #expect(CloudKitMessageSender.makeLiveStore() == nil)
        let outcomes = OutcomeLog()
        CloudKitMessageSender().send(.test, to: Self.destination, at: Self.firedAt) { outcomes.append($0) }
        #expect(outcomes.values == [.sendFailed(CloudKitMessageSender.notEntitledText)])
    }
}
