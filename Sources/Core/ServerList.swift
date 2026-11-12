import Foundation
import Security

// The Server list (ADR-0014): the hosts `server add` set up, kept on the personal Macs. One
// synchronizable item in mytokens' access group, so iCloud Keychain sync gives every personal
// Mac the same list. It is not a Secret: its label lacks the Secrets' prefix, so `list`, Sync
// and `get --unpushed` never see it, and it holds host names only — nothing secret.

/// The personal Macs' one list of Servers. Tests use an in-memory fake.
protocol ServerList {
    func read() throws -> [String]          // sorted, no duplicates; empty when never written
    func write(_ hosts: [String]) throws
}

/// The service and account the Server list item is stored under. A Secret cannot take them:
/// `put` and `rm` refuse the service.
let serverListService = "mytokens.server-list"
private let serverListAccount = "hosts"
private let serverListLabel = "mytokens server list"

/// Real list: a generic-password item in the data-protection keychain, synchronizable, under
/// mytokens' access group, readable after first unlock like every Secret (ADR-0011). Its data
/// is a JSON array of host names.
struct KeychainServerList: ServerList {
    var keychain: Keychain = SystemKeychain()

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccessGroup as String: mytokensAccessGroup,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: serverListService,
            kSecAttrAccount as String: serverListAccount,
        ]
    }

    private func mapErr(_ s: OSStatus) -> StoreError { s == errSecInteractionNotAllowed ? .locked : .keychain(s) }

    func read() throws -> [String] {
        var q = query
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        let s = keychain.copyMatching(q, &out)
        if s == errSecItemNotFound { return [] }
        guard s == errSecSuccess else { throw mapErr(s) }
        let data = (out as? Data) ?? ((out as? [String: Any])?[kSecValueData as String] as? Data)
        guard let data, let hosts = try? JSONDecoder().decode([String].self, from: data) else { throw StoreError.encoding }
        return Array(Set(hosts)).sorted()
    }

    func write(_ hosts: [String]) throws {
        let data = try JSONEncoder().encode(Array(Set(hosts)).sorted())
        let changes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: serverListLabel,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updated = keychain.update(query, changes)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw mapErr(updated) }
        let added = keychain.add(query.merging(changes) { _, new in new })
        guard added == errSecSuccess else { throw mapErr(added) }
    }
}
