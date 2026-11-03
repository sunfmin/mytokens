import XCTest
import Security

/// An in-memory keychain behind the `Keychain` seam, so the real `KeychainSecretStore`
/// query logic runs without a signed Helper. It plays the parts of SecItem that matter
/// here: attribute matching, update-all-matching, the system default accessibility
/// for a data-protection item written without one, and a locked screen.
final class InMemoryKeychain: Keychain {
    private(set) var items: [[String: Any]] = []
    /// The screen is locked (after first unlock since boot): items only readable
    /// while unlocked refuse every operation, as `errSecInteractionNotAllowed`.
    var screenLocked = false

    /// Query keys that steer the call rather than name an attribute to match.
    private static let control: Set<String> = [
        kSecMatchLimit as String, kSecReturnData as String, kSecReturnAttributes as String,
        kSecUseDataProtectionKeychain as String,
    ]

    private func matches(_ item: [String: Any], _ query: [String: Any]) -> Bool {
        query.allSatisfy { k, v in
            Self.control.contains(k) || (item[k].map { ($0 as AnyObject).isEqual(v) } ?? false)
        }
    }

    private func locked(_ item: [String: Any]) -> Bool {
        screenLocked && (item[kSecAttrAccessible as String] as AnyObject?)?.isEqual(kSecAttrAccessibleWhenUnlocked) == true
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        var item = attributes.filter { !Self.control.contains($0.key) }
        if (attributes[kSecUseDataProtectionKeychain as String] as? Bool) == true,
           item[kSecAttrAccessible as String] == nil {
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked   // the system default
        }
        if items.contains(where: { matches($0, [kSecAttrService as String: item[kSecAttrService as String] as Any,
                                               kSecAttrAccount as String: item[kSecAttrAccount as String] as Any]) }) {
            return errSecDuplicateItem
        }
        items.append(item)
        return errSecSuccess
    }

    func update(_ query: [String: Any], _ changes: [String: Any]) -> OSStatus {
        let hits = items.indices.filter { matches(items[$0], query) }
        if hits.isEmpty { return errSecItemNotFound }
        if hits.contains(where: { locked(items[$0]) }) { return errSecInteractionNotAllowed }
        for i in hits { items[i].merge(changes) { _, new in new } }
        return errSecSuccess
    }

    func copyMatching(_ query: [String: Any], _ result: inout CFTypeRef?) -> OSStatus {
        let hits = items.filter { matches($0, query) }
        if hits.isEmpty { return errSecItemNotFound }
        if hits.contains(where: locked) { return errSecInteractionNotAllowed }
        let all = (query[kSecMatchLimit as String] as AnyObject?)?.isEqual(kSecMatchLimitAll) == true
        result = (all ? hits as NSArray : hits[0] as NSDictionary) as CFTypeRef
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        let before = items.count
        items.removeAll { matches($0, query) }
        return items.count == before ? errSecItemNotFound : errSecSuccess
    }

    func accessibility(service: String) -> String? {
        items.first { ($0[kSecAttrService as String] as? String) == service }?[kSecAttrAccessible as String] as? String
    }
}

/// A personal Mac's Secret is readable while the screen is locked, once the Mac has
/// been unlocked since boot (ADR-0011); a Server's login keychain is unchanged (ADR-0010).
final class KeychainAccessibilityTests: XCTestCase {
    private let afterFirstUnlock = kSecAttrAccessibleAfterFirstUnlock as String
    private let whenUnlocked = kSecAttrAccessibleWhenUnlocked as String

    /// Write a Secret as a build from before ADR-0011 did: no accessibility set, so it
    /// takes the system default, readable only while unlocked.
    private func storeAsOldBuild(_ keychain: InMemoryKeychain, service: String) {
        _ = keychain.add([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccessGroup as String: "HL27PWAKDF.com.sunfmin.mytokens",
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "default",
            kSecValueData as String: Data("old-tok".utf8),
            kSecAttrComment as String: #"{"kind":"static","meta":null}"#,
            kSecAttrLabel as String: "mytokens: \(service)/default",
        ])
    }

    func testAStoredSecretIsWrittenReadableAfterFirstUnlockAndSynchronizable() throws {
        let keychain = InMemoryKeychain()
        let store = KeychainSecretStore.opened(.iCloud, keychain: keychain)
        try store.upsert(service: "gh", account: "default", secret: SecretValue(single: "tok"),
                         kind: "static", meta: nil, description: nil, level: .personal, pushed: false)
        XCTAssertEqual(keychain.accessibility(service: "gh"), afterFirstUnlock)
        XCTAssertEqual(keychain.items.first?[kSecAttrSynchronizable as String] as? Bool, true)

        keychain.screenLocked = true
        XCTAssertEqual(try store.get(service: "gh", account: "default")?.loneValue, "tok")
    }

    func testRewritingAnOldItemMovesItToo() throws {
        let keychain = InMemoryKeychain()
        storeAsOldBuild(keychain, service: "gh")
        let store = KeychainSecretStore(location: .iCloud, keychain: keychain)   // no migration run
        try store.upsert(service: "gh", account: "default", secret: SecretValue(single: "new"),
                         kind: "static", meta: nil, description: nil, level: .personal, pushed: false)
        XCTAssertEqual(keychain.accessibility(service: "gh"), afterFirstUnlock)
    }

    func testAnOldDefaultItemIsMigratedWhenTheStoreOpensUnlocked() throws {
        let keychain = InMemoryKeychain()
        storeAsOldBuild(keychain, service: "gh")
        storeAsOldBuild(keychain, service: "cf")

        // Before: with the screen locked, the old item can't be read.
        keychain.screenLocked = true
        XCTAssertThrowsError(try KeychainSecretStore(location: .iCloud, keychain: keychain)
            .get(service: "gh", account: "default")) { XCTAssertTrue("\($0)".contains("locked")) }

        // Opening the store while locked moves nothing and breaks nothing.
        let lockedOpen = KeychainSecretStore.opened(.iCloud, keychain: keychain)
        XCTAssertEqual(lockedOpen.migrateAccessibility(), errSecInteractionNotAllowed)
        XCTAssertEqual(keychain.accessibility(service: "gh"), whenUnlocked)

        // The next run on an unlocked Mac moves every old item, values untouched, ...
        keychain.screenLocked = false
        _ = KeychainSecretStore.opened(.iCloud, keychain: keychain)
        XCTAssertEqual(keychain.accessibility(service: "gh"), afterFirstUnlock)
        XCTAssertEqual(keychain.accessibility(service: "cf"), afterFirstUnlock)

        // ... a second run changes nothing, ...
        let snapshot = keychain.items.map { NSDictionary(dictionary: $0) }
        let again = KeychainSecretStore.opened(.iCloud, keychain: keychain)
        XCTAssertEqual(again.migrateAccessibility(), errSecItemNotFound)
        XCTAssertEqual(keychain.items.map { NSDictionary(dictionary: $0) }, snapshot)

        // ... and now the Secret is readable with the screen locked.
        keychain.screenLocked = true
        XCTAssertEqual(try again.get(service: "gh", account: "default")?.loneValue, "old-tok")
        XCTAssertEqual(try again.list().map(\.service).sorted(), ["cf", "gh"])
    }

    func testTheServerLoginKeychainIsUnchanged() throws {
        let keychain = InMemoryKeychain()
        let store = KeychainSecretStore.opened(.login, keychain: keychain)
        XCTAssertEqual(store.migrateAccessibility(), errSecItemNotFound)   // nothing to move
        try store.upsert(service: "gh", account: "default", secret: SecretValue(single: "tok"),
                         kind: "static", meta: nil, description: nil, level: .server, pushed: false)
        XCTAssertNil(keychain.accessibility(service: "gh"))
        XCTAssertEqual(try store.get(service: "gh", account: "default")?.loneValue, "tok")
    }
}
