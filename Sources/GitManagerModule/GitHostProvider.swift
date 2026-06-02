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

/// Tiện ích HTTP nhỏ dùng chung cho 2 provider.
struct HTTPClient: Sendable {
    let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

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
        req.timeoutInterval = 30 // không treo vô hạn (yêu cầu chống treo)

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
        guard (200..<300).contains(http.statusCode) else {
            throw GitHostError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }

    func getJSON<T: Decodable>(_ type: T.Type, url: URL, headers: [String: String]) async throws -> T {
        let data = try await request(url, headers: headers)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
