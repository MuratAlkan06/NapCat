/// How the last refresh pass's query went. With the connection state, it is
/// what lets the screen tell "no alerts" from "not checked yet" and
/// "couldn't check".
enum FetchStatus: Equatable, CaseIterable, Sendable {
    /// No pass has run the query yet: a live launch's first frames.
    case pending
    /// The last pass's query answered.
    case fetched
    /// The last pass could not check: its query failed, or there was no
    /// account to ask with. The next pass whose query answers clears it.
    case failed
}

/// The empty list's one sentence, state word first. Only `.noAlerts`
/// claims the good outcome, and `ListState` picks it only once a query has
/// come back empty.
enum EmptyHero: CaseIterable, Sendable {
    /// Nothing is known yet.
    case checking
    /// No usable iCloud account: no alert can arrive at all.
    case iCloudUnavailable
    /// The account works, but the last query failed.
    case couldNotCheck
    /// The query came back empty: the good outcome.
    case noAlerts

    var message: String {
        switch self {
        case .checking: return "Checking for alerts…"
        case .iCloudUnavailable: return "iCloud unavailable. Alerts can't arrive without it."
        case .couldNotCheck: return "Couldn't check for alerts just now. Pull down to try again."
        case .noAlerts: return "No alerts. Your Mac hasn't needed you."
        }
    }
}

/// Why the rows already listed could not be checked: what their note says.
/// A failed query is passing (the next pass may answer); no iCloud lasts
/// until the account is fixed, and nothing new can arrive meanwhile.
enum StaleReason: CaseIterable, Sendable {
    /// The account works, but the last query failed.
    case couldNotCheck
    /// No usable iCloud account.
    case iCloudUnavailable

    /// The note over the rows, in the caption register: one state word, an
    /// em dash, the cause, no closing period. A note: a glyph and text.
    var line: PhoneLine {
        switch self {
        case .couldNotCheck:
            return PhoneLine(text: "Stale — couldn't check for new alerts just now", severity: .info)
        case .iCloudUnavailable:
            return PhoneLine(text: "Stale — iCloud unavailable, so new alerts can't arrive", severity: .info)
        }
    }
}

/// What the receiver screen says about its list, from the pill's state, how
/// the last query went and whether there are rows. Pure, so every cell of
/// that matrix is table-tested (`ListStateTests`).
enum ListState: Equatable, Sendable {
    /// No rows: the hero, with this sentence.
    case empty(EmptyHero)
    /// Rows, and nothing says they are out of date.
    case rows
    /// Rows from an earlier pass: the last one could not check, so the list
    /// stays and one quiet line says why.
    case staleRows(StaleReason)

    /// No account beats everything (nothing can arrive). Otherwise the good
    /// outcome needs a query that answered: before the first one the hero
    /// says it is checking, and after a failed one that it couldn't check.
    init(connection: ConnectionState, fetch: FetchStatus, hasAlerts: Bool) {
        if hasAlerts {
            if connection == .iCloudUnavailable {
                self = .staleRows(.iCloudUnavailable)
            } else {
                self = fetch == .failed ? .staleRows(.couldNotCheck) : .rows
            }
            return
        }
        switch (connection, fetch) {
        case (.iCloudUnavailable, _): self = .empty(.iCloudUnavailable)
        case (.checking, _), (_, .pending): self = .empty(.checking)
        case (_, .failed): self = .empty(.couldNotCheck)
        case (_, .fetched): self = .empty(.noAlerts)
        }
    }

    /// The quiet line over stale rows; nil for every other state.
    var note: PhoneLine? {
        guard case .staleRows(let reason) = self else { return nil }
        return reason.line
    }
}
