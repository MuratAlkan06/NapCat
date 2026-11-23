// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import CloudKit
import Testing

/// F4 slice S3: plays CloudKit's part on a REAL `CKModifyRecordsOperation`,
/// the way `OperationDrivenStore` does for the alert lane (issue #139): the
/// operation is built by the code under test, then its own callbacks are
/// fired by hand in CloudKit's documented order — each per-record result,
/// then the batch result. No container, no database, nothing leaves the
/// process.
struct ModifyOperationScript: Sendable {
    enum Step: Sendable {
        /// The `index`th record to save reported saved.
        case saved(Int)
        case saveFailed(Int, NSError)
        /// The `index`th record ID to delete reported deleted.
        case deleted(Int)
        case deleteFailed(Int, NSError)
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
        let deletes = operation.recordIDsToDelete ?? []
        for step in steps {
            switch step {
            case .saved(let index):
                guard saves.indices.contains(index) else { Issue.record("no record \(index) to save"); return }
                operation.perRecordSaveBlock?(saves[index].recordID, .success(saves[index]))
            case .saveFailed(let index, let error):
                guard saves.indices.contains(index) else { Issue.record("no record \(index) to save"); return }
                operation.perRecordSaveBlock?(saves[index].recordID, .failure(error))
            case .deleted(let index):
                guard deletes.indices.contains(index) else { Issue.record("no record \(index) to delete"); return }
                operation.perRecordDeleteBlock?(deletes[index], .success(()))
            case .deleteFailed(let index, let error):
                guard deletes.indices.contains(index) else { Issue.record("no record \(index) to delete"); return }
                operation.perRecordDeleteBlock?(deletes[index], .failure(error))
            case .batchSucceeded:
                operation.modifyRecordsResultBlock?(.success(()))
            case .batchFailed(let error):
                operation.modifyRecordsResultBlock?(.failure(error))
            }
        }
    }

    /// A CloudKit error with this code (and, optionally, a transport error
    /// underneath it).
    static func ck(_ code: CKError.Code, underlying: NSError? = nil) -> NSError {
        CloudKitMessageSenderTests.ck(code, underlying: underlying)
    }
}

/// The driver itself is real: it fires exactly the callbacks it names, in
/// order, on the operation it is handed.
struct ModifyOperationScriptTests {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []
        func note(_ call: String) { lock.lock(); calls.append(call); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return calls }
    }

    static func operation(saving names: [String], deleting doomed: [String], calls: Calls) -> CKModifyRecordsOperation {
        let zone = CKRecordZone.ID(zoneName: "scratch-zone", ownerName: CKCurrentUserDefaultName)
        let records = names.map { CKRecord(recordType: "Scratch", recordID: CKRecord.ID(recordName: $0, zoneID: zone)) }
        let operation = CKModifyRecordsOperation(recordsToSave: records,
                                                 recordIDsToDelete: doomed.map { CKRecord.ID(recordName: $0, zoneID: zone) })
        operation.perRecordSaveBlock = { id, result in
            if case .failure(let error) = result {
                calls.note("save \(id.recordName) failed \((error as NSError).code)")
            } else {
                calls.note("save \(id.recordName) ok")
            }
        }
        operation.perRecordDeleteBlock = { id, result in
            if case .failure(let error) = result {
                calls.note("delete \(id.recordName) failed \((error as NSError).code)")
            } else {
                calls.note("delete \(id.recordName) ok")
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
        let operation = Self.operation(saving: ["a", "b"], deleting: ["c"], calls: calls)
        ModifyOperationScript([.saved(1), .saveFailed(0, ModifyOperationScript.ck(.quotaExceeded)),
                               .deleteFailed(0, ModifyOperationScript.ck(.unknownItem)), .deleted(0),
                               .batchFailed(ModifyOperationScript.ck(.networkFailure)), .batchSucceeded]).run(on: operation)
        #expect(calls.all == ["save b ok", "save a failed \(CKError.Code.quotaExceeded.rawValue)",
                              "delete c failed \(CKError.Code.unknownItem.rawValue)", "delete c ok",
                              "batch failed \(CKError.Code.networkFailure.rawValue)", "batch ok"])
    }

    /// Issue #139's root cause, pinned here because every record-path
    /// verdict depends on it: CloudKit's Result overlay hands a batch
    /// `partialFailure` to the result block as SUCCESS, so a refused record
    /// shows up only in its own per-record callback.
    @Test func aBatchPartialFailureArrivesAsSuccess() {
        let calls = Calls()
        ModifyOperationScript([.saveFailed(0, ModifyOperationScript.ck(.quotaExceeded)),
                               .batchFailed(ModifyOperationScript.ck(.partialFailure))])
            .run(on: Self.operation(saving: ["a"], deleting: [], calls: calls))
        #expect(calls.all == ["save a failed \(CKError.Code.quotaExceeded.rawValue)", "batch ok"])
    }

    @Test func anEmptyScriptFiresNothing() {
        let calls = Calls()
        ModifyOperationScript([]).run(on: Self.operation(saving: ["a"], deleting: [], calls: calls))
        #expect(calls.all.isEmpty)
    }
}
