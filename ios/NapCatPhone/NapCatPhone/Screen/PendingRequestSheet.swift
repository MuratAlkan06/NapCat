import NapCatWire
import SwiftUI

/// The request screen over the inbox, as a sheet with Close. It redraws at
/// each minute its expiry line changes and at the instant the window closes,
/// so the answers leave the screen when they stop counting (the inbox checks
/// the window again before anything is written, whatever the screen shows).
struct PendingRequestSheet: View {
    let inbox: RequestInbox
    let id: PromptID

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    /// Now, then each whole minute before `until`, then `until`: the moments
    /// the screen changes. Just now once the window has closed.
    static func schedule(now: Date, until: Date?) -> [Date] {
        guard let until, until > now else { return [now] }
        var marks: [Date] = [until]
        var mark = until.addingTimeInterval(-60)
        while mark > now {
            marks.append(mark)
            mark = mark.addingTimeInterval(-60)
        }
        return [now] + marks.reversed()
    }

    var body: some View {
        let now = Date()
        let until: Date? = if case .pending(let until)? = inbox.phase(of: id, at: now) { until } else { nil }
        NavigationStack {
            TimelineView(.explicit(Self.schedule(now: now, until: until))) { context in
                if let request = inbox.entries[id]?.request, let status = inbox.status(of: id, at: context.date) {
                    PendingRequestScreen(request: request, status: status, now: context.date, biometry: inbox.biometry,
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
        .onAppear { inbox.refreshBiometry() }
    }
}
