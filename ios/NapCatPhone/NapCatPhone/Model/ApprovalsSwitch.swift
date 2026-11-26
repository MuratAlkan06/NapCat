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

    /// Whether the phone holds a committed key: paired, or paired under
    /// biometrics that have changed since. Only then can the switch be set
    /// (Settings disables it on any other phone) or take effect.
    static func isCommitted(_ keyHealth: PhoneKeyring.Health) -> Bool {
        switch keyHealth {
        case .paired, .enrollmentChanged: return true
        case .unpaired: return false
        }
    }

    /// Whether the switch takes effect: only a stored `true` on a phone
    /// with a committed key. An unpaired phone receives nothing, whatever is
    /// stored, and Settings shows its switch off.
    static func effective(stored: Bool, keyHealth: PhoneKeyring.Health) -> Bool {
        stored && isCommitted(keyHealth)
    }
}
