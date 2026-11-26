import Foundation
import Testing

/// F4 (#175): the Mac's by-name runtime locks, brought to the phone.
/// The Mac's `PairingStructureTests` lock 7 (a) bans, in its four targets and
/// with no allowed site, every way its PR #171 re-checks reached a value's
/// stored parts, a class or a selector with no pinned word in sight (F-A,
/// F-D, F-F), and the reflection helpers its C1.5 security review's RP1
/// walked with no `Mirror` named (R1). The phone had no twin. Here the same
/// bans hold app-wide — every Swift file under `ios/NapCatPhone/NapCatPhone`,
/// Fixtures/ included — with no allowed site (none today):
///
/// 1. Nothing declares a runtime entry point: no `@_silgen_name`, no
///    `@_extern` (each declares a runtime or C entry point by name), no
///    `swift_reflectionMirror…` name (the Swift runtime's field reader's
///    entry points, however they would be reached), and no `_forEachField…`
///    (the standard library's reader over the same fields; on the Mac it is
///    in lock 7's reflection pattern, whose allowed lines hold `Mirror`
///    alone). That reader ignores `CustomReflectable`, so neither the
///    scanned code's redaction nor the `Mirror` pin
///    (`RecordPathStructureTests` lock 4) stops it; these bans do.
/// 2. Nothing calls the ObjC runtime's C API, by its families' prefixes
///    (`class_`, `object_`, `ivar_`, `method_`, `property_`, `protocol_`,
///    `sel_`, `imp_`, `objc_`): its ivar reader lists and reads a Swift
///    class's stored properties too — the inbox's, the keyring's, a
///    match's — and ignores every redaction.
/// 3. Nothing looks up a class, a selector or a protocol by name —
///    `NSClassFromString`, `classNamed`, `NSSelectorFromString`, `Selector`,
///    `NSProtocolFromString`: a string reaches what no pinned word names (the
///    Mac's S5 built a container from a looked-up class and selector with no
///    CloudKit import). `#selector` names a declared method, and is another
///    word.
/// 4. Nothing walks a value by the reflection helpers: no `descendant` (a
///    mirror's path walk, which reflects each child it reaches), no
///    `_reflect` and no `_getChild…` (the standard library's reflection
///    entry points) — the other words of the Mac's lock 7 reflection
///    pattern (`_forEachField…` is ban 1). `RecordPathStructureTests` lock 4
///    pins `Mirror` alone, and RP1's shape,
///    `[inbox].customMirror.descendant(0, "keyring")`, names no `Mirror`.
///
/// Each ban reads the app's sources with `//` comments removed (string
/// literals stay in: a word in a literal can only over-match) in every
/// constructor scan copy — as given, backticks removed, block comments a
/// space (`CloudKitStructureTests.constructorScanCopies`). Each catches
/// planted canaries, each by its own ban alone, so none passes vacuously.
/// What they stop, and no more: those words. Raw-pointer reads are lock 9 of
/// `RecordPathStructureTests` (the unsafe-memory families); key-value coding
/// is `KeyValueCodingStructureTests`.
@Suite struct RuntimeLookupStructureTests {
    typealias Source = CloudKitStructureTests.Source

    static let appDir: String = CloudKitStructureTests.appDir
    static let inboxFile: String = "\(appDir)/Model/RequestInbox.swift"
    static let feedFile: String = "\(appDir)/Model/AlertFeed.swift"
    static let settingsFile: String = "\(appDir)/Settings/SettingsScreen.swift"
    static let screenFile: String = "\(appDir)/Screen/AlertRow.swift"
    static let fixtureFile: String = "\(appDir)/Fixtures/FixtureRequests.swift"
    static let fixturePairingFile: String = "\(appDir)/Fixtures/FixturePairing.swift"
    static let delegateFile: String = "\(appDir)/PhoneAppDelegate.swift"

    static func app() throws -> [Source] {
        try CloudKitStructureTests.swiftFiles(under: appDir)
    }

    static func mutate(_ sources: [Source], _ path: String, _ transform: (String) -> String) -> [Source] {
        sources.map { $0.path == path ? ($0.path, transform($0.text)) : $0 }
    }

    /// `text` appended to the file at `path`.
    static func appended(_ sources: [Source], _ path: String, _ text: String) -> [Source] {
        mutate(sources, path) { $0 + text }
    }

    /// What every ban here reads: the sources with `//` comments removed,
    /// in every constructor scan copy.
    static func scanCopies(_ sources: [Source]) -> [[Source]] {
        let code: [Source] = sources.map { ($0.path, CloudKitStructureTests.codeOnly($0.text)) }
        return CloudKitStructureTests.constructorScanCopies(code)
    }

    /// Each of `patterns`' sites across `copies` must be exactly its
    /// `allowed` lines ("path: line" → count; no site for a pattern not
    /// listed), in every scan copy. The Mac's
    /// `PairingStructureTests.appSiteFailures`.
    static func siteFailuresInEveryCopy(_ patterns: [String], in copies: [[Source]], allowed: [String: [String: Int]] = [:],
                                        rule: String) -> [String] {
        var failures: [String] = []
        for pattern in patterns {
            for copy in copies {
                failures += CloudKitStructureTests.appSiteFailures(pattern, in: copy, allowed: allowed[pattern] ?? [:], rule: rule)
            }
        }
        return CloudKitStructureTests.unique(failures)
    }

    // MARK: 1. Nothing declares a runtime entry point (the Mac's F-A)

    /// The Mac's `runtimeEntryTokens`, and its `_forEachField…` reader.
    static let runtimeEntryTokens: [String] = [#"\b_silgen_name\b"#, #"\b_extern\b"#, #"\bswift_reflectionMirror\w*"#,
                                               #"\b_forEachField\w*"#]

    static func runtimeEntryFailures(_ app: [Source]) -> [String] { runtimeEntryFailures(in: scanCopies(app)) }

    static func runtimeEntryFailures(in copies: [[Source]]) -> [String] {
        siteFailuresInEveryCopy(runtimeEntryTokens, in: copies,
                                rule: "nothing declares a runtime entry point or calls its field reader — the reader ignores every redaction")
    }

    // MARK: 2-3. Nothing calls the ObjC runtime or looks up by name (the Mac's F-D, F-F)

    /// The Mac's `objcRuntimeTokens` (the C API by its families' prefixes)
    /// and `objcLookupTokens` (a class, a selector, a protocol by name).
    static let objcRuntimeTokens: [String] = [#"\b(?:class|object|ivar|method|property|protocol|sel|imp|objc)_[A-Za-z]\w*"#]
    static let objcLookupTokens: [String] = [#"\bNSClassFromString\b"#, #"\bNSSelectorFromString\b"#, #"\bSelector\b"#,
                                             #"\bclassNamed\b"#, #"\bNSProtocolFromString\b"#]

    /// The C API ban alone.
    static func objcAPIFailures(in copies: [[Source]]) -> [String] {
        siteFailuresInEveryCopy(objcRuntimeTokens, in: copies,
                                rule: "nothing calls the ObjC runtime's C API — its ivar reader ignores every redaction")
    }

    /// The lookup ban alone.
    static func objcLookupFailures(in copies: [[Source]]) -> [String] {
        siteFailuresInEveryCopy(objcLookupTokens, in: copies,
                                rule: "nothing looks up a class, a selector or a protocol by name — a string reaches what no pinned word names")
    }

    static func objcAPIFailures(_ app: [Source]) -> [String] { objcAPIFailures(in: scanCopies(app)) }

    static func objcLookupFailures(_ app: [Source]) -> [String] { objcLookupFailures(in: scanCopies(app)) }

    /// Both ObjC bans: the runtime's C API, then lookup by name.
    static func objcRuntimeFailures(_ app: [Source]) -> [String] {
        let copies: [[Source]] = scanCopies(app)
        return CloudKitStructureTests.unique(objcAPIFailures(in: copies) + objcLookupFailures(in: copies))
    }

    /// The suite's whole lock: the four bans, over one set of scan copies.
    static func lockFailures(_ app: [Source]) -> [String] {
        let copies: [[Source]] = scanCopies(app)
        var failures: [String] = runtimeEntryFailures(in: copies)
        failures += objcAPIFailures(in: copies)
        failures += objcLookupFailures(in: copies)
        failures += reflectionHelperFailures(in: copies)
        return CloudKitStructureTests.unique(failures)
    }

    /// The Mac's S5 (its re-check's round 3, F-F), verbatim: a container
    /// built from a looked-up class and selector, its private database read
    /// by name, a request sent by a looked-up selector — no CloudKit import,
    /// no container named. On the phone it is a second container, outside
    /// the CloudKit file and the capability gate, that
    /// `CloudKitStructureTests` lock 2 (which reads for the names) cannot see.
    static let s5Lines: [String] = [
        "\nenum ZZDyn {\n    static func zz() {\n",
        "        guard let cls = Bundle(identifier: \"com.apple.\" + \"CloudKit\")?.classNamed(\"CK\" + \"Container\") as AnyObject? else { return }\n",
        "        let c = cls.perform(NSSelectorFromString(\"containerWith\" + \"Identifier:\"), with: \"iCloud.zz\")?.takeUnretainedValue() as? NSObject\n",
        "        let db = c?.value(forKey: \"private\" + \"CloudDatabase\") as? NSObject\n",
        "        let done: @convention(block) (AnyObject?, AnyObject?) -> Void = { _, _ in }\n",
        "        _ = db?.perform(NSSelectorFromString(\"fetchAllRecordZones\" + \"WithCompletionHandler:\"), with: done as AnyObject)\n",
        "    }\n}\n",
    ]
    static let s5: String = s5Lines.joined()

    // MARK: 4. Nothing walks a value by the reflection helpers (the Mac's R1)

    /// The Mac's `reflectionPattern` words beside `Mirror` and
    /// `_forEachField…`, each as the Mac spells it.
    static let reflectionHelperTokens: [String] = [#"\bdescendant\b"#, #"\b_reflect\b"#, #"\b_getChild\w*"#]

    static func reflectionHelperFailures(_ app: [Source]) -> [String] { reflectionHelperFailures(in: scanCopies(app)) }

    static func reflectionHelperFailures(in copies: [[Source]]) -> [String] {
        siteFailuresInEveryCopy(reflectionHelperTokens, in: copies,
                                rule: "nothing walks a value by the reflection helpers — a walk by customMirror.descendant names no Mirror")
    }

    // MARK: - The tests

    /// The Mac's F-A canaries, on the phone: G1b's shape (the runtime's field
    /// reader declared by `@_silgen_name`, the fields read by `T.self`)
    /// reaching the inbox's keyring and its key store from Settings; its
    /// first spelling, by `type(of:)` (caught before by
    /// `RecordPathStructureTests` lock 8's dynamic-type rule alone, an
    /// unrelated one); each word alone, in other directories. Each is caught
    /// by the entry-point ban alone; G1b passes lock 8 (the gap). Each word
    /// bites its own probe alone, and G1b's entry points match in every scan
    /// copy of its text.
    @Test func nothingDeclaresARuntimeEntryPoint() throws {
        let app: [Source] = try Self.app()
        #expect(app.contains { $0.path == Self.settingsFile }, "vacuity: the scan sees Settings")
        #expect(app.contains { $0.path == Self.fixtureFile }, "vacuity: the scan sees Fixtures/")
        #expect(Self.runtimeEntryFailures(app).isEmpty, "\(Self.runtimeEntryFailures(app))")
        // The two declarations both spellings open with (the Mac's G1b, as planted).
        let entryPoints: [String] = [
            "\ntypealias ZZFree = @convention(c) (UnsafePointer<CChar>?) -> Void\n",
            "@_silgen_name(\"swift_reflectionMirror_count\") func zzN<T>(_: T, type: Any.Type) -> Int\n",
            "@_silgen_name(\"swift_reflectionMirror_subscript\") func zzC<T>(of: T, type: Any.Type, index: Int, ",
            "outName: UnsafeMutablePointer<UnsafePointer<CChar>?>, outFreeFunc: UnsafeMutablePointer<ZZFree?>) -> Any\n",
        ]
        let storeRead: String = "let store = zzField(keyring, \"store\") as? any SigningKeyStore else { return false }\n"
        let g1bGuard: String = "        guard let keyring = zzField(inbox, \"keyring\") as? PhoneKeyring, " + storeRead
        let typeOfGuard: String = "        guard let keyring = zzField(inbox, \"keyring\"), " + storeRead
        let g1bReader: [String] = [
            "func zzField<T>(_ v: T, _ label: String) -> Any? {\n    for i in 0..<zzN(v, type: T.self) {\n",
            "        var n: UnsafePointer<CChar>?\n        var f: ZZFree?\n",
            "        let c = zzC(of: v, type: T.self, index: i, outName: &n, outFreeFunc: &f)\n",
            "        let name = n.map { String(cString: $0) }\n        f?(n)\n        if name == label { return c }\n    }\n    return nil\n}\n",
            "extension SettingsScreen {\n    func zzSilgenUnpair(_ inbox: RequestInbox) -> Bool {\n",
            g1bGuard,
            "        return store.delete(.committed)\n    }\n}\n",
        ]
        let typeOfReader: [String] = [
            "func zzField(_ v: Any, _ label: String) -> Any? {\n    for i in 0..<zzN(v, type: type(of: v)) {\n",
            "        var n: UnsafePointer<CChar>?\n        var f: ZZFree?\n",
            "        let c = zzC(of: v, type: type(of: v), index: i, outName: &n, outFreeFunc: &f)\n",
            "        let name = n.map { String(cString: $0) }\n        f?(n)\n        if name == label { return c }\n    }\n    return nil\n}\n",
            "extension SettingsScreen {\n    func zzSilgenUnpair(_ inbox: RequestInbox) -> Bool {\n",
            typeOfGuard,
            "        return store.delete(.committed)\n    }\n}\n",
        ]
        let head: String = entryPoints.joined()
        let g1b: String = head + g1bReader.joined()
        let typeOf: String = head + typeOfReader.joined()
        let fixtureReader: String = "\n@_silgen_name(\"swift_reflectionMirror_count\") func zzN<T>(_: T, type: Any.Type) -> Int\n"
        let screenExtern: String = "\n@_extern(c, \"zz_reader\") func zzReader() -> Int\n"
        let stdlibReader: String = "\nfunc zz(_ t: Any.Type) { _ = _forEachField(of: t, options: []) { _, _, _, _ in true } }\n"
        let longerReader: String = "\nfunc zz<T>(_ t: T.Type) { _ = _forEachFieldWithKeyPath(of: t, options: .classType) { _, _ in true } }\n"
        let g1bMutant: [Source] = Self.appended(app, Self.settingsFile, g1b)
        let typeOfMutant: [Source] = Self.appended(app, Self.settingsFile, typeOf)
        let mutants: [(String, [Source])] = [
            ("G1b on the phone: the keyring's key store reached through the runtime's field reader, by T.self", g1bMutant),
            ("G1b's first spelling, by type(of:)", typeOfMutant),
            ("the reader declared in a fixture", Self.appended(app, Self.fixtureFile, fixtureReader)),
            ("an entry point by @_extern, in a screen", Self.appended(app, Self.screenFile, screenExtern)),
            ("the field reader by its standard-library name", Self.appended(app, Self.feedFile, stdlibReader)),
            ("a field reader by a longer name, in the inbox", Self.appended(app, Self.inboxFile, longerReader)),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            let caught: [String] = Self.runtimeEntryFailures(mutant)
            #expect(!caught.isEmpty, "canary '\(name)' was NOT caught")
            // Within the lock, the entry-point ban alone.
            #expect(Self.lockFailures(mutant) == caught, "canary '\(name)': another ban here fired")
        }
        // The gap: G1b passes lock 8, which caught only its type(of:) spelling.
        #expect(RecordPathStructureTests.unnamedConstructionFailures(g1bMutant).isEmpty, "G1b by T.self is lock 8's gap")
        #expect(!RecordPathStructureTests.unnamedConstructionFailures(typeOfMutant).isEmpty, "lock 8 reads the type(of:) spelling")
        // Each word bites alone, through the lock's own engine (and only its
        // own probe).
        let probes: [String] = ["@_silgen_name(\"zz\") func zz()", "@_extern(c, \"zz\") func zz()",
                                "let zz = \"swift_reflectionMirror_subscript\"", "_ = _forEachFieldWithKeyPath(of: t)"]
        #expect(probes.count == Self.runtimeEntryTokens.count)
        for (i, token) in Self.runtimeEntryTokens.enumerated() {
            for (j, probe) in probes.enumerated() {
                #expect(CloudKitStructureTests.hits(token, in: probe) == (i == j), "'\(token)' against '\(probe)'")
            }
        }
        // G1b's two entry points, in every scan copy of its exact text.
        let copies: [String] = [g1b, g1b.replacingOccurrences(of: "`", with: ""), CloudKitStructureTests.cleaned(g1b)]
        let attributes: [String] = ["_silgen_name", "_silgen_name"]
        let names: [String] = ["swift_reflectionMirror_count", "swift_reflectionMirror_subscript"]
        for copy in copies {
            #expect(CloudKitStructureTests.matches(Self.runtimeEntryTokens[0], in: copy) == attributes)
            #expect(CloudKitStructureTests.matches(Self.runtimeEntryTokens[2], in: copy) == names)
        }
        // Over-match controls: words that only contain the banned ones, and a
        // whole-line comment naming them (the lock's own stripping removes it).
        let near: [String] = [
            "\nlet zzSilgenName = 1, silgen_name = 2, _external = 3, extern = 4, swift_reflection = 5, reflectionMirror = 6",
            "\nlet forEachField = 7, zz_forEachField = 8, isForEachFieldName = 9, zzswift_reflectionMirror = 10",
            "\n/// never @_silgen_name(\"swift_reflectionMirror_count\"), never @_extern(c), never _forEachField(of:)",
        ]
        #expect(Self.lockFailures(Self.appended(app, Self.inboxFile, near.joined())).isEmpty)
    }

    /// The Mac's F-D and F-F canaries, on the phone: N10b's shape (a class's
    /// own ivars walked to a private holder: the inbox's keyring) and N10x's
    /// (inbox, keyring, key store, walked from Settings), and a C API call in
    /// a fixture — each caught by the C API ban alone. S5, verbatim; a
    /// match's context made by a looked-up class in the inbox (which
    /// `MatchHygieneStructureTests` lock 1, reading for `LAContext`, cannot
    /// see); and each lookup word in another directory — each caught by the
    /// lookup ban alone. S5 builds a container no container lock sees (the
    /// gap). Each C API family and each lookup word bites its own probe
    /// alone; N10b's readers and S5's lookups match in every scan copy.
    @Test func nothingCallsTheObjCRuntimeOrLooksUpByName() throws {
        let app: [Source] = try Self.app()
        #expect(Self.objcRuntimeFailures(app).isEmpty, "\(Self.objcRuntimeFailures(app))")
        let n10bLines: [String] = [
            "\nextension RequestInbox {\n    func zzIvarKeyring() -> PhoneKeyring? {\n        var n: UInt32 = 0\n",
            "        guard let list = class_copyIvarList(object_getClass(self), &n) else { return nil }\n        defer { free(list) }\n",
            "        for k in 0..<Int(n) where ivar_getName(list[k]).map({ String(cString: $0) }) == \"key\" + \"ring\" {\n",
            "            return object_getIvar(self, list[k]) as? PhoneKeyring\n        }\n        return nil\n    }\n}\n",
        ]
        let n10xLines: [String] = [
            "\nextension SettingsScreen {\n    func zzIvarChain(_ inbox: RequestInbox) {\n",
            "        func get(_ o: AnyObject, _ label: String) -> AnyObject? {\n            var n: UInt32 = 0\n",
            "            guard let list = class_copyIvarList(object_getClass(o), &n) else { return nil }\n            defer { free(list) }\n",
            "            for k in 0..<Int(n) where ivar_getName(list[k]).map({ String(cString: $0) }) == label { return object_getIvar(o, list[k]) as AnyObject? }\n",
            "            return nil\n        }\n",
            "        zzUseStore(get(inbox, \"keyring\").flatMap { get($0, \"store\") })\n    }\n}\n",
        ]
        let n10b: String = n10bLines.joined()
        let associated: String = "\nfunc zz(_ o: AnyObject, _ k: UnsafeRawPointer) -> Any? { objc_getAssociatedObject(o, k) }\n"
        let cAPI: [(String, [Source])] = [
            ("N10b on the phone: the inbox's own ivars walked to its keyring", Self.appended(app, Self.inboxFile, n10b)),
            ("N10x on the phone: inbox, keyring, key store, walked from Settings", Self.appended(app, Self.settingsFile, n10xLines.joined())),
            ("an associated object read, in a fixture", Self.appended(app, Self.fixturePairingFile, associated)),
        ]
        for (name, mutant) in cAPI {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            let caught: [String] = Self.objcAPIFailures(mutant)
            #expect(!caught.isEmpty, "canary '\(name)' was NOT caught")
            #expect(Self.lockFailures(mutant) == caught, "canary '\(name)': another ban here fired")
        }
        // Each family bites, through the lock's own engine (and no lookup
        // word with it).
        let families: [String] = ["class_copyIvarList(c, &n)", "object_getIvar(o, i)", "ivar_getName(i)", "method_getImplementation(m)",
                                  "property_getName(p)", "protocol_copyPropertyList(p, &n)", "sel_registerName(s)",
                                  "imp_implementationWithBlock(b)", "objc_getAssociatedObject(o, k)"]
        for probe in families {
            #expect(CloudKitStructureTests.hits(Self.objcRuntimeTokens[0], in: probe), "'\(probe)' was NOT caught")
            #expect(Self.objcLookupTokens.allSatisfy { !CloudKitStructureTests.hits($0, in: probe) })
        }
        // N10b's four reader names, in every scan copy of its exact text.
        let copies: [String] = [n10b, n10b.replacingOccurrences(of: "`", with: ""), CloudKitStructureTests.cleaned(n10b)]
        let readers: [String] = ["class_copyIvarList", "object_getClass", "ivar_getName", "object_getIvar"]
        for copy in copies {
            #expect(CloudKitStructureTests.matches(Self.objcRuntimeTokens[0], in: copy) == readers)
        }
        // F-F's shapes: S5, verbatim, and a match's context made by a looked-up
        // class and asked by a looked-up selector — no LAContext named.
        let contextLines: [String] = [
            "\nextension RequestInbox {\n    func zzLookedUpContext() -> AnyObject? {\n",
            "        guard let cls = NSClassFromString(\"LA\" + \"Context\") as AnyObject? else { return nil }\n",
            "        let made = cls.perform(NSSelectorFromString(\"new\"))?.takeRetainedValue()\n",
            "        _ = made?.perform(NSSelectorFromString(\"evaluate\" + \"Policy:localizedReason:reply:\"), with: 1, with: \"zz\")\n",
            "        return made\n    }\n}\n",
        ]
        let s5Mutant: [Source] = Self.appended(app, Self.settingsFile, Self.s5)
        let contextMutant: [Source] = Self.appended(app, Self.inboxFile, contextLines.joined())
        let lookups: [(String, [Source])] = [
            ("S5: a container built and asked by looked-up names, in Settings", s5Mutant),
            ("a match's context made by a looked-up class, in the inbox", contextMutant),
            ("a class looked up by name, in a fixture", Self.appended(app, Self.fixtureFile, "\nlet zz: AnyClass? = NSClassFromString(\"zz\")\n")),
            ("a selector made from a string, in the feed", Self.appended(app, Self.feedFile, "\nlet zz = Selector((\"zz\"))\n")),
            ("a protocol looked up by name, in a screen", Self.appended(app, Self.screenFile, "\nlet zz: Protocol? = NSProtocolFromString(\"zz\")\n")),
        ]
        for (name, mutant) in lookups {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            let caught: [String] = Self.objcLookupFailures(mutant)
            #expect(!caught.isEmpty, "canary '\(name)' was NOT caught")
            #expect(Self.lockFailures(mutant) == caught, "canary '\(name)': another ban here fired")
        }
        // The gaps: S5's container and the looked-up context pass the locks
        // that read for their names.
        let tests: [Source] = try CloudKitStructureTests.swiftFiles(under: CloudKitStructureTests.testsDir)
        #expect(CloudKitStructureTests.containerFailuresInEveryCopy(receiver: s5Mutant, tests: tests).isEmpty,
                "S5's container is the container lock's gap")
        #expect(MatchHygieneStructureTests.contextFailures(contextMutant).isEmpty, "a looked-up context is lock 1's gap")
        // Each lookup word bites its own probe alone, through the lock's own
        // engine (and the C API ban none of them).
        let lookupProbes: [String] = ["NSClassFromString(n)", "NSSelectorFromString(s)", "Selector((\"zz\"))", "b.classNamed(n)",
                                      "NSProtocolFromString(n)"]
        #expect(lookupProbes.count == Self.objcLookupTokens.count)
        for (i, token) in Self.objcLookupTokens.enumerated() {
            for (j, probe) in lookupProbes.enumerated() {
                #expect(CloudKitStructureTests.hits(token, in: probe) == (i == j), "'\(token)' against '\(probe)'")
            }
        }
        #expect(lookupProbes.allSatisfy { !CloudKitStructureTests.hits(Self.objcRuntimeTokens[0], in: $0) })
        // S5's lookups, in every scan copy of its exact text.
        let s5Copies: [String] = [Self.s5, Self.s5.replacingOccurrences(of: "`", with: ""), CloudKitStructureTests.cleaned(Self.s5)]
        let classLookups: [String] = ["classNamed"]
        let selectorLookups: [String] = ["NSSelectorFromString", "NSSelectorFromString"]
        for copy in s5Copies {
            #expect(CloudKitStructureTests.matches(Self.objcLookupTokens[3], in: copy) == classLookups)
            #expect(CloudKitStructureTests.matches(Self.objcLookupTokens[1], in: copy) == selectorLookups)
        }
        // Over-match controls: the phone's NSObject subclass (shipped today);
        // words that only contain the banned ones; the ObjC attributes,
        // Swift's own `class` and `protocol`; a `#selector` and its argument
        // label, UIKit's target-action among them; properties named like the
        // tokens; and a whole-line comment naming the lookups.
        let delegate: String = app.first { $0.path == Self.delegateFile }?.text ?? ""
        #expect(delegate.contains("final class PhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {"),
                "vacuity: an NSObject subclass is in the scan")
        let near: [String] = [
            "\nlet zzclass_x = 1, isObject_y = 2, Ivar_z = 3, objcName = 4, selector = 5, method = 6",
            "\n@objc protocol ZZP {}\nfinal class ZZC: NSObject { @objc func zz() {} }\nlet zzNSClassFromStringCount = 7",
            "\nlet zzSelector = #selector(ZZC.zz), Selectors = 8, isClassNamed = 9, classNamedCount = 10, zzNSSelectorFromString = 11",
            "\nfunc zz(_ c: NotificationCenter, _ o: ZZC) { c.addObserver(o, selector: #selector(ZZC.zz), name: nil, object: nil) }",
            "\nfunc zz(_ b: UIButton, _ o: ZZC) { b.addTarget(o, action: #selector(ZZC.zz), for: .touchUpInside) }",
            "\nstruct ZZS { var selector: String; var classNamedLabel: String; var protocolName: String; var objectID: Int }",
            "\nlet zzObjectWillChange = 12, propertyList = 13, methodName = 14, selName = 15, implName = 16",
            "\n/// never NSSelectorFromString(s), never Selector(\"zz\"), never classNamed(_:), never class_copyIvarList(c, &n)",
        ]
        #expect(Self.lockFailures(Self.appended(app, Self.inboxFile, near.joined())).isEmpty)
    }

    /// The Mac's R1 canaries (its C1.5 security review), on the phone: RP1's
    /// shape (the keyring's key store reached from Settings through
    /// `[inbox].customMirror.descendant(…)`, no `Mirror` named, and deleted)
    /// and its Optional-wrapper variant, in the inbox; the standard
    /// library's legacy reflection by `_reflect`, in a screen; its child
    /// reader by `_getChild…`, in the feed. Each is caught by its own word
    /// alone, and within the lock by the helper ban alone; each passes
    /// `RecordPathStructureTests` lock 4, the `Mirror` pin (the gap). Each
    /// word bites its own probe alone; RP1's walk and the child reader's
    /// names match in every scan copy.
    @Test func nothingWalksAValueByTheReflectionHelpers() throws {
        let app: [Source] = try Self.app()
        #expect(app.contains { $0.path == Self.inboxFile }, "vacuity: the scan sees the inbox")
        #expect(Self.reflectionHelperFailures(app).isEmpty, "\(Self.reflectionHelperFailures(app))")
        let rp1Lines: [String] = [
            "\nextension SettingsScreen {\n    func zzMirrorUnpair(_ inbox: RequestInbox) -> Bool {\n",
            "        guard let store = [inbox].customMirror.descendant(0, \"keyring\", \"store\") as? any SigningKeyStore else { return false }\n",
            "        return store.delete(.committed)\n    }\n}\n",
        ]
        let rp1: String = rp1Lines.joined()
        let rp1Optional: String = "\nextension RequestInbox {\n"
            + "    func zzA3() -> Any? { Optional(self).customMirror.descendant(\"some\", \"keyring\", \"store\") }\n}\n"
        let legacyLines: [String] = [
            "\nfunc zzLegacy(_ inbox: RequestInbox) -> Any? {\n    let m = _reflect(inbox)\n",
            "    for i in 0..<m.count where m[i].0 == \"keyring\" { return m[i].1.value }\n    return nil\n}\n",
        ]
        let childLines: [String] = [
            "\ntypealias ZZFree = @convention(c) (UnsafePointer<CChar>?) -> Void\n",
            "func zzChild(_ inbox: RequestInbox, _ label: String) -> Any? {\n",
            "    for i in 0..<_getChildCount(inbox, type: RequestInbox.self) {\n",
            "        var n: UnsafePointer<CChar>?\n        var f: ZZFree?\n",
            "        let c = _getChild(of: inbox, type: RequestInbox.self, index: i, outName: &n, outFreeFunc: &f)\n",
            "        let name = n.map { String(cString: $0) }\n        f?(n)\n        if name == label { return c }\n    }\n    return nil\n}\n",
        ]
        let child: String = childLines.joined()
        // Each canary, and the index of the one word that catches it.
        let canaries: [(String, Int, [Source])] = [
            ("RP1 on the phone: the keyring's key store reached from Settings by customMirror.descendant", 0,
             Self.appended(app, Self.settingsFile, rp1)),
            ("RP1 through an Optional wrapper, in the inbox", 0, Self.appended(app, Self.inboxFile, rp1Optional)),
            ("the legacy reflection by _reflect, in a screen", 1, Self.appended(app, Self.screenFile, legacyLines.joined())),
            ("the child reader by _getChild, in the feed", 2, Self.appended(app, Self.feedFile, child)),
        ]
        for (name, word, mutant) in canaries {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            let caught: [String] = Self.reflectionHelperFailures(mutant)
            #expect(!caught.isEmpty, "canary '\(name)' was NOT caught")
            // Within the lock, the helper ban alone; within it, its own word alone.
            #expect(Self.lockFailures(mutant) == caught, "canary '\(name)': another ban here fired")
            let copies: [[Source]] = Self.scanCopies(mutant)
            for (j, token) in Self.reflectionHelperTokens.enumerated() {
                let bites: Bool = !Self.siteFailuresInEveryCopy([token], in: copies, rule: "").isEmpty
                #expect(bites == (j == word), "canary '\(name)' against '\(token)'")
            }
            // The gap: the Mirror pin reads `Mirror` alone.
            #expect(RecordPathStructureTests.confirmationFailures(mutant).isEmpty, "canary '\(name)' is the Mirror pin's gap")
        }
        // Each word bites alone, through the lock's own engine (and only its
        // own probe).
        let probes: [String] = ["_ = x.customMirror.descendant(0)", "_ = _reflect(x)", "_ = _getChildCount(x, type: T.self)"]
        #expect(probes.count == Self.reflectionHelperTokens.count)
        for (i, token) in Self.reflectionHelperTokens.enumerated() {
            for (j, probe) in probes.enumerated() {
                #expect(CloudKitStructureTests.hits(token, in: probe) == (i == j), "'\(token)' against '\(probe)'")
            }
        }
        // RP1's walk and the child reader's two names, in every scan copy of
        // their exact text.
        let rp1Copies: [String] = [rp1, rp1.replacingOccurrences(of: "`", with: ""), CloudKitStructureTests.cleaned(rp1)]
        let childCopies: [String] = [child, child.replacingOccurrences(of: "`", with: ""), CloudKitStructureTests.cleaned(child)]
        let walks: [String] = ["descendant"]
        let readers: [String] = ["_getChildCount", "_getChild"]
        for copy in rp1Copies {
            #expect(CloudKitStructureTests.matches(Self.reflectionHelperTokens[0], in: copy) == walks)
        }
        for copy in childCopies {
            #expect(CloudKitStructureTests.matches(Self.reflectionHelperTokens[2], in: copy) == readers)
        }
        // Over-match controls: UIKit's isDescendant(of:); properties and a
        // method named like the tokens, and `descending` (other words); and
        // a whole-line and a trailing comment naming the shapes (the lock's
        // own stripping removes them).
        let near: [String] = [
            "\nfunc zz(_ a: UIView, _ b: UIView) -> Bool { a.isDescendant(of: b) }",
            "\nstruct ZZT { var descendants: [Int]; var descendantCount: Int; var isDescendant: Bool; func descendants(of n: Int) -> [Int] { [n] } }",
            "\nlet descending = 1, reflect = 2, _reflection = 3, zz_reflect = 4, reflected = 5, _reflects = 6",
            "\nlet getChild = 7, zz_getChild = 8, _get_child = 9, getChildCount = 10, childCount = 11",
            "\n/// never [inbox].customMirror.descendant(0, \"keyring\"), never _reflect(x), never _getChild(of:)",
            "\nlet zzTrailing = 12 // descendant, _reflect, _getChildCount",
        ]
        #expect(Self.lockFailures(Self.appended(app, Self.inboxFile, near.joined())).isEmpty)
    }
}
