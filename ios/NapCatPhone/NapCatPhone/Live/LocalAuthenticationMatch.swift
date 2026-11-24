import Foundation
import LocalAuthentication

/// The live `BiometricMatch` (F4 slice S-PAIR-B, #161): the context a
/// biometric match was just made in, carried to the ONE signature it
/// authorizes. `SecureEnclaveSigner` restores the key with it, signs and
/// invalidates it. A context that has matched is honored by the enclave
/// again and again until it is invalidated, so it is never kept: this
/// carrier lets go of it on `invalidate()`, and nothing else holds it.
@MainActor
final class LocalAuthenticationMatch: BiometricMatch {
    /// The matched context until the match is spent; nil afterwards.
    private(set) var context: LAContext?

    init(_ context: LAContext) {
        self.context = context
    }

    var isValid: Bool { context != nil }

    func invalidate() {
        context?.invalidate()
        context = nil
    }
}

/// The live `EnrollmentState`: the enrolled biometrics' state hash, read
/// with a fresh context that is only asked whether it could evaluate,
/// never to evaluate, so nothing is shown and nothing is authorized.
struct LocalAuthenticationEnrollment: EnrollmentState {
    func current() -> Data? {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(LocalAuthenticationGate.policy, error: &error)
        return context.domainState.biometry.stateHash
    }
}
