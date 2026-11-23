import Foundation
import NapCatWire
import Observation

/// Where a forwarded permission prompt stands on this phone.
enum RequestPhase: Equatable, Sendable {
    /// It may be answered until `until`, on this phone's clock.
    case pending(until: Date)
    /// Its window closed before it was answered here. Terminal.
    case expired
    /// The Mac took it back: answered at the Mac, its session ended, the
    /// Mac's switch went off, or the Mac's own clock ran out. Terminal.
    case withdrawn

    /// Whether the phone may still answer it.
    var isPending: Bool {
        if case .pending = self { return true }
        return false
    }
}

/// The permission prompts the Mac forwarded to this phone, each with its
/// window. A request is answerable only while it is pending: until the
/// Mac's expiry, and never longer than the TTL after this phone first saw
/// it (a Mac clock running ahead cannot stretch it). Expired and withdrawn
/// are terminal: once a request is either, nothing makes it pending again.
@MainActor
@Observable
final class RequestInbox {
    struct Entry: Equatable, Sendable {
        let request: PendingRequest
        /// When this phone first saw the request.
        let firstSeen: Date
        /// The Mac took it back (terminal).
        var withdrawn = false
        /// Its window was seen closed (terminal, whatever the clock does next).
        var expired = false

        /// The last moment this phone may answer.
        var answerableUntil: Date {
            min(request.expiresAt, firstSeen.addingTimeInterval(PendingRequest.timeToLive))
        }
    }

    /// The most requests held at once (the Mac forwards far fewer); past it
    /// the oldest finished ones go first.
    nonisolated static let capacity = 64

    private(set) var entries: [PromptID: Entry] = [:]
    @ObservationIgnored private let clock: () -> Date

    /// `clock` is this phone's wall clock (a test seam).
    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    /// The requests, newest first.
    var requests: [PendingRequest] {
        entries.values.map(\.request).sorted { ($0.createdAt, $0.id.hex) > ($1.createdAt, $1.id.hex) }
    }

    /// Where `id` stands now; nil for a request never held.
    func phase(of id: PromptID) -> RequestPhase? {
        guard let entry = entries[id] else { return nil }
        if entry.withdrawn { return .withdrawn }
        if entry.expired || clock() >= entry.answerableUntil { return .expired }
        return .pending(until: entry.answerableUntil)
    }

    /// A fetch of every request the Mac still offers. A new one is held from
    /// now; one held here and missing from the fetch was taken back. A
    /// request already finished here stays as it is, even if its record
    /// shows up again.
    func receive(_ offered: [PendingRequest]) {
        tick()
        let now = clock()
        let offeredIDs = Set(offered.map(\.id))
        for request in offered where entries[request.id] == nil {
            entries[request.id] = Entry(request: request, firstSeen: now)
        }
        for (id, entry) in entries where !offeredIDs.contains(id) && !entry.expired && !entry.withdrawn {
            entries[id]?.withdrawn = true
        }
        prune(now: now)
    }

    /// One request taken back (its record is gone). Terminal.
    func withdraw(_ id: PromptID) {
        tick()
        guard let entry = entries[id], !entry.expired else { return }
        entries[id]?.withdrawn = true
    }

    /// Marks every request whose window has closed as expired, for good.
    func tick() {
        let now = clock()
        for (id, entry) in entries where !entry.expired && !entry.withdrawn && now >= entry.answerableUntil {
            entries[id]?.expired = true
        }
    }

    /// Past `capacity`, finished requests go first, oldest first; a pending
    /// one is never dropped for a finished one.
    private func prune(now: Date) {
        guard entries.count > Self.capacity else { return }
        let finished = entries.values.filter { $0.withdrawn || $0.expired }
            .sorted { ($0.firstSeen, $0.request.id.hex) < ($1.firstSeen, $1.request.id.hex) }
        for entry in finished.prefix(entries.count - Self.capacity) {
            entries[entry.request.id] = nil
        }
    }
}
