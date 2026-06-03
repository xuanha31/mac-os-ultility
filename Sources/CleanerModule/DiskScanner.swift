import Foundation

// Phân tích dung lượng đĩa kiểu LAZY: chỉ quét 1 cấp mỗi lần, tính dung lượng nền,
// mở folder nào mới quét cấp đó → không nghẽn UI với cây triệu file.

@MainActor
public final class DiskNode: ObservableObject, Identifiable {
    public let id = UUID()
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    @Published public var size: Int64
    @Published public var children: [DiskNode]?   // nil = chưa nạp
    @Published public var isLoading = false

    public init(url: URL, name: String, isDirectory: Bool, size: Int64) {
        self.url = url; self.name = name; self.isDirectory = isDirectory; self.size = size
    }

    /// Nạp con (1 cấp) khi người dùng mở folder. Dung lượng từng con tính nền, cập nhật dần.
    public func loadChildrenIfNeeded() {
        guard isDirectory, children == nil, !isLoading else { return }
        isLoading = true
        let dir = url
        Task {
            let entries = await Task.detached(priority: .utility) {
                DiskScanner.immediateEntries(of: dir)
            }.value
            let nodes = entries.map { DiskNode(url: $0.url, name: $0.name, isDirectory: $0.isDir, size: $0.size) }
            self.children = nodes
            self.isLoading = false
            // Tính dung lượng các thư mục con ở nền, cập nhật + sắp xếp dần.
            for node in nodes where node.isDirectory {
                let u = node.url
                let sz = await Task.detached(priority: .utility) { DiskScanner.totalSize(of: u) }.value
                node.size = sz
                self.size = max(self.size, self.children?.reduce(0) { $0 + $1.size } ?? 0)
                self.resort()
            }
            self.resort()
        }
    }

    private func resort() {
        children?.sort { $0.size > $1.size }   // dung lượng cao lên đầu
    }

    /// Con cho cây: nil nếu là file (không hiện tam giác mở).
    public var outlineChildren: [DiskNode]? { isDirectory ? (children ?? []) : nil }
}

public enum DiskScanner {
    /// Tạo node gốc (chưa nạp con) — nạp khi mở.
    @MainActor
    public static func makeRoot(_ url: URL) -> DiskNode {
        DiskNode(url: url, name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
                 isDirectory: true, size: 0)
    }

    struct Entry { let url: URL; let name: String; let isDir: Bool; let size: Int64 }

    /// Liệt kê con trực tiếp (nhanh) — file có size ngay, folder size=0 (tính sau).
    static func immediateEntries(of url: URL) -> [Entry] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [Entry] = []
        for child in urls {
            let vals = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey])
            if vals?.isSymbolicLink == true { continue }
            let isDir = vals?.isDirectory ?? false
            let size = isDir ? 0 : Int64(vals?.totalFileAllocatedSize ?? vals?.fileSize ?? 0)
            out.append(Entry(url: child, name: child.lastPathComponent, isDir: isDir, size: size))
        }
        return out
    }

    /// Tổng dung lượng một thư mục (đi hết subtree một lần).
    static func totalSize(of url: URL) -> Int64 {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey],
                                     options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
        }
        return total
    }
}
