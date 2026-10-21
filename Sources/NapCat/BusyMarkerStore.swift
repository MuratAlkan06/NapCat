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
/// FileManager calls plus one descriptor-checked read per marker
/// (`open`/`fstat`/`read`). INJECTABLE root (tests point it at a temp dir). Only
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

    /// Risk F12 + security review L1 (2026-10-21): a marker is read only if it
    /// is a REGULAR file (the hook writes markers with mktemp + mv; a FIFO,
    /// device, directory or symlink is never one — and a FIFO could block the
    /// read) whose size is within `maxMarkerBytes`.
    ///
    /// The checks run on the OPENED DESCRIPTOR, never on the path first: an
    /// attribute check followed by a separate open could be raced by a swap to
    /// a symlink-to-FIFO, blocking the main thread in `open`. So the open
    /// itself refuses a symlink (`O_NOFOLLOW`) and cannot block on a FIFO
    /// (`O_NONBLOCK`; `O_CLOEXEC` keeps the fd out of any child), and `fstat`
    /// of that same descriptor decides regular-file + size. The read is
    /// bounded to `maxMarkerBytes + 1` bytes, so a file that grows after the
    /// `fstat` is still rejected without being read in full.
    private func cappedContents(of url: URL) -> String? {
        let cap = ClaudeBusyConstants.maxMarkerBytes
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= off_t(cap) else { return nil }
        var buffer = [UInt8](repeating: 0, count: cap + 1)
        var total = 0
        while total < buffer.count {
            let got = buffer.withUnsafeMutableBytes { raw in
                read(descriptor, raw.baseAddress! + total, raw.count - total)
            }
            if got < 0 && errno == EINTR { continue }
            guard got >= 0 else { return nil }
            if got == 0 { break }
            total += got
        }
        guard total <= cap else { return nil }
        return String(bytes: buffer[..<total], encoding: .utf8)
    }
}
