import Foundation
@testable import NapCatPhone
import SwiftUI
import Testing
import UIKit

/// Settings (#92): its fixed copy, About's version and link, and structural
/// locks over its source. Each lock is also run against a mutated copy, so a
/// lock that could never fail fails here instead.
@Suite struct SettingsScreenTests {
    typealias Source = CloudKitStructureTests.Source

    static let settingsDir = "\(CloudKitStructureTests.appDir)/Settings"

    static func settingsSources() throws -> [Source] {
        try CloudKitStructureTests.swiftFiles(under: settingsDir)
    }

    @Test func theScanSeesTheSettingsCode() throws {
        let paths = try Self.settingsSources().map(\.path)
        #expect(paths == ["\(Self.settingsDir)/AppVersion.swift", "\(Self.settingsDir)/SettingsScreen.swift"])
    }

    @Test func theScreenSaysExactlyThis() {
        #expect(SettingsScreen.title == "Settings")
        #expect(SettingsScreen.done == "Done")
        #expect([SettingsScreen.appearanceHeader, SettingsScreen.notificationsHeader, SettingsScreen.aboutHeader]
            == ["Appearance", "Notifications", "About"])
        #expect(SettingsScreen.paletteLabel == "Palette")
        #expect(SettingsScreen.statusLabel == "Status")
        #expect(SettingsScreen.versionLabel == "Version")
        #expect(SettingsScreen.siteLabel == "Website")
        #expect(UIImage(systemName: LinkOutLabel.symbol) != nil)
    }

    /// S-PAIR-C1.6 (#172): the Pairing row's words. The footer names the
    /// Mac's own buttons and pane, word for word, read from the Mac's source.
    /// AMENDED (the S-PAIR-C1.6 design review, M1): it names both buttons (a
    /// Mac already paired shows Pair a New iPhone… instead), says the pane
    /// is NapCat's own, and names the Face ID that comes with the scan.
    /// AMENDED (#175): it names THIS phone's biometric (a Touch ID phone
    /// read Face ID), in otherwise the same words; with none, biometrics.
    @Test func thePairingRowSaysExactlyThis() throws {
        #expect(SettingsScreen.pairingHeader == "Pairing")
        #expect(SettingsScreen.pairTitle == "Pair with Mac")
        #expect(SettingsScreen.pairTitle == PairingScreen.title, "the row names the screen it opens")
        let lead: String = "On your Mac, choose Pair iPhone… or Pair a New iPhone… in NapCat's Settings › Claude, "
        let faceID: String = lead + "then scan the code it shows and confirm with Face ID."
        let touchID: String = lead + "then scan the code it shows and confirm with Touch ID."
        let none: String = lead + "then scan the code it shows and confirm with biometrics."
        #expect(SettingsScreen.pairingFooter(.faceID) == faceID)
        #expect(SettingsScreen.pairingFooter(.touchID) == touchID)
        #expect(SettingsScreen.pairingFooter(nil) == none)
        for kind in BiometryKind.allCases {
            let footer: String = SettingsScreen.pairingFooter(kind)
            for other in BiometryKind.allCases {
                #expect(footer.contains(other.name) == (other == kind), "'\(footer)' and \(other.name)")
            }
            #expect(footer.hasPrefix(lead) && footer.hasSuffix("confirm with \(kind.name)."), "only the name changes: '\(footer)'")
        }
        #expect(BiometryKind.allCases.allSatisfy { !none.contains($0.name) }, "with none, no biometric is named")
        let mac = try CloudKitStructureTests.swiftFiles(under: "Sources/NapCat")
        let settings = try #require(mac.first { $0.path == "Sources/NapCat/SettingsContent.swift" }).text
        #expect(settings.contains("static let pairButtonTitle = \"Pair iPhone…\""), "the Mac's button is still Pair iPhone…")
        #expect(settings.contains("static let pairNewButtonTitle = \"Pair a New iPhone…\""),
                "the paired Mac's button is still Pair a New iPhone…")
        #expect(settings.contains("case .claude: return \"Claude\""), "the Mac's pane is still Claude")
    }

    /// #175: the footer names what the live pairing's own gate reads
    /// (`LivePairing.biometric()`: no context of Settings' own, as
    /// `MatchHygieneStructureTests` lock 1 requires), never a fixed one.
    static let footerShape: String = "} footer: { footer(Self.pairingFooter(pairing.biometric())) }"

    static func footerFailures(_ screen: String) -> [String] {
        let flat: String = SettingsReachabilityTests.flat(screen)
        var failures: [String] = []
        if !flat.contains(footerShape) { failures.append("the pairing footer lost '\(footerShape)'") }
        if CloudKitStructureTests.occurrences(of: "pairingFooter(", in: flat) != 2 {
            failures.append("the footer's words are declared once and said once, by the pairing row")
        }
        return failures
    }

    @Test func theFooterNamesThisPhonesBiometric() throws {
        let screen: String = try #require(try Self.settingsSources().first { $0.path.hasSuffix("/SettingsScreen.swift") }).text
        #expect(Self.footerFailures(screen).isEmpty, "\(Self.footerFailures(screen))")
        let mutants: [(String, String)] = [
            ("the footer told Face ID", screen.replacingOccurrences(of: "pairingFooter(pairing.biometric())", with: "pairingFooter(.faceID)")),
            ("a second footer, fixed", screen.replacingOccurrences(of: "            header(Self.aboutHeader)\n",
                                                                  with: "            header(Self.aboutHeader)\n            footer(Self.pairingFooter(.faceID))\n")),
        ]
        for (name, mutant) in mutants {
            #expect(mutant != screen, "canary '\(name)' did not apply")
            #expect(!Self.footerFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: Remote approvals (F4, #194)

    /// The switch's row: its group named as the Mac names its own, a label
    /// that says where the prompts go, and a footer that says, on a paired
    /// phone, what it does today and what it does not do yet, and on an
    /// unpaired one, to pair first (#194 design review). Lock-safe words:
    /// none of the words the answer path's locks count.
    @Test func theApprovalsRowSaysExactlyThis() {
        #expect(SettingsScreen.approvalsHeader == "Remote approvals")
        #expect(SettingsScreen.approvalsLabel == "Prompts on This iPhone")
        let paired: String = "Shows permission prompts that reach this iPhone through your iCloud, and notifies you "
            + "when one is waiting. This iPhone can't check which Mac sent a prompt. "
            + "You can't answer from iPhone yet — answer on your Mac."
        let unpaired: String = "Pair this iPhone with your Mac above to see its permission prompts here."
        #expect(SettingsScreen.approvalsPairedFooter == paired)
        #expect(SettingsScreen.approvalsUnpairedFooter == unpaired)
        let healths: [PhoneKeyring.Health] = [.paired, .enrollmentChanged, .unpaired(.neverPaired), .unpaired(.enrollmentChanged),
                                              .unpaired(.unreadable)]
        for health in healths {
            let committed: Bool = health == .paired || health == .enrollmentChanged
            #expect(SettingsScreen.approvalsFooter(for: health) == (committed ? paired : unpaired), "\(health)")
        }
        let footers: [String] = [paired, unpaired]
        for footer in footers {
            for word in ["match", "sign", "signed", "confirm", "confirmed"] {
                #expect(!footer.split(whereSeparator: { !$0.isLetter }).contains { $0.lowercased() == word }, "'\(word)' in '\(footer)'")
            }
        }
    }

    /// Only a stored true with a committed key (paired, or paired under
    /// biometrics changed since) takes effect; off, or unpaired, nothing.
    @Test func theSwitchTakesEffectOnlyOnWithACommittedKey() {
        let healths: [PhoneKeyring.Health] = [.paired, .enrollmentChanged, .unpaired(.neverPaired), .unpaired(.enrollmentChanged),
                                              .unpaired(.unreadable)]
        for health in healths {
            #expect(!ApprovalsSwitch.effective(stored: false, keyHealth: health), "off, \(health)")
            let committed: Bool = health == .paired || health == .enrollmentChanged
            #expect(ApprovalsSwitch.isCommitted(health) == committed, "\(health)")
            #expect(ApprovalsSwitch.effective(stored: true, keyHealth: health) == committed, "on, \(health)")
        }
    }

    /// The stored choice, as a test holds it.
    final class StoredSwitch: @unchecked Sendable {
        var on: Bool
        init(_ on: Bool) { self.on = on }
        var binding: Binding<Bool> { Binding(get: { self.on }, set: { self.on = $0 }) }
    }

    /// #194 design review: the row follows the pairing. Paired (or changed
    /// since), it shows the stored choice and sets it; unpaired, it shows
    /// off, a stored on included, and nothing set there is kept.
    @MainActor
    @Test func theSwitchFollowsThePairing() {
        let healths: [PhoneKeyring.Health] = [.paired, .enrollmentChanged, .unpaired(.neverPaired), .unpaired(.enrollmentChanged),
                                              .unpaired(.unreadable)]
        for health in healths {
            let committed: Bool = ApprovalsSwitch.isCommitted(health)
            for stored in [false, true] {
                let kept: StoredSwitch = StoredSwitch(stored)
                let shown: Binding<Bool> = SettingsScreen.shownSwitch(kept.binding, keyHealth: health)
                #expect(shown.wrappedValue == (committed && stored), "\(health), stored \(stored)")
                shown.wrappedValue = !stored
                #expect(kept.on == (committed ? !stored : stored), "\(health): set from \(stored)")
            }
        }
    }

    /// The switch is the phone's own: kept under `ApprovalsSwitch.storageKey`
    /// (a throwaway suite here), off unless set, and reading it writes
    /// nothing.
    @MainActor
    @Test func theSwitchIsOffUnlessSet() {
        #expect(ApprovalsSwitch.storageKey == "remoteApprovalsEnabled")
        PalettePersistenceTests.withSuite { suite in
            let stored = AppStorage(wrappedValue: false, ApprovalsSwitch.storageKey, store: suite)
            #expect(stored.wrappedValue == false)
            #expect(suite.object(forKey: ApprovalsSwitch.storageKey) == nil, "reading writes nothing")
            stored.wrappedValue = true
            #expect(AppStorage(wrappedValue: false, ApprovalsSwitch.storageKey, store: suite).wrappedValue)
        }
    }

    /// Settings sets the root's switch and nothing else: one toggle bound to
    /// it, under Pairing and shown with it; and the root keeps the one
    /// stored choice (`@AppStorage`), handed to Settings bound and to the
    /// inbox at its pinned triggers (`PushWiringTests`).
    /// AMENDED (#194 design review): the toggle follows the phone's pairing,
    /// read through the live pairing: shown through `shownSwitch`, disabled
    /// without a committed key, its footer chosen by the same reading.
    /// AMENDED (#194 polish): its label in the ink only with a committed
    /// key, dimmed to the secondary ink where the switch is disabled; and
    /// the root hands the switch to the inbox as Settings and the launch's
    /// pairing sheet close (`PushWiringTests` pins those two triggers).
    static let toggleShape: String = "Toggle(isOn: Self.shownSwitch($approvals, keyHealth: keyHealth)) { "
        + "Text(Self.approvalsLabel) .foregroundStyle(ApprovalsSwitch.isCommitted(keyHealth) ? theme.ink : theme.inkSecondary) } "
        + ".disabled(!ApprovalsSwitch.isCommitted(keyHealth))"
    static let footerSwitchShape: String = "} footer: { footer(Self.approvalsFooter(for: keyHealth)) }"
    static let switchShapes: [String] = [toggleShape, footerSwitchShape,
                                         "private func approvalsSection(_ keyHealth: PhoneKeyring.Health) -> some View {",
                                         "approvalsSection(pairing.health())"]
    static let approvalsSites: [String: Int] = CloudKitStructureTests.appSites([
        "Settings/SettingsScreen.swift": ["@Binding var approvals: Bool": 1, "Toggle(isOn: Self.shownSwitch($approvals, keyHealth: keyHealth)) {": 1,
                                          "SettingsScreen(palette: $palette, notifications: .on, approvals: .constant(false))": 1,
                                          "SettingsScreen(palette: $palette, notifications: .off, approvals: .constant(false))": 1],
        "NapCatPhoneApp.swift": ["@AppStorage(ApprovalsSwitch.storageKey) private var approvals = false": 1, "approvals: $approvals)": 2,
                                 "await inbox.syncPrompts(switchedOn: approvals)": 1, ".task { await inbox.syncPrompts(switchedOn: approvals) }": 1,
                                 "Task { await inbox.syncPrompts(switchedOn: approvals) }": 1, ".onChange(of: approvals) { _, on in": 1,
                                 PushWiringTests.settingsDismissSync: 1, PushWiringTests.pairingDismissSync: 1],
    ])

    static func approvalsFailures(_ app: [Source]) -> [String] {
        var failures: [String] = []
        let screen: String = SettingsReachabilityTests.flat(app.first { $0.path.hasSuffix("/Settings/SettingsScreen.swift") }?.text ?? "")
        for shape in switchShapes where !screen.contains(shape) { failures.append("Settings lost '\(shape)'") }
        if CloudKitStructureTests.occurrences(of: "Toggle(", in: screen) != 1 { failures.append("Settings holds one toggle, the switch") }
        if CloudKitStructureTests.occurrences(of: "approvalsSection(", in: screen) != 2 {
            failures.append("the switch's row is declared once and drawn once, with the pairing as it stands")
        }
        let stripped: [Source] = app.map { ($0.path, RecordPathStructureTests.literalsEmptied(CloudKitStructureTests.codeOnly($0.text))) }
        failures += CloudKitStructureTests.appSiteFailures(#"\bapprovals\b"#, in: stripped, allowed: approvalsSites,
                                                           rule: "the switch is kept by the root, set by Settings and read by the inbox alone")
        failures += CloudKitStructureTests.appSiteFailures(#"\bApprovalsSwitch\s*\.\s*storageKey\b"#, in: stripped,
                                                           allowed: CloudKitStructureTests.appSites(["NapCatPhoneApp.swift": [
                                                               "@AppStorage(ApprovalsSwitch.storageKey) private var approvals = false": 1]]),
                                                           rule: "one place keeps the switch")
        return failures
    }

    @Test func settingsSetsTheRootsSwitchAlone() throws {
        let app: [Source] = try CloudKitStructureTests.swiftFiles(under: CloudKitStructureTests.appDir)
        #expect(Self.approvalsFailures(app).isEmpty, "\(Self.approvalsFailures(app))")
        let settings: String = "\(Self.settingsDir)/SettingsScreen.swift"
        let root: String = SettingsReachabilityTests.rootFile
        func mutate(_ path: String, _ transform: (String) -> String) -> [Source] {
            app.map { $0.path == path ? ($0.path, transform($0.text)) : $0 }
        }
        let mutants: [(String, [Source])] = [
            ("the toggle bound to a constant", mutate(settings) {
                $0.replacingOccurrences(of: "Toggle(isOn: Self.shownSwitch($approvals, keyHealth: keyHealth))",
                                        with: "Toggle(isOn: .constant(true))") }),
            // #194 design review: the switch on an unpaired phone.
            ("the toggle bound straight to the stored choice", mutate(settings) {
                $0.replacingOccurrences(of: "Toggle(isOn: Self.shownSwitch($approvals, keyHealth: keyHealth))",
                                        with: "Toggle(isOn: $approvals)") }),
            ("the toggle settable unpaired", mutate(settings) {
                $0.replacingOccurrences(of: "            .disabled(!ApprovalsSwitch.isCommitted(keyHealth))\n", with: "") }),
            // #194 polish: the disabled row's label dims with it.
            ("the label in full ink while the switch is disabled", mutate(settings) {
                $0.replacingOccurrences(of: ".foregroundStyle(ApprovalsSwitch.isCommitted(keyHealth) ? theme.ink : theme.inkSecondary)",
                                        with: ".foregroundStyle(theme.ink)") }),
            // #194 polish: the root's two sheet-close hand-offs are pinned.
            ("the switch handed in as a third sheet closes", mutate(root) {
                $0.replacingOccurrences(of: ".sheet(item: $shownRequest) {",
                                        with: ".sheet(item: $shownRequest, onDismiss: { Task { await inbox.syncPrompts(switchedOn: approvals) } }) {") }),
            ("the footer fixed", mutate(settings) {
                $0.replacingOccurrences(of: "footer(Self.approvalsFooter(for: keyHealth))", with: "footer(Self.approvalsPairedFooter)") }),
            ("the row told it is paired", mutate(settings) {
                $0.replacingOccurrences(of: "approvalsSection(pairing.health())", with: "approvalsSection(.paired)") }),
            ("a second row", mutate(settings) {
                $0.replacingOccurrences(of: "                about\n", with: "                about\n                approvalsSection(.paired)\n") }),
            ("Settings switches it on as it appears", mutate(settings) {
                $0.replacingOccurrences(of: "        .tint(theme.accent)\n        .sheet(item: $ceremony)",
                                        with: "        .tint(theme.accent)\n        .onAppear { approvals = true }\n        .sheet(item: $ceremony)") }),
            ("a second toggle", mutate(settings) {
                $0.replacingOccurrences(of: "            NotificationSettingsButton(title: notifications.action)\n",
                                        with: "            NotificationSettingsButton(title: notifications.action)\n            Toggle(isOn: $approvals) { Text(\"x\") }\n") }),
            ("a second keeper", mutate("\(CloudKitStructureTests.appDir)/Model/AlertFeed.swift") {
                $0 + "\nenum Spare { static let key = ApprovalsSwitch.storageKey }" }),
            ("the root's switch on by default", mutate(root) {
                $0.replacingOccurrences(of: "private var approvals = false", with: "private var approvals = true") }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.approvalsFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        #expect(Self.approvalsFailures(mutate(settings) { $0 + "\n/// never approvals = true here\nlet spareApprovalsCount = 1" }).isEmpty)
    }

    /// #194 security review: the switch's stored key is spelled once, on
    /// `ApprovalsSwitch.storageKey`'s own line, string literals included (a
    /// word in a literal counts), so no source reads or writes the stored
    /// choice by its key: the root's `@AppStorage`, through that name, is
    /// its one keeper (`settingsSetsTheRootsSwitchAlone`).
    static let keyLiteralSites: [String: Int] = CloudKitStructureTests.appSites([
        "Model/ApprovalsSwitch.swift": ["static let storageKey = \"remoteApprovalsEnabled\"": 1]])

    static func keyLiteralFailures(_ app: [Source]) -> [String] {
        let code: [Source] = app.map { ($0.path, CloudKitStructureTests.codeOnly($0.text)) }
        return CloudKitStructureTests.appSiteFailures(#"remoteApprovalsEnabled"#, in: code, allowed: keyLiteralSites,
                                                      rule: "the switch's key is spelled by ApprovalsSwitch alone")
    }

    @Test func theSwitchKeyIsSpelledOnce() throws {
        let app: [Source] = try CloudKitStructureTests.swiftFiles(under: CloudKitStructureTests.appDir)
        #expect(Self.keyLiteralFailures(app).isEmpty, "\(Self.keyLiteralFailures(app))")
        func mutate(_ path: String, _ transform: (String) -> String) -> [Source] {
            app.map { $0.path == path ? ($0.path, transform($0.text)) : $0 }
        }
        let delegate: String = "\(CloudKitStructureTests.appDir)/PhoneAppDelegate.swift"
        let feed: String = "\(CloudKitStructureTests.appDir)/Model/AlertFeed.swift"
        let mutants: [(String, [Source])] = [
            // The review's probe, as planted.
            ("the delegate switches it on by its key", mutate(delegate) {
                $0.replacingOccurrences(of: "        // Fixture runs never touch the notification center.\n",
                                        with: "        UserDefaults.standard.set(true, forKey: \"remoteApprovalsEnabled\")\n"
                                            + "        // Fixture runs never touch the notification center.\n") }),
            ("the root keeps it by its key", mutate(SettingsReachabilityTests.rootFile) {
                $0.replacingOccurrences(of: "@AppStorage(ApprovalsSwitch.storageKey) private var approvals = false",
                                        with: "@AppStorage(\"remoteApprovalsEnabled\") private var approvals = false") }),
            ("a raw-string key", mutate(feed) { $0 + "\nlet spareKey = #\"remoteApprovalsEnabled\"#" }),
            ("a multi-line key", mutate(feed) { $0 + "\nlet spareKey = \"\"\"\nremoteApprovalsEnabled\n\"\"\"" }),
            ("a second spelling beside the first", mutate("\(CloudKitStructureTests.appDir)/Model/ApprovalsSwitch.swift") {
                $0.replacingOccurrences(of: "    static let storageKey = \"remoteApprovalsEnabled\"\n",
                                        with: "    static let storageKey = \"remoteApprovalsEnabled\"\n    static let spare = \"remoteApprovalsEnabled\"\n") }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.keyLiteralFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match control: a whole-line comment naming the key.
        #expect(Self.keyLiteralFailures(mutate(feed) { $0 + "\n/// never \"remoteApprovalsEnabled\" by hand\n" }).isEmpty)
    }

    // MARK: About

    @Test func theSiteLinkIsTheProjectSite() throws {
        let site = try #require(SettingsScreen.siteURL)
        #expect(site.absoluteString == "https://muratalkan06.github.io/NapCat/")
        #expect(site.scheme == "https")
    }

    /// About shows the build that is running: the host app's own Info.plist.
    @Test func aboutReadsTheVersionAndBuildFromTheBundle() throws {
        let info = try #require(Bundle.main.infoDictionary)
        let marketing = try #require(info["CFBundleShortVersionString"] as? String)
        let build = try #require(info["CFBundleVersion"] as? String)
        let version = AppVersion(bundle: .main)
        #expect(version == AppVersion(info: info))
        #expect(version.text == "\(marketing) (\(build))")
        #expect(version.spoken == "\(marketing), build \(build)")
        #expect(version.marketing != AppVersion.unknown && version.build != AppVersion.unknown)
    }

    @Test func versionTextFormatsAndFallsBack() {
        let version = AppVersion(info: ["CFBundleShortVersionString": "2.3.4", "CFBundleVersion": "17"])
        #expect(version.text == "2.3.4 (17)")
        #expect(version.spoken == "2.3.4, build 17")
        #expect(AppVersion(info: [:]).text == "unknown (unknown)")
        #expect(AppVersion(info: ["CFBundleVersion": 3]).build == "unknown")
    }

    // MARK: Lock 1: no iCloud, no network

    /// Each pattern is a way to reach iCloud or the network, or to reach
    /// the feed (which does). Settings works only on what it is handed.
    static let offLimits: [String] = [
        #"\bimport\s+(CloudKit|Network)\b"#,
        #"\bCK[A-Z]\w*"#,
        #"\bNW[A-Z]\w*"#,
        #"\bURLSession\b"#,
        #"\bURLRequest\b"#,
        #"\b(Data|String)\(contentsOf:"#,
        #"\bAlertFeed\b"#,
        #"\bAlertSource\b"#,
        #"\bNotificationGate\b"#,
        #"\b(refresh|receivePush|fetch\w*)\("#,
    ]

    static func networkFailures(_ sources: [Source]) -> [String] {
        violations(of: offLimits, in: sources)
    }

    static func violations(of patterns: [String], in sources: [Source]) -> [String] {
        var failures: [String] = []
        for source in sources {
            let code = CloudKitStructureTests.codeOnly(source.text)
            for pattern in patterns where code.range(of: pattern, options: .regularExpression) != nil {
                failures.append("\(source.path) matches \(pattern)")
            }
        }
        return failures
    }

    @Test func settingsHasNoCloudKitOrNetworkCalls() throws {
        let failures = Self.networkFailures(try Self.settingsSources())
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test func theNetworkLockCatchesEachBreach() throws {
        let clean = try Self.settingsSources()
        let breaches = [
            "import CloudKit",
            // (Never a container here: CloudKitStructureTests forbids tests to name one.)
            "let operation = CKQueryOperation(query: query)",
            "let monitor = NWPathMonitor()",
            "_ = URLSession.shared.dataTask(with: url)",
            "let request = URLRequest(url: url)",
            "let page = try Data(contentsOf: url)",
            "let feed: AlertFeed",
            "Task { await feed.refresh() }",
            "_ = try await source.fetchRecent()",
        ]
        for breach in breaches {
            let mutated = clean.map { ($0.path, $0.text + "\n\(breach)\n") }
            #expect(!Self.networkFailures(mutated).isEmpty, "missed: \(breach)")
        }
        // A comment may name them.
        #expect(Self.networkFailures(clean.map { ($0.path, $0.text + "\n// URLSession, CKRecord\n") }).isEmpty)
    }

    // MARK: Lock 2: theme tokens only

    /// A color, font or system style spelled in place instead of read from
    /// the theme.
    static let literalStyle: [String] = [
        #"\bColor\("#,
        #"\bColor\.\w"#,
        #"\bUIColor\b"#,
        #"\.font\(\."#,
        #"\bFont\.\w"#,
        #"\.(foregroundStyle|tint|background)\(\.[a-z]"#,
        #"\b(spacing|padding)\b[:(]\s*\d"#,
    ]

    @Test func settingsReadsEveryColorAndFontFromTheTheme() throws {
        let failures = Self.violations(of: Self.literalStyle, in: try Self.settingsSources())
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test func theThemeLockCatchesEachBreach() throws {
        let clean = try Self.settingsSources()
        for breach in [".foregroundStyle(Color(red: 1, green: 0, blue: 0))", ".tint(Color.blue)",
                       ".font(.system(size: 13))", ".foregroundStyle(.secondary)", "HStack(spacing: 6) {}",
                       ".padding(12)", "let c = UIColor.red"] {
            let mutated = clean.map { ($0.path, $0.text + "\n\(breach)\n") }
            #expect(!Self.violations(of: Self.literalStyle, in: mutated).isEmpty, "missed: \(breach)")
        }
    }

    // MARK: Lock 3: the version is read, never spelled; the permission is shared

    static let versionLiteral = #""\d+\.\d+(\.\d+)?( \(\d+\))?""#

    @Test func aboutNeverSpellsAVersionAndUsesTheSharedPermission() throws {
        let sources = try Self.settingsSources()
        #expect(Self.violations(of: [Self.versionLiteral], in: sources).isEmpty)
        #expect(!Self.violations(of: [Self.versionLiteral], in: [("Mutant.swift", #"let v = "0.1.0 (1)""#)]).isEmpty)
        let screen = try #require(sources.first { $0.path.hasSuffix("/SettingsScreen.swift") })
        let code = CloudKitStructureTests.codeOnly(screen.text)
        #expect(code.contains("var version = AppVersion(bundle: .main)"))
        #expect(code.contains("NotificationSettingsButton(title: notifications.action)"))
        #expect(code.contains("Form {"))
        #expect(code.contains(".pickerStyle(.inline)"))
    }
}
