/// The phone's own switch for remote approvals (F4, #194): Settings ›
/// Remote approvals. Off by default.
///
/// It gates only this phone's side: the prompt push subscription, the
/// snapshot reads and the waiting list. Nothing tells the Mac (owner
/// ruling: pairing is the Mac-visible half of the opt-in), so off is a
/// local pause. Switching off deletes the subscription and empties the
/// inbox (`RequestInbox.syncPrompts`).
enum ApprovalsSwitch {
    /// Where the app's own defaults keep the owner's choice (`ReceiverRoot`'s
    /// `@AppStorage`).
    static let storageKey = "remoteApprovalsEnabled"

    /// Whether the switch takes effect: only a stored `true` on a phone
    /// with a committed key (paired, or paired under biometrics that have
    /// changed since). An unpaired phone receives nothing, whatever is
    /// stored.
    static func effective(stored: Bool, keyHealth: PhoneKeyring.Health) -> Bool {
        guard stored else { return false }
        switch keyHealth {
        case .paired, .enrollmentChanged: return true
        case .unpaired: return false
        }
    }
}
