import Foundation
import Core

/// Một mục có thể dọn (thư mục cache/temp) cùng dung lượng đã quét.
public struct CleanTarget: Identifiable, Equatable {
    public let id: URL
    public let name: String
    public let url: URL
    public var sizeBytes: UInt64
    public var exists: Bool

    public init(name: String, url: URL, sizeBytes: UInt64 = 0, exists: Bool = true) {
        self.id = url
        self.name = name
        self.url = url
        self.sizeBytes = sizeBytes
        self.exists = exists
    }
}

/// Dọn file tạm/cache an toàn. Luôn cho người dùng xem trước & chọn mục.
/// (xem docs/features/03-temp-cleaner.md)
public final class TempCleaner {

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Danh sách target mặc định (whitelist). Không bao giờ quét bừa thư mục hệ thống.
    public func defaultTargets() -> [CleanTarget] {
        let home = fileManager.homeDirectoryForCurrentUser
        var candidates: [(String, URL)] = [
            ("Thư mục tạm (TMPDIR)", URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)),
            ("User Caches", home.appendingPathComponent("Library/Caches", isDirectory: true)),
            ("User Logs", home.appendingPathComponent("Library/Logs", isDirectory: true))
        ]
        if let systemCaches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            candidates.append(("App Caches", systemCaches))
        }

        // Khử trùng lặp theo path đã chuẩn hoá.
        var seen = Set<String>()
        return candidates.compactMap { name, url in
            let key = url.standardizedFileURL.path
            guard seen.insert(key).inserted else { return nil }
            let exists = fileManager.fileExists(atPath: url.path)
            return CleanTarget(name: name, url: url, exists: exists)
        }
    }

    /// Quét dung lượng từng target (cập nhật `sizeBytes`). Có thể chậm — gọi off-main.
    public func scan(_ targets: [CleanTarget]) -> [CleanTarget] {
        targets.map { target in
            var updated = target
            updated.sizeBytes = target.exists ? directorySize(target.url) : 0
            return updated
        }
    }

    /// Tổng dung lượng (bytes) của các mục trong một thư mục.
    public func directorySize(_ url: URL) -> UInt64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey],
            options: [],
            errorHandler: { _, _ in true } // bỏ qua mục không truy cập được
        ) else { return 0 }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            if let size = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize {
                total += UInt64(size)
            }
        }
        return total
    }

    /// Dung lượng của một mục bất kỳ: nếu là thư mục → tổng đệ quy; nếu là file → kích thước file.
    public func itemSize(_ url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        if values?.isDirectory == true {
            return directorySize(url)
        }
        if let size = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize {
            return UInt64(size)
        }
        return 0
    }

    /// Kết quả dọn một target.
    public struct CleanResult {
        public let target: CleanTarget
        public let freedBytes: UInt64
        public let dryRun: Bool
        public let failedItems: [URL]
    }

    /// Xoá nội dung BÊN TRONG thư mục target (không xoá chính thư mục đó).
    /// `dryRun = true` chỉ tính dung lượng, không xoá.
    public func clean(_ target: CleanTarget, dryRun: Bool) -> CleanResult {
        guard target.exists else {
            return CleanResult(target: target, freedBytes: 0, dryRun: dryRun, failedItems: [])
        }

        let contents = (try? fileManager.contentsOfDirectory(
            at: target.url,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []

        var freed: UInt64 = 0
        var failed: [URL] = []

        for item in contents {
            let size = itemSize(item) // đúng cho cả file lẫn thư mục con
            if dryRun {
                freed += size
                continue
            }
            do {
                try fileManager.removeItem(at: item)
                freed += size
            } catch {
                failed.append(item)
                Log.cleaner.error("Không xoá được \(item.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        return CleanResult(target: target, freedBytes: freed, dryRun: dryRun, failedItems: failed)
    }
}
