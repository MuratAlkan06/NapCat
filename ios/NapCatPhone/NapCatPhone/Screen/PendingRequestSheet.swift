import NapCatWire
import SwiftUI

/// The sheet's clock: what time it is, and a wait until a moment. A test
/// seam, like the inbox's clock. The system's wait runs on the continuous
/// clock, so time the phone spends asleep counts toward it.
struct SheetClock: Sendable {
    let now: @Sendable () -> Date
    let sleep: @Sendable (Date) async throws -> Void

    static let system = SheetClock(now: Date.init) { moment in
        try await Task.sleep(for: .seconds(max(0, moment.timeIntervalSinceNow)))
    }
}

/// The request screen over the inbox, as a sheet with Close. It redraws at
/// each minute its expiry line changes and at the instant the window closes,
/// so the answers leave the screen when they stop counting (the inbox checks
/// the window again before anything is written, whatever the screen shows).
/// Nothing animates the change. The clock stops once the state is final or
/// the sheet closes.
struct PendingRequestSheet: View {
    let inbox: RequestInbox
    let id: PromptID
    let clock: SheetClock

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    /// The moment the screen is drawn for, kept current by `follow`.
    @State private var now: Date

    init(inbox: RequestInbox, id: PromptID, clock: SheetClock = .system) {
        self.inbox = inbox
        self.id = id
        self.clock = clock
        _now = State(initialValue: clock.now())
    }

    /// Now, then each whole minute before `until` from now on (now itself
    /// when it is one), then `until`: the moments the screen changes, just
    /// after each. Just now once the window has closed.
    static func schedule(now: Date, until: Date?) -> [Date] {
        guard let until, until > now else { return [now] }
        var marks: [Date] = [until]
        var mark = until.addingTimeInterval(-60)
        while mark >= now {
            marks.append(mark)
            mark = mark.addingTimeInterval(-60)
        }
        return [now] + marks.reversed()
    }

    /// When `id`'s screen next changes with time alone: its window's close,
    /// while an answer from here can still go out; nil once the state is
    /// final (sent, answered, expired, withdrawn), whose screen never
    /// changes again.
    static func closes(_ inbox: RequestInbox, _ id: PromptID, at moment: Date) -> Date? {
        guard case .pending(let until)? = inbox.phase(of: id, at: moment),
              let status = inbox.status(of: id, at: moment), !PendingRequestScreen.mutesCard(status) else { return nil }
        return until
    }

    /// The first moment after `mark`. A reading holds through its mark (60 s
    /// left still reads "1 min"), so the screen is drawn for the moment past
    /// it, never for the mark itself.
    static func justAfter(_ mark: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: mark.timeIntervalSinceReferenceDate.nextUp)
    }

    /// Keeps the screen's moment current while the sheet is open: redraws at
    /// once, then past each moment in `schedule` until the state is final,
    /// then returns. Cancelled (the sheet closed), it returns at once.
    static func follow(clock: SheetClock, closes: (Date) -> Date?, redraw: (Date) -> Void) async {
        var moment = clock.now()
        redraw(moment)
        while let mark = schedule(now: moment, until: closes(moment)).dropFirst().first {
            do { try await clock.sleep(mark) } catch { return }
            moment = max(clock.now(), justAfter(mark))
            redraw(moment)
        }
    }

    /// What the screen re-reads as it appears and as the app returns to the
    /// foreground: the biometrics and the pairing, asking for nothing (the
    /// owner may have changed Settings, or re-enrolled Face ID, meanwhile).
    static func refresh(_ inbox: RequestInbox) {
        inbox.refreshBiometry()
        inbox.refreshKeyHealth()
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if let request = inbox.entries[id]?.request, let status = inbox.status(of: id, at: now) {
                    PendingRequestScreen(request: request, status: status, now: now, biometry: inbox.biometry,
                                         key: inbox.keyHealth, readOnly: inbox.isReadOnly,
                                         allow: { Task { await inbox.allow(id) } },
                                         deny: { Task { await inbox.deny(id) } })
                }
            }
            .background(theme.ground.ignoresSafeArea())
            .navigationTitle(PendingRequestScreen.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(PendingRequestScreen.closeTitle) { dismiss() }
                }
            }
        }
        .tint(theme.accent)
        .onAppear { Self.refresh(inbox) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Self.refresh(inbox) }
        }
        .task { await Self.follow(clock: clock, closes: { Self.closes(inbox, id, at: $0) }, redraw: { now = $0 }) }
    }
}
