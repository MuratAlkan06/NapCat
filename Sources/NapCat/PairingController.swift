import Foundation
import NapCatWire
import os
import Security

// F4 slice S-PAIR-C1 (#168, Refs #161): the THIN SHELL around the pure
// `PairingCeremonyState` — it makes the nonce, keeps the clock, runs the
// one-second tick while a ceremony is live, performs the effects the state
// machine returns (the record seam, the paired-key slot, the remembered
// record name, the audit), and owns Unpair. Design:
// design/remote-approvals.md, "Slice S-PAIR".
//
// ZERO IDLE COST: no timer, no fetch and no CloudKit traffic while no
// ceremony is live; the tick and the polls live and die with the sheet.
//
// LIVE TRANSPORT (S-PAIR-C1.5, #170): the app's record seam is
// `CloudKitPairingRecords` (the record path's file), fetching and deleting
// the pairing record by its derived name through the probe-gated live
// database. FAIL-DARK where iCloud is not there for it — no account, no
// network, no Production schema or zone yet, a build with no iCloud
// entitlement: the fetch reads "unreachable", the sheet says "Waiting —
// iCloud is unreachable; still trying", and the ceremony ends with its
// window; no other surface appears. Nothing here arms anything: the stored
// key is read by no decision path until S-PAIR-C2.
// UNPRIVILEGED — no sudo, no PLAN §4 command, no subprocess.

/// The repeating one-second tick a live ceremony runs on.
@MainActor
protocol PairingTicker: AnyObject {
    func cancel()
}

/// The app's tick: a main-run-loop timer in the common modes.
@MainActor
final class TimerPairingTicker: PairingTicker {
    private var timer: Timer?

    init(_ fire: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { fire() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

/// What Settings › Claude shows for the pairing (the pane's state).
enum PairingPaneState: Equatable, Sendable {
    case notPaired
    /// A ceremony is live and no phone was paired.
    case pairing
    case paired(PairingFingerprint, since: Date)
    /// A ceremony is live over a paired phone, whose key keeps working
    /// until the new code is confirmed.
    case rotating(PairingFingerprint, since: Date)
    /// #240: Unpair asked the keychain to delete the key and the keychain
    /// refused. #247: the slot reads the Unpair as outstanding
    /// (`PairedPhoneRead.unpairOutstanding`) until a deletion or a new
    /// pairing goes through, across relaunches.
    case unpairFailed
    /// #247: an item is stored that NapCat cannot read (the keychain refused
    /// the read, or the text is not a pairing this build reads) and no
    /// Unpair of it is outstanding: no pairing, with Unpair… to remove it.
    case unreadable
}

@MainActor
final class PairingController: ObservableObject, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    typealias TickerFactory = (@escaping @MainActor () -> Void) -> any PairingTicker

    @Published private(set) var state = PairingCeremonyState()
    /// The clock as of the last event: the sheet's countdown reads it.
    @Published private(set) var now: Date
    /// The slot, as last read (`refreshPaired`).
    @Published private(set) var paired = PairedPhoneRead.notPaired

    /// The sheet must show (true) or close (false).
    var onSheetChange: ((Bool) -> Void)?
    /// What Settings › Claude shows changed.
    var onPaneChange: (() -> Void)?
    /// A VoiceOver announcement: a transition's new line, or the window's
    /// last minute and last ten seconds.
    var announce: ((String) -> Void)?

    private let source: any PairingRecordSource
    private let keys: PairedKeyStore
    private let readRemembered: () -> String?
    private let writeRemembered: (String?) -> Void
    private let makeNonce: () -> [UInt8]?
    private let clock: () -> Date
    private let killSwitch: () -> Void
    private let audit: (PairingAudit) -> Void
    private let makeTicker: TickerFactory
    private var ticker: (any PairingTicker)?
    /// Bumped by every begin, so a late fetch for an earlier ceremony is
    /// dropped.
    private var generation = 0
    /// The record work under way (fetches, deletions), for `settle()`.
    private var work: [Task<Void, Never>] = []

    init(source: any PairingRecordSource, keys: PairedKeyStore,
         readRemembered: @escaping () -> String?, writeRemembered: @escaping (String?) -> Void,
         makeNonce: @escaping () -> [UInt8]? = PairingController.secureNonce,
         clock: @escaping () -> Date = Date.init, killSwitch: @escaping () -> Void,
         audit: @escaping (PairingAudit) -> Void = PairingLog.record,
         makeTicker: @escaping TickerFactory = { TimerPairingTicker($0) }) {
        self.source = source
        self.keys = keys
        self.readRemembered = readRemembered
        self.writeRemembered = writeRemembered
        self.makeNonce = makeNonce
        self.clock = clock
        self.killSwitch = killSwitch
        self.audit = audit
        self.makeTicker = makeTicker
        now = clock()
    }

    /// The app's controller, beside the remote-approvals toggle it stops on
    /// Unpair (none in debugBattery mode, like the toggle). Construction does
    /// no I/O: the slot is read when Settings opens, and the live database is
    /// built on the record source's first fetch or deletion. The remembered
    /// name is read from the app's own persistent domain only
    /// (`rememberedName`).
    static func makeIfEnabled(remoteApprovals: RemoteApprovalsController?, keys: PairedKeyStore,
                              defaults: UserDefaults) -> PairingController? {
        guard let remoteApprovals else { return nil }
        let domain = Bundle.main.bundleIdentifier ?? ""
        return PairingController(
            source: CloudKitPairingRecords(database: { CloudKitMessageSender.makeLivePairingDatabase() }), keys: keys,
            readRemembered: { Self.rememberedName(in: defaults.persistentDomain(forName: domain)) },
            writeRemembered: { name in
                if let name { defaults.set(name, forKey: DefaultsKey.pairingRecordToDelete) }
                else { defaults.removeObject(forKey: DefaultsKey.pairingRecordToDelete) }
            },
            killSwitch: { [weak remoteApprovals] in remoteApprovals?.setEnabled(false) })
    }

    /// The remembered record name as the app's OWN persistent domain holds
    /// it (`domain`: that domain's contents), never through the defaults
    /// search list — where a launch argument, the global domain or a
    /// registered default could supply a name for the launch to delete a
    /// record by. nil unless it is text; its shape is checked at the
    /// deletion (`deleteRememberedRecord`).
    nonisolated static func rememberedName(in domain: [String: Any]?) -> String? {
        domain?[DefaultsKey.pairingRecordToDelete] as? String
    }

    /// 32 bytes from the system's cryptographic random source, or nil if it
    /// fails (then no ceremony begins).
    nonisolated static func secureNonce() -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: 32)
        return SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess ? bytes : nil
    }

    // MARK: - What Settings and the sheet render

    /// A refused Unpair shows first, in every phase: the slot reads it as
    /// outstanding (#247), whether or not the item itself still reads.
    var paneState: PairingPaneState {
        let running: Bool
        switch state.phase {
        case .showing, .comparing, .committing: running = true
        case .idle, .paired, .ended: running = false
        }
        switch paired {
        case .unpairOutstanding: return .unpairFailed
        case .paired(let phone):
            return running ? .rotating(phone.fingerprint, since: phone.pairedAt) : .paired(phone.fingerprint, since: phone.pairedAt)
        case .unreadable: return running ? .pairing : .unreadable
        case .notPaired: return running ? .pairing : .notPaired
        }
    }

    var sheetContent: PairingSheetContent {
        PairingSheetContent.make(state, now: now.timeIntervalSince1970)
    }

    // MARK: - Driving the ceremony

    /// Re-reads the slot (Settings opening, and after every change to it).
    func refreshPaired() {
        let read = keys.read()
        guard read != paired else { return }
        paired = read
        onPaneChange?()
    }

    /// Pair iPhone… / Pair a New iPhone… / Start Over.
    func begin() {
        refreshPaired()
        guard let nonce = makeNonce() else {
            audit(.nonceUnavailable)
            return
        }
        generation += 1
        // #240: after a refused Unpair the owner asked for the key to go, so
        // a pairing begun then is a first one (the slot reads it as no
        // pairing, #247): its sheet never says the old pairing keeps working.
        let rotating = if case .paired = paired { true } else { false }
        run(.begin(nonce: nonce, rotating: rotating, now: clock().timeIntervalSince1970))
    }

    func cancel() { run(.cancel) }
    func codesMatch() { run(.codesMatch(now: clock().timeIntervalSince1970)) }
    func codesDiffer() { run(.codesDiffer) }

    /// The sheet became key and unoccluded (true), or stopped being so.
    func setVisible(_ visible: Bool) {
        guard visible != state.visible else { return }
        run(.visible(visible))
    }

    /// The one-second tick (the ticker's; tests call it by hand).
    func tick() { run(.tick(now: clock().timeIntervalSince1970)) }

    /// Unpair, after the owner confirmed it: the remote-approvals toggle
    /// goes off through its kill switch FIRST (#247), so no refused or slow
    /// deletion can leave it on; then the slot records the item as the one
    /// to remove and asks the keychain to delete it. A refused deletion
    /// leaves the slot reading the Unpair as outstanding (#240, #247), so the
    /// pane says so, across relaunches; one that goes through ends it.
    func unpair() {
        killSwitch()
        let gone = keys.unpair()
        audit(gone ? .unpaired : .unpairFailed)
        refreshPaired()
    }

    /// #240: Try Again, after a refused Unpair — already confirmed, so no
    /// alert: the kill switch, then the outstanding Unpair's own deletion
    /// (#247), bound to the item that Unpair recorded: an item written since
    /// is never deleted by it. Nothing while the pane shows no refusal.
    func retryUnpair() {
        guard paired == .unpairOutstanding else { return }
        killSwitch()
        let gone = keys.retryUnpair()
        audit(gone ? .unpaired : .unpairFailed)
        refreshPaired()
    }

    /// Launch: a record name remembered from a ceremony that never ended
    /// (NapCat quit or crashed mid-pairing) is deleted by that name, and
    /// forgotten once it is gone. The nonce was never stored. Only a pairing
    /// record name's shape is acted on (64 lowercase hex digits,
    /// `PairingResponseCheck.isRecordName`): anything else names no record
    /// this Mac made, so nothing is deleted by it, and it is forgotten.
    func deleteRememberedRecord() {
        guard state.phase == .idle, let name = readRemembered() else { return }
        guard PairingResponseCheck.isRecordName(name) else {
            writeRemembered(nil)
            audit(.leftoverMalformed)
            return
        }
        work.append(Task { [weak self] in
            guard let self else { return }
            let gone = await source.delete(recordName: name)
            if gone, readRemembered() == name { writeRemembered(nil) }
            audit(gone ? .leftoverDeleted : .leftoverKept)
        })
    }

    /// Waits for the record work under way (tests).
    func settle() async {
        while !work.isEmpty {
            let pending = work
            work = []
            for task in pending { await task.value }
        }
    }

    // MARK: - Effects

    private func run(_ event: PairingEvent) {
        let before = state
        let paneBefore = paneState
        let secondsBefore = state.secondsLeft(now: now.timeIntervalSince1970)
        now = clock()
        var events = [event]
        var slotChanged = false
        while !events.isEmpty {
            for effect in state.apply(events.removeFirst()) {
                switch perform(effect) {
                case .none: break
                case .some(let next):
                    events.append(next)
                    slotChanged = true
                }
            }
        }
        // #240, #247: a new key written replaces the one Unpair could not
        // remove, and the slot then reads it as the pairing.
        if slotChanged { paired = keys.read() }
        let live = state.phase.isLive
        if live, ticker == nil { ticker = makeTicker { [weak self] in self?.tick() } }
        if !live { ticker?.cancel(); ticker = nil }
        if (before.phase == .idle) != (state.phase == .idle) { onSheetChange?(state.phase != .idle) }
        if let line = PairingSheetContent.announcement(from: before, to: state, secondsBefore: secondsBefore,
                                                       secondsAfter: state.secondsLeft(now: now.timeIntervalSince1970)) {
            announce?(line)
        }
        if paneState != paneBefore { onPaneChange?() }
    }

    /// Performs one effect; a commit returns the keychain write's outcome
    /// as the next event.
    private func perform(_ effect: PairingEffect) -> PairingEvent? {
        switch effect {
        case .rememberRecord(let name):
            writeRemembered(name)
        case .fetch(let name):
            let generation = self.generation
            work.append(Task { [weak self] in
                guard let self else { return }
                let fetched = await source.fetch(recordName: name)
                guard generation == self.generation else { return }
                run(.fetched(fetched, now: clock().timeIntervalSince1970))
            })
        case .delete(let name):
            work.append(Task { [weak self] in
                guard let self else { return }
                if await source.delete(recordName: name), readRemembered() == name { writeRemembered(nil) }
            })
        case .commit(let candidate):
            let phone = PairedPhone(publicKey: candidate.response.publicKey, pairedAt: clock())
            return .committed(phone.map { keys.commit($0) } ?? false)
        case .audit(let line):
            audit(line)
        }
        return nil
    }

    // MARK: - Never printed, dumped or reflected (S-PAIR-C1.5, the C1.5 security review's R1)

    /// The shell holds the paired-key slot (PairingStructureTests lock 7): it
    /// prints, debug-prints, dumps and reflects as a fixed word and nothing
    /// more, so no print, description or `Mirror`-based walk — a `Mirror`, or
    /// `customMirror.descendant` from any wrapper, an array or an optional —
    /// reaches the slot through it. It does NOT stop runtime reflection: the
    /// Swift runtime's field reader and the ObjC runtime's ivar reader both
    /// ignore `CustomReflectable` and read the stored fields as declared.
    /// Lock 7's bans stop them — the Swift one by name, the ObjC one by its C
    /// API — not this redaction; raw-pointer reads remain the accepted R-1
    /// residual. The conformance is the class's own, on its declaration (an
    /// extension of the controller is banned, lock 6).
    nonisolated var description: String { "pairing (redacted)" }
    nonisolated var debugDescription: String { description }
    nonisolated var customMirror: Mirror { Mirror(self, children: [], displayStyle: .class) }
}

/// The `pairing` log category: closed codes only (`PairingAudit.code`).
enum PairingLog {
    private static let logger = Logger(subsystem: "com.muratalkan.napcat", category: "pairing")

    static func record(_ event: PairingAudit) {
        logger.notice("\(event.code, privacy: .public)")
    }
}
