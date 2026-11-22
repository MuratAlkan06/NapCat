import Foundation

/// The app's version as its bundle states it: the marketing version and the
/// build number, "0.1.0 (1)". Read from the Info.plist, never spelled in
/// code, so About always shows the build that is running.
struct AppVersion: Equatable, Sendable {
    nonisolated static let marketingKey = "CFBundleShortVersionString"
    nonisolated static let buildKey = "CFBundleVersion"
    /// Shown for a key the bundle lacks.
    nonisolated static let unknown = "unknown"

    let marketing: String
    let build: String

    init(info: [String: Any]) {
        marketing = info[Self.marketingKey] as? String ?? Self.unknown
        build = info[Self.buildKey] as? String ?? Self.unknown
    }

    init(bundle: Bundle) {
        self.init(info: bundle.infoDictionary ?? [:])
    }

    /// "0.1.0 (1)".
    var text: String { "\(marketing) (\(build))" }

    /// What VoiceOver reads: "0.1.0, build 1".
    var spoken: String { "\(marketing), build \(build)" }
}
