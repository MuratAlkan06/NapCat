import Foundation
import IOKit
import IOKit.pwr_mgt
import os

/// The system power notifications the lid guard reacts to.
///
/// Why IOKit and not `NSWorkspace.willSleepNotification`: an NSWorkspace
/// observer cannot delay sleep at all, and its delivery may be postponed
/// (Apple QA1340). Only a connection made with `IORegisterForSystemPower` gets
/// the acknowledgment protocol we need to hand the message to Messages before
/// the machine goes down.
enum SystemSleepEvent: Equatable, Sendable {
    /// The system is ASKING whether it may sleep (idle-sleep poll). Must be
    /// answered IMMEDIATELY and without policy: while this is unanswered every
    /// sleep on the machine is delayed, up to the OS cap (~30 s).
    case canSystemSleep
    /// Sleep is happening. This is the only event the fire gate runs on; the
    /// acknowledgment may be held briefly (`LidGuardTuning.ackHoldBudget`).
    case systemWillSleep
    /// Waking up (before drivers are back). No acknowledgment required.
    case systemWillPowerOn
    /// Awake. No acknowledgment required.
    case systemHasPoweredOn
}

/// Acknowledgment token for one power notification. `allow()` is idempotent —
/// exactly one `IOAllowPowerChange` per notification, no matter how many code
/// paths (fast path, hold path, force-ack timer) call it.
final class SystemSleepAck: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private let action: @Sendable () -> Void

    init(action: @escaping @Sendable () -> Void) {
        self.action = action
    }

    /// For events that carry no acknowledgment (wake).
    static func noOp() -> SystemSleepAck { SystemSleepAck {} }

    func allow() {
        lock.lock()
        callCount += 1
        let isFirst = callCount == 1
        lock.unlock()
        guard isFirst else { return }
        action()
    }

    /// How many times `allow()` was CALLED (the action ran on the first call
    /// only). Observability for the ack-exactly-once tests.
    var allowCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    var didAllow: Bool { allowCallCount > 0 }
}

/// Sleep/wake feed behind a protocol so tests can synthesize the full message
/// table without touching IOKit.
///
/// Registration is NOT a lifetime thing: `start` is called when the lid guard
/// ARMS and `stop` when it disarms or the app quits, so a disarmed NapCat has
/// zero sleep-path footprint.
protocol SystemSleepSource: AnyObject, Sendable {
    /// Registers for system power notifications. `handler` is invoked on a
    /// PRIVATE serial queue (never the main queue) with an ack token.
    func start(handler: @escaping @Sendable (SystemSleepEvent, SystemSleepAck) -> Void)
    /// Deregisters and tears the notification port down. Idempotent.
    func stop()
    /// Whether registration is currently desired/active.
    var isRunning: Bool { get }
}

/// READER FILE (structural-isolation boundary): the ONLY place
/// `IORegisterForSystemPower`, `IODeregisterForSystemPower`,
/// `IOAllowPowerChange`, and `IONotificationPortSetDispatchQueue` may appear
/// (`LidGuardStructureTests` enforces this).
///
/// All of these are UNPRIVILEGED: registering for power notifications needs no
/// root, no entitlement, and adds no PLAN §4 command.
final class IOKitSystemSleepSource: SystemSleepSource, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.muratalkan.napcat", category: "lidguard")

    /// Private serial queue for both the notification callbacks and the
    /// register/unregister work, so teardown can never race a callback.
    private let queue = DispatchQueue(label: "com.muratalkan.napcat.lidguard.power")

    private let lock = NSLock()
    /// Guarded by `lock`: the state the caller asked for. Register/unregister
    /// work is enqueued only on a real transition, so the serial queue sees the
    /// transitions in order.
    private var desiredRunning = false
    private var handler: (@Sendable (SystemSleepEvent, SystemSleepAck) -> Void)?

    // Touched ONLY on `queue`.
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    /// Deliberate self-retain while registered: the C callback holds an opaque
    /// pointer to us, so we must outlive the registration. Balanced in
    /// `unregister()`.
    private var selfReference: Unmanaged<IOKitSystemSleepSource>?

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return desiredRunning
    }

    func start(handler: @escaping @Sendable (SystemSleepEvent, SystemSleepAck) -> Void) {
        lock.lock()
        guard !desiredRunning else {
            lock.unlock()
            return
        }
        desiredRunning = true
        self.handler = handler
        lock.unlock()
        queue.async { [weak self] in self?.register() }
    }

    func stop() {
        lock.lock()
        guard desiredRunning else {
            lock.unlock()
            return
        }
        desiredRunning = false
        handler = nil
        lock.unlock()
        // Asynchronous on the notification queue: any in-flight callback
        // finishes first, and a caller on the main thread can never deadlock
        // against a callback that is waiting for the main queue.
        queue.async { [weak self] in self?.unregister() }
    }

    // MARK: - Registration (queue-confined)

    private func register() {
        guard rootPort == 0 else { return }
        let reference = Unmanaged.passRetained(self)
        var port: IONotificationPortRef?
        var object: io_object_t = 0
        let connection = IORegisterForSystemPower(
            reference.toOpaque(),
            &port,
            Self.powerCallback,
            &object
        )
        guard connection != 0, let port else {
            reference.release()
            // Clear the desired flag too, otherwise `isRunning` stays true and
            // every later refreshArming() skips the retry — an armed guard that
            // silently never hears a sleep notification again.
            lock.lock()
            desiredRunning = false
            handler = nil
            lock.unlock()
            Self.logger.error("IORegisterForSystemPower failed — lid guard cannot observe sleep")
            return
        }
        // Private queue, never the main runloop: sleep notifications must be
        // serviced even if the main thread is busy.
        IONotificationPortSetDispatchQueue(port, queue)
        rootPort = connection
        notifyPort = port
        notifier = object
        selfReference = reference
        Self.logger.notice("lid guard armed — registered for system power notifications")
    }

    private func unregister() {
        guard rootPort != 0 else { return }
        if let notifyPort {
            IONotificationPortSetDispatchQueue(notifyPort, nil)
        }
        IODeregisterForSystemPower(&notifier)
        IOServiceClose(rootPort)
        if let notifyPort {
            IONotificationPortDestroy(notifyPort)
        }
        rootPort = 0
        notifyPort = nil
        notifier = 0
        selfReference?.release()
        selfReference = nil
        Self.logger.notice("lid guard disarmed — deregistered from system power notifications")
    }

    // MARK: - Callback

    /// Context-free C trampoline; the opaque refcon is the retained `self`.
    private static let powerCallback: IOServiceInterestCallback = { refcon, _, messageType, messageArgument in
        guard let refcon else { return }
        Unmanaged<IOKitSystemSleepSource>.fromOpaque(refcon)
            .takeUnretainedValue()
            .deliver(messageType: messageType, argument: messageArgument)
    }

    /// Runs on `queue` (set via `IONotificationPortSetDispatchQueue`).
    private func deliver(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        guard let event = Self.event(forMessageType: messageType) else { return }
        let ack: SystemSleepAck
        switch event {
        case .canSystemSleep, .systemWillSleep:
            let connection = rootPort
            let notificationID = Int(bitPattern: argument)
            ack = SystemSleepAck { IOAllowPowerChange(connection, notificationID) }
        case .systemWillPowerOn, .systemHasPoweredOn:
            ack = .noOp()
        }
        dispatch(event: event, ack: ack)
    }

    /// Hands one event to the installed handler. If `stop()` raced a callback
    /// that was already queued, there is no handler left — and we must STILL
    /// acknowledge, or macOS waits out its ~30 s timeout before sleeping.
    /// Internal so the no-handler path is unit-testable without IOKit.
    func dispatch(event: SystemSleepEvent, ack: SystemSleepAck) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        guard let handler else {
            ack.allow()
            return
        }
        handler(event, ack)
    }

    // MARK: - Message constants

    /// `iokit_common_msg(x)` from `<IOKit/IOMessage.h>`. The macro itself is
    /// NOT importable into Swift ("macro unavailable: structure not
    /// supported"), so its one-line arithmetic is reproduced verbatim:
    /// `sys_iokit | sub_iokit_common | x`, where
    /// `sys_iokit = err_system(0x38) = (0x38 & 0x3f) << 26` (= 0xE000_0000)
    /// and `sub_iokit_common = err_sub(0) = 0`.
    /// `SystemSleepSourceTests` locks the four resulting values.
    static func iokitCommonMessage(_ message: UInt32) -> UInt32 {
        let sysIOKit: UInt32 = (0x38 & 0x3F) << 26
        let subIOKitCommon: UInt32 = 0
        return sysIOKit | subIOKitCommon | message
    }

    /// `kIOMessageCanSystemSleep` — 0xE000_0270.
    static let canSystemSleepMessage = iokitCommonMessage(0x270)
    /// `kIOMessageSystemWillSleep` — 0xE000_0280.
    static let systemWillSleepMessage = iokitCommonMessage(0x280)
    /// `kIOMessageSystemWillPowerOn` — 0xE000_0320.
    static let systemWillPowerOnMessage = iokitCommonMessage(0x320)
    /// `kIOMessageSystemHasPoweredOn` — 0xE000_0300.
    static let systemHasPoweredOnMessage = iokitCommonMessage(0x300)
    /// `kIOMessageSystemWillNotSleep` — 0xE000_0290. Listed so the "ignored,
    /// needs no reply" case is explicit and testable.
    static let systemWillNotSleepMessage = iokitCommonMessage(0x290)

    /// Pure message-table mapping (unit-tested without registering anything).
    /// Unhandled messages — notably `kIOMessageSystemWillNotSleep`, which needs
    /// no reply — return nil and are ignored.
    nonisolated static func event(forMessageType messageType: UInt32) -> SystemSleepEvent? {
        switch messageType {
        case canSystemSleepMessage:
            return .canSystemSleep
        case systemWillSleepMessage:
            return .systemWillSleep
        case systemWillPowerOnMessage:
            return .systemWillPowerOn
        case systemHasPoweredOnMessage:
            return .systemHasPoweredOn
        default:
            return nil
        }
    }
}
