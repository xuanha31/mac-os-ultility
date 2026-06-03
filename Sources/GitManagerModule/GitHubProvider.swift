import Foundation

/// Provider GitHub — Pull Request. Token PAT scope `repo`.
public struct GitHubProvider: GitHostProvider {
    private let token: String
    private let http: HTTPClient

    public init(token: String, etagCache: ETagCache? = ETagCache()) {
        self.token = token
        self.http = HTTPClient(etagCache: etagCache)
    }

    private func headers() -> [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28"
        ]
    }

    // MARK: DTOs
    private struct PullDTO: Decodable {
        let number: Int
        let title: String
        let html_url: String
        let user: User
        let head: Ref
        let base: Ref
        let mergeable: Bool?
        struct User: Decodable { let login: String }
        struct Ref: Decodable { let ref: String; let sha: String }
    }
    private struct CheckRunsDTO: Decodable {
        let check_runs: [Run]
        struct Run: Decodable { let status: String; let conclusion: String? }
    }
    private struct RepoDTO: Decodable {
        let allow_merge_commit: Bool?
        let allow_squash_merge: Bool?
        let allow_rebase_merge: Bool?
    }

    // MARK: GitHostProvider
    public func listMergeRequests(_ ref: RemoteRef) async throws -> [MergeRequest] {
        guard let base = ref.apiBaseURL else { throw GitHostError.noAPIBase }
        guard let url = URL(string: "\(base.absoluteString)/repos/\(ref.fullPath)/pulls?state=open&per_page=50") else {
            throw GitHostError.noAPIBase
        }
        let pulls = try await http.getJSON([PullDTO].self, url: url, headers: headers())

        var result: [MergeRequest] = []
        for pull in pulls {
            let ci = await checkStatus(ref: ref, sha: pull.head.sha)
            result.append(MergeRequest(
                id: pull.number,
                title: pull.title,
                author: pull.user.login,
                sourceBranch: pull.head.ref,
                targetBranch: pull.base.ref,
                webURL: pull.html_url,
                ciStatus: ci,
                mergeable: pull.mergeable
            ))
        }
        return result
    }

    /// CI: gộp các check-run của commit head. Lỗi → unknown.
    private func checkStatus(ref: RemoteRef, sha: String) async -> CIStatus {
        guard let base = ref.apiBaseURL,
              let url = URL(string: "\(base.absoluteString)/repos/\(ref.fullPath)/commits/\(sha)/check-runs") else {
            return .unknown
        }
        guard let dto = try? await http.getJSON(CheckRunsDTO.self, url: url, headers: headers()),
              !dto.check_runs.isEmpty else {
            return .unknown
        }
        if dto.check_runs.contains(where: { $0.status != "completed" }) { return .pending }
        let bad: Set<String> = ["failure", "timed_out", "cancelled", "action_required", "stale"]
        if dto.check_runs.contains(where: { bad.contains($0.conclusion ?? "") }) { return .failed }
        return .success
    }

    public func allowedMergeMethods(_ ref: RemoteRef) async throws -> [MergeMethod] {
        guard let base = ref.apiBaseURL,
              let url = URL(string: "\(base.absoluteString)/repos/\(ref.fullPath)") else {
            throw GitHostError.noAPIBase
        }
        let repo = try await http.getJSON(RepoDTO.self, url: url, headers: headers())
        var methods: [MergeMethod] = []
        if repo.allow_merge_commit ?? true { methods.append(.merge) }
        if repo.allow_squash_merge ?? true { methods.append(.squash) }
        if repo.allow_rebase_merge ?? true { methods.append(.rebase) }
        return methods.isEmpty ? [.merge] : methods
    }

    public func merge(_ mr: MergeRequest, in ref: RemoteRef, method: MergeMethod) async throws {
        guard let base = ref.apiBaseURL,
              let url = URL(string: "\(base.absoluteString)/repos/\(ref.fullPath)/pulls/\(mr.id)/merge") else {
            throw GitHostError.noAPIBase
        }
        let body = try JSONSerialization.data(withJSONObject: ["merge_method": method.rawValue])
        var hdrs = headers()
        hdrs["Content-Type"] = "application/json"
        _ = try await http.request(url, method: "PUT", headers: hdrs, body: body)
    }
}
