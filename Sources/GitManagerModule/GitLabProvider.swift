import Foundation

/// Provider GitLab — Merge Request. Token PAT scope `api`.
public struct GitLabProvider: GitHostProvider {
    private let token: String
    private let http = HTTPClient()

    public init(token: String) { self.token = token }

    private func headers() -> [String: String] {
        ["PRIVATE-TOKEN": token]
    }

    /// Project id = path đầy đủ URL-encoded ("group/sub/repo" → "group%2Fsub%2Frepo").
    private func encodedProject(_ ref: RemoteRef) -> String {
        ref.fullPath.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ref.fullPath
    }

    // MARK: DTOs
    private struct MergeDTO: Decodable {
        let iid: Int
        let title: String
        let web_url: String
        let author: Author
        let source_branch: String
        let target_branch: String
        let merge_status: String?
        let pipeline: Pipeline?
        struct Author: Decodable { let username: String }
        struct Pipeline: Decodable { let status: String? }
    }
    private struct ProjectDTO: Decodable {
        let merge_method: String?
    }

    // MARK: GitHostProvider
    public func listMergeRequests(_ ref: RemoteRef) async throws -> [MergeRequest] {
        guard let base = ref.apiBaseURL,
              let url = URL(string: "\(base.absoluteString)/projects/\(encodedProject(ref))/merge_requests?state=opened&per_page=50") else {
            throw GitHostError.noAPIBase
        }
        let mrs = try await http.getJSON([MergeDTO].self, url: url, headers: headers())
        return mrs.map { mr in
            MergeRequest(
                id: mr.iid,
                title: mr.title,
                author: mr.author.username,
                sourceBranch: mr.source_branch,
                targetBranch: mr.target_branch,
                webURL: mr.web_url,
                ciStatus: ciStatus(from: mr.pipeline?.status),
                mergeable: mr.merge_status.map { $0 == "can_be_merged" }
            )
        }
    }

    private func ciStatus(from raw: String?) -> CIStatus {
        switch raw {
        case "success": return .success
        case "failed", "canceled": return .failed
        case "running", "pending", "created", "scheduled": return .pending
        default: return .unknown
        }
    }

    public func allowedMergeMethods(_ ref: RemoteRef) async throws -> [MergeMethod] {
        guard let base = ref.apiBaseURL,
              let url = URL(string: "\(base.absoluteString)/projects/\(encodedProject(ref))") else {
            throw GitHostError.noAPIBase
        }
        let project = try await http.getJSON(ProjectDTO.self, url: url, headers: headers())
        // GitLab merge_method: "merge" | "rebase_merge" | "ff". Squash luôn khả dụng qua param.
        var methods: [MergeMethod] = [.merge, .squash]
        if project.merge_method == "rebase_merge" { methods.append(.rebase) }
        return methods
    }

    public func merge(_ mr: MergeRequest, in ref: RemoteRef, method: MergeMethod) async throws {
        guard let base = ref.apiBaseURL,
              let url = URL(string: "\(base.absoluteString)/projects/\(encodedProject(ref))/merge_requests/\(mr.id)/merge") else {
            throw GitHostError.noAPIBase
        }
        let body = try JSONSerialization.data(withJSONObject: ["squash": method == .squash])
        var hdrs = headers()
        hdrs["Content-Type"] = "application/json"
        _ = try await http.request(url, method: "PUT", headers: hdrs, body: body)
    }
}
