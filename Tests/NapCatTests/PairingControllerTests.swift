// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Combine
import CryptoKit
import NapCatWire
import Testing
@testable import NapCat

/// The pairing record, played by a test: answers each fetch with the next
/// scripted reading (then `.nothing`), records every fetch and deletion.
final class ScriptedPairingRecords: PairingRecordSource, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [PairingFetch]
    private var fetchedNames: [String] = []
    private var deletedNames: [String] = []
    private var deleteAnswer: Bool

    init(_ script: [PairingFetch] = [], deleteAnswer: Bool = true) {
        self.script = script
        self.deleteAnswer = deleteAnswer
    }

    var fetches: [String] { locked { fetchedNames } }
    var deletions: [String] { locked { deletedNames } }
    func answer(_ next: PairingFetch) { locked { script.append(next) } }
    func setDeleteAnswer(_ answer: Bool) { locked { deleteAnswer = answer } }

    func fetch(recordName: String) async -> PairingFetch {
        locked {
            fetchedNames.append(recordName)
            return script.isEmpty ? .nothing : script.removeFirst()
        }
    }

    func delete(recordName: String) async -> Bool {
        locked {
            deletedNames.append(recordName)
            return deleteAnswer
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// A ticker the test fires by hand; tells its world when it is cancelled.
@MainActor
final class ManualPairingTicker: PairingTicker {
    let fire: @MainActor () -> Void
    private let cancelled: @MainActor () -> Void
    private var done = false

    init(_ fire: @escaping @MainActor () -> Void, cancelled: @escaping @MainActor () -> Void) {
        self.fire = fire
        self.cancelled = cancelled
    }

    func cancel() {
        guard !done else { return }
        done = true
        cancelled()
    }
}

/// F4 slice S-PAIR-C1 (#168): the shell around the ceremony, over fakes — a
/// scripted pairing record, an in-memory slot, an in-memory remembered name,
/// a hand-set clock and a hand-fired tick. No CloudKit, keychain, defaults or
/// timer is touched.
@MainActor
final class PairingWorld {
    let records: ScriptedPairingRecords
    let items = FakeTopicStore()
    var remembered: String?
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    var killSwitches = 0
    var audits: [PairingAudit] = []
    var sheets: [Bool] = []
    var announcements: [String] = []
    var nonce: [UInt8]? = PhoneHalf.nonce
    /// Ticks made and not yet cancelled.
    var liveTickers = 0
    private(set) var controller: PairingController!

    init(records: ScriptedPairingRecords = ScriptedPairingRecords()) {
        self.records = records
        controller = PairingController(
            source: records, keys: PairedKeyStore(items: items),
            readRemembered: { [unowned self] in remembered }, writeRemembered: { [unowned self] in remembered = $0 },
            makeNonce: { [unowned self] in nonce }, clock: { [unowned self] in clock },
            killSwitch: { [unowned self] in killSwitches += 1 }, audit: { [unowned self] in audits.append($0) },
            makeTicker: { [unowned self] fire in
                liveTickers += 1
                return ManualPairingTicker(fire) { [unowned self] in liveTickers -= 1 }
            })
        controller.onSheetChange = { [unowned self] in sheets.append($0) }
        controller.announce = { [unowned self] in announcements.append($0) }
    }

    /// Moves the clock and fires the tick, then waits for the record work.
    func advance(to seconds: TimeInterval) async {
        clock = Date(timeIntervalSince1970: 1_800_000_000 + seconds)
        controller.tick()
        await controller.settle()
    }
}

@MainActor
struct PairingControllerTests {
    @Test func aCeremonyRemembersItsNameThenPollsAndFreezes() async throws {
        let response = try PhoneHalf.response()
        let world = PairingWorld(records: ScriptedPairingRecords([.nothing, .found(.response(response))]))
        world.controller.begin()
        #expect(world.sheets == [true], "the sheet shows")
        #expect(world.remembered == PhoneHalf.recordName(), "the NAME is remembered before anything else happens")
        #expect(world.liveTickers == 1, "a live ceremony ticks")
        #expect(world.controller.sheetContent.qrPayload == ApprovalSigning.pairingPayload(nonce: PhoneHalf.nonce))
        await world.advance(to: 2.5)
        #expect(world.records.fetches == [PhoneHalf.recordName()], "fetched by name only")
        #expect(world.controller.state.phase == .showing(offline: false))
        await world.advance(to: 5)
        guard case .comparing(let candidate) = world.controller.state.phase else {
            Issue.record("not comparing: \(world.controller.state.phase)")
            return
        }
        #expect(candidate.response == response)
        #expect(world.controller.sheetContent.screen == .compare && world.controller.sheetContent.qrPayload == nil)
        #expect(world.items.storedValue == nil, "nothing is kept before Codes Match")
        #expect(world.announcements.last?.hasPrefix(PairingSheetContent.compareLine) == true)
        #expect(world.announcements.last?.hasSuffix(candidate.fingerprint.spoken) == true, "the code is spoken as it appears")
    }

    /// Commit order: verify → display → Codes Match → keychain write →
    /// record delete (and only then the remembered name goes).
    @Test func codesMatchWritesTheKeyThenDeletesTheRecord() async throws {
        let response = try PhoneHalf.response()
        let world = PairingWorld(records: ScriptedPairingRecords([.found(.response(response))]))
        world.controller.begin()
        await world.advance(to: 2.5)
        world.clock = Date(timeIntervalSince1970: 1_800_000_010)
        world.controller.codesMatch()
        #expect(world.items.writeCount == 1)
        let phone = try #require(PairedPhone(publicKey: response.publicKey, pairedAt: world.clock))
        #expect(world.items.storedValue == PairedKeyStore.text(of: phone))
        #expect(world.controller.paired == .paired(phone))
        #expect(world.controller.state.phase == .paired(phone.fingerprint))
        await world.controller.settle()
        #expect(world.records.deletions == [PhoneHalf.recordName()])
        #expect(world.remembered == nil, "the name is forgotten once the record is gone")
        #expect(world.controller.paneState == .paired(phone.fingerprint, since: phone.pairedAt))
        #expect(world.audits.contains(.committed))
        #expect(world.sheets == [true], "Done closes it, not the commit (no auto-close)")
        world.controller.cancel()
        #expect(world.sheets == [true, false])
    }

    @Test func aFailedKeychainWriteEndsSaveFailedAndKeepsTheOldKey() async throws {
        let response = try PhoneHalf.response()
        let world = PairingWorld(records: ScriptedPairingRecords([.found(.response(response))]))
        let old = try #require(PairedPhone(publicKey: Array(P256.Signing.PrivateKey().publicKey.x963Representation),
                                           pairedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(PairedKeyStore(items: world.items).commit(old))
        world.controller.begin()
        #expect(world.controller.paneState == .rotating(old.fingerprint, since: old.pairedAt))
        #expect(world.controller.state.rotating)
        await world.advance(to: 2.5)
        world.items.setFailWrites(true)
        world.controller.codesMatch()
        #expect(world.controller.state.phase == .ended(.saveFailed))
        #expect(world.controller.paired == .paired(old), "no partial state: the old pairing stands")
        await world.controller.settle()
        #expect(world.records.deletions == [PhoneHalf.recordName()])
    }

    /// Nonce death is total, whatever ends the ceremony, and the record is
    /// deleted each time.
    @Test func everyEndBurnsTheNonceAndDeletesTheRecord() async throws {
        let ends: [(String, (PairingWorld) async throws -> Void)] = [
            ("cancel", { $0.controller.cancel() }),
            ("the window", { await $0.advance(to: 300) }),
            ("They Don't Match", { world in
                world.records.answer(.found(.response(try PhoneHalf.response())))
                await world.advance(to: 2.5)
                world.controller.codesDiffer()
            }),
            ("a refusal", { world in
                world.records.answer(.found(.response(try PhoneHalf.response(macNonce: PhoneHalf.otherNonce))))
                await world.advance(to: 2.5)
            }),
            ("a second, different response", { world in
                world.records.answer(.found(.response(try PhoneHalf.response())))
                world.records.answer(.found(.response(try PhoneHalf.response())))
                await world.advance(to: 2.5)
                await world.advance(to: 5)
            }),
        ]
        for (name, end) in ends {
            let world = PairingWorld()
                world.controller.begin()
            try await end(world)
            await world.controller.settle()
            #expect(!world.controller.state.holdsNonce, "\(name): the nonce survived")
            #expect(world.records.deletions == [PhoneHalf.recordName()], "\(name): the record was not deleted")
            #expect(world.remembered == nil, "\(name)")
            #expect(world.liveTickers == 0, "\(name): the tick outlived the ceremony")
            #expect(world.items.writeCount == 0, "\(name): something was kept")
        }
    }

    /// A deletion that fails leaves the name remembered for the next launch,
    /// and that launch deletes it by name — never with a nonce.
    @Test func aLeftoverNameIsDeletedAtTheNextLaunch() async {
        let first = PairingWorld()
        first.records.setDeleteAnswer(false)
        first.controller.begin()
        first.controller.cancel()
        await first.controller.settle()
        #expect(first.remembered == PhoneHalf.recordName(), "kept: the record may still be there")

        let relaunch = PairingWorld()
        relaunch.remembered = first.remembered
        relaunch.controller.deleteRememberedRecord()
        await relaunch.controller.settle()
        #expect(relaunch.records.deletions == [PhoneHalf.recordName()])
        #expect(relaunch.remembered == nil && relaunch.audits == [.leftoverDeleted])

        let stillFailing = PairingWorld()
        stillFailing.remembered = "f".padding(toLength: 64, withPad: "f", startingAt: 0)
        stillFailing.records.setDeleteAnswer(false)
        stillFailing.controller.deleteRememberedRecord()
        await stillFailing.controller.settle()
        #expect(stillFailing.remembered != nil && stillFailing.audits == [.leftoverKept])

        let nothing = PairingWorld()
        nothing.controller.deleteRememberedRecord()
        await nothing.controller.settle()
        #expect(nothing.records.deletions.isEmpty && nothing.audits.isEmpty, "no leftover, no deletion")
    }

    /// S-PAIR-C1.5 (#170): a remembered name of any shape but a pairing
    /// record's (64 lowercase hex digits) names no record this Mac made:
    /// nothing is deleted by it, and it is forgotten.
    @Test(arguments: CloudKitPairingRecordsTests.malformedNames)
    func aLeftoverOfAnyOtherShapeIsNeverDeleted(_ name: String) async {
        let world = PairingWorld()
        world.remembered = name
        world.controller.deleteRememberedRecord()
        await world.controller.settle()
        #expect(world.records.deletions.isEmpty, "nothing is deleted by it")
        #expect(world.remembered == nil && world.audits == [.leftoverMalformed])
    }

    /// A late answer to an earlier ceremony's fetch is dropped.
    @Test func aStaleFetchIsDropped() async throws {
        let world = PairingWorld(records: ScriptedPairingRecords([.found(.response(try PhoneHalf.response()))]))
        world.controller.begin()
        world.clock = Date(timeIntervalSince1970: 1_800_000_002.5)
        world.controller.tick()
        world.nonce = PhoneHalf.otherNonce
        world.controller.begin()
        await world.controller.settle()
        #expect(world.controller.state.phase == .showing(offline: false), "the old ceremony's response is not the new one's")
        #expect(world.controller.sheetContent.qrPayload == ApprovalSigning.pairingPayload(nonce: PhoneHalf.otherNonce))
    }

    @Test func noNonceNoCeremony() {
        let world = PairingWorld()
        world.nonce = nil
        world.controller.begin()
        #expect(world.controller.state.phase == .idle && world.sheets.isEmpty && world.remembered == nil)
        #expect(world.audits == [.nonceUnavailable] && world.liveTickers == 0)
    }

    /// Unpair deletes the slot and runs the kill switch, whatever the
    /// deletion came to.
    @Test func unpairDeletesTheKeyAndRunsTheKillSwitch() throws {
        let world = PairingWorld()
        let phone = try #require(PairedPhone(publicKey: Array(P256.Signing.PrivateKey().publicKey.x963Representation),
                                             pairedAt: world.clock))
        #expect(PairedKeyStore(items: world.items).commit(phone))
        world.controller.refreshPaired()
        #expect(world.controller.paneState == .paired(phone.fingerprint, since: phone.pairedAt))
        world.controller.unpair()
        #expect(world.items.storedValue == nil && world.killSwitches == 1 && world.audits == [.unpaired])
        #expect(world.controller.paneState == .notPaired)
        world.items.setFailDeletes(true)
        #expect(PairedKeyStore(items: world.items).commit(phone))
        world.controller.unpair()
        #expect(world.killSwitches == 2 && world.audits == [.unpaired, .unpairFailed], "the kill switch runs regardless")
    }

    /// Zero idle cost: no tick before a ceremony, none after one ends.
    @Test func nothingTicksWhileNoCeremonyIsLive() async {
        let world = PairingWorld()
        world.controller.refreshPaired()
        #expect(world.liveTickers == 0)
        world.controller.begin()
        #expect(world.liveTickers == 1)
        await world.advance(to: 300)
        #expect(world.liveTickers == 0 && world.controller.state.phase == .ended(.expired))
        #expect(world.records.fetches.count <= Int(300 / PairingCeremonyState.pollInterval))
    }

    /// The window's last minute and last ten seconds are announced, once
    /// each; the seconds between are not.
    @Test func theCountdownIsAnnouncedAtOneMinuteAndTenSecondsOnly() async {
        let world = PairingWorld()
        world.controller.begin()
        let opening = world.announcements
        for second in stride(from: 1.0, through: 299, by: 1) { await world.advance(to: second) }
        let countdowns = world.announcements.dropFirst(opening.count).filter { $0.hasPrefix("Code expires in") }
        #expect(countdowns == ["Code expires in 1:00", "Code expires in 0:10"])
    }

    /// S-PAIR-C1.5 (the C1 security delta check's (b)): a live ceremony's shell gives the code away
    /// through no way of describing it — dumped whole, its state reflected —
    /// because the state that holds the nonce redacts itself.
    @Test func aLiveControllerPrintsAndReflectsNoCode() throws {
        let world = PairingWorld()
        world.controller.begin()
        let payload = try #require(world.controller.sheetContent.qrPayload)
        let secrets = Redaction.secrets(payload: payload, nonce: PhoneHalf.nonce)
        #expect(world.controller.state.holdsNonce, "vacuity: the ceremony is live")
        for (name, value) in [("the controller", world.controller as Any), ("its state", world.controller.state),
                              ("its sheet", world.controller.sheetContent)] {
            #expect(Redaction.leaks(value, secrets: secrets).isEmpty, "\(name) leaks through \(Redaction.leaks(value, secrets: secrets))")
        }
    }

    /// S-PAIR-C1.5, the C1.5 security review's R1 (its RP1 probe wrote a fake
    /// key into the slot through `[controller].customMirror.descendant(0,
    /// "keys", "items")`): no reflection from any wrapper — an array's, an
    /// optional's, the controller's own mirror, the slot's — reaches the slot
    /// or its item, so nothing is written by that route; the controller and
    /// the slot print and dump as fixed words. A control: an unredacted
    /// holder of the same item is reached by the same route. (`Mirror`
    /// routes only: the runtime's own field reader ignores the redaction —
    /// `PairingStructureTests.nothingDeclaresARuntimeEntryPoint` stops it.)
    @Test func noReflectionReachesThePairedKeySlot() throws {
        let world = PairingWorld()
        let controller: PairingController = world.controller
        let slot = PairedKeyStore(items: world.items)
        let attacker = try #require(PairedPhone(publicKey: Array(P256.Signing.PrivateKey().publicKey.x963Representation),
                                                pairedAt: world.clock))
        let routes: [(String, Any?)] = [
            ("RP1: an array's customMirror.descendant", [controller].customMirror.descendant(0, "keys", "items")),
            ("RP1 through an optional", Optional(controller).customMirror.descendant("some", "keys", "items")),
            ("the controller's own mirror", Mirror(reflecting: controller).descendant("keys", "items")),
            ("the slot, by its label", Mirror(reflecting: controller).descendant("keys")),
            ("the record source, by its label", Mirror(reflecting: controller).descendant("source")),
            ("the slot's item, from the slot", Mirror(reflecting: slot).descendant("items")),
            ("the slot's item, through an array", [slot].customMirror.descendant(0, "items")),
        ]
        for (name, reached) in routes {
            #expect(reached == nil, "\(name) reached a part")
            #expect((reached as? any TopicStore)?.write(PairedKeyStore.text(of: attacker)) == nil)
        }
        world.controller.refreshPaired()
        #expect(world.items.writeCount == 0 && world.controller.paneState == .notPaired, "nothing was written")
        for (name, value, word) in [("the controller", controller as Any, "pairing (redacted)"),
                                    ("the slot", slot as Any, "paired key slot (redacted)")] {
            #expect(Mirror(reflecting: value).children.isEmpty, "\(name) reflects a part")
            var dumped = ""
            dump(value, to: &dumped)
            for text in [String(describing: value), String(reflecting: value), dumped] {
                #expect(text.contains(word) && !text.contains("items") && !text.contains("keys"), "\(name): \(text)")
            }
        }
        struct Slot { let items: any TopicStore }
        struct Holder { let keys: Slot }
        #expect([Holder(keys: Slot(items: world.items))].customMirror.descendant(0, "keys", "items") is any TopicStore,
                "vacuity: the route reaches an unredacted holder's item")
    }

    /// The redaction leaves the controller observable: the sheet (SwiftUI's
    /// `@ObservedObject`) still hears every change.
    @Test func theRedactedControllerStillPublishes() {
        let world = PairingWorld()
        var changes = 0
        let watch = world.controller.objectWillChange.sink { changes += 1 }
        world.controller.begin()
        #expect(changes > 0, "a change the sheet would not hear")
        watch.cancel()
    }

    /// Hidden while not key or occluded (S1b), announced; back on key.
    @Test func theSheetHidesTheCodeWhileNotVisible() {
        let world = PairingWorld()
        world.controller.begin()
        world.controller.setVisible(false)
        #expect(world.controller.sheetContent.screen == .hidden && world.controller.sheetContent.qrPayload == nil)
        #expect(world.announcements.last == "Note: " + PairingSheetContent.hiddenLine, "its severity word first")
        #expect(world.controller.state.holdsNonce, "hiding burns nothing")
        world.controller.setVisible(true)
        #expect(world.controller.sheetContent.screen == .code)
    }
}
