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
// possible only when the iPhone half lands (a later slice amends this file
// and its lint deliberately).

/// The seam's record sink in this slice: it writes NOTHING. There is no
/// CloudKit record operation before the iPhone half exists — and since the
/// host is never armed, the intake never asks this sink to save anyway.
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
    private let readStored: () -> Any?
    private let writeStored: (Bool) -> Void
    private let makeHost: HostFactory
    private let probe: () -> ChannelPolicyFinding
    private let audit: (ApprovalAuditEvent) -> Void
    private var changeHandler: (() -> Void)?

    private(set) var state = RemoteApprovalsState()
    /// Built on the first switch-on, never before. Kept after the kill switch
    /// (stopped: no socket, no listener, no connection), so a decision that
    /// arrives for a prompt the kill switch withdrew is still answered by
    /// that prompt's own lifecycle — and logged as ignored.
    private(set) var host: ApprovalSeamHost?

    /// `readStored` / `writeStored` are the stored toggle
    /// (`DefaultsKey.remoteApprovalsEnabled` in the app).
    init(socketPath: String, readStored: @escaping () -> Any?, writeStored: @escaping (Bool) -> Void,
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
    /// guard (it holds the alert topic, a secret the gate keeps on the Mac)
    /// or without a home directory to put the socket in. Construction does
    /// no I/O: nothing listens until `reconcile()` reads a switched-on
    /// toggle. The socket path comes from the user database, like the
    /// channel server's, so both land on the same socket.
    static func makeIfEnabled(debugBattery: Bool, lidGuard: LidGuardController?,
                              defaults: UserDefaults = .standard) -> RemoteApprovalsController? {
        guard RemoteApprovalsPolicy.remoteApprovalsMayBeConstructed(debugBattery: debugBattery) else { return nil }
        guard let lidGuard, let home = SeamPaths.homeDirectory() else { return nil }
        return RemoteApprovalsController(
            socketPath: SeamPaths.socketPath(home: home),
            readStored: { defaults.object(forKey: DefaultsKey.remoteApprovalsEnabled) },
            writeStored: { defaults.set($0, forKey: DefaultsKey.remoteApprovalsEnabled) },
            makeHost: { Self.failDarkHost(socketPath: $0, secrets: { @Sendable in [lidGuard.storedTopic] }) },
            probe: { ChannelPolicyProbe.probe() })
    }

    /// The ONE construction of the seam host: never armed, and its record
    /// sink writes nothing (fail-dark until the iPhone half exists).
    /// Its closures run on the seam's queue, hence `@Sendable`.
    nonisolated static func failDarkHost(socketPath: String, secrets: @escaping @Sendable () -> [String],
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
    /// sessions just relayed: counts per kind of those the gate would
    /// forward, opened in the last `ApprovalIntake.waitingContextSeconds`.
    /// Nothing while not listening — off, the host is never even reached.
    func waitingPrompts() -> WaitingPromptCounts {
        guard state.phase == .listening, let host else { return .none }
        let tools = host.withIntake { $0.recentForwardableTools(within: ApprovalIntake.waitingContextSeconds) } ?? []
        return WaitingPromptCounts(tools)
    }

    /// Called (on the main actor) after every change the menu renders.
    func setChangeHandler(_ handler: (() -> Void)?) {
        changeHandler = handler
    }

    // MARK: - Driving the toggle

    /// Applies the stored toggle: at launch, and before every refresh.
    func reconcile() {
        run(.toggle(RemoteApprovalsPolicy.enabled(stored: readStored())))
    }

    /// The menu or the Settings window opened: the stored toggle again (it
    /// may have been written outside NapCat), then — while on — a fresh
    /// policy reading and a retry of a socket that could not be opened.
    func refresh() {
        reconcile()
        run(.refresh)
    }

    /// The user flipped the toggle. Off is the kill switch.
    func setEnabled(_ enabled: Bool) {
        writeStored(enabled)
        reconcile()
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
