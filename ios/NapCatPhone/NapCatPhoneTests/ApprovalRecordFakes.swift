import CloudKit
import Foundation
import Testing

/// F4 slice S3: plays CloudKit's part on a REAL `CKModifyRecordsOperation`
/// (the Mac's alert lane does the same since issue #139): the operation is
/// built by the code under test, then its own callbacks are fired by hand in
/// CloudKit's documented order — each per-record result, then the batch
/// result. No container, no database, nothing leaves the process.
struct ModifyOperationScript: Sendable {
    enum Step: Sendable {
        /// The `index`th record to save reported saved.
        case saved(Int)
        case saveFailed(Int, NSError)
        case batchSucceeded
        case batchFailed(NSError)
    }

    let steps: [Step]

    init(_ steps: [Step]) {
        self.steps = steps
    }

    /// Fires `steps` on `operation`; records an issue for a step that names
    /// a record the operation does not carry (a script that could never run).
    func run(on operation: CKModifyRecordsOperation) {
        let saves = operation.recordsToSave ?? []
        for step in steps {
            switch step {
            case .saved(let index):
                guard saves.indices.contains(index) else { Issue.record("no record \(index) to save"); return }
                operation.perRecordSaveBlock?(saves[index].recordID, .success(saves[index]))
            case .saveFailed(let index, let error):
                guard saves.indices.contains(index) else { Issue.record("no record \(index) to save"); return }
                operation.perRecordSaveBlock?(saves[index].recordID, .failure(error))
            case .batchSucceeded:
                operation.modifyRecordsResultBlock?(.success(()))
            case .batchFailed(let error):
                operation.modifyRecordsResultBlock?(.failure(error))
            }
        }
    }

    /// A CloudKit error with this code, optionally over a transport error.
    static func ck(_ code: CKError.Code, underlying: NSError? = nil) -> NSError {
        var info: [String: Any] = [:]
        if let underlying { info[NSUnderlyingErrorKey] = underlying }
        return NSError(domain: CKErrorDomain, code: code.rawValue, userInfo: info)
    }

    /// A batch `partialFailure` around exactly these record errors.
    static func partial(_ errors: [NSError]) -> NSError {
        var byID: [AnyHashable: Any] = [:]
        for (index, error) in errors.enumerated() { byID[CKRecord.ID(recordName: "item-\(index)")] = error }
        return NSError(domain: CKErrorDomain, code: CKError.Code.partialFailure.rawValue,
                       userInfo: [CKPartialErrorsByItemIDKey: byID])
    }

    static func url(_ code: URLError.Code) -> NSError {
        NSError(domain: NSURLErrorDomain, code: code.rawValue)
    }
}

/// The driver itself is real: it fires exactly the callbacks it names, in
/// order, on the operation it is handed.
@Suite struct ModifyOperationScriptTests {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []
        func note(_ call: String) { lock.lock(); calls.append(call); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return calls }
    }

    static func operation(saving names: [String], calls: Calls) -> CKModifyRecordsOperation {
        let zone = CKRecordZone.ID(zoneName: "scratch-zone", ownerName: CKCurrentUserDefaultName)
        let records = names.map { CKRecord(recordType: "Scratch", recordID: CKRecord.ID(recordName: $0, zoneID: zone)) }
        let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
        operation.perRecordSaveBlock = { id, result in
            if case .failure(let error) = result {
                calls.note("save \(id.recordName) failed \((error as NSError).code)")
            } else {
                calls.note("save \(id.recordName) ok")
            }
        }
        operation.modifyRecordsResultBlock = { result in
            if case .failure(let error) = result {
                calls.note("batch failed \((error as NSError).code)")
            } else {
                calls.note("batch ok")
            }
        }
        return operation
    }

    @Test func itFiresTheNamedCallbacksInOrder() {
        let calls = Calls()
        let operation = Self.operation(saving: ["a", "b"], calls: calls)
        ModifyOperationScript([.saved(1), .saveFailed(0, ModifyOperationScript.ck(.quotaExceeded)),
                               .batchFailed(ModifyOperationScript.ck(.networkFailure)), .batchSucceeded]).run(on: operation)
        #expect(calls.all == ["save b ok", "save a failed \(CKError.Code.quotaExceeded.rawValue)",
                              "batch failed \(CKError.Code.networkFailure.rawValue)", "batch ok"])
    }

    /// The Mac's issue #139 root cause, pinned on the phone too because the
    /// decision writer's verdict depends on it: CloudKit's Result overlay
    /// hands a batch `partialFailure` to the result block as SUCCESS, so a
    /// refused record shows up only in its own per-record callback.
    @Test func aBatchPartialFailureArrivesAsSuccess() {
        let calls = Calls()
        ModifyOperationScript([.saveFailed(0, ModifyOperationScript.ck(.quotaExceeded)),
                               .batchFailed(ModifyOperationScript.ck(.partialFailure))])
            .run(on: Self.operation(saving: ["a"], calls: calls))
        #expect(calls.all == ["save a failed \(CKError.Code.quotaExceeded.rawValue)", "batch ok"])
    }

    @Test func anEmptyScriptFiresNothing() {
        let calls = Calls()
        ModifyOperationScript([]).run(on: Self.operation(saving: ["a"], calls: calls))
        #expect(calls.all.isEmpty)
    }

    @Test func theErrorHelpersCarryTheirCodes() throws {
        let timedOut = ModifyOperationScript.url(.timedOut)
        let error = ModifyOperationScript.ck(.networkFailure, underlying: timedOut)
        #expect(error.domain == CKErrorDomain && error.code == CKError.Code.networkFailure.rawValue)
        #expect((error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == URLError.Code.timedOut.rawValue)
        let partial = ModifyOperationScript.partial([ModifyOperationScript.ck(.quotaExceeded)])
        let byID = try #require(partial.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Any])
        #expect(byID.count == 1)
    }
}
