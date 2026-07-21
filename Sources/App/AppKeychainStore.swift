import Foundation
import Security

enum AppKeychainStore {
    #if DEBUG
    // Dev builds are ad-hoc signed with a different code signature on every
    // rebuild. Keychain item ACLs are tied to the creator's signature, so a
    // dev build reading a real item triggers the keychain password prompt —
    // and because save() recreates items, a dev-build WRITE re-owns the item
    // under the throwaway dev signature, making the release app prompt on its
    // next launch too. Back the store with UserDefaults in DEBUG so dev builds
    // never touch (or poison) the real keychain items.

    private static func defaultsKey(_ key: String, service: String) -> String {
        "debugKeychainStore.\(service).\(key)"
    }

    static func save(key: String, value: String, service: String = Constants.bundleIdentifier) {
        UserDefaults.standard.set(value, forKey: defaultsKey(key, service: service))
    }

    static func load(key: String, service: String = Constants.bundleIdentifier) -> String? {
        UserDefaults.standard.string(forKey: defaultsKey(key, service: service))
    }

    static func delete(key: String, service: String = Constants.bundleIdentifier) {
        UserDefaults.standard.removeObject(forKey: defaultsKey(key, service: service))
    }
    #else
    static func save(key: String, value: String, service: String = Constants.bundleIdentifier) {
        guard let data = value.data(using: .utf8) else { return }

        delete(key: key, service: service)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service,
            kSecValueData as String: data,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("[Keychain] Save failed for \(key): \(status)")
        }
    }

    static func load(key: String, service: String = Constants.bundleIdentifier) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String, service: String = Constants.bundleIdentifier) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service,
        ]

        SecItemDelete(query as CFDictionary)
    }
    #endif
}
