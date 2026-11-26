@testable import NapCatPhone
import Testing
import UserNotifications

/// How pushes and the permission row reach the user. The delegate itself
/// is never driven here: it only forwards to `AlertFeed.refresh()`, which
/// `AlertFeedTests` covers.
@Suite struct PushWiringTests {
    /// A push while the app is open still presents: banner, sound and a
    /// Notification Center entry, exactly that set (no badge).
    @Test func aForegroundPushPresentsBannerListAndSound() {
        #expect(ForegroundPresentation.options == [.banner, .list, .sound])
    }

    /// The Settings affordance resolves to the system's deep link.
    @Test func thePermissionRowOpensNotificationSettings() {
        #expect(PermissionRow.settingsURL != nil)
    }

    // MARK: Prompt pushes (F4, #194)

    typealias Source = CloudKitStructureTests.Source
    static let delegateFile: String = "\(CloudKitStructureTests.appDir)/PhoneAppDelegate.swift"
    static let rootFile: String = SettingsReachabilityTests.rootFile

    /// Each of the delegate's three push callbacks tries the prompt
    /// subscription's push first: a prompt push reads the prompts (with the
    /// switch as last set), a tapped one opens its prompt first, and only
    /// what is not a prompt push goes to the alert feed. Whitespace collapsed.
    static let delegateShapes: [String] = [
        "if CloudKitAlertSource.pushedPromptID(in: userInfo) != nil { await inbox.refreshPrompts() return .noData } "
            + "guard feed.isLive else { return .noData } return await feed.receivePush(",
        "willPresent notification: UNNotification ) async -> UNNotificationPresentationOptions { "
            + "let userInfo = notification.request.content.userInfo "
            + "if let prompt = CloudKitAlertSource.pushedPromptID(in: userInfo) { await receivePrompt(prompt, opens: false) } "
            + "else { await receivePush(named: feed.pushedRecordName(in: userInfo)) } return ForegroundPresentation.options }",
        "didReceive response: UNNotificationResponse ) async { let userInfo = response.notification.request.content.userInfo "
            + "if let prompt = CloudKitAlertSource.pushedPromptID(in: userInfo) { await receivePrompt(prompt, opens: true) } "
            + "else { await receivePush(named: feed.pushedRecordName(in: userInfo)) } }",
        "private func receivePrompt(_ id: PromptID, opens: Bool) async { if opens { inbox.open(id) } await inbox.refreshPrompts() }",
    ]
    /// The root opens what a tapped push asked for, once the inbox holds it.
    static let openShape: String = ".onChange(of: inbox.opening, initial: true) { _, id in guard let id else { return } "
        + "if let request = inbox.entries[id]?.request { shownRequest = request } inbox.opened() }"

    /// Every way the prompts are read: at launch, on every return to the
    /// foreground, on a pull, as the switch changes (the root, with the
    /// owner's switch), and on a prompt push (the delegate, with the switch
    /// as last set). No other line, and nothing that runs on a timer.
    static let readSites: [(word: String, sites: [String: Int])] = [
        ("syncPrompts", CloudKitStructureTests.appSites([
            "Model/RequestInbox.swift": ["func syncPrompts(switchedOn stored: Bool) async {": 1, "await syncPrompts(switchedOn: switchedOn)": 1],
            "NapCatPhoneApp.swift": ["await inbox.syncPrompts(switchedOn: approvals)": 1, ".task { await inbox.syncPrompts(switchedOn: approvals) }": 1,
                                    "Task { await inbox.syncPrompts(switchedOn: approvals) }": 1, "Task { await inbox.syncPrompts(switchedOn: on) }": 1]])),
        ("refreshPrompts", CloudKitStructureTests.appSites([
            "Model/RequestInbox.swift": ["func refreshPrompts() async {": 1],
            "PhoneAppDelegate.swift": ["await inbox.refreshPrompts()": 2]])),
        ("open", CloudKitStructureTests.appSites([
            "Model/RequestInbox.swift": ["func open(_ id: PromptID) {": 1],
            "PhoneAppDelegate.swift": ["if opens { inbox.open(id) }": 1]])),
    ]
    static let timerWords: String = #"\b(?:Timer|sleep|asyncAfter|DispatchSourceTimer|TimelineView|periodic|repeatForever)\b"#
    static let timerFreeFiles: [String] = ["Model/RequestInbox.swift", "Live/LivePromptSource.swift", "PhoneAppDelegate.swift",
                                           "NapCatPhoneApp.swift"]

    static func promptPushFailures(_ app: [Source]) -> [String] {
        var failures: [String] = []
        let delegate: String = SettingsReachabilityTests.flat(app.first { $0.path == delegateFile }?.text ?? "")
        for shape in delegateShapes where !delegate.contains(shape) {
            failures.append("the delegate lost '\(shape)'")
        }
        if !SettingsReachabilityTests.flat(app.first { $0.path == rootFile }?.text ?? "").contains(openShape) {
            failures.append("the root lost '\(openShape)'")
        }
        let stripped: [Source] = app.map { ($0.path, RecordPathStructureTests.literalsEmptied(CloudKitStructureTests.codeOnly($0.text))) }
        for (word, sites) in readSites {
            let pattern: String = word == "open" ? #"\b(?:func\s+|\.\s*)open\s*\("# : #"\b"# + word + #"\b"#
            failures += CloudKitStructureTests.appSiteFailures(pattern, in: stripped, allowed: sites,
                                                               rule: "the prompts are read, and a prompt opened, at the pinned sites alone")
        }
        for file in timerFreeFiles {
            let path: String = "\(CloudKitStructureTests.appDir)/\(file)"
            if CloudKitStructureTests.hits(timerWords, in: stripped.first { $0.path == path }?.text ?? "") {
                failures.append("\(path) holds a timer — the prompts are never read on one")
            }
        }
        return failures
    }

    @Test func aPromptPushIsReadFirstAndATapOpensItsPrompt() throws {
        let app: [Source] = try CloudKitStructureTests.swiftFiles(under: CloudKitStructureTests.appDir)
        #expect(Self.promptPushFailures(app).isEmpty, "\(Self.promptPushFailures(app))")
        let delegate: String = Self.delegateFile
        let root: String = Self.rootFile
        let inbox: String = "\(CloudKitStructureTests.appDir)/Model/RequestInbox.swift"
        func mutate(_ path: String, _ transform: (String) -> String) -> [Source] {
            app.map { $0.path == path ? ($0.path, transform($0.text)) : $0 }
        }
        let mutants: [(String, [Source])] = [
            ("an alert push tried first", mutate(delegate) {
                $0.replacingOccurrences(of: "        if let prompt = CloudKitAlertSource.pushedPromptID(in: userInfo) {\n            await receivePrompt(prompt, opens: true)",
                                        with: "        if feed.pushedRecordName(in: userInfo) == nil, let prompt = CloudKitAlertSource.pushedPromptID(in: userInfo) {\n"
                                            + "            await receivePrompt(prompt, opens: true)") }),
            ("a tap that opens nothing", mutate(delegate) {
                $0.replacingOccurrences(of: "await receivePrompt(prompt, opens: true)", with: "await receivePrompt(prompt, opens: false)") }),
            ("a banner that opens its prompt", mutate(delegate) {
                $0.replacingOccurrences(of: "await receivePrompt(prompt, opens: false)", with: "await receivePrompt(prompt, opens: true)") }),
            ("a background prompt push read as an alert", mutate(delegate) {
                $0.replacingOccurrences(of: "        if CloudKitAlertSource.pushedPromptID(in: userInfo) != nil {\n            await inbox.refreshPrompts()\n"
                                            + "            return .noData\n        }\n", with: "") }),
            ("the root opens nothing", mutate(root) { $0.replacingOccurrences(of: "{ shownRequest = request }", with: "{ _ = request }") }),
            ("the root opens late (not at launch)", mutate(root) {
                $0.replacingOccurrences(of: ".onChange(of: inbox.opening, initial: true)", with: ".onChange(of: inbox.opening)") }),
            ("a read on a timer", mutate(root) {
                $0.replacingOccurrences(of: "        .task { await inbox.syncPrompts(switchedOn: approvals) }\n",
                                        with: "        .task { while true { await inbox.syncPrompts(switchedOn: approvals); try? await Task.sleep(for: .seconds(60)) } }\n") }),
            ("a read from a new site", mutate("\(CloudKitStructureTests.appDir)/Model/AlertFeed.swift") {
                $0 + "\nfunc spare(_ i: RequestInbox) async { await i.refreshPrompts() }" }),
            ("a prompt opened from a new site", mutate(root) {
                $0.replacingOccurrences(of: "            inbox.opened()\n", with: "            inbox.opened()\n            inbox.open(id)\n") }),
            ("a timer in the inbox", mutate(inbox) { $0 + "\nlet spareTimer = Timer.publish(every: 60, on: .main, in: .common)" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.promptPushFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: words that only contain the pinned ones, a
        // string naming them, and a whole-line comment.
        #expect(Self.promptPushFailures(mutate(inbox) {
            $0 + "\nlet syncPromptsCount = 1, opened2 = 2, isOpen = true, sleepy = \"Timer\"\n/// never syncPrompts on a Timer\n"
        }).isEmpty)
    }
}
