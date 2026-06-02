import Foundation

/// Phân giải origin URL → RemoteRef (host + path + loại nền tảng).
/// Hỗ trợ dạng SSH (`git@host:path.git`) và HTTPS (`https://host/path.git`).
public enum RepoCorrelator {

    public static func parse(remoteURL raw: String) -> RemoteRef? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let (host, path) = splitHostPath(trimmed)
        guard let host, let path, !path.isEmpty else { return nil }

        let cleanPath = path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: ".git", with: "")

        return RemoteRef(kind: kind(forHost: host), host: host, fullPath: cleanPath)
    }

    private static func kind(forHost host: String) -> GitHostKind {
        let lower = host.lowercased()
        if lower.contains("github") { return .github }
        if lower.contains("gitlab") { return .gitlab }
        return .unknown
    }

    /// Tách (host, path) từ các dạng URL git phổ biến.
    private static func splitHostPath(_ url: String) -> (String?, String?) {
        // SSH dạng scp: git@host:owner/repo.git
        if !url.contains("://"), let atRange = url.range(of: "@"), let colonRange = url.range(of: ":") {
            let host = String(url[atRange.upperBound..<colonRange.lowerBound])
            let path = String(url[colonRange.upperBound...])
            return (host, path)
        }
        // URL có scheme: https://host/path  hoặc  ssh://git@host/path
        if let comps = URLComponents(string: url), let host = comps.host {
            return (host, comps.path)
        }
        return (nil, nil)
    }
}
