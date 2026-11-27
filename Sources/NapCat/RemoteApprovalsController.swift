import Foundation
import NapCatSeam
import NapCatWire

// F4 slice S2: the Mac toggle for remote approvals, a THIN SHELL around the
// pure `RemoteApprovalsState`: it reads and writes the stored toggle,
// performs the effects the state machine returns, and owns the seam host.
// Design: design/remote-approvals.md.
//
// BEHIND THE TOGGLE ONLY (lint-locked, ApprovalChannelStructureTests): the
// seam host is built in exactly one place, `failDarkHost`, and started only
// by `listen()`, which runs for a switched-on toggle alone; the managed-
// settings probe runs only as the state machine's `.probe` effect, which it
// returns only while on. Off — the default — nothing exists: no socket, no
// listener, no probe, no timer.
//
// FAIL-DARK: the host is built never armed and its record sink writes
// nothing, so a prompt heard here is classified, audited and kept on this
// Mac. No CloudKit record operation exists in this slice; forwarding becomes
// possible only when the Mac arms it (the Mac's decision alone, not the
// iPhone's), which waits on the Mac's live record path and the seam's check
// of which program listens (still owed; #221 holds every answer until then),
// among the items owed before arming (a later slice amends this file and
// its lint deliberately).

/// The seam's record sink in this slice: it writes NOTHING. No prompt record
/// is written before the Mac's live record path exists — and since the host
/// is never armed, the intake never asks this sink to save anyway.
final class FailDarkApprovalRecords: ApprovalRecordSink {
    func save(_ id: PromptID, tool: ApprovalTool, inputPreview: String, expiresAt: Int) {}
    func retract(_ id: PromptID) {}
    func supersedeWaitingAlert(_ id: PromptID) {}
}

extension WaitingPromptCounts {
    /// Counts per kind. Exhaustive on purpose: a new gate tool does not
    /// compile until it has its own count.
    init(_ tools: [ApprovalTool]) {
        self.init()
        for tool in tools {
            switch tool {
            case .bash: bash += 1
            case .write: write += 1
            case .edit: edit += 1
            case .notebookEdit: notebookEdit += 1
            case .read: read += 1
            }
        }
    }
}

@MainActor
final class RemoteApprovalsController {
    /// Builds the seam host for a socket path (the production factory is
    /// `failDarkHost`; tests inject their own).
    typealias HostFactory = (_ socketPath: String) -> ApprovalSeamHost

    private let socketPath: String
    private let readStored: () -> Bool
    private let writeStored: (Bool) -> Void
    private let makeHost: HostFactory
    private let probe: () -> ChannelPolicyFinding
    private let audit: (ApprovalAuditEvent) -> Void
    private var changeHandler: (() -> Void)?

    private(set) var state = RemoteApprovalsState()
    /// Built on the first switch-on, never before. Kept after the kill switch
    /// (stopped: no socket, no listener, no connection), so a decision that
    /// arrives for a prompt the kill switch withdrew is still answered by
    /// that prompt's own lifecycle — and logged as ignored. Private, so
    /// nothing outside this file can start it again behind the switch
    /// (lint-locked; tests see the host through their own factory).
    private var host: ApprovalSeamHost?
    /// Where the last read for a waiting alert left off (`waitingPrompts`),
    /// handed back at the next read, so a prompt is new to one read at most.
    /// Kept here, on the main actor; opaque, never a prompt's ID.
    private var relayMark: PromptRelayMark?

    /// `readStored` / `writeStored` are the stored toggle
    /// (`DefaultsKey.remoteApprovalsEnabled` in the app): the read is the
    /// toggle as `RemoteApprovalsPolicy.enabled` reads it (`storedToggle`).
    init(socketPath: String, readStored: @escaping () -> Bool, writeStored: @escaping (Bool) -> Void,
         makeHost: @escaping HostFactory, probe: @escaping () -> ChannelPolicyFinding,
         audit: @escaping (ApprovalAuditEvent) -> Void = ApprovalAuditLog.record) {
        self.socketPath = socketPath
        self.readStored = readStored
        self.writeStored = writeStored
        self.makeHost = makeHost
        self.probe = probe
        self.audit = audit
    }

    /// The single construction site, gated by the debug-sim wiring predicate
    /// (checked FIRST): nil in debugBattery mode, and nil without the lid
    /// guard (it holds the alert topic, a secret the gate keeps on the Mac —
    /// or, when the topic could not be read, the fail-closed nil)
    /// or without a home directory to put the socket in. Construction does
    /// no I/O: nothing listens until a read of the stored toggle finds
    /// it on. The socket path comes from the user database, like the
    /// channel server's, so both land on the same socket. The toggle is
    /// read from the app's own domain (`storedToggle`).
    static func makeIfEnabled(debugBattery: Bool, lidGuard: LidGuardController?,
                              defaults: UserDefaults = .standard) -> RemoteApprovalsController? {
        guard RemoteApprovalsPolicy.remoteApprovalsMayBeConstructed(debugBattery: debugBattery) else { return nil }
        guard let lidGuard, let home = SeamPaths.homeDirectory() else { return nil }
        return RemoteApprovalsController(
            socketPath: SeamPaths.socketPath(home: home),
            readStored: { Self.storedToggle(defaults, domain: Bundle.main.bundleIdentifier ?? "") },
            writeStored: { defaults.set($0, forKey: DefaultsKey.remoteApprovalsEnabled) },
            makeHost: { Self.failDarkHost(socketPath: $0, secrets: { @Sendable in lidGuard.approvalSecrets }) },
            probe: { ChannelPolicyProbe.probe() })
    }

    /// The stored toggle as NapCat reads it (#205): what the app's OWN
    /// persistent domain (`domain`: its name) holds, and what the defaults
    /// search list reads — ON only when both are a Bool `true`
    /// (`RemoteApprovalsPolicy.enabled`). A launch argument, a per-host
    /// value, the global domain or a registered default can never turn it
    /// on, since only the app's own domain is read for that; one that
    /// outranks the app's domain (a launch argument, a managed setting, a
    /// per-host value written with `defaults -currentHost`) can turn it off.
    nonisolated static func storedToggle(_ defaults: UserDefaults, domain: String) -> Bool {
        RemoteApprovalsPolicy.enabled(stored: defaults.persistentDomain(forName: domain)?[DefaultsKey.remoteApprovalsEnabled],
                                      searched: defaults.object(forKey: DefaultsKey.remoteApprovalsEnabled))
    }

    /// The ONE construction of the seam host: never armed, and its record
    /// sink writes nothing (fail-dark until the Mac arms forwarding, which
    /// waits on, among other items, its live record path and the seam's
    /// check of which program listens).
    /// Its closures run on the seam's queue, hence `@Sendable`.
    nonisolated static func failDarkHost(socketPath: String, secrets: @escaping @Sendable () -> [String]?,
                                         audit: @escaping @Sendable (ApprovalAuditEvent) -> Void = ApprovalAuditLog.record,
                                         peerReader: @escaping @Sendable (Int32) -> SeamPeer? = SeamSocket.peer(of:))
        -> ApprovalSeamHost {
        ApprovalSeamHost(socketPath: socketPath, armed: { false }, secrets: secrets,
                         records: FailDarkApprovalRecords(), audit: audit, peerReader: peerReader)
    }

    // MARK: - What the menu and Settings render

    var phase: RemoteApprovalsPhase { state.phase }
    var enabled: Bool { state.enabled }
    /// The managed-settings reading, while on.
    var finding: ChannelPolicyFinding? { state.finding }

    /// What a waiting buzz may say about the permission prompts wired
    /// sessions just relayed, and what the alert lane needs to tell whether
    /// the phone's own prompt push covers a wait: one read of the intake
    /// (`ApprovalIntake.waitingPromptRead`), as counts only. Per kind, those
    /// the gate would forward that opened in the last
    /// `ApprovalIntake.waitingContextSeconds`, and of those the ones with
    /// evidence; how many prompts were relayed since the previous read and
    /// in the last `ApprovalIntake.newPromptSeconds`, and how many of those
    /// have evidence. Every read moves the mark on. Nothing while not
    /// listening — off, the host is never even reached, and the mark stays.
    func waitingPrompts() -> WaitingPromptContext {
        guard state.phase == .listening, let host else { return .none }
        let mark = relayMark
        let prompts = host.withIntake { $0.waitingPromptRead(after: mark, within: ApprovalIntake.waitingContextSeconds) }
        guard let prompts else { return .none }
        relayMark = prompts.mark
        return WaitingPromptContext(counts: WaitingPromptCounts(prompts.recent),
                                    countsWithEvidence: WaitingPromptCounts(prompts.recentWithEvidence),
                                    newPrompts: prompts.newPrompts, newPromptsWithEvidence: prompts.newPromptsWithEvidence)
    }

    /// Called (on the main actor) after every change the menu renders.
    func setChangeHandler(_ handler: (() -> Void)?) {
        changeHandler = handler
    }

    // MARK: - Driving the toggle

    /// Applies the stored toggle: at launch, and before every refresh.
    func reconcile() {
        run(.toggle(readStored()))
    }

    /// The menu or the Settings window opened: the stored toggle again (it
    /// may have been written outside NapCat), then — while on — a fresh
    /// policy reading and a retry of a socket that could not be opened.
    func refresh() {
        reconcile()
        run(.refresh)
    }

    /// The user flipped the toggle (the menu, Settings, or Unpair's kill
    /// switch). Off is the kill switch, run in process at once and never
    /// read back (#205): within this call, and until the store is next read
    /// (`reconcile()`), nothing the store holds can keep the feature on. The
    /// off is still written, for the next launch; a store that never kept
    /// that write can read on again at the next read. On is written, then
    /// read back, so a stored value that disagrees keeps it off; a vetoed
    /// on is written back off, so what is stored matches what the switch
    /// shows.
    func setEnabled(_ enabled: Bool) {
        guard enabled else {
            run(.toggle(false))
            writeStored(false)
            return
        }
        writeStored(true)
        let readBack = readStored()
        run(.toggle(readBack))
        if !readBack { writeStored(false) }
    }

    /// NapCat is quitting: a hard stop — the kill switch, final.
    func shutdown() {
        run(.shutdown)
    }

    private func run(_ event: RemoteApprovalsEvent) {
        let before = state
        for effect in state.apply(event) {
            perform(effect)
        }
        if state != before { changeHandler?() }
    }

    private func perform(_ effect: RemoteApprovalsEffect) {
        switch effect {
        case .startListening:
            listen()
        case .stopListening:
            host?.stop()
            audit(.stopped)
        case .probe:
            run(.probed(probe()))
        }
    }

    /// The ONE place the seam host is built and started — only for a
    /// switched-on toggle.
    private func listen() {
        guard state.enabled else { return }
        let host = self.host ?? makeHost(socketPath)
        self.host = host
        let started = host.start()
        audit(started ? .listening : .listenFailed)
        run(.listened(started))
    }
}
