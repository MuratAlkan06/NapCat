import Foundation
@testable import NapCatPhone
import Testing

/// F4 slice S-PAIR-C1.6 (#172): how a live pairing begins, read from the
/// sources (SwiftUI composition and the camera can't be driven headlessly).
///
/// 1. User-started, from Settings only. The live pairing is named on its
///    pinned lines alone: built once, by the live inbox's factory, held by
///    the inbox, handed to Settings by the root (`SettingsReachabilityTests`
///    pins that hand-off). A ceremony is made from it at ONE site, Settings'
///    Pair with Mac action, which raises the sheet (the ceremony is its
///    item); the root's sheet flag is raised nowhere else; and the pairing
///    sheet is built at two sites, the fixture launch's (the root) and
///    Settings'.
/// 2. The code from the camera only. `ScannedCode`, the one thing a ceremony
///    scans, is built outside Fixtures/ at ONE site, the live scanner's
///    hand-on of the first QR code it reads, whose callback is pinned whole
///    and whose scanner reads QR codes only. Every line naming the type, or
///    `scanned` (the ceremony's entry and the closures that carry a code to
///    it), is on an allow-list. No app source takes anything in from a URL,
///    a deep link, a user activity, a shortcut, the pasteboard, a drop, a
///    file, a photo or the launch options, and the app declares no URL
///    scheme and no associated domain.
///
/// AMENDED (#194): the live pairing's factory is handed the live approvals
/// database (built once by the live inbox's factory and shared with the
/// live prompt source), on its pinned lines; and Settings' Remote approvals
/// switch sits under the Pairing row, shown with it, handed the phone's
/// pairing as the live pairing reads it.
///
/// Each lock is a pure function over comment-stripped sources and catches
/// planted canaries, so none can pass vacuously.
@Suite struct PairingEntryStructureTests {
    typealias Source = CloudKitStructureTests.Source

    static let appDir = CloudKitStructureTests.appDir
    static let settingsFile = "\(appDir)/Settings/SettingsScreen.swift"
    static let rootFile = "\(appDir)/NapCatPhoneApp.swift"
    static let scannerFile = "\(appDir)/Live/QRScanner.swift"
    static let fixturesDir = "\(appDir)/Fixtures/"

    static func app() throws -> [Source] {
        try CloudKitStructureTests.swiftFiles(under: appDir)
    }

    static func mutate(_ sources: [Source], _ path: String, _ transform: (String) -> String) -> [Source] {
        sources.map { $0.path == path ? ($0.path, transform($0.text)) : $0 }
    }

    static func stripped(_ app: [Source], fixtures: Bool = true) -> [Source] {
        app.filter { fixtures || !$0.path.hasPrefix(fixturesDir) }.map { ($0.path, CloudKitStructureTests.codeOnly($0.text)) }
    }

    // MARK: 1. User-started, from Settings only

    static let pairAction = "ceremony = pairing.makeCeremony()"
    static let inboxInit: String = "init(writer: any DecisionWriter, biometrics: any BiometricGate, keyring: PhoneKeyring, "
        + "pairing: LivePairing? = nil,"
    static let livePairingSites = CloudKitStructureTests.appSites([
        "Live/LivePairing.swift": ["struct LivePairing {": 1,
                                   "static func make(keyring: PhoneKeyring, biometrics: any BiometricGate, "
                                       + "database: (any CloudKitApprovalDatabase)?) -> LivePairing {": 1,
                                   "return LivePairing(camera: LiveCameraAccess(), keyring: keyring, biometrics: biometrics, writer: writer)": 1],
        "Model/RequestInbox.swift": ["let pairing: LivePairing?": 1,
                                     inboxInit: 1,
                                     "pairing: LivePairing.make(keyring: keyring, biometrics: biometrics, database: database),": 1],
        "Settings/SettingsScreen.swift": ["var pairing: LivePairing?": 1,
                                          "private func pairingSection(_ pairing: LivePairing) -> some View {": 1],
    ])
    static let makeCeremonySites = CloudKitStructureTests.appSites([
        "Live/LivePairing.swift": ["func makeCeremony() -> PairingCeremony {": 1],
        "Settings/SettingsScreen.swift": [pairAction: 1],
    ])
    static let sheetFlagSites = CloudKitStructureTests.appSites([
        "NapCatPhoneApp.swift": ["@State private var showsPairing: Bool": 1, ".sheet(isPresented: $showsPairing) {": 1],
    ])
    /// AMENDED (#178, a blank first sheet): Settings' sheet is presented BY
    /// its ceremony (`.sheet(item:)`), no longer by a flag raised beside it,
    /// whose content read the ceremony back and could find none. Every
    /// line of Settings naming `ceremony` is pinned: the item is declared,
    /// set by the Pair with Mac action alone, bound by the sheet alone, and
    /// handed to the sheet's content.
    static let itemSheet: String = ".sheet(item: $ceremony) { ceremony in"
    static let settingsSheet: String = "if let pairing { PairingSheet(ceremony: ceremony, camera: pairing.camera) }"
    static let settingsCeremonySites: [String: Int] = CloudKitStructureTests.appSites([
        "Settings/SettingsScreen.swift": ["@State private var ceremony: PairingCeremony?": 1, pairAction: 1, itemSheet: 2,
                                          settingsSheet: 2],
    ])
    static let sheetSites = CloudKitStructureTests.appSites([
        "NapCatPhoneApp.swift": ["PairingSheet(ceremony: pairing.ceremony, camera: pairing.camera)": 1],
        "Settings/SettingsScreen.swift": [settingsSheet: 1],
    ])
    /// Settings' row and sheet, whitespace collapsed: the row shows only
    /// with a live pairing; its action makes the ceremony, which raises the
    /// sheet; the sheet runs that ceremony on the live camera and lets it go
    /// when it closes.
    static let rowShape: String = "if let pairing { pairingSection(pairing) approvalsSection(pairing.health()) }"
    static let actionShape: String = "Button(Self.pairTitle) { " + pairAction + " }"
    static let sheetShape: String = itemSheet + " " + settingsSheet + " }"
    static let settingsShapes: [String] = [rowShape, actionShape, sheetShape]

    static func entryFailures(_ app: [Source]) -> [String] {
        var failures: [String] = []
        let code = stripped(app)
        failures += CloudKitStructureTests.appSiteFailures(#"\bLivePairing\b"#, in: code, allowed: livePairingSites,
                                                           rule: "the live pairing is named on its pinned lines alone")
        failures += CloudKitStructureTests.appSiteFailures(#"\bmakeCeremony\b"#, in: code, allowed: makeCeremonySites,
                                                           rule: "a live ceremony is made by Settings' Pair with Mac alone")
        failures += CloudKitStructureTests.appSiteFailures(#"\bshowsPairing\b"#, in: code, allowed: sheetFlagSites,
                                                           rule: "a pairing sheet opens on its pinned flags alone")
        failures += CloudKitStructureTests.appSiteFailures(#"\bceremony\b"#, in: code.filter { $0.path == settingsFile },
                                                           allowed: settingsCeremonySites,
                                                           rule: "Settings' sheet opens on its own ceremony, set by the tap alone")
        for copy in CloudKitStructureTests.constructorScanCopies(code) {
            failures += CloudKitStructureTests.appSiteFailures(#"\bPairingSheet\s*(?:\.\s*init\s*)?\("#, in: copy, allowed: sheetSites,
                                                               rule: "the pairing sheet is built by the root (fixture) and Settings alone")
        }
        let settings = SettingsReachabilityTests.flat(app.first { $0.path == settingsFile }?.text ?? "")
        for shape in settingsShapes where !settings.contains(shape) {
            failures.append("Settings lost '\(shape)'")
        }
        return CloudKitStructureTests.unique(failures)
    }

    @Test func aLivePairingIsStartedFromSettingsAlone() throws {
        let app = try Self.app()
        #expect(app.contains { $0.path == Self.settingsFile }, "vacuity: the scan sees Settings")
        #expect(Self.entryFailures(app).isEmpty, "\(Self.entryFailures(app))")
        let settings = Self.settingsFile
        let root = Self.rootFile
        let mutants: [(String, [Source])] = [
            ("the pairing opened as Settings appears", Self.mutate(app, settings) {
                $0.replacingOccurrences(of: "        .tint(theme.accent)\n        .sheet(item: $ceremony)",
                                        with: "        .tint(theme.accent)\n        .onAppear { ceremony = Spare.ceremony }\n"
                                            + "        .sheet(item: $ceremony)") }),
            ("a ceremony made as Settings appears", Self.mutate(app, settings) {
                $0.replacingOccurrences(of: "        .tint(theme.accent)\n        .sheet(item: $ceremony)",
                                        with: "        .tint(theme.accent)\n        .task { ceremony = pairing?.makeCeremony() }\n"
                                            + "        .sheet(item: $ceremony)") }),
            ("the live pairing opened by the root at launch", Self.mutate(app, root) {
                $0.replacingOccurrences(of: "        .task { await feed.start() }\n",
                                        with: "        .task { await feed.start() }\n        .task { _ = inbox.pairing?.makeCeremony() }\n") }),
            ("the action making no ceremony", Self.mutate(app, settings) {
                $0.replacingOccurrences(of: "                " + Self.pairAction + "\n", with: "") }),
            ("Settings' sheet back on a flag beside its ceremony (#178)", Self.mutate(app, settings) {
                $0.replacingOccurrences(of: "        .sheet(item: $ceremony) { ceremony in\n            if let pairing {",
                                        with: "        .sheet(isPresented: .constant(ceremony != nil)) {\n            if let pairing, let ceremony {")
            }),
            ("a second pairing sheet", Self.mutate(app, "\(Self.appDir)/Screen/ReceiverScreen.swift") {
                $0 + "\nfunc spare(c: PairingCeremony) -> some View { PairingSheet.init(ceremony: c, camera: FixtureCamera(answer: .ready)) }" }),
            ("the live pairing held elsewhere", Self.mutate(app, "\(Self.appDir)/Model/AlertFeed.swift") {
                $0 + "\nenum Spare { @MainActor static var held: LivePairing? }" }),
            ("the row shown with no live pairing", Self.mutate(app, settings) {
                $0.replacingOccurrences(of: "                if let pairing {\n                    pairingSection(pairing)\n",
                                        with: "                pairingSection(pairing!)\n                if let pairing {\n") }),
            // #194: the switch shown with no live pairing.
            ("the approvals switch shown with no live pairing", Self.mutate(app, settings) {
                $0.replacingOccurrences(of: "                    pairingSection(pairing)\n                    approvalsSection(pairing.health())\n                }\n",
                                        with: "                    pairingSection(pairing)\n                }\n                approvalsSection(.paired)\n") }),
            // #194 design review: the switch told the phone is paired.
            ("the approvals switch told the phone is paired", Self.mutate(app, settings) {
                $0.replacingOccurrences(of: "approvalsSection(pairing.health())", with: "approvalsSection(.paired)") }),
            ("the sheet over a fixture camera", Self.mutate(app, settings) {
                $0.replacingOccurrences(of: "PairingSheet(ceremony: ceremony, camera: pairing.camera)",
                                        with: "PairingSheet(ceremony: ceremony, camera: FixtureCamera(answer: .ready))") }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.entryFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match control: a doc comment naming the shapes.
        #expect(Self.entryFailures(Self.mutate(app, settings) {
            $0 + "\n/// never pairing.makeCeremony() on appear, never showsPairing = true but on the tap, never a LivePairing elsewhere,"
                + "\n/// never ceremony = nil by hand"
        }).isEmpty)
    }

    // MARK: 2. The code from the camera only

    /// THE construction: the live scanner hands on what it read.
    static let cameraHandOn = "scanned(ScannedCode(payload: payload))"
    /// The scanner's coordinator: built with the hand-on and the failure
    /// (AMENDED, #175: a scanner VisionKit stops mid-scan is reported too;
    /// `PairingScreenTests.scanFailureFailures` pins where it goes).
    static let coordinatorInit: String = "init(scanned: @escaping @MainActor (ScannedCode) -> Void, failed: @escaping @MainActor () -> Void) {"
    static let coordinatorBuilt: String = "Coordinator(scanned: scanned, failed: failed)"
    /// Every line naming the type outside Fixtures/ (its own description is
    /// a string that names it).
    static let scannedCodeSites = CloudKitStructureTests.appSites([
        "Live/QRScanner.swift": ["struct ScannedCode: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {": 1,
                                 "var description: String { \"ScannedCode(redacted)\" }": 1,
                                 "let scanned: @MainActor (ScannedCode) -> Void": 2,
                                 coordinatorInit: 1, cameraHandOn: 1],
        "Screen/PairingScreen.swift": ["let scanned: @MainActor (ScannedCode) -> Void": 1],
        "Model/PairingCeremony.swift": ["func scanned(_ code: ScannedCode) async {": 1],
    ])
    static let scannedCodeBuilt = CloudKitStructureTests.appSites([
        "Live/QRScanner.swift": ["var description: String { \"ScannedCode(redacted)\" }": 1, cameraHandOn: 1],
    ])
    /// Every line naming `scanned` outside Fixtures/: the ceremony's entry,
    /// the screen's and the scanner's closures, the sheet's one call and the
    /// root's (a fixture launch's own code, to its fixture ceremony).
    /// AMENDED (the S-PAIR-C1.6 design review, M2): the screen's scanner
    /// line also hands on the scanner's start failure
    /// (`PairingScreenTests.scanFailureFailures` pins where it goes).
    static let previewLine: String = "PairingScreen(phase: .scanning, camera: .ready, biometry: .available(.faceID), liveCamera: false, "
        + "scanned: { _ in },"
    static let scannedSites = CloudKitStructureTests.appSites([
        "Live/QRScanner.swift": ["let scanned: @MainActor (ScannedCode) -> Void": 2, coordinatorBuilt: 2,
                                 coordinatorInit: 1, "self.scanned = scanned": 2,
                                 cameraHandOn: 1],
        "Screen/PairingScreen.swift": ["let scanned: @MainActor (ScannedCode) -> Void": 1,
                                       "QRScannerView(scanned: scanned, failed: scanFailed)": 2,
                                       "scanned: { code in Task { await ceremony.scanned(code) } },": 2,
                                       previewLine: 1],
        "Model/PairingCeremony.swift": ["func scanned(_ code: ScannedCode) async {": 1],
        "NapCatPhoneApp.swift": ["if let pairing, let scan = pairing.scan { await pairing.ceremony.scanned(scan) }": 1],
    ])
    /// The scanner's one callback, whole: the first QR code's text, handed
    /// on once, as a `ScannedCode`.
    static let handOnHead = "func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],"
    static let handOnBody = "allItems: [RecognizedItem]) { guard !handedOn else { return } for item in addedItems { "
        + "guard case .barcode(let code) = item, let payload = code.payloadStringValue else { continue } "
        + "handedOn = true dataScanner.stopScanning() " + cameraHandOn + " return }"
    /// The scanner: VisionKit's, built once, for QR codes only.
    static let scannerLine: String = "let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], "
        + "qualityLevel: .balanced,"
    static let scannerSites = CloudKitStructureTests.appSites(["Live/QRScanner.swift": [scannerLine: 1]])
    /// Every other way in, by any app source, Fixtures/ included.
    static let otherEntries = [
        #"\bonOpenURL\b"#, #"\bopenURLContexts\b"#, #"\bopen\s+url\b"#, #"\bhandlesExternalEvents\b"#,
        #"\b(?:NSUserActivity|userActivity|onContinueUserActivity)\b"#, #"\b(?:UIApplicationShortcutItem|shortcutItem)\b"#,
        #"\b(?:UIPasteboard|PasteButton|UIPasteControl|onPasteCommand|pasteDestination)\b"#,
        #"\b(?:dropDestination|onDrop|UIDropInteraction|NSItemProvider|importsItemProviders)\b"#,
        #"\b(?:fileImporter|UIDocumentPickerViewController|PhotosPicker|PHPickerViewController|UIImagePickerController)\b"#,
        #"\b(?:VNDetectBarcodesRequest|CIDetector|ImageAnalyzer)\b"#,
    ]
    /// The launch options are named by the delegate's signature alone.
    static let launchOptionsSites = CloudKitStructureTests.appSites([
        "PhoneAppDelegate.swift": ["didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil": 1],
    ])
    /// What the project could declare to take a code in from outside.
    static let configBans = ["CFBundleURLTypes", "CFBundleURLSchemes", "associated-domains", "applinks:", "UIApplicationShortcutItems",
                             "CFBundleDocumentTypes", "NSUserActivityTypes"]
    static let configFiles = ["ios/NapCatPhone/project.yml", "ios/NapCatPhone/NapCatPhone.entitlements",
                              "ios/NapCatPhone/NapCatPhone.xcodeproj/project.pbxproj"]

    static func config() throws -> [Source] {
        try configFiles.map { ($0, try String(contentsOf: CloudKitStructureTests.repoRoot.appendingPathComponent($0), encoding: .utf8)) }
    }

    static func cameraFailures(_ app: [Source], config: [Source]) -> [String] {
        var failures: [String] = []
        let live = stripped(app, fixtures: false)
        failures += CloudKitStructureTests.appSiteFailures(#"\bScannedCode\b"#, in: live, allowed: scannedCodeSites,
                                                           rule: "outside Fixtures/ a scanned code is named on its pinned lines alone")
        failures += CloudKitStructureTests.appSiteFailures(#"\bscanned\b"#, in: live, allowed: scannedSites,
                                                           rule: "a code reaches a ceremony along its pinned path alone")
        for copy in CloudKitStructureTests.constructorScanCopies(live) {
            failures += CloudKitStructureTests.appSiteFailures(#"\bScannedCode\s*(?:\.\s*init\s*)?\("#, in: copy, allowed: scannedCodeBuilt,
                                                               rule: "outside Fixtures/ a scanned code is built from the camera's read alone")
        }
        let all = stripped(app)
        for copy in CloudKitStructureTests.constructorScanCopies(all) {
            failures += CloudKitStructureTests.appSiteFailures(#"\bDataScannerViewController\s*(?:\.\s*init\s*)?\("#, in: copy,
                                                               allowed: scannerSites, rule: "one scanner, QR codes only")
        }
        failures += RecordPathStructureTests.implicitInitFailures(app, rule: "a scanned code is built by name only")
        let scanner = CloudKitStructureTests.codeOnly(app.first { $0.path == scannerFile }?.text ?? "")
        if CloudKitStructureTests.body(after: handOnHead, in: scanner).map(SettingsReachabilityTests.flat) != handOnBody {
            failures.append("the scanner hands on the first QR code's text, once, as a ScannedCode — exactly as pinned")
        }
        for (path, text) in all {
            for pattern in otherEntries where CloudKitStructureTests.hits(pattern, in: text) {
                failures.append("'\(pattern)' in \(path) — a pairing code comes from the camera alone")
            }
        }
        failures += CloudKitStructureTests.appSiteFailures(#"\blaunchOptions\b"#, in: all, allowed: launchOptionsSites,
                                                           rule: "nothing reads the launch options")
        for (path, text) in config {
            for ban in configBans where text.contains(ban) {
                failures.append("'\(ban)' in \(path) — the app declares no way in but the camera")
            }
        }
        return CloudKitStructureTests.unique(failures)
    }

    @Test func aPairingCodeComesFromTheCameraAlone() throws {
        let app = try Self.app()
        let config = try Self.config()
        #expect(config.allSatisfy { !$0.text.isEmpty }, "vacuity: every config file was read")
        #expect(Self.cameraFailures(app, config: config).isEmpty, "\(Self.cameraFailures(app, config: config))")
        let scanner = Self.scannerFile
        let root = Self.rootFile
        let feed = "\(Self.appDir)/Model/AlertFeed.swift"
        let mutants: [(String, [Source])] = [
            ("a code built from a string", Self.mutate(app, feed) { $0 + "\nlet spare = ScannedCode(payload: \"napcat-pair-v1:x\")" }),
            ("a code built by implicit init", Self.mutate(app, root) {
                $0.replacingOccurrences(of: "await pairing.ceremony.scanned(scan)", with: "await pairing.ceremony.scanned(.init(payload: \"x\"))") }),
            ("a code from a deep link", Self.mutate(app, root) {
                $0.replacingOccurrences(of: "        .task { await feed.start() }\n",
                                        with: "        .task { await feed.start() }\n        .onOpenURL { url in spare(url) }\n") }),
            ("a code from the pasteboard", Self.mutate(app, "\(Self.appDir)/Screen/PairingScreen.swift") {
                $0 + "\nfunc spare() -> String? { UIPasteboard.general.string }" }),
            ("a code from a user activity", Self.mutate(app, root) {
                $0 + "\nfunc spare(_ a: NSUserActivity) -> URL? { a.webpageURL }" }),
            ("a code from the launch options", Self.mutate(app, "\(Self.appDir)/PhoneAppDelegate.swift") {
                $0.replacingOccurrences(of: "        return true\n    }\n", with: "        _ = launchOptions?[.url]\n        return true\n    }\n") }),
            ("the scanner's read handed on twice", Self.mutate(app, scanner) {
                $0.replacingOccurrences(of: "                handedOn = true\n", with: "") }),
            ("any barcode, not only QR", Self.mutate(app, scanner) {
                $0.replacingOccurrences(of: "[.barcode(symbologies: [.qr])]", with: "[.barcode()]") }),
            ("the scanner's text replaced", Self.mutate(app, scanner) {
                $0.replacingOccurrences(of: Self.cameraHandOn, with: "scanned(ScannedCode(payload: \"napcat-pair-v1:x\"))") }),
            ("a second entry into a ceremony", Self.mutate(app, "\(Self.appDir)/Screen/PairingScreen.swift") {
                $0 + "\nfunc spare(c: PairingCeremony, s: ScannedCode) async { await c.scanned(s) }" }),
            ("a code handed to the screen's closure elsewhere", Self.mutate(app, "\(Self.appDir)/Screen/PairingScreen.swift") {
                $0.replacingOccurrences(of: "        .tint(theme.accent)\n        .onChange(of: phase)",
                                        with: "        .tint(theme.accent)\n        .onAppear { scanned(Spare.code) }\n        .onChange(of: phase)") }),
            ("a code type extended in a fixture, used live", RecordPathStructureTests.mutate(RecordPathStructureTests.mutate(app,
                "\(Self.fixturesDir)FixturePairing.swift") { $0 + "\nextension ScannedCode { static let spare = ScannedCode(payload: \"x\") }" },
                root) { $0.replacingOccurrences(of: "await pairing.ceremony.scanned(scan)", with: "await pairing.ceremony.scanned(.spare)") }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.cameraFailures(mutant, config: config).isEmpty, "canary '\(name)' was NOT caught")
        }
        // The project's declarations: a URL scheme, an associated domain.
        for (file, plant) in [("ios/NapCatPhone/project.yml", "        INFOPLIST_KEY_CFBundleURLTypes: napcat\n"),
                              ("ios/NapCatPhone/NapCatPhone.entitlements", "<key>com.apple.developer.associated-domains</key>")] {
            let planted = config.map { $0.path == file ? ($0.path, $0.text + plant) : $0 }
            #expect(!Self.cameraFailures(app, config: planted).isEmpty, "canary '\(plant)' was NOT caught")
        }
        // Over-match controls: fixtures build their own codes (they do), and a
        // doc comment may name what the lock bans.
        #expect(Self.cameraFailures(Self.mutate(app, "\(Self.fixturesDir)FixturePairing.swift") {
            $0 + "\nlet spareCode = ScannedCode(payload: \"x\")\n/// never onOpenURL, never UIPasteboard"
        }, config: config).isEmpty)
    }

    /// The running app (the test host) declares no URL scheme and no
    /// activity type: the built Info.plist, not only the project's text.
    @Test func theBuiltAppDeclaresNoWayInButTheCamera() {
        for key in ["CFBundleURLTypes", "NSUserActivityTypes", "UIApplicationShortcutItems", "CFBundleDocumentTypes"] {
            #expect(Bundle.main.object(forInfoDictionaryKey: key) == nil, "\(key) is declared")
        }
    }

    /// A scanned code describes, prints and reflects as its type's name
    /// alone: the pairing code it holds is a secret while it is on screen.
    @Test func aScannedCodeShowsNothingOfItsCode() {
        let code = ScannedCode(payload: PairingCeremonyTests.payload)
        var dumped = ""
        dump(code, to: &dumped)
        for text in [String(describing: code), String(reflecting: code), "\(code)", dumped] {
            #expect(!text.contains(PairingCeremonyTests.payload) && !text.contains("napcat-pair"), "the code leaked: \(text)")
        }
        #expect(Mirror(reflecting: code).children.isEmpty)
    }
}
