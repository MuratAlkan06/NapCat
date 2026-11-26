import SwiftUI

/// NapCat Phone — the iOS receiver for the Mac's alerts (F3). A device build
/// shows the alerts the Mac writes to the owner's iCloud; simulator builds,
/// previews and tests show fixtures (`AlertSourceKind`, `LiveCapability`).
@main
struct NapCatPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate
    private let opensSettings = LaunchOptions.fromLaunchArguments().screen == .settings
    /// The pairing screen's fixture, for a `-NapCatPairing` launch only.
    private let pairing = FixturePairing.make(options: LaunchOptions.fromLaunchArguments())

    var body: some Scene {
        WindowGroup {
            ReceiverRoot(feed: appDelegate.feed, inbox: appDelegate.inbox, pairing: pairing, opensSettings: opensSettings)
        }
    }
}

/// The screen over the live feed: the first refresh at launch, another on
/// every return to the foreground (the missed-alert reconciliation: whatever
/// arrived while the app was away is fetched on open), and one whenever the
/// owner pulls the list down. Everything below it, Settings included, is
/// drawn in the owner's palette.
///
/// Settings opens from the gear in the main screen's toolbar as a sheet: a
/// self-contained task beside the alert list (which has no hierarchy for a
/// push to extend), closed with Done or a swipe, the list kept as it was
/// underneath.
///
/// A forwarded permission prompt opens over it as a sheet too (F4, slice
/// S3), drawn in the same palette: a `-NapCatRequest` launch opens on its
/// fixture prompt; since #194, a row of the main screen's waiting list, or a
/// tapped prompt push, opens that prompt.
///
/// Remote approvals (F4, #194): the owner's switch is kept in the app's
/// own defaults, set in Settings, and handed to the inbox at launch, on
/// every return to the foreground, on a pull, whenever it changes, and as
/// Settings or the launch's pairing sheet closes (a pairing made there can
/// make a stored on take effect, read at once); the inbox reads the prompts
/// then (`RequestInbox.syncPrompts`), never on a timer.
///
/// The pairing screen (F4, slice S-PAIR-B) opens the same way for a
/// `-NapCatPairing` launch: its fixture ceremony scans the launch's code, if
/// it has one, as the sheet opens. The live pairing (slice S-PAIR-C1.6)
/// opens from Settings' Pair with Mac, on the owner's tap, and its code
/// comes from the camera alone.
struct ReceiverRoot: View {
    let feed: AlertFeed
    let inbox: RequestInbox
    let pairing: FixturePairing?

    /// The chosen palette, kept in the app's own defaults across launches.
    /// A missing or unknown stored value reads as the default.
    @AppStorage(PaletteID.storageKey) private var palette = PaletteID.fallback
    /// The owner's remote-approvals switch (`ApprovalsSwitch`), off unless set.
    @AppStorage(ApprovalsSwitch.storageKey) private var approvals = false
    @State private var showsSettings: Bool
    /// The permission prompt shown as a sheet, if any.
    @State private var shownRequest: PendingRequest?
    @State private var showsPairing: Bool
    @Environment(\.scenePhase) private var scenePhase

    init(feed: AlertFeed, inbox: RequestInbox, pairing: FixturePairing? = nil, opensSettings: Bool = false) {
        self.feed = feed
        self.inbox = inbox
        self.pairing = pairing
        _showsSettings = State(initialValue: opensSettings)
        _showsPairing = State(initialValue: pairing != nil && !opensSettings)
        _shownRequest = State(initialValue: opensSettings ? nil : inbox.requests.first)
    }

    var body: some View {
        NavigationStack {
            ReceiverScreen(alerts: feed.alerts, connection: feed.connection, fetch: feed.fetch,
                           requests: inbox.pendingRequests, open: { shownRequest = $0 })
                .refreshable {
                    await feed.pullToRefresh()
                    await inbox.syncPrompts(switchedOn: approvals)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        SettingsGearButton { showsSettings = true }
                    }
                }
        }
        .sheet(isPresented: $showsSettings, onDismiss: { Task { await inbox.syncPrompts(switchedOn: approvals) } }) {
            SettingsScreen(palette: $palette, notifications: feed.notificationPermission, pairing: inbox.pairing,
                           approvals: $approvals)
        }
        .sheet(item: $shownRequest) { request in
            PendingRequestSheet(inbox: inbox, id: request.id)
        }
        .sheet(isPresented: $showsPairing, onDismiss: { Task { await inbox.syncPrompts(switchedOn: approvals) } }) {
            if let pairing {
                PairingSheet(ceremony: pairing.ceremony, camera: pairing.camera)
            }
        }
        .environment(\.theme, ThemeID.fallback.theme(palette: palette))
        .task { await feed.start() }
        .task {
            if let pairing, let scan = pairing.scan { await pairing.ceremony.scanned(scan) }
        }
        .task { await inbox.syncPrompts(switchedOn: approvals) }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await feed.refresh() }
            Task { await inbox.syncPrompts(switchedOn: approvals) }
        }
        .onChange(of: approvals) { _, on in
            Task { await inbox.syncPrompts(switchedOn: on) }
        }
        .onChange(of: inbox.opening, initial: true) { _, id in
            guard let id else { return }
            if let request = inbox.entries[id]?.request { shownRequest = request }
            inbox.opened()
        }
    }
}

#Preview("Main screen") {
    ReceiverRoot(feed: AlertFeed.make(options: LaunchOptions(), now: .now, liveCapable: false),
                 inbox: RequestInbox.make(options: LaunchOptions(), now: .now))
}
