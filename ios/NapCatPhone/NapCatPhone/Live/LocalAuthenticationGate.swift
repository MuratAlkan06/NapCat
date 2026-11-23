import Foundation
import LocalAuthentication

/// The live `BiometricGate`: Face ID, Touch ID or Optic ID ONLY
/// (`.deviceOwnerAuthenticationWithBiometrics`), with the passcode fallback
/// button hidden, and a fresh context for every confirmation, so an earlier
/// match is never reused. A failed match, a cancel or a lockout is not a
/// confirmation, and nothing is sent (CL-3).
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
            return try await context.evaluatePolicy(Self.policy, localizedReason: reason) ? .confirmed : .notConfirmed
        } catch {
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
