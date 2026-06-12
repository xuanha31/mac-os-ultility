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
    @Published var autoScanEnabled = false
    @Published var autoScanIntervalMinutes: Int = 5

    private let credentials = GitCredentials()
    private var autoScanTask: Task<Void, Never>?

    init() {
        githubToken = credentials.token(for: .github) ?? ""
        gitlabToken = credentials.token(for: .gitlab) ?? ""
    }

    deinit { autoScanTask?.cancel() }

    func toggleAutoScan(_ on: Bool) {
        autoScanEnabled = on
        autoScanTask?.cancel()
        guard on else { return }
        autoScanTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(autoScanIntervalMinutes) * 60_000_000_000)
                guard !Task.isCancelled else { break }
                if let repo = self.selectedRepo { self.loadMergeRequests(for: repo) }
            }
        }
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
    @ObservedObject var viewModel: GitViewModel
    @State private var showFolderPicker = false
    @State private var showTokens = false
    @State private var mergeTarget: MergeRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            header
            HStack(alignment: .top, spacing: Theme.gap) {
                repoList.frame(width: 280)
                mrList
            }
            if !viewModel.status.isEmpty {
                Text(viewModel.status)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(Theme.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg)
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
        VStack(alignment: .leading, spacing: Theme.gap) {
            HStack {
                Text("Git Manager")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if viewModel.isBusy { ProgressView().controlSize(.small) }
                Button("Chọn thư mục…") { showFolderPicker = true }
                Button("Quét") { viewModel.scan(doFetch: false) }.disabled(viewModel.rootPath == nil)
                Button("Quét + Fetch") { viewModel.scan(doFetch: true) }.disabled(viewModel.rootPath == nil)
                Button("Token…") { showTokens = true }
            }
            HStack(spacing: 12) {
                Toggle("Tự quét mỗi", isOn: Binding(
                    get: { viewModel.autoScanEnabled },
                    set: { viewModel.toggleAutoScan($0) }
                ))
                .foregroundStyle(Theme.textSecondary)
                Stepper("\(viewModel.autoScanIntervalMinutes) phút",
                        value: $viewModel.autoScanIntervalMinutes, in: 1...60)
                    .fixedSize()
                    .disabled(!viewModel.autoScanEnabled)
                    .foregroundStyle(Theme.textSecondary)
                Text("(dùng ETag, tự động làm mới MR/PR)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, Theme.pad)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
        }
    }

    private var repoList: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Text("Repositories".uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(1)
                .foregroundStyle(Theme.textTertiary)
            List(viewModel.repos, selection: $viewModel.selectedRepoID) { repo in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(repo.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        if repo.isDirty { Image(systemName: "pencil.circle.fill").foregroundStyle(Theme.orange) }
                    }
                    HStack(spacing: 8) {
                        Label(repo.currentBranch, systemImage: "arrow.triangle.branch")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                        if repo.ahead > 0 {
                            Text("↑\(repo.ahead)").font(Theme.mono(11)).foregroundStyle(Theme.green)
                        }
                        if repo.behind > 0 {
                            Text("↓\(repo.behind)").font(Theme.mono(11)).foregroundStyle(Theme.orange)
                        }
                    }
                    if let ref = repo.remoteRef {
                        Text("\(ref.kind.rawValue) · \(ref.fullPath)")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .tag(repo.id)
                .listRowBackground(Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { viewModel.select(repo) }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
        }
    }

    private var mrList: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Text((viewModel.selectedRepo.map { "MR/PR — \($0.name)" } ?? "MR/PR").uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(1)
                .foregroundStyle(Theme.textTertiary)
            if viewModel.mergeRequests.isEmpty {
                Text("Không có MR/PR đang mở (hoặc chưa tải).")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.mergeRequests) { mr in
                    HStack {
                        ciIcon(mr.ciStatus)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("#\(mr.id) \(mr.title)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Text("\(mr.sourceBranch) → \(mr.targetBranch) · @\(mr.author)")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Button("Merge") { mergeTarget = mr }
                            .disabled(mr.mergeable == false)
                    }
                    .listRowBackground(Color.clear)
                }
                .scrollContentBackground(.hidden)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ciIcon(_ status: CIStatus) -> some View {
        let (name, color): (String, Color) = {
            switch status {
            case .success: return ("checkmark.circle.fill", Theme.green)
            case .failed:  return ("xmark.circle.fill", Theme.red)
            case .pending: return ("clock.fill", Theme.orange)
            case .unknown: return ("questionmark.circle", Theme.textTertiary)
            }
        }()
        return Image(systemName: name).foregroundStyle(color)
    }

    private var tokensSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Personal Access Token")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("GitHub cần scope `repo`; GitLab cần scope `api`. Lưu an toàn trong Keychain.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            VStack(alignment: .leading, spacing: 4) {
                Text("GitHub PAT")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                SecureField("ghp_…", text: $viewModel.githubToken)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("GitLab PAT")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
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
        .background(Theme.bg)
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
            Text("Xác nhận Merge #\(mr.id)")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(mr.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Grid(alignment: .leading, verticalSpacing: 6) {
                GridRow {
                    Text("Nhánh:").foregroundStyle(Theme.textSecondary)
                    Text("\(mr.sourceBranch) → \(mr.targetBranch)").foregroundStyle(Theme.textPrimary)
                }
                GridRow {
                    Text("Tác giả:").foregroundStyle(Theme.textSecondary)
                    Text("@\(mr.author)").foregroundStyle(Theme.textPrimary)
                }
                GridRow {
                    Text("CI:").foregroundStyle(Theme.textSecondary)
                    Text(mr.ciStatus.rawValue).foregroundStyle(Theme.textPrimary)
                }
                GridRow {
                    Text("Có thể merge:").foregroundStyle(Theme.textSecondary)
                    Text(mr.mergeable == nil ? "?" : (mr.mergeable! ? "Có" : "Không/Conflict"))
                        .foregroundStyle(mr.mergeable == false ? Theme.red : Theme.textPrimary)
                }
            }
            .font(.system(size: 12.5))

            Picker("Kiểu merge", selection: $method) {
                ForEach(allowedMethods, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)

            if mr.ciStatus != .success {
                Label("CI chưa pass — cân nhắc trước khi merge.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(Theme.orange)
            }

            HStack {
                Spacer()
                Button("Hủy", action: onCancel)
                Button("Merge \(method.rawValue)") { onMerge(method) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.red)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Theme.bg)
        .onAppear {
            if !allowedMethods.contains(method) { method = allowedMethods.first ?? .merge }
        }
    }
}
