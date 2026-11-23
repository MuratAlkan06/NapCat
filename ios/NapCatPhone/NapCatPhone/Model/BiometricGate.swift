/// The biometrics a phone can have. The words for Allow name the one it has.
enum BiometryKind: String, CaseIterable, Sendable {
    case faceID
    case touchID
    case opticID

    var name: String {
        switch self {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        }
    }

    /// The system's own glyph for it.
    var symbol: String {
        switch self {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        }
    }
}

/// Whether Allow can be confirmed on this phone.
enum BiometricAvailability: Equatable, Sendable {
    case available(BiometryKind)
    /// No biometrics, none enrolled, or locked out: Allow cannot be
    /// confirmed here (Deny still works). Carries the biometric the phone
    /// has, if it has one, so the screen can name it.
    case unavailable(BiometryKind?)

    /// The biometric this phone has, whether or not it can confirm now.
    var kind: BiometryKind? {
        switch self {
        case .available(let kind): return kind
        case .unavailable(let kind): return kind
        }
    }
}

/// What one confirmation came to. Anything short of a match (a failed
/// match, a cancel, a lockout, no biometrics) is `.notConfirmed`.
enum BiometricResult: Equatable, Sendable {
    case confirmed
    case notConfirmed
}

/// THE seam in front of Allow (CL-3: Allow is in-app and biometric-only;
/// Deny never asks). The live gate is `LocalAuthenticationGate`; tests use a
/// scripted one and never reach the real prompt.
@MainActor
protocol BiometricGate {
    /// Cheap and side-effect free: whether a confirmation could succeed.
    func availability() -> BiometricAvailability
    /// Asks for a biometric match, once.
    func confirm(reason: String) async -> BiometricResult
}
