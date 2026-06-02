import Foundation
import Core

/// Quét repo Git local trong một thư mục gốc (root và các thư mục con cấp 1).
public struct LocalRepoScanner {
    private let git: GitCLI
    private let fileManager: FileManager

    public init(git: GitCLI = GitCLI(), fileManager: FileManager = .default) {
        self.git = git
        self.fileManager = fileManager
    }

    /// Tìm các thư mục là git repo (chứa `.git`).
    public func findRepositories(in root: URL) -> [URL] {
        var result: [URL] = []
        if hasGitDir(root) { result.append(root) }

        let children = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for child in children {
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir && hasGitDir(child) {
                result.append(child)
            }
        }
        return result
    }

    private func hasGitDir(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    /// Đọc thông tin một repo. `doFetch = true` chạy `git fetch` trước (chậm/cần mạng).
    public func inspect(_ repoURL: URL, doFetch: Bool = false) -> GitRepoInfo {
        if doFetch {
            _ = git.tryRun(["fetch", "--quiet"], in: repoURL)
        }

        var info = GitRepoInfo(name: repoURL.lastPathComponent, localPath: repoURL)
        info.currentBranch = git.tryRun(["rev-parse", "--abbrev-ref", "HEAD"], in: repoURL) ?? "?"
        info.isDirty = !(git.tryRun(["status", "--porcelain"], in: repoURL) ?? "").isEmpty
        info.remoteURL = git.tryRun(["remote", "get-url", "origin"], in: repoURL)
        if let remote = info.remoteURL {
            info.remoteRef = RepoCorrelator.parse(remoteURL: remote)
        }

        // ahead/behind so với upstream (nếu có).
        if let counts = git.tryRun(["rev-list", "--left-right", "--count", "@{upstream}...HEAD"], in: repoURL) {
            let parts = counts.split(whereSeparator: { $0 == "\t" || $0 == " " })
            if parts.count == 2 {
                info.behind = Int(parts[0]) ?? 0
                info.ahead = Int(parts[1]) ?? 0
            }
        }
        return info
    }

    /// Quét + inspect toàn bộ repo trong root.
    public func scan(root: URL, doFetch: Bool = false) -> [GitRepoInfo] {
        findRepositories(in: root)
            .map { inspect($0, doFetch: doFetch) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
