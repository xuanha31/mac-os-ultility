import Foundation
import Network

// MARK: - DTO (JSON cho app iOS)

struct TeamDTO: Codable { let team_id: String; let apple_id: String }
struct DeviceDTO: Codable { let udid: String; let name: String }
struct AppDTO: Codable {
    let id: String; let name: String; let team_id: String
    let source: String?            // mô tả gộp để hiển thị
    let github_repo: String?       // field riêng để app iOS prefill khi sửa
    let ipa_url: String?
}
struct RecordDTO: Codable {
    let id: String; let app_id: String; let device_udid: String
    let signed_bundle_id: String; let status: String; let days_left: Int
    let signed_at: String; let expires_at: String
}
private struct AddDeviceBody: Codable { let udid: String; let name: String? }
private struct AddAppBody: Codable { let name: String; let team_id: String; let github_repo: String?; let ipa_url: String? }
private struct SignBody: Codable { let device_udid: String }

/// HTTP API server nhúng trong MacUtil (Network.framework, không cần dep ngoài).
/// App iOS trên nhiều máy gọi tới để ra lệnh ký; việc ký/cài chạy bằng XcodeSigner native.
public final class SignServer {
    private var listener: NWListener?
    private weak var state: SignState?
    private let queue = DispatchQueue(label: "com.macutil.signserver")

    public init(state: SignState) { self.state = state }

    public func start(port: UInt16) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw SignError("Cổng không hợp lệ") }
        let l = try NWListener(using: params, on: nwPort)
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: self?.queue ?? .global())
            self?.receive(conn, buffer: Data())
        }
        l.start(queue: queue)
        listener = l
    }

    public func stop() { listener?.cancel(); listener = nil }

    // MARK: - Đọc & parse request

    private struct Req { let method: String; let path: String; let body: Data }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = self.parse(buf) {
                let resp = self.route(req)
                conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
            } else if isComplete || error != nil {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)   // cần thêm dữ liệu
            }
        }
    }

    /// Trả Req nếu đã nhận đủ header + body; nil nếu cần thêm.
    private func parse(_ buf: Data) -> Req? {
        let sep = Data("\r\n\r\n".utf8)
        guard let r = buf.range(of: sep) else { return nil }
        let headerData = buf.subdata(in: buf.startIndex..<r.lowerBound)
        guard let header = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = header.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])
        var contentLength = 0
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = r.upperBound
        let available = buf.distance(from: bodyStart, to: buf.endIndex)
        if available < contentLength { return nil }   // chờ thêm body
        let body = buf.subdata(in: bodyStart..<buf.index(bodyStart, offsetBy: contentLength))
        return Req(method: method, path: path, body: body)
    }

    // MARK: - Routing

    private func route(_ req: Req) -> Data {
        let m = req.method
        // bỏ query string, tách path
        let p = req.path.split(separator: "?").first.map(String.init)?.split(separator: "/").map(String.init) ?? []

        if m == "GET", p == ["status"] { return json(["status": "ok"]) }
        if m == "GET", p == ["teams"] { return json(onMain { self.state?.dtoTeams() ?? [] }) }
        if m == "GET", p == ["devices"] { return json(onMain { self.state?.dtoDevices() ?? [] }) }
        if m == "POST", p == ["devices"] {
            guard let b = decode(req.body, AddDeviceBody.self) else { return bad() }
            onMain { self.state?.serverAddDevice(udid: b.udid, name: b.name ?? b.udid) }
            return json(["ok": true])
        }
        if m == "GET", p == ["apps"] { return json(onMain { self.state?.dtoApps() ?? [] }) }
        if m == "POST", p == ["apps"] {
            guard let b = decode(req.body, AddAppBody.self) else { return bad() }
            let ok = onMain { self.state?.serverAddApp(name: b.name, teamID: b.team_id,
                                                       githubRepo: b.github_repo, ipaURL: b.ipa_url) ?? false }
            return json(["ok": ok])
        }
        if m == "PUT", p.count == 2, p[0] == "apps" {
            guard let b = decode(req.body, AddAppBody.self) else { return bad() }
            let ok = onMain { self.state?.serverUpdateApp(appID: p[1], name: b.name, teamID: b.team_id,
                                                          githubRepo: b.github_repo, ipaURL: b.ipa_url) ?? false }
            return ok ? json(["ok": true]) : notFound()
        }
        if m == "DELETE", p.count == 2, p[0] == "apps" {
            let ok = onMain { self.state?.serverDeleteApp(appID: p[1]) ?? false }
            return ok ? json(["ok": true]) : notFound()
        }
        if m == "POST", p.count == 3, p[0] == "apps", p[2] == "sign" {
            guard let b = decode(req.body, SignBody.self) else { return bad() }
            let ok = onMain { self.state?.serverSign(appID: p[1], deviceUDID: b.device_udid) ?? false }
            return json(["ok": ok])
        }
        if m == "GET", p == ["installations"] { return json(onMain { self.state?.dtoRecords() ?? [] }) }
        if m == "GET", p.count == 3, p[0] == "installations", p[2] == "log" {
            let log = onMain { self.state?.recordLog(id: p[1]) ?? "" }
            return json(["log": log])
        }
        return httpResponse(404, "Not Found", Data("{\"error\":\"not found\"}".utf8))
    }

    // MARK: - Helpers

    private func onMain<T>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated { body() } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }

    private func json<T: Encodable>(_ value: T) -> Data {
        let data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        return httpResponse(200, "OK", data)
    }
    private func bad() -> Data { httpResponse(400, "Bad Request", Data("{\"error\":\"bad request\"}".utf8)) }
    private func notFound() -> Data { httpResponse(404, "Not Found", Data("{\"error\":\"not found\"}".utf8)) }
    private func decode<T: Decodable>(_ body: Data, _ t: T.Type) -> T? {
        try? JSONDecoder().decode(T.self, from: body)
    }
    private func httpResponse(_ status: Int, _ reason: String, _ jsonBody: Data) -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(jsonBody.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var d = Data(head.utf8); d.append(jsonBody); return d
    }
}

// MARK: - SignState: API cho server

private let iso8601 = ISO8601DateFormatter()

extension SignState {
    func dtoTeams() -> [TeamDTO] { teams.map { TeamDTO(team_id: $0.teamID, apple_id: $0.appleID) } }
    func dtoDevices() -> [DeviceDTO] { devices.map { DeviceDTO(udid: $0.udid, name: $0.name) } }
    func dtoApps() -> [AppDTO] {
        apps.map { AppDTO(id: $0.id.uuidString, name: $0.name, team_id: $0.teamID,
                          source: $0.sourcePath ?? $0.githubRepo ?? $0.ipaURL,
                          github_repo: $0.githubRepo, ipa_url: $0.ipaURL) }
    }
    func dtoRecords() -> [RecordDTO] {
        records.map {
            RecordDTO(id: $0.id.uuidString, app_id: $0.appID.uuidString, device_udid: $0.deviceUDID,
                      signed_bundle_id: $0.signedBundleID, status: $0.status, days_left: $0.daysLeft,
                      signed_at: iso8601.string(from: $0.signedAt), expires_at: iso8601.string(from: $0.expiresAt))
        }
    }
    func recordLog(id: String) -> String? { records.first { $0.id.uuidString == id }?.log }

    func serverAddDevice(udid: String, name: String) {
        addDeviceFromConnected(SignDevice(udid: udid, name: name))
    }
    func serverAddApp(name: String, teamID: String, githubRepo: String?, ipaURL: String?) -> Bool {
        guard teams.contains(where: { $0.teamID == teamID }) else { return false }
        addApp(SignApp(name: name, sourcePath: nil, githubRepo: githubRepo, ipaURL: ipaURL, teamID: teamID))
        return true
    }
    func serverUpdateApp(appID: String, name: String, teamID: String, githubRepo: String?, ipaURL: String?) -> Bool {
        guard let existing = apps.first(where: { $0.id.uuidString == appID }),
              teams.contains(where: { $0.teamID == teamID }) else { return false }
        var app = existing
        app.name = name
        app.teamID = teamID
        app.githubRepo = githubRepo
        app.ipaURL = ipaURL
        app.sourcePath = nil          // app iOS chỉ chỉnh github/url; bỏ path local cũ nếu có
        updateApp(app)
        return true
    }
    func serverDeleteApp(appID: String) -> Bool {
        guard let app = apps.first(where: { $0.id.uuidString == appID }) else { return false }
        deleteApp(app)
        return true
    }
    func serverSign(appID: String, deviceUDID: String) -> Bool {
        guard let app = apps.first(where: { $0.id.uuidString == appID }),
              let device = devices.first(where: { $0.udid == deviceUDID }) else { return false }
        signAndInstall(app: app, device: device)
        return true
    }
}
