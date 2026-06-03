import Foundation

/// Lưu trữ ETag HTTP per-URL để tránh tải lại dữ liệu không đổi (GIT-10).
/// Thread-safe bằng NSLock — dùng được từ nhiều Task/thread.
public final class ETagCache: @unchecked Sendable {
    private var etags: [URL: String] = [:]
    private var cached: [URL: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func etag(for url: URL) -> String? {
        lock.withLock { etags[url] }
    }

    public func cachedData(for url: URL) -> Data? {
        lock.withLock { cached[url] }
    }

    public func store(etag: String, data: Data, for url: URL) {
        lock.withLock {
            etags[url] = etag
            cached[url] = data
        }
    }

    public func invalidate(for url: URL) {
        lock.withLock {
            etags.removeValue(forKey: url)
            cached.removeValue(forKey: url)
        }
    }
}
