// NapCatWire — the wire contract between NapCat on the Mac (the writer) and
// the NapCat Phone receiver on iOS (the reader), F3 stage 1.
//
// Constants ONLY. This file has zero import statements and performs no I/O,
// so the same target builds for macOS and iOS and neither app can drift from
// the other: a renamed field, record type or subscription ID changes here,
// once, for both. `WireContractTests` pins every value.

/// The CloudKit wire contract for one NapCat alert.
///
/// The Mac writes ONE record per alert into the PRIVATE database's default
/// zone of `containerIdentifier`; the phone holds one query subscription
/// (`subscriptionID`) that fires on record creation. A record carries exactly
/// the three `Field`s and nothing else — no session id, no ntfy topic, no
/// text from a Claude session: `body` is the app-generated message the Mac
/// would otherwise have published to ntfy.
public enum AlertWire {
    /// The owner's iCloud container (private database, default zone).
    public static let containerIdentifier = "iCloud.com.muratalkan.napcat"

    /// The record type every alert is written as.
    public static let recordType = "Alert"

    /// The ONE query subscription the phone registers (firesOnRecordCreation,
    /// TRUEPREDICATE). Fixed and versioned on purpose: re-registering it is
    /// idempotent, and a second subscription under another ID would make the
    /// phone buzz twice for every alert.
    public static let subscriptionID = "napcat-alert-created-v1"

    /// The record's fields — the complete set.
    public enum Field: String, CaseIterable, Sendable {
        /// The app-generated message text (String).
        case body
        /// Which delivery lane sent it (String, one of `Lane`).
        case lane
        /// When the event happened on the Mac (Date).
        case firedAt
    }

    /// Values of the `lane` field. `lid` = the lid-close alert and the test
    /// message; `session` = the Claude session alerts (finish, waiting,
    /// connection restored).
    public enum Lane: String, CaseIterable, Sendable {
        case lid
        case session
    }
}
