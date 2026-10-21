import Foundation

// Track C slice C3 — the ONE kqueue filesystem-object source on the marker
// dir (B1 AMENDMENT, PLAN.md Track C: while the finish alert is ARMED, one
// kqueue source may watch the marker dir). READER FILE: a read-only observer.
// It only REPORTS that the directory changed or vanished — it never reads a
// marker, never probes a process, never touches the B1 snapshot, and never
// schedules anything. `FinishAlertStructureTests` bans network, process,
// IOKit power, logging and timer symbols here; `O_EVTONLY` and
// `makeFileSystemObjectSource` are confined to this file
// (`ClaudeDetectionStructureTests`).

/// What one coalesced kqueue delivery means for the finish alert.
enum MarkerDirectoryEvent: Equatable, Sendable {
    /// An entry was created, removed or renamed inside the directory (a marker
    /// write is mktemp + mv, so a rewrite lands here too).
    case contentsChanged
    /// The directory itself was deleted, renamed or revoked. Never a finish:
    /// the owner tears everything down and re-arms only via reconciliation.
    case directoryGone
}

/// Observer over one directory, behind a protocol so the controller tests
/// drive events by hand. Same lifecycle shape as `SystemSleepSource`: started
/// when the finish alert ARMS, stopped when it disarms, so a disarmed NapCat
/// holds no descriptor and no source at all.
protocol MarkerDirectoryWatching: AnyObject {
    var isRunning: Bool { get }
    /// Starts observing. `handler` runs on a PRIVATE serial queue (never the
    /// main queue). Returns false (and stays stopped) when the directory
    /// cannot be opened. Starting a running watcher is a no-op returning true.
    func start(handler: @escaping @Sendable (MarkerDirectoryEvent) -> Void) -> Bool
    /// Cancels the source; its cancel handler closes the descriptor.
    /// Idempotent; start → stop → start works.
    func stop()
}

/// The production watcher: `open(O_EVTONLY | O_CLOEXEC)` + a dispatch
/// filesystem-object source. `O_EVTONLY` asks only for event notifications —
/// it never keeps the volume from unmounting and never blocks the directory's
/// deletion; `O_CLOEXEC` keeps the descriptor out of any child process.
final class KqueueMarkerDirectoryWatcher: MarkerDirectoryWatching, @unchecked Sendable {
    /// The kqueue bits observed: entries changing, and the directory itself
    /// going away. Computed: the option set is not `Sendable`, so it cannot
    /// be a stored static under Swift 6.
    static var eventMask: DispatchSource.FileSystemEvent { [.write, .delete, .rename, .revoke] }

    private let directory: URL
    /// Private serial queue for the event and cancel handlers.
    private let queue = DispatchQueue(label: "com.muratalkan.napcat.finishalert.watch")

    private let lock = NSLock()
    /// Guarded by `lock`. Non-nil exactly while running.
    private var source: DispatchSourceFileSystemObject?

    init(directory: URL) {
        self.directory = directory
    }

    deinit {
        // An owner that forgets to stop must not leak the descriptor (the
        // event handler's capture of the source is released on cancel).
        source?.cancel()
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return source != nil
    }

    func start(handler: @escaping @Sendable (MarkerDirectoryEvent) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard source == nil else { return true }
        let descriptor = open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: Self.eventMask,
            queue: queue
        )
        let reader = SourceDataReader(newSource)
        newSource.setEventHandler {
            guard let event = Self.event(for: reader.data) else { return }
            handler(event)
        }
        newSource.setCancelHandler {
            close(descriptor)
        }
        source = newSource
        newSource.activate()
        return true
    }

    func stop() {
        lock.lock()
        let running = source
        source = nil
        lock.unlock()
        // Cancellation stops further event-handler invocations; the cancel
        // handler then closes the descriptor on the private queue.
        running?.cancel()
    }

    /// Pure mapping of one coalesced delivery (unit-tested). The directory
    /// going away WINS over a simultaneous write: a vanished directory is
    /// never a finish. Anything else (no bit we asked for) is ignored.
    static func event(for data: DispatchSource.FileSystemEvent) -> MarkerDirectoryEvent? {
        if !data.isDisjoint(with: [.delete, .rename, .revoke]) { return .directoryGone }
        if data.contains(.write) { return .contentsChanged }
        return nil
    }
}

/// Lets the source's own event handler read `data` without the handler
/// closure capturing a non-Sendable existential. Read only on the source's
/// queue, inside its event handler — the one place `data` is meaningful.
private final class SourceDataReader: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject

    init(_ source: DispatchSourceFileSystemObject) {
        self.source = source
    }

    var data: DispatchSource.FileSystemEvent { source.data }
}
