// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import CloudKit
import Testing
@testable import NapCat

/// Plays CloudKit's part on the REAL save operation: builds it with
/// `CloudKitMessageSender.makeSaveOperation` (exactly what the live store adds
/// to the database), then fires the operation's own callbacks by hand, in
/// CloudKit's documented order — each per-record result, then the batch
/// result. No container, no database, nothing leaves the process.
final class OperationDrivenStore: CloudKitAlertStore, @unchecked Sendable {
    enum Step: Sendable {
        case recordSaved
        case recordFailed(NSError)
        case batchSucceeded
        case batchFailed(NSError)
    }

    let steps: [Step]

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func accountStatus(completion: @escaping @Sendable (CKAccountStatus, (any Error)?) -> Void) {
        completion(.available, nil)
    }

    func save(_ payload: CloudKitAlertPayload, completion: @escaping @Sendable ((any Error)?) -> Void) {
        let operation = CloudKitMessageSender.makeSaveOperation(payload, completion: completion)
        guard let record = operation.recordsToSave?.first else {
            Issue.record("the save operation carries no record")
            return
        }
        for step in steps {
            switch step {
            case .recordSaved: operation.perRecordSaveBlock?(record.recordID, .success(record))
            case .recordFailed(let error): operation.perRecordSaveBlock?(record.recordID, .failure(error))
            case .batchSucceeded: operation.modifyRecordsResultBlock?(.success(()))
            case .batchFailed(let error): operation.modifyRecordsResultBlock?(.failure(error))
            }
        }
    }
}

/// Issue #139 — the phone lane honours the RECORD's own result. Live
/// evidence (2026-11-23): CloudKit reported batch success around records it
/// had refused (the default zone ignores `isAtomic`), the Mac logged
/// "iCloud outcome accepted — no ntfy fallback", and every alert for 24 h
/// went nowhere.
struct CloudKitRecordResultTests {
    static let destination = NtfyDestination(server: "https://ntfy.sh", topic: "napcat-record-result-tests")
    static let firedAt = Date(timeIntervalSince1970: 1_800_000_456.25)

    static func ck(_ code: CKError.Code) -> NSError { CloudKitMessageSenderTests.ck(code) }

    // MARK: - The table: per-record result × batch result

    struct ResultRow: CustomTestStringConvertible, Sendable {
        let name: String
        let steps: [OperationDrivenStore.Step]
        let expected: MessageSendOutcome
        /// Whether the composite must then try ntfy — stated, not derived.
        let fallsBack: Bool
        var testDescription: String { name }
    }

    static let resultRows: [ResultRow] = [
        // THE LIVE BUG: a refused record inside a successful batch.
        ResultRow(name: "record refused (quotaExceeded) + batch success",
                  steps: [.recordFailed(ck(.quotaExceeded)), .batchSucceeded],
                  expected: .sendFailed(CloudKitMessageSender.quotaExceededText), fallsBack: true),
        ResultRow(name: "record refused (serverRejectedRequest) + batch success",
                  steps: [.recordFailed(ck(.serverRejectedRequest)), .batchSucceeded],
                  expected: .sendFailed(CloudKitMessageSender.serverRejectedText), fallsBack: true),
        // Codes OUTSIDE the definitive list are still the record's own verdict.
        ResultRow(name: "record refused (internalError, unlisted) + batch success",
                  steps: [.recordFailed(ck(.internalError)), .batchSucceeded],
                  expected: .sendFailed(CloudKitMessageSender.refusedText), fallsBack: true),
        ResultRow(name: "record refused (invalidArguments, unlisted) + batch success",
                  steps: [.recordFailed(ck(.invalidArguments)), .batchSucceeded],
                  expected: .sendFailed(CloudKitMessageSender.refusedText), fallsBack: true),
        ResultRow(name: "record refused (a code this SDK does not know) + batch success",
                  steps: [.recordFailed(NSError(domain: CKErrorDomain, code: 9_999)), .batchSucceeded],
                  expected: .sendFailed(CloudKitMessageSender.refusedText), fallsBack: true),
        // A timeout UNDER the record's own failure is still the record's
        // verdict: the batch-level timeout rule never reaches it.
        ResultRow(name: "record refused (networkFailure over a timed-out connection) + batch success",
                  steps: [.recordFailed(CloudKitMessageSenderTests.ck(
                              .networkFailure, underlying: CloudKitMessageSenderTests.url(.timedOut))),
                          .batchSucceeded],
                  expected: .sendFailed(CloudKitMessageSender.unreachableText), fallsBack: true),
        // Plain success: the record said saved, the batch agreed.
        ResultRow(name: "record saved + batch success", steps: [.recordSaved, .batchSucceeded],
                  expected: .accepted, fallsBack: false),
        // Nothing confirms the record landed.
        ResultRow(name: "batch success with no per-record result", steps: [.batchSucceeded],
                  expected: .sendFailed(CloudKitMessageSender.unconfirmedSaveText), fallsBack: true),
        // Batch-level errors keep the existing table.
        ResultRow(name: "batch failure (serverResponseLost), no per-record result",
                  steps: [.batchFailed(ck(.serverResponseLost))], expected: .timedOutUnconfirmed, fallsBack: false),
        ResultRow(name: "batch failure (networkUnavailable), no per-record result",
                  steps: [.batchFailed(ck(.networkUnavailable))],
                  expected: .sendFailed(CloudKitMessageSender.noInternetText), fallsBack: true),
        ResultRow(name: "batch failure (internalError), no per-record result",
                  steps: [.batchFailed(ck(.internalError))], expected: .timedOutUnconfirmed, fallsBack: false),
        ResultRow(name: "record saved + batch failure (internalError)",
                  steps: [.recordSaved, .batchFailed(ck(.internalError))], expected: .timedOutUnconfirmed,
                  fallsBack: false),
        // …but a record that reported its own failure is judged by it.
        ResultRow(name: "record refused (internalError) + batch failure",
                  steps: [.recordFailed(ck(.internalError)),
                          .batchFailed(CloudKitMessageSenderTests.partial([ck(.internalError)]))],
                  expected: .sendFailed(CloudKitMessageSender.refusedText), fallsBack: true),
    ]

    /// An isolated defaults suite with the phone toggle ON (removed on exit).
    static func withPhoneEnabled(_ body: (UserDefaults) -> Void) {
        let suite = "com.muratalkan.napcat.tests.recordresult.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: DefaultsKey.phoneTransportEnabled)
        body(defaults)
    }

    static func cloudKitSender(_ steps: [OperationDrivenStore.Step]) -> CloudKitMessageSender {
        let store = OperationDrivenStore(steps)
        return CloudKitMessageSender(isEntitled: { true }, makeStore: { store })
    }

    /// The CloudKit sender's own outcome, and — through the composite — the
    /// ntfy fallback it does or does not trigger.
    @Test(arguments: resultRows)
    func theRecordsOwnResultDecides(_ row: ResultRow) {
        let direct = OutcomeLog()
        Self.cloudKitSender(row.steps).send(.lidAlert(busySessionCount: 1), to: Self.destination,
                                            at: Self.firedAt) { direct.append($0) }
        #expect(direct.values == [row.expected], "the CloudKit sender's outcome")
        #expect(CompositeMessageSender.fallsBack(after: row.expected) == row.fallsBack, "the table's fallback column")

        Self.withPhoneEnabled { defaults in
            let log = TransportLog()
            let ntfy = ScriptedSender("ntfy", log: log, outcome: .rejected(503))
            let composite = CompositeMessageSender(ntfy: ntfy, phone: Self.cloudKitSender(row.steps),
                                                   defaults: defaults, isEntitled: { true },
                                                   now: { 1_800_000_500 })
            let kind = LidGuardMessageKind.sessionFinished(minutes: 7, folded: 1, stillWorking: 0)
            let outcomes = OutcomeLog()
            composite.send(kind, to: Self.destination, at: Self.firedAt) { outcomes.append($0) }
            #expect(composite.phoneSnapshot.lastOutcome == row.expected, "the phone outcome the panel shows")
            if row.fallsBack {
                #expect(ntfy.sends == [RecordedMessageSend(kind: kind, destination: Self.destination,
                                                           firedAt: Self.firedAt)],
                        "the same alert must go out over ntfy")
                #expect(outcomes.values == [.rejected(503)], "the caller sees the ntfy fallback's outcome")
            } else {
                #expect(ntfy.sends.isEmpty, "no ntfy fallback")
                #expect(outcomes.values == [row.expected])
            }
        }
    }

    /// A batch-level error with no per-record failure is classified exactly as
    /// before — every row of the existing save table, with or without a
    /// per-record success in front of it. (Batch `partialFailure` rows are
    /// skipped: CloudKit's own Result overlay never delivers one to the result
    /// block — see `aBatchPartialFailureIsNeverAccepted`.)
    @Test func everyBatchLevelErrorKeepsTheExistingMapping() {
        var checked = 0
        for row in CloudKitMessageSenderTests.saveRows {
            guard let error = row.error, error.code != CKError.Code.partialFailure.rawValue else { continue }
            for steps: [OperationDrivenStore.Step] in [[.batchFailed(error)], [.recordSaved, .batchFailed(error)]] {
                let outcomes = OutcomeLog()
                Self.cloudKitSender(steps).send(.test, to: Self.destination, at: Self.firedAt) {
                    outcomes.append($0)
                }
                #expect(outcomes.values == [row.expected], "\(row.name) / \(steps.count) step(s)")
                checked += 1
            }
        }
        #expect(checked >= 40, "vacuity: the save table was replayed")
    }

    /// CloudKit's Result overlay hands a batch `partialFailure` to the result
    /// block as SUCCESS (observed on the macOS 27.2 SDK while writing this
    /// test) — the very path issue #139 lived on: the record's own failure
    /// went to the per-record callback, the batch said success, and the old
    /// code said accepted. Whatever the overlay does with it, a partial
    /// failure is never accepted, and with the record's own failure in front
    /// (CloudKit's documented order) the record decides.
    @Test func aBatchPartialFailureIsNeverAccepted() {
        for inner in [Self.ck(.quotaExceeded), Self.ck(.internalError), Self.ck(.serverResponseLost)] {
            let partial = CloudKitMessageSenderTests.partial([inner])
            let alone = OutcomeLog()
            Self.cloudKitSender([.batchFailed(partial)]).send(.test, to: Self.destination, at: Self.firedAt) {
                alone.append($0)
            }
            #expect(alone.values.count == 1 && alone.values != [.accepted], "code \(inner.code): \(alone.values)")
            let withRecord = OutcomeLog()
            Self.cloudKitSender([.recordFailed(inner), .batchFailed(partial)]).send(.test, to: Self.destination,
                                                                                    at: Self.firedAt) {
                withRecord.append($0)
            }
            #expect(withRecord.values == [.sendFailed(CloudKitMessageSender.refusalText(inner))], "code \(inner.code)")
        }
    }

    /// EVERY per-record failure is definitive — every code CloudKit defines,
    /// an unknown one and another domain: the definitive list's sentence where
    /// it has one, `refusedText` otherwise. Never unconfirmed, never accepted.
    @Test func everyPerRecordFailureIsDefinitive() {
        var errors: [NSError] = (0...64).compactMap { raw in
            CKError.Code(rawValue: raw).map { NSError(domain: CKErrorDomain, code: $0.rawValue) }
        }
        errors += [NSError(domain: CKErrorDomain, code: 9_999), NSError(domain: NSURLErrorDomain, code: -1001),
                   NSError(domain: "com.example", code: 3)]
        for error in errors {
            let expectedText = error.domain == CKErrorDomain
                ? CKError.Code(rawValue: error.code).flatMap(CloudKitMessageSender.definitiveFailureText)
                    ?? CloudKitMessageSender.refusedText
                : CloudKitMessageSender.refusedText
            for batch: OperationDrivenStore.Step in [.batchSucceeded, .batchFailed(error)] {
                let outcomes = OutcomeLog()
                Self.cloudKitSender([.recordFailed(error), batch]).send(.test, to: Self.destination,
                                                                        at: Self.firedAt) { outcomes.append($0) }
                #expect(outcomes.values == [.sendFailed(expectedText)], "\(error.domain) \(error.code)")
            }
        }
        #expect(errors.count >= 39, "vacuity: the CloudKit code space was enumerated")
        // The unlisted codes the gate named, spelled out.
        for code in [CKError.Code.internalError, .invalidArguments, .serverResponseLost, .zoneBusy] {
            #expect(CloudKitMessageSender.classifySave(CloudKitRecordRefusal(error: Self.ck(code)))
                    == .sendFailed(CloudKitMessageSender.refusedText), "code \(code.rawValue)")
        }
        #expect(CloudKitMessageSender.classifySave(CloudKitSaveUnconfirmed())
                == .sendFailed(CloudKitMessageSender.unconfirmedSaveText))
    }

    /// The refactor kept the operation's shape: one new record (the built
    /// payload's), never overwriting, atomic, user-initiated, short-lived,
    /// with the ntfy request ceiling.
    @Test func theSaveOperationKeepsItsShape() throws {
        let payload = CloudKitMessageSender.makePayload(kind: .test, firedAt: Self.firedAt)
        let operation = CloudKitMessageSender.makeSaveOperation(payload) { _ in }
        let records = try #require(operation.recordsToSave)
        #expect(records.map(\.recordID.recordName) == [payload.recordName])
        #expect(records.first?.recordID.zoneID == CKRecordZone.ID.default)
        #expect(operation.recordIDsToDelete == nil)
        #expect(operation.savePolicy == .ifServerRecordUnchanged)
        #expect(operation.isAtomic)
        #expect(operation.configuration.qualityOfService == .userInitiated)
        #expect(!operation.configuration.isLongLived)
        #expect(operation.configuration.timeoutIntervalForRequest == LidGuardTuning.requestTimeout)
        #expect(operation.configuration.timeoutIntervalForResource == LidGuardTuning.requestTimeout)
        #expect(operation.perRecordSaveBlock != nil && operation.modifyRecordsResultBlock != nil)
    }

    // MARK: - Source: the tested operation IS the one the live store adds

    static func cloudKitCode() throws -> String {
        try PhoneTransportSchemaTests.code(PhoneTransportSchemaTests.cloudKitFile)
    }

    @Test func theLiveStoreAddsTheTestedOperation() throws {
        let code = try Self.cloudKitCode()
        let count = PhoneTransportStructureTests.occurrences
        #expect(count("database.add(CloudKitMessageSender.makeSaveOperation(payload, completion: completion))", code) == 1)
        // S-PAIR-C1.5 (#170): the pairing record's live database adds the two
        // operations it is handed, and nothing else (PhoneTransportStructureTests).
        #expect(count("database.add(", code) == 3, "the live store adds exactly one kind of operation")
        #expect(count("database.add(operation)", code) == 2, "the pairing database adds what it is handed, at its two submits")
        #expect(count("CKModifyRecordsOperation(", code) == 1, "one operation site: makeSaveOperation")
        #expect(count(".perRecordSaveBlock = ", code) == 1)
        #expect(count(".modifyRecordsResultBlock = ", code) == 1)
    }

    // MARK: - The diagnostic log line (closed vocabulary)

    /// The per-record failure log call, byte-locked: its ONE interpolation is
    /// `diagnosticCode`, public. So the logged string is exactly
    /// `logPrefix + diagnosticCode(error)`, which the tests below pin down.
    static let logCall = ".error(\"phone: iCloud refused the alert: \\(Self.diagnosticCode(error), privacy: .public)\")"
    static let logPrefix = "phone: iCloud refused the alert: "

    /// EVERY log call in the CloudKit file, pinned: a CloudKit error reaches
    /// this file only, so a new log line here is a deliberate edit of this list.
    static let fileLogCalls = [
        ".error(\"phone: the iCloud store could not be built\")",
        logCall,
    ]

    @Test func thePerRecordFailureLogLineIsLocked() throws {
        let code = try Self.cloudKitCode()
        let calls = LidGuardStructureTests.logCalls(in: code).filter { $0.text.contains("diagnosticCode(") }
        #expect(calls.map(\.text) == [Self.logCall])
        #expect(Self.logCall.contains("\\(") && Self.logCall.components(separatedBy: "\\(").count == 2,
                "vacuity: exactly one interpolation")
        // It sits in the per-record callback, on the failure branch.
        let callback = try #require(PhoneTransportStructureTests.body(after: "operation.perRecordSaveBlock = {", in: code))
        #expect(callback.contains("if case .failure(let error) = result {") && callback.contains("Self.logger"),
                "the code is logged where CloudKit delivers the record's failure")
    }

    /// The locked line is the per-record callback's ONLY log call — nothing
    /// else there may log the error, in any form — and the CloudKit file logs
    /// exactly the pinned list.
    @Test func nothingElseLogsTheRecordsError() throws {
        let code = try Self.cloudKitCode()
        let callback = try #require(PhoneTransportStructureTests.body(after: "operation.perRecordSaveBlock = {", in: code))
        #expect(LidGuardStructureTests.logCalls(in: callback).map(\.text) == [Self.logCall],
                "the per-record callback logs exactly the locked line")
        #expect(PhoneTransportStructureTests.occurrences(of: "logger", in: callback) == 1,
                "one logger reference in the per-record callback")
        #expect(LidGuardStructureTests.logCalls(in: code).map(\.text) == Self.fileLogCalls,
                "the CloudKit file's log calls are exactly the pinned list")
    }

    struct CodeRow: CustomTestStringConvertible, Sendable {
        let error: NSError
        let expected: String
        var testDescription: String { expected }
    }

    static let codeRows: [CodeRow] = [
        CodeRow(error: ck(.quotaExceeded), expected: "quotaExceeded (25)"),
        CodeRow(error: ck(.internalError), expected: "internalError (1)"),
        CodeRow(error: ck(.invalidArguments), expected: "invalidArguments (12)"),
        CodeRow(error: ck(.serverRejectedRequest), expected: "serverRejectedRequest (15)"),
        CodeRow(error: ck(.accountTemporarilyUnavailable), expected: "accountTemporarilyUnavailable (36)"),
        CodeRow(error: NSError(domain: CKErrorDomain, code: 13), expected: "code 13"),
        CodeRow(error: NSError(domain: CKErrorDomain, code: 9_999), expected: "code 9999"),
        CodeRow(error: NSError(domain: NSURLErrorDomain, code: -1001), expected: "non-CloudKit code -1001"),
    ]

    @Test(arguments: codeRows)
    func theDiagnosticIsTheCodeNameAndNumber(_ row: CodeRow) {
        #expect(CloudKitMessageSender.diagnosticCode(row.error) == row.expected)
    }

    /// The closed switch names every code from 1 to 36 that exists (13 never
    /// did), and every output — named or not — has one of the three fixed
    /// shapes.
    @Test func theCodeNameSwitchIsClosedAndComplete() {
        var named: [Int] = []
        for raw in -2...64 {
            let error = NSError(domain: CKErrorDomain, code: raw)
            let line = CloudKitMessageSender.diagnosticCode(error)
            if let name = CKError.Code(rawValue: raw).flatMap(CloudKitMessageSender.codeName) {
                named.append(raw)
                #expect(line == "\(name) (\(raw))")
                #expect(name.range(of: "^[a-z][A-Za-z]+$", options: .regularExpression) != nil, "\(name)")
            } else {
                #expect(line == "code \(raw)")
            }
        }
        #expect(named == Array(1...12) + Array(14...36))
    }

    /// Fed an error that CARRIES the body, the topic, the server and the
    /// record name — in its description, its server description and its
    /// partial-error map — the logged string carries none of them, for every
    /// code.
    @Test func theLoggedStringNeverCarriesTheAlertOrTheAddress() {
        let topic = "napcat-secret-topic-139"
        let kind = LidGuardMessageKind.sessionFinished(minutes: 42, folded: 2, stillWorking: 1)
        let payload = CloudKitMessageSender.makePayload(kind: kind, firedAt: Self.firedAt)
        let leaky = "could not save \(payload.recordName) (\(payload.body)) for \(topic) at ntfy.example.com"
        var checked = 0
        for raw in [1, 2, 12, 14, 15, 25, 34, 9_999] {
            let error = NSError(domain: CKErrorDomain, code: raw, userInfo: [
                NSLocalizedDescriptionKey: leaky,
                NSLocalizedFailureReasonErrorKey: leaky,
                "ServerErrorDescription": leaky,
                CKPartialErrorsByItemIDKey: [CKRecord.ID(recordName: payload.recordName):
                    NSError(domain: CKErrorDomain, code: 25, userInfo: [NSLocalizedDescriptionKey: leaky])],
            ])
            #expect(error.localizedDescription.contains(topic), "vacuity: the error really carries the secrets")
            let logged = Self.logPrefix + CloudKitMessageSender.diagnosticCode(error)
            for secret in [payload.body, payload.recordName, topic, "ntfy.example.com", leaky, "could not save"] {
                #expect(!logged.contains(secret), "'\(secret)' in '\(logged)'")
            }
            for word in ["topic", "body", "lid-", "session-", "http"] {
                #expect(!logged.contains(word), "'\(word)' in '\(logged)'")
            }
            checked += 1
        }
        #expect(checked == 8)
    }
}
