/// The phone's live prompt source (F4, #194): the prompt push
/// subscription and the snapshot read, each one operation built in the
/// CloudKit file and handed to the approvals database, which runs only what
/// its admit list allows (`LiveCloudKitApprovalDatabase`).
///
/// It is built once per launch, by the live inbox's factory
/// (`RequestInbox.make`), over the same live approvals database the live
/// pairing writes through; a build that cannot hold the iCloud entitlement
/// has none, and its inbox reads nothing. Every answer still goes to the
/// unsent writer: nothing here arms.
struct LivePromptSource: PromptSource {
    let database: any CloudKitApprovalDatabase

    /// Looked up first; created only when the lookup found it missing, so a
    /// second ensure saves nothing. A lookup that failed creates nothing.
    func ensureSubscription() async -> Bool {
        let lookup: CloudKitAlertSource.SubscriptionLookup = await withCheckedContinuation { continuation in
            database.submit(CloudKitAlertSource.makePromptSubscriptionLookup { continuation.resume(returning: $0) })
        }
        guard lookup == .missing else { return lookup == .found }
        return await withCheckedContinuation { continuation in
            database.submit(CloudKitAlertSource.makePromptSubscriptionSave { continuation.resume(returning: $0) })
        }
    }

    func removeSubscription() async -> Bool {
        await withCheckedContinuation { continuation in
            database.submit(CloudKitAlertSource.makePromptSubscriptionRemoval { continuation.resume(returning: $0) })
        }
    }

    func snapshot() async -> [PendingRequest]? {
        await withCheckedContinuation { continuation in
            database.submit(CloudKitAlertSource.makePromptSnapshot { continuation.resume(returning: $0) })
        }
    }
}
