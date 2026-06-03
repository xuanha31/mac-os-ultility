import Foundation
import Core

// SSH-01: Model SSHProfile + lưu/đọc credential từ Keychain.

public enum SSHAuthMethod: String, Codable, CaseIterable, Identifiable {
    case password   = "Password"
    case privateKey = "Private Key"
    public var id: String { rawValue }
}

/// Cấu hình một SSH host (không lưu secret trong file — chỉ lưu Keychain).
public struct SSHProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var authMethod: SSHAuthMethod
    /// Đường dẫn file private key (authMethod == .privateKey).
    public var privateKeyPath: String
    /// Tag / nhóm để sắp xếp (tùy chọn).
    public var group: String

    public init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        port: Int = 22,
        username: String = "",
        authMethod: SSHAuthMethod = .password,
        privateKeyPath: String = "",
        group: String = ""
    ) {
        self.id = id; self.name = name; self.host = host; self.port = port
        self.username = username; self.authMethod = authMethod
        self.privateKeyPath = privateKeyPath; self.group = group
    }

    public var displayName: String { name.isEmpty ? "\(username)@\(host)" : name }

    // Keychain keys
    var passwordKey: String    { "ssh-pwd-\(id)" }
    var passphraseKey: String  { "ssh-pp-\(id)" }
    var knownHostKey: String   { "ssh-kh-\(host)" }
}

/// Lưu danh sách profile + secret trong Keychain.
public final class SSHProfileStore: @unchecked Sendable {
    private let keychain = Keychain(service: "com.macutil.ssh")
    private let listKey = "profiles"

    public init() {}

    public func load() -> [SSHProfile] {
        guard let json = (try? keychain.get(listKey)).flatMap({ $0 }),
              let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([SSHProfile].self, from: data) else { return [] }
        return list
    }

    public func save(_ profiles: [SSHProfile]) {
        guard let data = try? JSONEncoder().encode(profiles),
              let json = String(data: data, encoding: .utf8) else { return }
        try? keychain.set(json, for: listKey)
    }

    public func password(for p: SSHProfile) -> String?   { try? keychain.get(p.passwordKey) ?? nil }
    public func passphrase(for p: SSHProfile) -> String? { try? keychain.get(p.passphraseKey) ?? nil }
    public func knownHostKey(for host: String, port: Int) -> String? {
        try? keychain.get("ssh-kh-\(host):\(port)") ?? nil
    }

    public func setPassword(_ v: String, for p: SSHProfile) throws {
        try keychain.set(v, for: p.passwordKey)
    }
    public func setPassphrase(_ v: String, for p: SSHProfile) throws {
        try keychain.set(v, for: p.passphraseKey)
    }
    public func storeKnownHostKey(_ key: String, host: String, port: Int) throws {
        try keychain.set(key, for: "ssh-kh-\(host):\(port)")
    }

    public func deleteSecrets(for p: SSHProfile) {
        try? keychain.delete(p.passwordKey)
        try? keychain.delete(p.passphraseKey)
    }
}
