import Foundation

public enum GitHostError: Error, CustomStringConvertible {
    case noAPIBase
    case noToken
    case http(status: Int, body: String)
    case transport(String)

    public var description: String {
        switch self {
        case .noAPIBase: return "Không xác định được API base URL cho host này."
        case .noToken: return "Chưa cấu hình token (PAT) cho nền tảng này."
        case .http(let status, let body): return "HTTP \(status): \(body)"
        case .transport(let msg): return "Lỗi mạng: \(msg)"
        }
    }
}

/// Giao diện chung cho GitHub/GitLab (xem docs/features/07-git-manager.md).
public protocol GitHostProvider: Sendable {
    func listMergeRequests(_ ref: RemoteRef) async throws -> [MergeRequest]
    func allowedMergeMethods(_ ref: RemoteRef) async throws -> [MergeMethod]
    func merge(_ mr: MergeRequest, in ref: RemoteRef, method: MergeMethod) async throws
}

/// Tiện ích HTTP nhỏ dùng chung cho 2 provider. Hỗ trợ ETag caching (GIT-10).
struct HTTPClient: Sendable {
    let session: URLSession
    let etagCache: ETagCache?

    init(session: URLSession = .shared, etagCache: ETagCache? = nil) {
        self.session = session
        self.etagCache = etagCache
    }

    func request(
        _ url: URL,
        method: String = "GET",
        headers: [String: String],
        body: Data? = nil
    ) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }
        req.timeoutInterval = 30

        // Thêm ETag nếu có cache cho GET request
        if method == "GET", let cache = etagCache, let etag = cache.etag(for: url) {
            req.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw GitHostError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw GitHostError.transport("Phản hồi không hợp lệ")
        }

        // 304 Not Modified → trả dữ liệu đã cache
        if http.statusCode == 304, let cache = etagCache, let cached = cache.cachedData(for: url) {
            return cached
        }

        guard (200..<300).contains(http.statusCode) else {
            throw GitHostError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }

        // Lưu ETag mới nếu có
        if let cache = etagCache, let etag = http.value(forHTTPHeaderField: "ETag") {
            cache.store(etag: etag, data: data, for: url)
        }
        return data
    }

    func getJSON<T: Decodable>(_ type: T.Type, url: URL, headers: [String: String]) async throws -> T {
        let data = try await request(url, headers: headers)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
