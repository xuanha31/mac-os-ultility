import Foundation
import Core

/// Lưu/đọc PAT cho GitHub & GitLab qua Keychain; tạo provider tương ứng.
public struct GitCredentials {
    private let keychain: Keychain

    public init(keychain: Keychain = Keychain(service: "com.macutil.git")) {
        self.keychain = keychain
    }

    private func account(for kind: GitHostKind) -> String { "pat-\(kind.rawValue)" }

    public func token(for kind: GitHostKind) -> String? {
        (try? keychain.get(account(for: kind))).flatMap { $0 }
    }

    public func setToken(_ token: String, for kind: GitHostKind) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try keychain.delete(account(for: kind))
        } else {
            try keychain.set(trimmed, for: account(for: kind))
        }
    }

    /// Tạo provider phù hợp với host; nil nếu chưa có token hoặc host không hỗ trợ.
    public func provider(for ref: RemoteRef) -> GitHostProvider? {
        guard let token = token(for: ref.kind), !token.isEmpty else { return nil }
        switch ref.kind {
        case .github: return GitHubProvider(token: token)
        case .gitlab: return GitLabProvider(token: token)
        case .unknown: return nil
        }
    }
}
