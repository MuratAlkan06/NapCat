import Foundation
import Testing

/// F4 (#175, L-1): the Mac's key-value coding ban, brought to the phone.
/// The Mac's `PhoneTransportStructureTests` bans in its four targets (its
/// PR #171 re-checks' F-B, F-C and R-C) every way to read, write, evaluate
/// or observe a property by its name as a string: its G2 read a container's
/// private database by `value(forKey: "private" + "CloudDatabase")`, the key
/// split, naming no pinned word. The phone had no twin. Here the same nine
/// bans hold app-wide — every Swift file under `ios/NapCatPhone/NapCatPhone`,
/// Fixtures/ included — in every constructor scan copy, `//` comments
/// removed (`RuntimeLookupStructureTests.scanCopies`):
///
/// - key-value coding's doors: `value(forKey:)`, `value(forKeyPath:)`,
///   `value(forUndefinedKey:)`; every `setValue…`, `setValuesForKeys`,
///   `setNilValueForKey`; the collection proxies and the bulk read;
/// - what evaluates a key-path string: `NSExpression`, `NSPredicate`,
///   `NSSortDescriptor`, any `forKeyPath` argument, `#keyPath`;
/// - and observing, by key path, by selector or by block: `addObserver`.
///
/// Each is named nowhere but on its pinned lines, each pinned to its exact
/// line and count (the Mac's precedent for a word with legitimate uses): the
/// alert lane's two predicates and its one sort descriptor, in the CloudKit
/// file — the subscription's and the fetch query's, the F3 spike's proven
/// shapes, each a constant handed to CloudKit (`NSPredicate(value: true)`
/// evaluates no key path; the sort key is the wire's own field). The phone
/// has no other site: no notification observer, no setter by name. Before
/// this lock the only phone ban on any of these words was the CloudKit
/// file's own setter list (`RecordPathStructureTests` lock 5), which reads
/// that file alone.
@Suite struct KeyValueCodingStructureTests {
    typealias Source = CloudKitStructureTests.Source
    typealias Lookup = RuntimeLookupStructureTests

    static let appDir: String = CloudKitStructureTests.appDir
    static let cloudKitFile: String = CloudKitStructureTests.cloudKitFile
    static let keyringFile: String = "\(appDir)/Model/PhoneKeyring.swift"
    static let pairingFile: String = "\(appDir)/Live/LivePairing.swift"

    /// The Mac's `keyValueCodingBans`, in its order.
    static let setValuePattern: String = #"\bset(?:Nil)?Values?\w*"#
    static let predicatePattern: String = #"\bNSPredicate\b"#
    static let sortDescriptorPattern: String = #"\bNSSortDescriptor\b"#
    static let addObserverPattern: String = #"\baddObserver\b"#
    static let keyValueCodingBans: [String] = [#"\bvalue\s*\(\s*for(?:Undefined)?Key"#, setValuePattern,
                                               #"\b(?:mutable(?:Ordered)?(?:Array|Set)Value|dictionaryWithValues)\b"#,
                                               #"\bNSExpression\b"#, predicatePattern, sortDescriptorPattern, #"\bforKeyPath\b"#,
                                               #"#keyPath\b"#, addObserverPattern]
    /// A probe each ban matches, in order (the Mac's).
    static let keyValueCodingProbes: [String] = ["c.value(forKey: k)", "c.setValue(v, forKeyPath: k)", "c.mutableArrayValue(forKey: k)",
                                                 "NSExpression(format: f)", "NSPredicate(format: f)",
                                                 "NSSortDescriptor(key: k, ascending: true)", "c.removeObserver(o, forKeyPath: k)",
                                                 "#keyPath(C.p)", "c.addObserver(o, forKeyPath: k, context: nil)"]

    /// The alert lane's three pinned lines: the subscription's predicate, and
    /// the fetch query's predicate and sort descriptor.
    static let subscriptionPredicate: String = "predicate: NSPredicate(value: true),"
    static let queryLine: String = "let query = CKQuery(recordType: AlertWire.recordType, predicate: NSPredicate(value: true))"
    static let sortLine: String = "query.sortDescriptors = [NSSortDescriptor(key: AlertWire.Field.firedAt.rawValue, ascending: false)]"
    static let predicateSites: [String: Int] = CloudKitStructureTests.appSites([
        "Live/CloudKitAlertSource.swift": [subscriptionPredicate: 1, queryLine: 1],
    ])
    static let sortDescriptorSites: [String: Int] = CloudKitStructureTests.appSites([
        "Live/CloudKitAlertSource.swift": [sortLine: 1],
    ])
    static let keyValueCodingAppSites: [String: [String: Int]] = [
        predicatePattern: predicateSites,
        sortDescriptorPattern: sortDescriptorSites,
    ]
    static let rule: String = "nothing in the app reads, writes, evaluates or observes a property by its name as a string"

    static func keyValueCodingFailures(_ app: [Source]) -> [String] {
        Lookup.siteFailuresInEveryCopy(keyValueCodingBans, in: Lookup.scanCopies(app), allowed: keyValueCodingAppSites, rule: rule)
    }

    /// The Mac's R-C canaries, on the phone: S5, verbatim (a container built
    /// and read by name, in Settings); the S-PAIR-B review's B2 by key-value
    /// coding (a reuse window set on a context by a split key, which the
    /// policy lock's word, `SigningKeyStructureTests`, cannot see — the
    /// gap); a read by name from a third file and from a fixture; N8's
    /// evaluator; a property set by name; an observer by key path and a
    /// notification observer (the phone has none); and each pinned door
    /// widened — a third predicate, a pinned line changed, a second sort
    /// descriptor on the pinned line, the pinned line in another file. Each
    /// is caught; the CloudKit file's own setter ban misses every one (the
    /// gap).
    @Test func keyValueCodingIsBannedAppWide() throws {
        let app: [Source] = try Lookup.app()
        #expect(Self.keyValueCodingFailures(app).isEmpty, "\(Self.keyValueCodingFailures(app))")
        let pinned: Int = Self.predicateSites.count + Self.sortDescriptorSites.count
        #expect(pinned == 3, "vacuity: two predicate lines and one sort line are pinned")
        let ck: String = Self.cloudKitFile
        let file: String = app.first { $0.path == ck }?.text ?? ""
        let pinnedLines: [String] = [Self.subscriptionPredicate, Self.queryLine, Self.sortLine]
        for line in pinnedLines {
            #expect(file.contains(line), "vacuity: '\(line)' is in the scan")
        }
        let reuseByKey: String = "\nfunc zz(_ c: NSObject) { c.setValue(300, forKey: \"touchIDAuthenticationAllowable\" + \"ReuseDuration\") }\n"
        let readByName: String = "\nfunc zzReadByName(_ o: NSObject) -> NSObject? {\n    o.value(forKey: \"private\" + \"CloudDatabase\") as? NSObject\n}\n"
        let fixtureRead: String = "\nfunc zz(_ o: AnyObject) -> Any? { o.value(forKey: \"zz\") }\n"
        let evaluator: String = "\nfunc zz(_ c: Any) -> Any? { NSExpression(forKeyPath: \"zz\").expressionValue(with: c, context: nil) }\n"
        let setByName: String = "\nfunc zz(_ o: NSObject) { o.setValue(nil, forKey: \"zz\") }\n"
        let keyPathObserver: String = "\nfunc zz(_ o: NSObject, _ c: NSObject) { c.addObserver(o, forKeyPath: \"zz\", options: [], context: nil) }\n"
        let notificationObserver: String = "\nlet zz = NotificationCenter.default.addObserver(forName: nil, object: nil, queue: nil) { _ in }\n"
        let thirdPredicate: String = "\nlet zz = NSPredicate(format: \"zz == 1\")\n"
        let changedPredicate: String = "predicate: NSPredicate(format: \"TRUEPREDICATE\"),"
        let secondSort: String = "ascending: false), NSSortDescriptor(key: \"zz\", ascending: true)]"
        let queryElsewhere: String = "\n        " + Self.queryLine + "\n"
        let reuseMutant: [Source] = Lookup.appended(app, Lookup.inboxFile, reuseByKey)
        let mutants: [(String, [Source])] = [
            ("S5: a container built and read by name, in Settings", Lookup.appended(app, Lookup.settingsFile, Lookup.s5)),
            ("B2 by key-value coding: a reuse window set by a split key, in the inbox", reuseMutant),
            ("a property read by name from a third file", Lookup.appended(app, Lookup.feedFile, readByName)),
            ("a read by name in a fixture", Lookup.appended(app, Lookup.fixtureFile, fixtureRead)),
            ("N8's evaluator, in the keyring's file", Lookup.appended(app, Self.keyringFile, evaluator)),
            ("a property set by name, in a screen", Lookup.appended(app, Lookup.screenFile, setByName)),
            ("an observer by key path", Lookup.appended(app, Self.pairingFile, keyPathObserver)),
            ("a notification observer, in the app delegate", Lookup.appended(app, Lookup.delegateFile, notificationObserver)),
            ("a third predicate, in the CloudKit file", Lookup.appended(app, ck, thirdPredicate)),
            ("the subscription's predicate changed", Lookup.mutate(app, ck) {
                $0.replacingOccurrences(of: Self.subscriptionPredicate, with: changedPredicate) }),
            ("a second sort descriptor on the pinned line", Lookup.mutate(app, ck) {
                $0.replacingOccurrences(of: "ascending: false)]", with: secondSort) }),
            ("the query's pinned line in another file", Lookup.appended(app, Lookup.feedFile, queryElsewhere)),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.keyValueCodingFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
            // The CloudKit file's own setter ban never reads another file: the gap.
            let ckText: String = mutant.first { $0.path == ck }?.text ?? ""
            #expect(RecordPathStructureTests.decisionSchemaFailures(ckText).isEmpty, "canary '\(name)': the CloudKit file's own ban fired")
        }
        // B2's split key passes the policy lock, which reads for its word.
        #expect(SigningKeyStructureTests.policyFailures(reuseMutant).isEmpty, "a split reuse key is the policy lock's gap")
        // Each ban bites, through the app-wide engine, planted in the inbox.
        #expect(Self.keyValueCodingProbes.count == Self.keyValueCodingBans.count)
        for (pattern, probe) in zip(Self.keyValueCodingBans, Self.keyValueCodingProbes) {
            let line: String = "\nlet zz = " + probe
            let mutant: [Source] = Lookup.appended(app, Lookup.inboxFile, line)
            let caught: [String] = Lookup.siteFailuresInEveryCopy([pattern], in: Lookup.scanCopies(mutant), allowed: Self.keyValueCodingAppSites,
                                                                  rule: Self.rule)
            #expect(!caught.isEmpty, "'\(pattern)' did not bite '\(probe)'")
        }
        // Every spelling, through the lock's engine in every scan copy (the
        // backticked one in the backtick-stripped copy, the comment-split one
        // in the cleaned copy).
        let spellings: [String] = ["c.value(forKeyPath: k)", "c.value (forUndefinedKey: k)", "c.`value`(forKey: k)",
                                   "c.value/* x */(forKey: k)", "c.setValuesForKeys(d)", "c.setNilValueForKey(k)",
                                   "c.mutableOrderedSetValue(forKey: k)", "c.dictionaryWithValues(forKeys: k)"]
        for spelling in spellings {
            let one: [Source] = [("zz.swift", spelling)]
            #expect(!Lookup.siteFailuresInEveryCopy(Self.keyValueCodingBans, in: Lookup.scanCopies(one), rule: Self.rule).isEmpty,
                    "'\(spelling)' was NOT caught")
        }
        let rawOnly: [[Source]] = [[("zz.swift", "c.`value`(forKey: k)\nc.value/* x */(forKey: k)")]]
        #expect(Lookup.siteFailuresInEveryCopy(Self.keyValueCodingBans, in: rawOnly, rule: Self.rule).isEmpty,
                "vacuity: those two spellings need the cleaned copies")
        // Over-match controls: words that only contain the banned ones; the
        // phone's look-alikes — defaults read and written by key, a record's
        // fields by subscript, Swift key paths, a notification publisher, the
        // query's `predicate:` label and `sortDescriptors`; and a whole-line
        // comment naming the bans (the lock's own stripping removes it).
        let near: [String] = [
            "\nlet zzSettings = 1, values = 2, valueForKeyCount = 3, resetValue = 4, addObserverCount = 5, keyPathName = 6",
            "\nlet zzNSPredicates = 7, sortDescriptor = 8, forKeyPaths = 9, zzNSExpression = 10, isSetValue = 11",
            "\nfunc zz(_ d: UserDefaults, _ k: String) -> Bool { d.set(1, forKey: k); return d.bool(forKey: k) && d.object(forKey: k) != nil }",
            "\nfunc zz(_ r: CKRecord, _ v: CKRecordValue) { r[\"zz\"] = v; r.encryptedValues[\"zz\"] = v }",
            "\nlet zzPath: KeyPath<PhoneAlert, String> = \\.body\nfunc zz(_ a: [PhoneAlert]) -> [String] { a.map(\\.body) + a.map { $0[keyPath: zzPath] } }",
            "\nlet zzActive = NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)",
            "\nlet zzQuery = CKQuery(recordType: \"zz\", predicate: p)\nlet sortDescriptors = 12, predicate = 13",
            "\n/// never value(forKey:), never setValue(_:forKey:), never addObserver(_:forKeyPath:), never NSPredicate(format:)",
        ]
        #expect(Self.keyValueCodingFailures(Lookup.appended(app, Lookup.inboxFile, near.joined())).isEmpty)
    }
}
