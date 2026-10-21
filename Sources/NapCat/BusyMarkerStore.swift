import Foundation

/// One parsed marker together with the session id it was read under (the
/// marker FILE NAME). The id is an internal diff key only (Track C finish
/// alert): it never reaches a log line or a message body — message kinds carry
/// Int counts/minutes exclusively.
struct IdentifiedBusyMarker: Equatable, Sendable {
    let sessionID: String
    let marker: BusyMarker
}

/// Reads the companion hook's marker directory. Subprocess-free: plain
/// FileManager calls. INJECTABLE root (tests point it at a temp dir). Only
/// files whose name matches the session-id regex are ever parsed; anything
/// unparseable, foreign, not a regular file, or larger than
/// `ClaudeBusyConstants.maxMarkerBytes` is ignored (never counted busy).
@MainActor
protocol BusyMarkerStore: AnyObject {
    /// All parseable `v1` markers found (no freshness filtering here — the
    /// policy applies the 12h cap, so freshness stays in one place).
    func markers() -> [BusyMarker]
    /// The same markers as `markers()`, each keyed by its session id (the file
    /// name). Track C diffs these across fs events; ids are internal keys only.
    func identifiedMarkers() -> [IdentifiedBusyMarker]
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

    /// One read path: `markers()` is derived from `identifiedMarkers()`.
    func markers() -> [BusyMarker] {
        identifiedMarkers().map(\.marker)
    }

    /// Sorted by session id so the result is deterministic.
    func identifiedMarkers() -> [IdentifiedBusyMarker] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
        var found: [IdentifiedBusyMarker] = []
        for name in names.sorted() {
            // Path-traversal / foreign-file guard: only session-id-shaped
            // names are ever opened.
            guard ClaudeBusyConstants.isValidSessionID(name) else { continue }
            let url = root.appendingPathComponent(name)
            guard let contents = cappedContents(of: url),
                  let marker = ClaudeActivityPolicy.parseMarker(contents) else { continue }
            found.append(IdentifiedBusyMarker(sessionID: name, marker: marker))
        }
        return found
    }

    /// Risk F12: a marker is read only if it is a REGULAR file (the hook
    /// writes markers with mktemp + mv; a FIFO, device, directory or symlink
    /// is never one — and a FIFO could block the read) whose size is within
    /// `maxMarkerBytes`. `attributesOfItem` does not follow symlinks. The read
    /// itself is bounded to `maxMarkerBytes + 1` bytes, so a file that grows
    /// between the size check and the read is still rejected without being
    /// read in full.
    private func cappedContents(of url: URL) -> String? {
        let cap = ClaudeBusyConstants.maxMarkerBytes
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size <= cap else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: cap + 1), data.count <= cap else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
