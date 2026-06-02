import Foundation

public enum GitHostKind: String, Codable, Sendable {
    case github
    case gitlab
    case unknown
}

/// Tham chiếu remote đã phân giải từ origin URL.
public struct RemoteRef: Equatable, Sendable {
    public let kind: GitHostKind
    public let host: String
    /// Đường dẫn project đầy đủ, ví dụ "owner/repo" hoặc "group/sub/repo" (GitLab).
    public let fullPath: String

    public init(kind: GitHostKind, host: String, fullPath: String) {
        self.kind = kind
        self.host = host
        self.fullPath = fullPath
    }

    /// owner = phần đầu (GitHub luôn 2 phần); repo = phần cuối.
    public var owner: String { fullPath.split(separator: "/").dropLast().joined(separator: "/") }
    public var repo: String { String(fullPath.split(separator: "/").last ?? "") }

    /// Base URL của REST API theo loại host.
    public var apiBaseURL: URL? {
        switch kind {
        case .github:
            return host == "github.com"
                ? URL(string: "https://api.github.com")
                : URL(string: "https://\(host)/api/v3") // GitHub Enterprise
        case .gitlab:
            return URL(string: "https://\(host)/api/v4")
        case .unknown:
            return nil
        }
    }
}

public struct GitRepoInfo: Identifiable, Equatable, Sendable {
    public var id: URL { localPath }
    public var name: String
    public var localPath: URL
    public var currentBranch: String
    public var ahead: Int
    public var behind: Int
    public var isDirty: Bool
    public var remoteURL: String?
    public var remoteRef: RemoteRef?

    public init(
        name: String,
        localPath: URL,
        currentBranch: String = "",
        ahead: Int = 0,
        behind: Int = 0,
        isDirty: Bool = false,
        remoteURL: String? = nil,
        remoteRef: RemoteRef? = nil
    ) {
        self.name = name
        self.localPath = localPath
        self.currentBranch = currentBranch
        self.ahead = ahead
        self.behind = behind
        self.isDirty = isDirty
        self.remoteURL = remoteURL
        self.remoteRef = remoteRef
    }
}

public enum CIStatus: String, Sendable {
    case success
    case failed
    case pending
    case unknown
}

public enum MergeMethod: String, CaseIterable, Sendable {
    case merge
    case squash
    case rebase
}

/// Merge Request (GitLab) / Pull Request (GitHub) — mô hình chung.
public struct MergeRequest: Identifiable, Equatable, Sendable {
    /// number (GitHub) hoặc iid (GitLab).
    public let id: Int
    public let title: String
    public let author: String
    public let sourceBranch: String
    public let targetBranch: String
    public let webURL: String
    public let ciStatus: CIStatus
    public let mergeable: Bool?

    public init(
        id: Int,
        title: String,
        author: String,
        sourceBranch: String,
        targetBranch: String,
        webURL: String,
        ciStatus: CIStatus,
        mergeable: Bool?
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
        self.webURL = webURL
        self.ciStatus = ciStatus
        self.mergeable = mergeable
    }
}
