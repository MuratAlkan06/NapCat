import CryptoKit
import Foundation
import NapCatWire
@testable import NapCatPhone
import Testing

/// The pairing seam, played by a test: keeps every response it is handed
/// and answers with the scripted outcome; `during` runs while the save is
/// under way. Nothing is written anywhere.
@MainActor
final class RecordingPairingWriter: PairingResponseWriter {
    var outcome: PairingWriteOutcome
    var during: (() -> Void)?
    private(set) var written: [PairingResponse] = []

    init(_ outcome: PairingWriteOutcome = .saved) {
        self.outcome = outcome
    }

    func write(_ response: PairingResponse) async -> PairingWriteOutcome {
        written.append(response)
        during?()
        return outcome
    }
}

/// The phone's half of the pairing ceremony (F4 slice S-PAIR-B): one strict
/// scan, a provisional key, one match for the proof, one response written,
/// the phone's own code shown, and the key committed only on the owner's
/// confirm. Software keys, a scripted gate and a recording writer only.
@MainActor
@Suite struct PairingCeremonyTests {
    nonisolated static let nonce = Array((0..<32).map { UInt8($0 * 7 & 0xff) })
    nonisolated static let payload = ApprovalSigning.pairingPayload(nonce: nonce)!

    @MainActor
    final class World {
        let clock = TestClock()
        let keys = PhoneKeyringTests.World()
        let gate = ScriptedBiometricGate()
        let writer = RecordingPairingWriter()
        private(set) lazy var ceremony = PairingCeremony(keyring: keys.keyring, biometrics: gate, writer: writer,
                                                         clock: { [clock] in clock.now })

        /// A pairing from an earlier ceremony, committed: its public key.
        func pairedBefore() -> [UInt8] {
            let key = keys.keyring.makeProvisional() ?? []
            _ = keys.keyring.commitProvisional()
            return key
        }

        /// Whether the committed key signs, verifiably by `publicKey`.
        func committedSigns(as publicKey: [UInt8]) -> Bool {
            let message = Array("probe".utf8)
            guard case .signed(let signature) = keys.keyring.sign(message, match: TestMatch()) else { return false }
            return SignatureCheck.verifies(signature, over: message, by: publicKey)
        }
    }

    // MARK: One scan, one response, the phone's own code

    /// The response carries exactly what the Mac checks: the record name
    /// from the labeled nonce digest, the new key, the HMAC keyed by the
    /// nonce over the pinned confirmation layout, and the new key's proof
    /// over the pinned proof layout. Then the phone shows ITS key's code and
    /// waits: the key is provisional, and nothing reads "Paired".
    @Test func aScanWritesOneResponseAndWaits() async throws {
        let world = World()
        await world.ceremony.scanned(Self.payload)
        #expect(world.gate.requests == [PairingCeremony.reason])
        try #require(world.writer.written.count == 1)
        let response = world.writer.written[0]
        let publicKey = Array(response.publicKey)
        let nameDigest = SHA256.hash(data: Array(ApprovalSigning.pairNameLabel.utf8) + Self.nonce)
        #expect(response.recordName == nameDigest.map { String(format: "%02x", $0) }.joined())
        #expect(response.wireVersion == ApprovalWire.wireVersion)
        #expect(publicKey.count == 65 && publicKey.first == 0x04)
        let confirmation = try #require(ApprovalSigning.pairingConfirmationMessage(wireVersion: 1, publicKey: publicKey))
        let mac = HMAC<SHA256>.authenticationCode(for: confirmation, using: SymmetricKey(data: Self.nonce))
        #expect(response.confirmation == Data(mac))
        let proof = try #require(ApprovalSigning.pairingProofMessage(nonce: Self.nonce, publicKey: publicKey))
        #expect(SignatureCheck.verifies(response.proof, over: proof, by: publicKey))
        let fingerprint = try #require(KeyFingerprint(publicKey: publicKey))
        #expect(world.ceremony.phase == .waiting(fingerprint, until: world.clock.now.addingTimeInterval(PairingCeremony.window)))
        #expect(world.keys.committed() == nil, "provisional until the confirm")
        #expect(world.keys.provisional() != nil)
        #expect(world.keys.keyring.health() == .unpaired(.neverPaired))
        #expect(world.gate.matches.allSatisfy { !$0.isValid }, "the proof spent its match")
    }

    /// The owner's confirm commits the key: from then on decisions are
    /// signed by the key the pairing showed.
    @Test func theConfirmCommitsTheKey() async throws {
        let world = World()
        await world.ceremony.scanned(Self.payload)
        let publicKey = Array(try #require(world.writer.written.first).publicKey)
        let fingerprint = try #require(KeyFingerprint(publicKey: publicKey))
        world.ceremony.confirmCodesMatch()
        #expect(world.ceremony.phase == .paired(fingerprint))
        #expect(world.keys.provisional() == nil)
        #expect(world.committedSigns(as: publicKey))
    }

    /// The code is this phone's own: computed from the key it made, the
    /// one it wrote — never from anything it read.
    @Test func theCodeIsThePhonesOwnKeys() async throws {
        let world = World()
        await world.ceremony.scanned(Self.payload)
        guard case .waiting(let shown, _) = world.ceremony.phase else {
            Issue.record("not waiting: \(world.ceremony.phase)")
            return
        }
        let written = Array(try #require(world.writer.written.first).publicKey)
        #expect(shown == KeyFingerprint(publicKey: written))
        // ... and the key the phone holds (provisionally) is that key.
        let probe = Array("probe".utf8)
        guard case .signed(let signature) = world.keys.keyring.signProvisional(probe, match: TestMatch()) else {
            Issue.record("the provisional key did not sign")
            return
        }
        #expect(SignatureCheck.verifies(signature, over: probe, by: written))
    }

    // MARK: Strict reading; one scan per ceremony

    nonisolated static let refusedPayloads: [String] = {
        let good = payload
        let encoded = String(good.dropFirst("napcat-pair-v1:".count))
        return [
            "", "napcat-pair-v1:", "napcat-pair-v1", good + "=", good + "\n", " " + good, good + " ",
            "NAPCAT-PAIR-V1:" + encoded, "napcat-pair-v2:" + encoded, "napcat-pair-v1:" + String(encoded.dropLast()),
            "napcat-pair-v1:" + encoded + "A", "napcat-pair-v1:" + encoded.replacingOccurrences(of: "-", with: "+"),
            "napcat-pair-v1:" + String(encoded.dropLast()) + "/", "https://example.com/pair?code=" + encoded,
            "napcat-pair-v1:" + encoded.uppercased(), FixturePairing.strayCode,
        ].filter { $0 != good }
    }()

    /// Anything but the exact payload is refused: no key is made, nothing
    /// is asked, nothing is written, and the ceremony is over.
    @Test(arguments: refusedPayloads)
    func anythingElseIsRefused(_ payload: String) async {
        let world = World()
        await world.ceremony.scanned(payload)
        #expect(world.ceremony.phase == .refused)
        #expect(world.gate.requests.isEmpty)
        #expect(world.writer.written.isEmpty)
        #expect(world.keys.provisional() == nil && world.keys.committed() == nil)
        await world.ceremony.scanned(Self.payload)
        #expect(world.ceremony.phase == .refused, "one scan per ceremony")
        #expect(world.writer.written.isEmpty)
    }

    /// A second scan, in any later phase, changes nothing.
    @Test func aSecondScanIsIgnored() async throws {
        let world = World()
        await world.ceremony.scanned(Self.payload)
        let first = try #require(world.writer.written.first)
        let other = ApprovalSigning.pairingPayload(nonce: Array(repeating: 9, count: 32))!
        await world.ceremony.scanned(other)
        world.ceremony.confirmCodesMatch()
        await world.ceremony.scanned(other)
        #expect(world.writer.written == [first])
        #expect(world.gate.requests.count == 1)
    }

    // MARK: Provisional until the confirm: a stale code never costs a pairing

    /// Each way a ceremony ends without the confirm discards its key and
    /// leaves the earlier pairing signing.
    @Test func everyEndWithoutTheConfirmKeepsTheEarlierPairing() async throws {
        let ends: [(String, PairingCeremony.Phase, (World) async -> Void)] = [
            ("cancelled while waiting", .cancelled, { world in
                await world.ceremony.scanned(Self.payload)
                world.ceremony.cancel()
            }),
            ("cancelled during the match", .cancelled, { world in
                world.gate.during = { world.ceremony.cancel() }
                await world.ceremony.scanned(Self.payload)
            }),
            ("cancelled during the save", .cancelled, { world in
                world.writer.during = { world.ceremony.cancel() }
                await world.ceremony.scanned(Self.payload)
            }),
            ("the window closes while waiting", .expired, { world in
                await world.ceremony.scanned(Self.payload)
                world.clock.advance(PairingCeremony.window)
                world.ceremony.tick()
            }),
            ("the confirm comes too late", .expired, { world in
                await world.ceremony.scanned(Self.payload)
                world.clock.advance(PairingCeremony.window + 1)
                world.ceremony.confirmCodesMatch()
            }),
            ("the window closes during the match", .expired, { world in
                world.gate.during = { world.clock.advance(PairingCeremony.window) }
                await world.ceremony.scanned(Self.payload)
            }),
            ("the window closes during the save", .expired, { world in
                world.writer.during = { world.clock.advance(PairingCeremony.window) }
                await world.ceremony.scanned(Self.payload)
            }),
            ("not confirmed", .failed(.notConfirmed), { world in
                world.gate.confirms = false
                await world.ceremony.scanned(Self.payload)
            }),
            ("already answered", .failed(.alreadyAnswered), { world in
                world.writer.outcome = .alreadyAnswered
                await world.ceremony.scanned(Self.payload)
            }),
            ("unsent", .failed(.unsent), { world in
                world.writer.outcome = .failed
                await world.ceremony.scanned(Self.payload)
            }),
            ("unconfirmed", .failed(.unconfirmed), { world in
                world.writer.outcome = .unconfirmed
                await world.ceremony.scanned(Self.payload)
            }),
            ("the proof not signed", .failed(.notSigned), { world in
                world.keys.enclave.forced = .keyUnusable
                await world.ceremony.scanned(Self.payload)
            }),
        ]
        for (name, expected, run) in ends {
            let world = World()
            let earlier = world.pairedBefore()
            await run(world)
            #expect(world.ceremony.phase == expected, "\(name): \(world.ceremony.phase)")
            #expect(world.keys.provisional() == nil, "\(name): the provisional key stayed")
            world.keys.enclave.forced = nil
            #expect(world.committedSigns(as: earlier), "\(name): the earlier pairing stopped signing")
            #expect(world.gate.matches.allSatisfy { !$0.isValid }, "\(name): a match outlived the ceremony")
            if case .failed(.alreadyAnswered) = expected {
                #expect(PairingScreen.fingerprint(in: world.ceremony.phase) == nil, "nothing of the saved response is shown")
            }
        }
    }

    /// Never "Paired" before the confirm: every phase a ceremony passes
    /// through on its way to waiting is short of it.
    @Test func neverPairedBeforeTheConfirm() async {
        let world = World()
        var seen: [PairingCeremony.Phase] = [world.ceremony.phase]
        world.gate.during = { seen.append(world.ceremony.phase) }
        world.writer.during = { seen.append(world.ceremony.phase) }
        await world.ceremony.scanned(Self.payload)
        seen.append(world.ceremony.phase)
        world.clock.advance(PairingCeremony.window - 1)
        world.ceremony.tick()
        seen.append(world.ceremony.phase)
        for phase in seen {
            if case .paired = phase { Issue.record("Paired before the confirm") }
        }
        #expect(seen.map { "\($0)".prefix(6) } == ["scanni", "confir", "saving", "waitin", "waitin"])
        world.ceremony.confirmCodesMatch()
        if case .paired = world.ceremony.phase {} else { Issue.record("the confirm did not pair: \(world.ceremony.phase)") }
    }

    /// No match possible (no biometrics enrolled, locked out, or none at
    /// all): the scan is not taken. No key is made, nothing is asked or
    /// written, no window opens, and the ceremony waits at its start, with
    /// the reading the screen names the cause from. Once a match is
    /// possible again, the same ceremony takes its one scan.
    @Test(arguments: [BiometricAvailability.unavailable(.faceID), .unavailable(.touchID), .unavailable(nil)])
    func noMatchPossibleNoScanTaken(_ unavailable: BiometricAvailability) async throws {
        let world = World()
        world.gate.available = unavailable
        world.ceremony.refreshBiometry()
        #expect(world.ceremony.biometry == unavailable)
        await world.ceremony.scanned(Self.payload)
        #expect(world.ceremony.phase == .scanning)
        #expect(world.ceremony.deadline == nil)
        #expect(world.gate.requests.isEmpty && world.writer.written.isEmpty)
        #expect(world.keys.provisional() == nil && world.keys.committed() == nil)
        world.ceremony.tick()
        #expect(world.ceremony.phase == .scanning, "no window, nothing to end")
        world.gate.available = .available(.faceID)
        await world.ceremony.scanned(Self.payload)
        #expect(world.ceremony.biometry == .available(.faceID), "the scan re-reads it")
        #expect(world.gate.requests == [PairingCeremony.reason])
        try #require(world.writer.written.count == 1)
        if case .waiting = world.ceremony.phase {} else { Issue.record("not waiting: \(world.ceremony.phase)") }
    }

    /// The reading is taken as the ceremony is made, and changes only when
    /// it is read again.
    @Test func theBiometricsAreReadAtTheStartAndOnRefresh() {
        let world = World()
        #expect(world.ceremony.biometry == .available(.faceID))
        world.gate.available = .unavailable(.faceID)
        #expect(world.ceremony.biometry == .available(.faceID))
        world.ceremony.refreshBiometry()
        #expect(world.ceremony.biometry == .unavailable(.faceID))
        let late = PairingCeremony(keyring: world.keys.keyring, biometrics: world.gate, writer: world.writer)
        #expect(late.biometry == .unavailable(.faceID))
    }

    /// No enclave, no key: nothing is asked and nothing written.
    @Test func noKeyNoPairing() async {
        let world = World()
        world.keys.enclave.isAvailable = false
        await world.ceremony.scanned(Self.payload)
        #expect(world.ceremony.phase == .failed(.noKey))
        #expect(world.gate.requests.isEmpty && world.writer.written.isEmpty)
    }

    /// A finished ceremony starts over on Scan Again: a new ceremony, which
    /// takes one scan again. A paired one, or one under way, does not.
    @Test func scanAgainStartsANewCeremony() async {
        let world = World()
        await world.ceremony.scanned(FixturePairing.strayCode)
        world.ceremony.restart()
        #expect(world.ceremony.phase == .scanning && world.ceremony.deadline == nil)
        await world.ceremony.scanned(Self.payload)
        #expect(world.writer.written.count == 1)
        world.ceremony.restart()
        #expect(world.ceremony.phase != .scanning, "waiting is not over")
        world.ceremony.confirmCodesMatch()
        world.ceremony.restart()
        if case .paired = world.ceremony.phase {} else { Issue.record("a pairing restarted: \(world.ceremony.phase)") }
    }

    /// The fixture launch's states are the states they name.
    @Test(arguments: FixturePairingState.allCases)
    func eachFixturePairingIsInItsState(_ state: FixturePairingState) async {
        let fixture = FixturePairing.pairing(state, biometrics: ScriptedBiometricGate())
        #expect(fixture.camera.isLive == false)
        if let scan = fixture.scan { await fixture.ceremony.scanned(scan) }
        let phase = fixture.ceremony.phase
        switch state {
        case .scan: #expect(phase == .scanning && fixture.camera.state() == .ready)
        case .camera: #expect(phase == .scanning && fixture.camera.state() == .notAsked)
        case .cameraOff: #expect(phase == .scanning && fixture.camera.state() == .off)
        case .code: if case .waiting = phase {} else { Issue.record("\(phase)") }
        case .stray: #expect(phase == .refused)
        case .taken: #expect(phase == .failed(.alreadyAnswered))
        }
    }

    // MARK: The code shown

    @Test func theCodeIsFortyEightBitsOfTheKeysDigest() throws {
        let key = [UInt8(0x04)] + Array(repeating: UInt8(0xab), count: 64)
        let fingerprint = try #require(KeyFingerprint(publicKey: key))
        let digest = Array(SHA256.hash(data: key))
        #expect(fingerprint.digits == digest.prefix(6).map { String(format: "%02X", $0) }.joined())
        #expect(fingerprint.digits.count == 12)
        #expect(fingerprint.grouped.split(separator: " ").map(\.count) == [4, 4, 4])
        #expect(fingerprint.grouped.replacingOccurrences(of: " ", with: "") == fingerprint.digits)
        #expect(fingerprint.spoken.split(separator: ",").count == 3)
        #expect(fingerprint.spoken.replacingOccurrences(of: ", ", with: " ").split(separator: " ").map(String.init)
                == fingerprint.digits.map(String.init), "every character on its own")
        #expect(KeyFingerprint(publicKey: Array(key.dropLast())) == nil)
        #expect(KeyFingerprint(publicKey: [0x02] + Array(key.dropFirst())) == nil)
        #expect(KeyFingerprint(publicKey: [0x04] + Array(repeating: UInt8(0xac), count: 64)) != fingerprint)
    }

    /// The response refuses anything off the wire's shape.
    @Test func aResponseHasTheWiresShape() {
        let name = String(repeating: "a", count: 64)
        let key = Data([0x04] + Array(repeating: UInt8(1), count: 64))
        let mac = Data(count: 32)
        let proof = Data(count: 64)
        #expect(PairingResponse(recordName: name, wireVersion: 1, publicKey: key, confirmation: mac, proof: proof) != nil)
        #expect(PairingResponse(recordName: name.uppercased(), wireVersion: 1, publicKey: key, confirmation: mac, proof: proof) == nil)
        #expect(PairingResponse(recordName: String(name.dropLast()), wireVersion: 1, publicKey: key, confirmation: mac, proof: proof) == nil)
        #expect(PairingResponse(recordName: name, wireVersion: 2, publicKey: key, confirmation: mac, proof: proof) == nil)
        #expect(PairingResponse(recordName: name, wireVersion: 1, publicKey: key.dropLast(), confirmation: mac, proof: proof) == nil)
        #expect(PairingResponse(recordName: name, wireVersion: 1, publicKey: Data([0x02]) + key.dropFirst(), confirmation: mac,
                                proof: proof) == nil)
        #expect(PairingResponse(recordName: name, wireVersion: 1, publicKey: key, confirmation: mac.dropLast(), proof: proof) == nil)
        #expect(PairingResponse(recordName: name, wireVersion: 1, publicKey: key, confirmation: mac, proof: proof + [0]) == nil)
    }

    // MARK: The locks

    typealias Source = CloudKitStructureTests.Source
    static let appDir = CloudKitStructureTests.appDir
    static let ceremonyFile = "\(appDir)/Model/PairingCeremony.swift"

    /// Every site naming the provisional key's three methods, in the app
    /// (#166): each declared once, by the keyring, and called once, by the
    /// ceremony.
    static let provisionalSites = CloudKitStructureTests.appSites([
        "Model/PhoneKeyring.swift": ["func makeProvisional() -> [UInt8]? {": 1,
                                     "func signProvisional(_ message: [UInt8], match: any BiometricMatch) -> SigningOutcome {": 1,
                                     "func commitProvisional() -> Bool {": 1],
        "Model/PairingCeremony.swift": [
            "guard let publicKey = keyring.makeProvisional(), let fingerprint = KeyFingerprint(publicKey: publicKey) else {": 1,
            "guard case .signed(let proof) = keyring.signProvisional(proofMessage, match: match) else { return nil }": 1,
            "guard keyring.commitProvisional() else {": 1],
    ])

    /// The ceremony's one write, after the proof, in `scanned`; its key
    /// committed in one place, after the waiting check, and "Paired" set
    /// only right after; the provisional key the only one that signs a
    /// proof; the code computed once, from the key the ceremony made; and
    /// the nonce held by no property and handed to nothing but the wire's
    /// builders and the MAC's key. Across the app: only fixtures (and
    /// tests) conform to the writer seam or build a ceremony, in this
    /// slice.
    ///
    /// AMENDED (#166, the S-PAIR-B security review): the provisional key's
    /// methods are pinned by NAME, not by a receiver spelled `keyring.`
    /// (B15, B16 and B19 committed from a fixture, through `let f =
    /// k.commitProvisional` and through a renamed receiver): every site
    /// naming one is on `provisionalSites`. The writer seam's adoption is
    /// read over any number of lines, through a refining protocol and
    /// through a typealias (B11-B13), in every scan copy. And no app source
    /// has an implicit `.init(` (B10 built a live ceremony with one).
    static func ceremonyFailures(_ app: [Source]) -> [String] {
        var failures: [String] = []
        let file = CloudKitStructureTests.codeOnly(app.first { $0.path == ceremonyFile }?.text ?? "")
        let flat = SettingsReachabilityTests.flat(file)
        let order = ["func scanned(_ payload: String) async { guard phase == .scanning else { return } refreshBiometry() "
                        + "guard case .available = biometry else { return } deadline = clock().addingTimeInterval(Self.window)",
                     "guard let nonce = ApprovalSigning.pairingNonce(fromPayload: payload) else {",
                     "guard let publicKey = keyring.makeProvisional(), let fingerprint = KeyFingerprint(publicKey: publicKey) else {",
                     "guard case .confirmed(let match) = await biometrics.confirm(reason: Self.reason) else {",
                     "guard let response = Self.response(nonce: nonce, publicKey: publicKey, keyring: keyring, match: match) else {",
                     "phase = .saving let outcome = await writer.write(response)"]
        var cursor = flat.startIndex
        for step in order {
            guard let found = flat.range(of: step, range: cursor..<flat.endIndex) else {
                failures.append("the ceremony lost '\(step)', or it moved out of order")
                break
            }
            cursor = found.upperBound
        }
        if !flat.contains("guard case .waiting(let fingerprint, _) = phase else { return } guard isOpen else { end(.expired) return } "
                          + "guard keyring.commitProvisional() else { end(.failed(.notKept)) return } phase = .paired(fingerprint)") {
            failures.append("the key is committed only from waiting, inside the window, and Paired only right after")
        }
        for (token, count) in [("writer.write(response)", 1), ("phase = .paired(", 1), ("KeyFingerprint(", 1), ("keyring.makeProvisional(", 1),
                               ("keyring.signProvisional(", 1), ("keyring.commitProvisional(", 1)] {
            for (path, text) in app {
                let code = RecordPathStructureTests.constructionSpelling(CloudKitStructureTests.codeOnly(text))
                let expected = path == ceremonyFile ? count : 0
                if CloudKitStructureTests.occurrences(of: token, in: code) != expected {
                    failures.append("'\(token)' in \(path) — only the ceremony, \(count) time(s)")
                }
            }
        }
        if CloudKitStructureTests.occurrences(of: "writer.write(", in: file) != 1 {
            failures.append("the ceremony writes once: its one response")
        }
        if CloudKitStructureTests.hits(#"(?m)^    (?:\w+ |\w+\(\w+\) )*(?:var|let) \w*[Nn]once"#, in: file) {
            failures.append("a property holds the nonce — it lives in one call's locals")
        }
        let nonceUses = CloudKitStructureTests.siteTally(#"\bnonce\b"#, in: file)
        let allowedNonce: [String: Int] = [
            "guard let nonce = ApprovalSigning.pairingNonce(fromPayload: payload) else {": 1,
            "guard let response = Self.response(nonce: nonce, publicKey: publicKey, keyring: keyring, match: match) else {": 2,
            "static func response(nonce: [UInt8], publicKey: [UInt8], keyring: PhoneKeyring, match: any BiometricMatch) -> PairingResponse? {": 1,
            "guard let proofMessage = ApprovalSigning.pairingProofMessage(nonce: nonce, publicKey: publicKey),": 2,
            "let nameInput = ApprovalSigning.pairingRecordNameInput(nonce: nonce),": 2,
            "let confirmation = Data(HMAC<SHA256>.authenticationCode(for: confirmationMessage, using: SymmetricKey(data: nonce)))": 1,
        ]
        if nonceUses != allowedNonce {
            failures.append("the nonce goes only to the wire's builders and the MAC's key: \(nonceUses)")
        }
        for token in [#"\bLogger\b"#, #"\blogger\b"#, #"\b(?:print|debugPrint|dump)\s*\("#, #"\bos_log\b"#, #"\bNSLog\b"#,
                      #"\bUserDefaults\b"#, #"\bAppStorage\b"#] where CloudKitStructureTests.hits(token, in: file) {
            failures.append("'\(token)' in the ceremony — nothing of a pairing is logged or kept")
        }
        // #168 (the PR #167 review's (c)): and every other name for the
        // writer seam, declared in any file, Fixtures/ included.
        let conformances = CloudKitStructureTests.seamNames("PairingResponseWriter", in: app).sorted()
            .map(CloudKitStructureTests.adoptionPattern)
        for (path, text) in app {
            let code = CloudKitStructureTests.codeOnly(text)
            let fixture = path.hasPrefix("\(appDir)/Fixtures/")
            if !fixture, CloudKitStructureTests.constructorScanCopies(code).contains(where: { copy in
                conformances.contains { CloudKitStructureTests.hits($0, in: copy) } }) {
                failures.append("\(path) conforms to the pairing writer — only fixtures, until the record path exists")
            }
            if !fixture, CloudKitStructureTests.hits(#"\bPairingCeremony\s*(?:\.\s*init\s*)?\("#, in: code) {
                failures.append("\(path) builds a ceremony — only the fixture launch, in this slice")
            }
        }
        failures += CloudKitStructureTests.appSiteFailures(#"\b(?:makeProvisional|signProvisional|commitProvisional)\b"#,
                                                           in: app.map { ($0.path, CloudKitStructureTests.codeOnly($0.text)) },
                                                           allowed: provisionalSites,
                                                           rule: "the provisional key is made, signs and is committed by the ceremony only")
        failures += RecordPathStructureTests.implicitInitFailures(app, rule: "a ceremony and its code are built by name only")
        return failures
    }

    @Test func theCeremonyKeepsItsOrderAndHoldsNoNonce() throws {
        let app = try CloudKitStructureTests.swiftFiles(under: Self.appDir)
        #expect(app.contains { $0.path == Self.ceremonyFile }, "vacuity: the ceremony is where the lock looks")
        #expect(Self.ceremonyFailures(app).isEmpty, "\(Self.ceremonyFailures(app))")
        func mutate(_ path: String, _ transform: (String) -> String) -> [Source] {
            app.map { $0.path == path ? ($0.path, transform($0.text)) : $0 }
        }
        let file = Self.ceremonyFile
        let inbox = "\(Self.appDir)/Model/RequestInbox.swift"
        let fixture = "\(Self.appDir)/Fixtures/FixturePairing.swift"
        let mutants: [(String, [Source])] = [
            ("a scan taken with no match possible", mutate(file) {
                $0.replacingOccurrences(of: "        guard case .available = biometry else { return }\n", with: "") }),
            ("a scan taken on a stale reading", mutate(file) {
                $0.replacingOccurrences(of: "        guard phase == .scanning else { return }\n        refreshBiometry()\n",
                                        with: "        guard phase == .scanning else { return }\n") }),
            ("committed without the confirm", mutate(file) {
                $0.replacingOccurrences(of: "        case .saved: phase = .waiting(fingerprint, until: deadline ?? clock())",
                                        with: "        case .saved: _ = keyring.commitProvisional(); phase = .waiting(fingerprint, until: deadline ?? clock())") }),
            ("Paired before the confirm", mutate(file) {
                $0.replacingOccurrences(of: "case .saved: phase = .waiting(fingerprint, until: deadline ?? clock())",
                                        with: "case .saved: phase = .paired(fingerprint)") }),
            ("the confirm past the window", mutate(file) {
                $0.replacingOccurrences(of: "        guard isOpen else {\n            end(.expired)\n            return\n        }\n        guard keyring.commitProvisional()",
                                        with: "        guard keyring.commitProvisional()") }),
            ("a second write", mutate(file) {
                $0 + "\nextension PairingCeremony { func spare(r: PairingResponse) async { _ = await writer.write(response) } }" }),
            ("the write before the proof", mutate(file) {
                $0.replacingOccurrences(of: "        phase = .confirming\n", with: "        phase = .confirming\n        _ = await writer.write(spare)\n") }),
            ("the nonce kept", mutate(file) {
                $0.replacingOccurrences(of: "    private(set) var deadline: Date?\n", with: "    private(set) var deadline: Date?\n    private var lastNonce: [UInt8] = []\n") }),
            ("the nonce logged", mutate(file) {
                $0.replacingOccurrences(of: "        phase = .confirming\n", with: "        phase = .confirming\n        print(nonce)\n") }),
            ("the nonce handed on", mutate(file) {
                $0.replacingOccurrences(of: "        phase = .confirming\n", with: "        phase = .confirming\n        spare(nonce)\n") }),
            ("the code from the written record", mutate(file) {
                $0.replacingOccurrences(of: "case .saved: phase = .waiting(fingerprint,",
                                        with: "case .saved: phase = .waiting(KeyFingerprint(publicKey: Array(response.publicKey))!,") }),
            ("a decision signed by the provisional key", mutate(inbox) { $0 + "\nfunc spare(k: PhoneKeyring) { _ = k.signProvisional(m, match: x); _ = keyring.signProvisional(m, match: x) }" }),
            ("a live writer", mutate(inbox) { $0 + "\nstruct SpareWriter: PairingResponseWriter { func write(_ r: PairingResponse) async -> PairingWriteOutcome { .saved } }" }),
            ("a live ceremony", mutate(inbox) { $0 + "\nlet spare = PairingCeremony.init(keyring: k, biometrics: b, writer: w)" }),
            // #166: the security review's B10-B13, B15, B16 and B19, as planted.
            ("B10: a live ceremony by typed implicit init", mutate(inbox) {
                $0 + "\nfunc spareCeremony(k: PhoneKeyring, b: any BiometricGate, w: any PairingResponseWriter) -> PairingCeremony { "
                    + "let c: PairingCeremony = .init(keyring: k, biometrics: b, writer: w); return c }" }),
            ("B11: a live writer through a refining protocol", mutate(inbox) {
                $0 + "\nprotocol SneakyWriter: PairingResponseWriter {}\nstruct LivePairingWriter: SneakyWriter { "
                    + "func write(_ r: PairingResponse) async -> PairingWriteOutcome { .saved } }" }),
            ("B12: a live writer, its conformance on the next line", mutate(inbox) {
                $0 + "\nstruct LivePairingWriter2:\n    PairingResponseWriter { func write(_ r: PairingResponse) async -> PairingWriteOutcome { .saved } }" }),
            ("B13: a live writer through a typealias", mutate(inbox) {
                $0 + "\ntypealias PW = PairingResponseWriter\nstruct LivePairingWriter3: PW { "
                    + "func write(_ r: PairingResponse) async -> PairingWriteOutcome { .saved } }" }),
            ("B15: the provisional key committed from a fixture", mutate(fixture) {
                $0 + "\nextension FixturePairing { func sneak(k: PhoneKeyring) { _ = k.commitProvisional() } }" }),
            ("B16: committed through an unapplied reference", mutate(inbox) {
                $0 + "\nextension RequestInbox { func sneak2(k: PhoneKeyring) { let f = k.commitProvisional; _ = f() } }" }),
            ("B19: committed through a renamed receiver", mutate(inbox) {
                $0 + "\nextension RequestInbox { func sneak5() { let k = keyring; _ = k.commitProvisional() } }" }),
            // … and their neighbours: a writer adopted by an extension over
            // lines, through a composed alias, behind a block comment holding
            // a brace; a key made or a proof signed outside the ceremony, on
            // the keyring's implicit self, or a second time in the ceremony;
            // and a code built by implicit init.
            ("a live writer by extension, over lines", mutate(inbox) {
                $0 + "\nextension RequestInbox:\n    Sendable,\n    PairingResponseWriter {}" }),
            ("a live writer through a composed typealias", mutate(inbox) {
                $0 + "\ntypealias PW = Sendable &\n    PairingResponseWriter\nactor LivePairingWriter4: PW {}" }),
            ("a live writer behind a block comment holding a brace", mutate(inbox) {
                $0 + "\nstruct LivePairingWriter5 /* { */: PairingResponseWriter {}" }),
            ("a provisional key made outside the ceremony", mutate(inbox) {
                $0 + "\nfunc spare(k: PhoneKeyring) -> [UInt8]? { k.makeProvisional() }" }),
            ("committed on the keyring's implicit self", mutate("\(Self.appDir)/Model/PhoneKeyring.swift") {
                $0 + "\nextension PhoneKeyring { func spare() -> Bool { commitProvisional() } }" }),
            ("committed a second time in the ceremony", mutate(file) {
                $0.replacingOccurrences(of: "        case .saved: phase = .waiting(fingerprint, until: deadline ?? clock())",
                                        with: "        case .saved: phase = .waiting(fingerprint, until: deadline ?? clock()); _ = keyring.commitProvisional") }),
            ("a code by implicit init", mutate(file) {
                $0 + "\nextension PairingCeremony { static func spare(k: [UInt8]) -> KeyFingerprint? { .init(publicKey: k) } }" }),
            // #168 (the PR #167 review's (c)), its G8 shape: a protocol
            // refining the writer, declared in Fixtures/, with a live
            // conformer; and an alias there, adopted live.
            ("G8: a fixture protocol refining the writer, a live conformer", RecordPathStructureTests.mutate(RecordPathStructureTests.mutate(app, fixture) {
                $0 + "\nprotocol ReviewerPairingSeam: PairingResponseWriter {}" }, inbox) {
                $0 + "\nstruct ReviewerLiveWriter: ReviewerPairingSeam {\n    func write(_ response: PairingResponse) async -> PairingWriteOutcome { .saved }\n}" }),
            ("a fixture alias of the writer, adopted live", RecordPathStructureTests.mutate(RecordPathStructureTests.mutate(app, fixture) {
                $0 + "\ntypealias SpareWriter = PairingResponseWriter" }, inbox) { $0 + "\nactor LiveSpare: SpareWriter {}" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.ceremonyFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: a fixture may adopt the writer (it does) on
        // any number of lines; the seam as a stored existential or a
        // parameter (the ceremony's own); and a doc comment naming the
        // shapes.
        #expect(Self.ceremonyFailures(mutate(fixture) {
            $0 + "\nactor SpareFixtureWriter:\n    PairingResponseWriter { func write(_ r: PairingResponse) async -> PairingWriteOutcome { .saved } }"
        }).isEmpty)
        #expect(Self.ceremonyFailures(mutate(inbox) {
            $0 + "\n/// never protocol P: PairingResponseWriter, never typealias W = PairingResponseWriter, never k.commitProvisional()"
                + "\nfunc spare(w: any PairingResponseWriter) -> Bool { true }"
        }).isEmpty)
        // A conditional conformance and a generic class, each over lines.
        for probe in ["extension Array:\n    PairingResponseWriter where Element: Sendable {",
                      "final class X<T: Equatable>: NSObject, @unchecked Sendable,\n    PairingResponseWriter {"] {
            #expect(CloudKitStructureTests.hits(CloudKitStructureTests.adoptionPattern("PairingResponseWriter"), in: probe), "missed '\(probe)'")
        }
        // The seam's own declaration and a protocol extension of it adopt nothing.
        for probe in ["protocol PairingResponseWriter: Sendable {", "extension PairingResponseWriter where Self: Sendable {"] {
            #expect(!CloudKitStructureTests.hits(CloudKitStructureTests.adoptionPattern("PairingResponseWriter"), in: probe), "over-match '\(probe)'")
        }
    }

    // MARK: The S-PAIR-B tests touch nothing live

    /// The S-PAIR-B test files after C1's two (`SigningKeyStructureTests`
    /// covers those). The locks among them name live tokens as text, in
    /// their literals, so the scan reads code with the literals emptied:
    /// what runs is what counts.
    static let testFiles = ["DecisionSignerTests.swift", "PairingCeremonyTests.swift", "PairingScreenTests.swift",
                            "MatchHygieneStructureTests.swift"]
    static let liveTokens = SigningKeyStructureTests.liveTokens
        + ["AVCaptureDevice", "DataScannerViewController", "LiveCameraAccess(", "QRScannerView(", "FixturePairing.make("]

    /// Every one-line string literal (plain or raw) emptied.
    static func literalsEmptied(_ code: String) -> String {
        code.replacingOccurrences(of: ##"#"(?:[^"\n]|"(?!#))*"#|"(?:[^"\\\n]|\\.)*""##, with: "\"\"", options: .regularExpression)
    }

    static func liveFailures(_ tests: [Source]) -> [String] {
        tests.flatMap { path, text in
            let code = RecordPathStructureTests.constructionSpelling(literalsEmptied(CloudKitStructureTests.codeOnly(text)))
            return liveTokens.filter { code.contains($0) }.map { "'\($0)' in \(path) — the S-PAIR-B tests touch nothing live" }
        }
    }

    @Test func theTestsTouchNothingLive() throws {
        let all = try CloudKitStructureTests.swiftFiles(under: CloudKitStructureTests.testsDir)
        let tests: [Source] = Self.testFiles.map { name in
            let path = "\(CloudKitStructureTests.testsDir)/\(name)"
            return (path, all.first { $0.path == path }?.text ?? "")
        }
        #expect(tests.allSatisfy { !$0.text.isEmpty }, "vacuity: every listed file was read")
        #expect(Self.liveFailures(tests).isEmpty, "\(Self.liveFailures(tests))")
        for planted in ["let c = AVCaptureDevice.authorizationStatus(for: .video)", "let s = DataScannerViewController(recognizedDataTypes: [])",
                        "let a = LiveCameraAccess()", "let v = QRScannerView(scanned: { _ in })", "let p = FixturePairing.make(options: o)",
                        "let g = LocalAuthenticationGate()", "let c = LAContext()", "let e = SecureEnclaveSigner.init()"] {
            #expect(!Self.liveFailures(tests.map { ($0.path, $0.text + "\n" + planted) }).isEmpty, "canary '\(planted)' was NOT caught")
        }
        // A token inside a literal is text, not a call.
        #expect(Self.liveFailures([("t", "let s = \"LAContext()\"; let r = #\"\"SecItemAdd(\"\"#")]).isEmpty)
    }
}
