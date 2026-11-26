import CryptoKit
import Foundation
import LocalAuthentication
import os

/// N-25 (F4 slice S-PAIR-C1.6, #172): THE line the phone logs when a
/// biometric match or a Secure Enclave key operation fails (the gate's
/// evaluation, the enclave's key making, and its restore and signature), so
/// the owner's device drills can capture the real error without a debugger.
///
/// One fixed line in the `signing` category, public, in closed vocabulary
/// only: the error's domain, read through a closed table (`Domain`), and
/// its numeric code. Never the error's own text, the reason the prompt
/// showed, a key, a message or anything else (lint-locked:
/// `SigningKeyStructureTests` lock 7). It is the iPhone's log, not the
/// Mac's: read it in the Mac's Console.app with the iPhone selected under
/// Devices, searching for subsystem `com.muratalkan.napcat.phone` (category
/// `signing`). A plain `log stream` on the Mac never shows it; a simulator
/// run's is read with `xcrun simctl spawn booted log stream --predicate
/// 'subsystem == "com.muratalkan.napcat.phone" AND category == "signing"'`.
enum SigningFailureLog {
    /// The domains the line can name: these, and `other` for any other.
    enum Domain: String, CaseIterable, Sendable {
        case localAuthentication = "com.apple.LocalAuthentication"
        case osStatus = "NSOSStatusErrorDomain"
        /// A CryptoKit error wrapping a Security status: the code is that
        /// status.
        case coreCrypto = "CryptoKitError.underlyingCoreCryptoError"
        case cryptoKit = "CryptoKitError"
        case other
    }

    private static let logger = Logger(subsystem: "com.muratalkan.napcat.phone", category: "signing")

    /// Logs one failure, on the one line.
    static func record(_ error: any Error) {
        let (domain, code) = Self.reading(error)
        logger.error("biometric or enclave operation failed (domain \(domain.rawValue, privacy: .public), code \(code, privacy: .public))")
    }

    /// The failure as the line names it: a domain from the closed table, and
    /// a number.
    static func reading(_ error: any Error) -> (domain: Domain, code: Int) {
        if case CryptoKitError.underlyingCoreCryptoError(let status) = error { return (.coreCrypto, Int(status)) }
        let nsError = error as NSError
        if error is CryptoKitError { return (.cryptoKit, nsError.code) }
        switch nsError.domain {
        case LAError.errorDomain: return (.localAuthentication, nsError.code)
        case NSOSStatusErrorDomain: return (.osStatus, nsError.code)
        default: return (.other, nsError.code)
        }
    }
}
