import Foundation
import Combine
import Darwin

/// ViewModel cho tính năng Sign (ký + cài app iOS bằng toolchain Xcode native).
@MainActor
public final class SignState: ObservableObject {
    @Published public var teams: [SignTeam] = []
    @Published public var devices: [SignDevice] = []
    @Published public var apps: [SignApp] = []
    @Published public var records: [SignRecord] = []

    @Published public var connectedDevices: [SignDevice] = []   // phát hiện qua USB
    @Published public var availableIdentities: [String] = []    // tên cert trong Keychain

    @Published public var isBusy = false
    @Published public var log = ""
    @Published public var statusMessage = ""

    // API server cho app iOS gọi tới
    @Published public var isServerRunning = false
    @Published public var serverPort = 8080
    private var server: SignServer?

    private var store = SignStore()

    public init() {
        store = SignStore.load()
        teams = store.teams; devices = store.devices
        apps = store.apps; records = store.records
        refreshEnvironment()
    }

    private func persist() {
        store.teams = teams; store.devices = devices
        store.apps = apps; store.records = records
        store.save()
    }

    // MARK: - Môi trường (cert + device kết nối)

    /// Quét lại signing identity trong Keychain + thiết bị USB.
    public func refreshEnvironment() {
        Task.detached { [weak self] in
            let idents = (try? XcodeSigner.listSigningIdentities()) ?? []
            let connected = XcodeSigner.listConnectedDevices()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.availableIdentities = idents.map(\.name)
                self.connectedDevices = connected.map { SignDevice(udid: $0.udid, name: $0.name) }
            }
        }
    }

    /// Thêm team từ một signing identity (tự lấy teamID = OU của cert).
    public func addTeam(fromCertNamed name: String) {
        Task.detached { [weak self] in
            do {
                let idents = try XcodeSigner.listSigningIdentities()
                guard let ident = idents.first(where: { $0.name == name }) else {
                    throw SignError("Không thấy identity: \(name)")
                }
                let teamID = try XcodeSigner.teamID(forCertNamed: name)
                let appleID = Self.extractEmail(from: name) ?? name
                let team = SignTeam(teamID: teamID, appleID: appleID,
                                    certSHA1: ident.sha1, certName: name)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if !self.teams.contains(where: { $0.teamID == teamID }) {
                        self.teams.append(team); self.persist()
                    }
                    self.setStatus("✓ Đã thêm team \(teamID) (\(appleID))")
                }
            } catch {
                await MainActor.run { [weak self] in self?.setStatus("Lỗi thêm team: \(error)") }
            }
        }
    }

    public func addDeviceFromConnected(_ d: SignDevice) {
        if !devices.contains(where: { $0.udid == d.udid }) { devices.append(d); persist() }
    }

    public func addApp(_ app: SignApp) { apps.append(app); persist() }
    public func deleteApp(_ app: SignApp) { apps.removeAll { $0.id == app.id }; persist() }
    public func deleteTeam(_ t: SignTeam) { teams.removeAll { $0.teamID == t.teamID }; persist() }
    public func deleteDevice(_ d: SignDevice) { devices.removeAll { $0.udid == d.udid }; persist() }

    // MARK: - Ký + cài

    public func signAndInstall(app: SignApp, device: SignDevice) {
        guard let team = teams.first(where: { $0.teamID == app.teamID }) else {
            setStatus("App chưa gắn team hợp lệ."); return
        }
        isBusy = true; log = ""
        appendLog("=== Ký \(app.name) cho \(device.name) bằng team \(team.teamID) ===\n")
        Task.detached { [weak self] in
            guard let self else { return }
            let logCb: (String) -> Void = { s in Task { @MainActor [weak self] in self?.appendLog(s) } }
            do {
                let ipa = try await self.resolveIPA(app, log: logCb)
                let bundleID = try XcodeSigner.signAndInstall(
                    ipa: ipa, team: team, appName: app.name, udid: device.udid, log: logCb)
                let now = Date()
                let rec = SignRecord(appID: app.id, deviceUDID: device.udid, signedBundleID: bundleID,
                                     signedAt: now, expiresAt: now.addingTimeInterval(7*24*3600),
                                     status: "ok", log: await self.log)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.records.removeAll { $0.appID == app.id && $0.deviceUDID == device.udid }
                    self.records.append(rec); self.persist()
                    self.isBusy = false
                    self.setStatus("✓ Đã cài \(app.name) lên \(device.name). Vào iPhone → Settings → General → VPN & Device Management để Trust.")
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.appendLog("\n✗ LỖI: \(error)\n")
                    self.isBusy = false
                    self.setStatus("Ký thất bại: \(error)")
                }
            }
        }
    }

    /// Lấy file IPA: từ path local, hoặc tải release mới nhất của GitHub repo.
    private func resolveIPA(_ app: SignApp, log: @escaping (String) -> Void) async throws -> URL {
        if let path = app.sourcePath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        guard let repo = app.githubRepo, !repo.isEmpty else {
            throw SignError("App chưa có nguồn IPA (file local hoặc GitHub repo).")
        }
        log("→ Lấy IPA mới nhất từ GitHub \(repo)...\n")
        let apiURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        let (data, _) = try await URLSession.shared.data(from: apiURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".ipa") == true }),
              let urlStr = asset["browser_download_url"] as? String,
              let url = URL(string: urlStr) else {
            throw SignError("Không tìm thấy asset .ipa trong release mới nhất của \(repo).")
        }
        let (tmp, _) = try await URLSession.shared.download(from: url)
        let dest = XcodeSigner.supportDir.appendingPathComponent("dl-\(UUID().uuidString).ipa")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    // MARK: - API server (app iOS gọi tới)

    public func toggleServer() {
        if isServerRunning { stopServer() } else { startServer() }
    }

    public func startServer() {
        let srv = SignServer(state: self)
        do {
            try srv.start(port: UInt16(serverPort))
            server = srv
            isServerRunning = true
            setStatus("✓ Server đang chạy ở http://<IP-Mac>:\(serverPort) — app iOS trỏ Server URL tới đây.")
        } catch {
            setStatus("Không mở được server cổng \(serverPort): \(error)")
        }
    }

    public func stopServer() {
        server?.stop(); server = nil; isServerRunning = false
        setStatus("Đã dừng server.")
    }

    /// IP LAN của Mac (để hiển thị cho app iOS trỏ tới).
    public func macLANAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(first) }
        var ptr = first
        while true {
            let flags = Int32(ptr.pointee.ifa_flags)
            let name = String(cString: ptr.pointee.ifa_name)
            if flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
               ptr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET),
               name.hasPrefix("en") {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(ptr.pointee.ifa_addr, socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                               &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if !ip.hasPrefix("169.254") { address = ip; break }
                }
            }
            guard let next = ptr.pointee.ifa_next else { break }
            ptr = next
        }
        return address
    }

    // MARK: - Helpers

    private func appendLog(_ s: String) { log += s }

    private func setStatus(_ msg: String) {
        statusMessage = msg
        Task { try? await Task.sleep(nanoseconds: 6_000_000_000); if statusMessage == msg { statusMessage = "" } }
    }

    nonisolated static func extractEmail(from certName: String) -> String? {
        // "Apple Development: hanx2707@gmail.com (XXXX)"
        guard let r = try? NSRegularExpression(pattern: #"([^\s:]+@[^\s)]+)"#),
              let m = r.firstMatch(in: certName, range: NSRange(certName.startIndex..., in: certName)),
              let range = Range(m.range(at: 1), in: certName) else { return nil }
        return String(certName[range])
    }
}
