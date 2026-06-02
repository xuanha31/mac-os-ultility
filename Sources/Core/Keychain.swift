import Foundation
import Security

/// Wrapper Keychain dùng chung cho mọi module cần lưu bí mật
/// (DB credential, SSH passphrase, Git PAT...). Không bao giờ lưu plaintext ra đĩa.
public struct Keychain {
    public let service: String

    public init(service: String = "com.macutil.app") {
        self.service = service
    }

    public enum KeychainError: Error, CustomStringConvertible {
        case unexpectedStatus(OSStatus)

        public var description: String {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
                return "Keychain error \(status): \(message)"
            }
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// Lưu (ghi đè nếu đã tồn tại).
    public func set(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        var query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary) // xoá cũ trước để ghi đè
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    /// Đọc giá trị; trả `nil` nếu không có.
    public func get(_ account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.unexpectedStatus(status)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Xoá; không lỗi nếu vốn không tồn tại.
    public func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
