import Foundation
import LocalAuthentication

/// The live `BiometricGate`: Face ID, Touch ID or Optic ID ONLY
/// (`.deviceOwnerAuthenticationWithBiometrics`), with the passcode fallback
/// button hidden, and a fresh context for every confirmation, so an earlier
/// match is never reused. A failed match, a cancel or a lockout is not a
/// confirmation, and nothing is sent (CL-3).
///
/// A context that matched is handed on in a `LocalAuthenticationMatch`, to
/// the one signature it authorizes (the key is restored with it, so one
/// match covers this check and the key's), and invalidated after it. The
/// gate keeps nothing: every context is a local of the call that made it.
/// A failed evaluation is logged on the N-25 line (`SigningFailureLog`),
/// by its domain and code only.
struct LocalAuthenticationGate: BiometricGate {
    static let policy = LAPolicy.deviceOwnerAuthenticationWithBiometrics

    /// `biometryType` is set by `canEvaluatePolicy` whatever it returns, so
    /// a phone with Face ID that has none enrolled still names Face ID.
    func availability() -> BiometricAvailability {
        let context = LAContext()
        var error: NSError?
        let canConfirm = context.canEvaluatePolicy(Self.policy, error: &error)
        guard let kind = Self.kind(context.biometryType) else { return .unavailable(nil) }
        return canConfirm ? .available(kind) : .unavailable(kind)
    }

    func confirm(reason: String) async -> BiometricResult {
        let context = LAContext()
        // An empty title removes the fallback button: biometrics or nothing.
        context.localizedFallbackTitle = ""
        do {
            guard try await context.evaluatePolicy(Self.policy, localizedReason: reason) else {
                context.invalidate()
                return .notConfirmed
            }
            return .confirmed(LocalAuthenticationMatch(context))
        } catch {
            context.invalidate()
            SigningFailureLog.record(error)
            return .notConfirmed
        }
    }

    nonisolated static func kind(_ type: LABiometryType) -> BiometryKind? {
        switch type {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        case .none: return nil
        @unknown default: return nil
        }
    }
}
