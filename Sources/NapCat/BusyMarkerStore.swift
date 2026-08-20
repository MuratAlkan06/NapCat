import Foundation

/// Reads the companion hook's marker directory. Subprocess-free: plain
/// FileManager calls. INJECTABLE root (tests point it at a temp dir). Only
/// files whose name matches the session-id regex are ever parsed; anything
/// unparseable or foreign is ignored (never counted busy).
@MainActor
protocol BusyMarkerStore: AnyObject {
    /// All parseable `v1` markers found (no freshness filtering here — the
    /// policy applies the 12h cap, so freshness stays in one place).
    func markers() -> [BusyMarker]
    /// Whether the marker directory exists at all (absent ⇒ "not installed").
    func markerDirExists() -> Bool
    /// Whether the hook's private log exists (its presence = "the hook has run
    /// at least once while not paused").
    func hookLogExists() -> Bool
    /// Marker-dir modification time as a unix epoch, or nil if unreadable.
    /// The dir mtime bumps on marker create/remove/sweep — the liveness clock.
    func lastActivityEpoch() -> Int?
}

@MainActor
final class MarkerDirectoryStore: BusyMarkerStore {
    private let root: URL
    private let fileManager = FileManager.default

    init(root: URL = ClaudeBusyConstants.markerDirURL) {
        self.root = root
    }

    func markerDirExists() -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func hookLogExists() -> Bool {
        fileManager.fileExists(atPath: root.appendingPathComponent(ClaudeBusyConstants.logFileName).path)
    }

    func lastActivityEpoch() -> Int? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: root.path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return Int(modified.timeIntervalSince1970)
    }

    func markers() -> [BusyMarker] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
        var found: [BusyMarker] = []
        for name in names {
            // Path-traversal / foreign-file guard: only session-id-shaped
            // names are ever opened.
            guard ClaudeBusyConstants.isValidSessionID(name) else { continue }
            let url = root.appendingPathComponent(name)
            guard let contents = try? String(contentsOf: url, encoding: .utf8),
                  let marker = ClaudeActivityPolicy.parseMarker(contents) else { continue }
            found.append(marker)
        }
        return found
    }
}
