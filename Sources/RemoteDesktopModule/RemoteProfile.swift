import Foundation
import Core

// RD-01: Model RemoteProfile (VNC/RDP) + lưu/đọc credential từ Keychain.
// Mô phỏng SSHProfile/SSHProfileStore (Sources/SSHModule/SSHProfile.swift).

public enum RemoteKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case vnc = "VNC"
    case rdp = "RDP"
    public var id: String { rawValue }
    public var defaultPort: Int { self == .vnc ? 5900 : 3389 }
}

/// Cấu hình một host remote (VNC/RDP). Secret lưu Keychain, không lưu ra file.
public struct RemoteProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: RemoteKind
    public var host: String
    public var port: Int
    /// RDP cần username; VNC thường để trống (hoặc auth Apple Remote Desktop).
    public var username: String
    public var group: String

    public init(
        id: UUID = UUID(),
        name: String = "",
        kind: RemoteKind = .vnc,
        host: String = "",
        port: Int = 5900,
        username: String = "",
        group: String = ""
    ) {
        self.id = id; self.name = name; self.kind = kind; self.host = host
        self.port = port; self.username = username; self.group = group
    }

    public var displayName: String {
        name.isEmpty ? "\(kind.rawValue) · \(host.isEmpty ? "?" : host)" : name
    }

    var passwordKey: String { "remote-pwd-\(id)" }
}

/// Lưu danh sách profile + secret trong Keychain (service riêng cho remote).
public final class RemoteProfileStore: @unchecked Sendable {
    private let keychain = Keychain(service: "com.macutil.remote")
    private let listKey = "remote-profiles"

    public init() {}

    public func load() -> [RemoteProfile] {
        guard let json = (try? keychain.get(listKey)).flatMap({ $0 }),
              let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([RemoteProfile].self, from: data) else { return [] }
        return list
    }

    public func save(_ profiles: [RemoteProfile]) {
        guard let data = try? JSONEncoder().encode(profiles),
              let json = String(data: data, encoding: .utf8) else { return }
        try? keychain.set(json, for: listKey)
    }

    public func password(for p: RemoteProfile) -> String? { try? keychain.get(p.passwordKey) ?? nil }

    public func setPassword(_ v: String, for p: RemoteProfile) throws {
        try keychain.set(v, for: p.passwordKey)
    }

    public func deleteSecrets(for p: RemoteProfile) {
        try? keychain.delete(p.passwordKey)
    }
}
