import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// The live `SigningEnclave`: the phone's Secure Enclave (F4 slice
/// S-PAIR-B, #161). THE ONLY FILE that names the enclave (lint-locked).
///
/// The simulator and CI have no Secure Enclave (`isAvailable` is false
/// there), so this file is proven by review and by the owner's device
/// drill; every rule above it runs over software keys in the tests.
///
/// - The key is made with ONE access control: usable only after a match of
///   the biometrics enrolled NOW (`.biometryCurrentSet`: adding or removing
///   a face or a finger invalidates it for good), for signing
///   (`.privateKeyUsage`), on this device only, while it is unlocked. There
///   is no passcode fallback (CL-3): no `.devicePasscode`, no
///   `.userPresence`, no `.or`.
/// - A key is restored from its stored block in ONE place, `sign`, with the
///   context of the match that authorizes this one signature, so one match
///   covers the app's own check and the key's (S-PAIR amendment 2). The
///   match is invalidated after the signature, on every path, and nothing
///   here is kept: no key handle, no context.
struct SecureEnclaveSigner: SigningEnclave {
    var isAvailable: Bool { SecureEnclave.isAvailable }

    /// The one access control a key is made under.
    static func accessControl() -> SecAccessControl? {
        SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], nil)
    }

    func makeKey() -> MadeKey? {
        guard SecureEnclave.isAvailable, let access = Self.accessControl(),
              let key = try? SecureEnclave.P256.Signing.PrivateKey(accessControl: access) else { return nil }
        return MadeKey(keyData: key.dataRepresentation, publicKey: Array(key.publicKey.x963Representation))
    }

    func sign(_ message: [UInt8], with keyData: Data, match: any BiometricMatch) -> SigningOutcome {
        defer { match.invalidate() }
        guard match.isValid, let context = (match as? LocalAuthenticationMatch)?.context else { return .notAuthorized }
        do {
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: keyData, authenticationContext: context)
            return .signed(try key.signature(for: SHA256.hash(data: message)).rawRepresentation)
        } catch {
            return Self.outcome(of: error)
        }
    }

    /// What a failed restore or signature means. A cancel or a lockout (the
    /// owner's act, or a passing state) is never the key's fault; anything
    /// else after a good match is the class an invalidated key raises.
    nonisolated static func outcome(of error: any Error) -> SigningOutcome {
        if case CryptoKitError.underlyingCoreCryptoError(let status) = error {
            return status == errSecUserCanceled ? .notAuthorized : .keyUnusable
        }
        let nsError = error as NSError
        switch nsError.domain {
        case LAError.errorDomain:
            return notAuthorizedCodes.contains(nsError.code) ? .notAuthorized : .keyUnusable
        case NSOSStatusErrorDomain:
            return nsError.code == Int(errSecUserCanceled) ? .notAuthorized : .keyUnusable
        default:
            return .keyUnusable
        }
    }

    /// The LocalAuthentication codes that say "not now", never "this key".
    nonisolated static let notAuthorizedCodes: Set<Int> = [
        LAError.Code.userCancel.rawValue, LAError.Code.appCancel.rawValue, LAError.Code.systemCancel.rawValue,
        LAError.Code.biometryLockout.rawValue, LAError.Code.notInteractive.rawValue,
    ]
}
