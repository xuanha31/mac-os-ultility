import SwiftUI
import UniformTypeIdentifiers
import GitManagerModule

@MainActor
final class GitViewModel: ObservableObject {
    @Published var rootPath: URL?
    @Published var repos: [GitRepoInfo] = []
    @Published var selectedRepoID: URL?
    @Published var mergeRequests: [MergeRequest] = []
    @Published var allowedMethods: [MergeMethod] = MergeMethod.allCases
    @Published var isBusy = false
    @Published var status = ""

    @Published var githubToken = ""
    @Published var gitlabToken = ""

    private let credentials = GitCredentials()

    init() {
        githubToken = credentials.token(for: .github) ?? ""
        gitlabToken = credentials.token(for: .gitlab) ?? ""
    }

    var selectedRepo: GitRepoInfo? {
        repos.first { $0.id == selectedRepoID }
    }

    func saveTokens() {
        do {
            try credentials.setToken(githubToken, for: .github)
            try credentials.setToken(gitlabToken, for: .gitlab)
            status = "Đã lưu token vào Keychain."
        } catch {
            status = "Lỗi lưu token: \(error)"
        }
    }

    func scan(doFetch: Bool) {
        guard let root = rootPath else { status = "Hãy chọn thư mục gốc chứa repo."; return }
        isBusy = true
        status = doFetch ? "Đang quét + fetch…" : "Đang quét…"
        Task {
            let found = await Task.detached { LocalRepoScanner().scan(root: root, doFetch: doFetch) }.value
            self.repos = found
            self.isBusy = false
            self.status = "Tìm thấy \(found.count) repo."
            if let first = found.first { self.select(first) }
        }
    }

    func select(_ repo: GitRepoInfo) {
        selectedRepoID = repo.id
        mergeRequests = []
        loadMergeRequests(for: repo)
    }

    func loadMergeRequests(for repo: GitRepoInfo) {
        guard let ref = repo.remoteRef else {
            status = "Repo không có remote GitHub/GitLab nhận diện được."
            return
        }
        guard let provider = credentials.provider(for: ref) else {
            status = "Chưa có token cho \(ref.kind.rawValue) (host \(ref.host))."
            return
        }
        isBusy = true
        status = "Đang tải MR/PR…"
        Task {
            do {
                async let mrs = provider.listMergeRequests(ref)
                async let methods = provider.allowedMergeMethods(ref)
                self.mergeRequests = try await mrs
                self.allowedMethods = (try? await methods) ?? MergeMethod.allCases
                self.status = "\(self.mergeRequests.count) MR/PR đang mở."
            } catch {
                self.status = "Lỗi tải MR/PR: \(error)"
            }
            self.isBusy = false
        }
    }

    func merge(_ mr: MergeRequest, method: MergeMethod) {
        guard let repo = selectedRepo, let ref = repo.remoteRef,
              let provider = credentials.provider(for: ref) else { return }
        isBusy = true
        status = "Đang merge #\(mr.id)…"
        Task {
            do {
                try await provider.merge(mr, in: ref, method: method)
                self.status = "Đã merge #\(mr.id) (\(method.rawValue))."
                self.loadMergeRequests(for: repo)
            } catch {
                self.status = "Lỗi merge: \(error)"
                self.isBusy = false
            }
        }
    }
}

struct GitView: View {
    @StateObject private var viewModel = GitViewModel()
    @State private var showFolderPicker = false
    @State private var showTokens = false
    @State private var mergeTarget: MergeRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            HStack(alignment: .top, spacing: 16) {
                repoList.frame(width: 280)
                Divider()
                mrList
            }
            if !viewModel.status.isEmpty {
                Text(viewModel.status).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                viewModel.rootPath = url
                viewModel.scan(doFetch: false)
            }
        }
        .sheet(isPresented: $showTokens) { tokensSheet }
        .sheet(item: $mergeTarget) { mr in mergeSheet(mr) }
    }

    private var header: some View {
        HStack {
            Text("Git Manager").font(.largeTitle.bold())
            Spacer()
            if viewModel.isBusy { ProgressView().controlSize(.small) }
            Button("Chọn thư mục…") { showFolderPicker = true }
            Button("Quét") { viewModel.scan(doFetch: false) }.disabled(viewModel.rootPath == nil)
            Button("Quét + Fetch") { viewModel.scan(doFetch: true) }.disabled(viewModel.rootPath == nil)
            Button("Token…") { showTokens = true }
        }
    }

    private var repoList: some View {
        VStack(alignment: .leading) {
            Text("Repositories").font(.headline)
            List(viewModel.repos, selection: $viewModel.selectedRepoID) { repo in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(repo.name).font(.body.bold())
                        if repo.isDirty { Image(systemName: "pencil.circle.fill").foregroundStyle(.orange) }
                    }
                    HStack(spacing: 8) {
                        Label(repo.currentBranch, systemImage: "arrow.triangle.branch").font(.caption)
                        if repo.ahead > 0 { Text("↑\(repo.ahead)").font(.caption) }
                        if repo.behind > 0 { Text("↓\(repo.behind)").font(.caption) }
                    }
                    .foregroundStyle(.secondary)
                    if let ref = repo.remoteRef {
                        Text("\(ref.kind.rawValue) · \(ref.fullPath)").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .tag(repo.id)
                .contentShape(Rectangle())
                .onTapGesture { viewModel.select(repo) }
            }
        }
    }

    private var mrList: some View {
        VStack(alignment: .leading) {
            Text(viewModel.selectedRepo.map { "MR/PR — \($0.name)" } ?? "MR/PR")
                .font(.headline)
            if viewModel.mergeRequests.isEmpty {
                Text("Không có MR/PR đang mở (hoặc chưa tải).")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.mergeRequests) { mr in
                    HStack {
                        ciIcon(mr.ciStatus)
                        VStack(alignment: .leading) {
                            Text("#\(mr.id) \(mr.title)").font(.body.bold()).lineLimit(1)
                            Text("\(mr.sourceBranch) → \(mr.targetBranch) · @\(mr.author)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Merge") { mergeTarget = mr }
                            .disabled(mr.mergeable == false)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ciIcon(_ status: CIStatus) -> some View {
        let (name, color): (String, Color) = {
            switch status {
            case .success: return ("checkmark.circle.fill", .green)
            case .failed:  return ("xmark.circle.fill", .red)
            case .pending: return ("clock.fill", .orange)
            case .unknown: return ("questionmark.circle", .secondary)
            }
        }()
        return Image(systemName: name).foregroundStyle(color)
    }

    private var tokensSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Personal Access Token").font(.title2.bold())
            Text("GitHub cần scope `repo`; GitLab cần scope `api`. Lưu an toàn trong Keychain.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text("GitHub PAT")
                SecureField("ghp_…", text: $viewModel.githubToken)
            }
            VStack(alignment: .leading) {
                Text("GitLab PAT")
                SecureField("glpat-…", text: $viewModel.gitlabToken)
            }
            HStack {
                Spacer()
                Button("Hủy") { showTokens = false }
                Button("Lưu") { viewModel.saveTokens(); showTokens = false }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func mergeSheet(_ mr: MergeRequest) -> some View {
        MergeSheet(
            mr: mr,
            allowedMethods: viewModel.allowedMethods,
            onMerge: { method in
                viewModel.merge(mr, method: method)
                mergeTarget = nil
            },
            onCancel: { mergeTarget = nil }
        )
    }
}

/// Dialog xác nhận merge: hiện branch, CI, conflict + chọn method.
private struct MergeSheet: View {
    let mr: MergeRequest
    let allowedMethods: [MergeMethod]
    let onMerge: (MergeMethod) -> Void
    let onCancel: () -> Void

    @State private var method: MergeMethod = .squash

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Xác nhận Merge #\(mr.id)").font(.title2.bold())
            Text(mr.title).font(.headline)

            Grid(alignment: .leading) {
                GridRow { Text("Nhánh:").foregroundStyle(.secondary); Text("\(mr.sourceBranch) → \(mr.targetBranch)") }
                GridRow { Text("Tác giả:").foregroundStyle(.secondary); Text("@\(mr.author)") }
                GridRow { Text("CI:").foregroundStyle(.secondary); Text(mr.ciStatus.rawValue) }
                GridRow {
                    Text("Có thể merge:").foregroundStyle(.secondary)
                    Text(mr.mergeable == nil ? "?" : (mr.mergeable! ? "Có" : "Không/Conflict"))
                }
            }

            Picker("Kiểu merge", selection: $method) {
                ForEach(allowedMethods, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)

            if mr.ciStatus != .success {
                Label("CI chưa pass — cân nhắc trước khi merge.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Hủy", action: onCancel)
                Button("Merge \(method.rawValue)") { onMerge(method) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            if !allowedMethods.contains(method) { method = allowedMethods.first ?? .merge }
        }
    }
}
