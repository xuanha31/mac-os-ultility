import Foundation
import Core

// DB-10: Model connection profile + lưu credential vào Keychain.

public enum DatabaseType: String, CaseIterable, Identifiable, Sendable, Codable {
    case mysql  = "MySQL"
    case redis  = "Redis"
    case oracle = "Oracle"
    public var id: String { rawValue }

    public var defaultPort: Int {
        switch self { case .mysql: 3306; case .redis: 6379; case .oracle: 1521 }
    }
}

/// Thông tin kết nối database (không chứa password — lưu Keychain riêng).
public struct ConnectionProfile: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var type: DatabaseType
    public var host: String
    public var port: Int
    public var username: String
    public var database: String  // schema name / service name (Oracle) / db index (Redis)

    public init(
        id: UUID = UUID(),
        name: String = "",
        type: DatabaseType = .mysql,
        host: String = "localhost",
        port: Int? = nil,
        username: String = "",
        database: String = ""
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.host = host
        self.port = port ?? type.defaultPort
        self.username = username
        self.database = database
    }

    /// Khóa Keychain để lưu password của profile này.
    var keychainAccount: String { "db-\(id.uuidString)" }
}

/// Lưu/đọc danh sách profile (metadata) + password trong Keychain.
public final class ProfileStore: @unchecked Sendable {
    private let keychain = Keychain(service: "com.macutil.db")
    private let metaKey = "profiles-list"

    public init() {}

    public func loadProfiles() -> [ConnectionProfile] {
        guard let json = (try? keychain.get(metaKey)).flatMap({ $0 }),
              let data = json.data(using: .utf8),
              let profiles = try? JSONDecoder().decode([ConnectionProfile].self, from: data) else {
            return []
        }
        return profiles
    }

    public func saveProfiles(_ profiles: [ConnectionProfile]) {
        guard let data = try? JSONEncoder().encode(profiles),
              let json = String(data: data, encoding: .utf8) else { return }
        try? keychain.set(json, for: metaKey)
    }

    public func password(for profile: ConnectionProfile) -> String? {
        try? keychain.get(profile.keychainAccount) ?? nil
    }

    public func setPassword(_ password: String, for profile: ConnectionProfile) throws {
        try keychain.set(password, for: profile.keychainAccount)
    }

    public func deletePassword(for profile: ConnectionProfile) {
        try? keychain.delete(profile.keychainAccount)
    }
}
