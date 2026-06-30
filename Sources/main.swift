import Foundation
import Security

// mytokens — Slice 0: signed-app entitlement gate.
// `selftest` proves the data-protection (iCloud) keychain is reachable from this
// signed binary when invoked directly via the PATH symlink (ADR-0001, ADR-0003).
// An unsigned binary gets errSecMissingEntitlement (-34018); this must exit 0.

func msg(_ status: OSStatus) -> String {
    SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "status \(status)"
}

/// Add → read-back → delete a synchronizable item in our own access group.
/// Returns 0 on a clean round-trip, 1 otherwise.
func selftest() -> Int32 {
    let service = "mytokens.selftest"
    let account = "selftest"
    let payload = "SELFTEST-OK".data(using: .utf8)!

    func base() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,   // -> iCloud Keychain
            kSecUseDataProtectionKeychain as String: true,       // -> data-protection keychain
        ]
    }

    SecItemDelete(base() as CFDictionary)  // clear any leftover from a prior run

    var addQuery = base()
    addQuery[kSecValueData as String] = payload
    let added = SecItemAdd(addQuery as CFDictionary, nil)
    print("ADD   \(added)  \(msg(added))")
    if added != errSecSuccess { return 1 }

    var readQuery = base()
    readQuery[kSecReturnData as String] = true
    var out: CFTypeRef?
    let read = SecItemCopyMatching(readQuery as CFDictionary, &out)
    let matched = (out as? Data) == payload
    print("READ  \(read)  match=\(matched)  \(msg(read))")

    let deleted = SecItemDelete(base() as CFDictionary)
    print("DEL   \(deleted)  \(msg(deleted))")

    let ok = added == errSecSuccess && read == errSecSuccess && matched && deleted == errSecSuccess
    print(ok ? "SELFTEST PASS" : "SELFTEST FAIL")
    return ok ? 0 : 1
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "selftest":
    exit(selftest())
default:
    FileHandle.standardError.write(Data("usage: mytokens selftest\n".utf8))
    exit(64)
}
