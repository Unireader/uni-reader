import Foundation
import Security

/// 极简 Keychain 封装（generic password）：API key 这类本机密钥的唯一下落。
/// 不落 UserDefaults（plist 明文，备份/同步会带走），更不进工作区共享文件夹。
/// 零第三方依赖，直接 Security 框架；非沙盒 App，无需 keychain-access-group entitlement。
enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "UniReader"

    static func read(_ account: String) -> String? {
        let q = query(account)
        var item: CFTypeRef?
        var qret = q
        qret[kSecReturnData as String] = true
        qret[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(qret as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 写密钥（存在即更新）；空串 = 删除（设置页清空输入框 = 不要这个 key 了）。
    static func write(_ account: String, _ value: String) {
        if value.isEmpty { delete(account); return }
        let data = Data(value.utf8)
        let q = query(account)
        let attrs = [kSecValueData as String: data]
        if SecItemUpdate(q as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
