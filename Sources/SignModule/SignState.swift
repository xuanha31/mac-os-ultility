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

    // Tự động gia hạn trước khi cert hết hạn (7 ngày)
    @Published public var autoRefreshEnabled: Bool = UserDefaults.standard.bool(forKey: "signAutoRefresh") {
        didSet { UserDefaults.standard.set(autoRefreshEnabled, forKey: "signAutoRefresh") }
    }
    public let refreshThresholdDays = 2
    @Published public var lastAutoRefresh: Date?
    private var autoRefreshTask: Task<Void, Never>?

    /// Báo Telegram cả khi refresh THÀNH CÔNG (mặc định tắt để tránh spam).
    @Published public var notifyTelegramOnSuccess: Bool = UserDefaults.standard.bool(forKey: "signNotifyTGSuccess") {
        didSet { UserDefaults.standard.set(notifyTelegramOnSuccess, forKey: "signNotifyTGSuccess") }
    }
    /// Lỗi của lần performSign gần nhất (nil nếu thành công). Auto-refresh đọc để gom báo Telegram.
    public private(set) var lastError: String?

    // LiveContainer: cache IPA guest đã chuẩn bị (phục vụ qua HTTP repo). Không devicectl.
    @Published public var guestCache: [UUID: GuestIPAInfo] = [:]
    public let freeSlotLimit = 3

    private var store = SignStore()

    public init() {
        store = SignStore.load()
        teams = store.teams; devices = store.devices
        apps = store.apps; records = store.records
        refreshEnvironment()
        startAutoRefreshLoop()
    }

    // MARK: - Tự động gia hạn

    private func startAutoRefreshLoop() {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runAutoRefresh()
                try? await Task.sleep(for: .seconds(3600))   // kiểm tra mỗi giờ
            }
        }
    }

    /// Quét các bản ký sắp hết hạn (<= refreshThresholdDays) và re-sign lặng lẽ.
    /// Không cần 2FA (account ở Xcode) nên chạy nền hoàn toàn tự động.
    ///
    /// KHÔNG còn nuốt lỗi: mỗi thất bại trong 1 chu kỳ được gom thành 1 tin Telegram
    /// (tên app, tên/UDID thiết bị, số ngày còn lại, trích đoạn lỗi). Chỉ xử lý app
    /// native — guest app do LiveContainer tự quản, không devicectl.
    public func runAutoRefresh() async {
        guard autoRefreshEnabled, !isBusy else { return }
        let nativeAppIDs = Set(apps.filter { $0.installMode == .native }.map { $0.id })
        let expiring = records.filter {
            $0.status == "ok" && $0.daysLeft <= refreshThresholdDays && nativeAppIDs.contains($0.appID)
        }
        guard !expiring.isEmpty else { return }

        // Ưu tiên USB: quét thiết bị đang thực sự kết nối để báo lỗi rõ khi không reach được.
        let connected = await Task.detached { XcodeSigner.listConnectedDevices() }.value
        let connectedUDIDs = Set(connected.map { $0.udid })

        var failures: [String] = []
        var succeeded: [String] = []
        for rec in expiring {
            guard let app = apps.first(where: { $0.id == rec.appID }),
                  let device = devices.first(where: { $0.udid == rec.deviceUDID }) else { continue }

            if !connectedUDIDs.contains(device.udid) {
                failures.append(failureLine(app: app, device: device, daysLeft: rec.daysLeft,
                                            detail: "Thiết bị không kết nối (USB). devicectl/xcodebuild cần usbmuxd — cắm cáp rồi thử lại."))
                continue
            }
            let ok = await performSign(app: app, device: device, quiet: true)
            if ok {
                succeeded.append(app.name)
            } else {
                failures.append(failureLine(app: app, device: device, daysLeft: rec.daysLeft,
                                            detail: lastError ?? "không rõ (xem log MacUtil)"))
            }
        }
        lastAutoRefresh = Date()

        if !failures.isEmpty {
            let header = "🔴 <b>MacUtil — auto-refresh THẤT BẠI</b> (\(failures.count)/\(expiring.count))\n"
            await sendTelegram(header + "\n" + failures.joined(separator: "\n\n"))
        } else if notifyTelegramOnSuccess, !succeeded.isEmpty {
            let names = succeeded.map { TelegramNotifier.esc($0) }.joined(separator: ", ")
            await sendTelegram("🟢 <b>MacUtil — auto-refresh OK</b>\nĐã gia hạn: \(names)")
        }
    }

    /// Một dòng lỗi (HTML) cho tin Telegram gom.
    private func failureLine(app: SignApp, device: SignDevice, daysLeft: Int, detail: String) -> String {
        let snippet = String(detail.prefix(400))
        return "• <b>\(TelegramNotifier.esc(app.name))</b> → \(TelegramNotifier.esc(device.name)) "
            + "(<code>\(TelegramNotifier.esc(device.udid))</code>), còn \(daysLeft) ngày\n"
            + "  <i>\(TelegramNotifier.esc(snippet))</i>"
    }

    /// Gửi Telegram, ghi kết quả vào log MacUtil.
    private func sendTelegram(_ html: String) async {
        await TelegramNotifier.send(html) { [weak self] s in
            Task { @MainActor in self?.appendLog(s) }
        }
    }

    /// Gửi 1 tin thử để xác nhận cấu hình telegram.json.
    public func testTelegram() {
        Task {
            let ok = await TelegramNotifier.send(
                "✅ <b>MacUtil</b> — tin nhắn thử. Cấu hình Telegram hoạt động.") { [weak self] s in
                Task { @MainActor in self?.appendLog(s) }
            }
            setStatus(ok ? "✓ Đã gửi tin thử Telegram."
                         : "✗ Không gửi được Telegram — kiểm tra telegram.json / xem log.")
        }
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

    public func addApp(_ app: SignApp) {
        // Chỉ 1 app được đánh dấu là LiveContainer host.
        if app.isLiveContainerHost { for i in apps.indices { apps[i].isLiveContainerHost = false } }
        apps.append(app); persist()
    }
    public func updateApp(_ app: SignApp) {
        guard let idx = apps.firstIndex(where: { $0.id == app.id }) else { return }
        if app.isLiveContainerHost {
            for i in apps.indices where apps[i].id != app.id { apps[i].isLiveContainerHost = false }
        }
        apps[idx] = app; persist()
    }
    public func deleteApp(_ app: SignApp) {
        apps.removeAll { $0.id == app.id }
        records.removeAll { $0.appID == app.id }   // dọn bản ghi cài liên quan
        if let info = guestCache[app.id] { try? FileManager.default.removeItem(atPath: info.localPath) }
        guestCache.removeValue(forKey: app.id)     // dọn IPA guest đã chuẩn bị
        persist()
    }

    // MARK: - LiveContainer: slot & host

    /// Số slot native đang chiếm (mỗi app native đã cài = 1). Guest KHÔNG tính.
    public var usedNativeSlots: Int {
        let nativeIDs = Set(apps.filter { $0.installMode == .native }.map { $0.id })
        let occupied = records.filter { $0.status == "ok" && nativeIDs.contains($0.appID) }.map { $0.appID }
        return Set(occupied).count
    }

    /// App được đánh dấu là LiveContainer host (nếu có).
    public var liveContainerHost: SignApp? { apps.first { $0.isLiveContainerHost } }

    /// LiveContainer host đã thực sự cài (có record ok) chưa?
    public var isLiveContainerInstalled: Bool {
        guard let host = liveContainerHost else { return false }
        return records.contains { $0.appID == host.id && $0.status == "ok" }
    }

    // MARK: - LiveContainer: chuẩn bị guest IPA + repo

    /// Chuẩn bị 1 guest app: resolve IPA về local (KHÔNG resign — LiveContainer tự ký),
    /// đọc bundle id/version, cache lại để phục vụ qua HTTP repo + AirDrop.
    public func prepareGuest(_ app: SignApp) {
        Task { await prepareGuestAsync(app) }
    }

    @discardableResult
    func prepareGuestAsync(_ app: SignApp) async -> Bool {
        guard app.installMode == .liveContainer else { return false }
        guard !isBusy else { return false }
        isBusy = true
        appendLog("=== Chuẩn bị guest '\(app.name)' cho LiveContainer (IPA gốc, không ký) ===\n")
        let logCb: (String) -> Void = { s in Task { @MainActor [weak self] in self?.appendLog(s) } }
        do {
            let ipa = try await resolveIPA(app, log: logCb)
            let dest = XcodeSigner.guestDir.appendingPathComponent("\(app.id.uuidString).ipa")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: ipa, to: dest)
            let meta = try await Task.detached(priority: .userInitiated) {
                try XcodeSigner.readIPAInfo(dest)
            }.value
            let size = ((try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber)?.intValue ?? 0
            guestCache[app.id] = GuestIPAInfo(appID: app.id, name: app.name, bundleID: meta.bundleID,
                                              version: meta.version, localPath: dest.path,
                                              size: size, preparedAt: Date())
            isBusy = false
            setStatus("✓ Guest '\(app.name)' sẵn sàng (\(meta.bundleID)). Bật server → thêm source trong LiveContainer, hoặc AirDrop IPA.")
            return true
        } catch {
            appendLog("\n✗ LỖI chuẩn bị guest: \(error)\n")
            isBusy = false
            setStatus("✗ \(error)")
            return false
        }
    }

    /// Đường dẫn IPA guest đã chuẩn bị (để UI "Hiện trong Finder" / AirDrop).
    public func guestIPAPath(_ app: SignApp) -> String? { guestCache[app.id]?.localPath }

    /// URL source (AltStore-style) để dán vào LiveContainer khi server đang chạy.
    public func lcSourceURLString() -> String? {
        guard isServerRunning, let ip = macLANAddress() else { return nil }
        return "http://\(ip):\(serverPort)/lc/source.json"
    }

    // MARK: - LiveContainer: dữ liệu cho HTTP repo (SignServer gọi)

    private static let ymd: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// JSON nguồn kiểu AltStore để LiveContainer duyệt & cài guest app.
    /// (Định dạng AltSource v1 + mảng `versions` v2 để tối đa tương thích;
    ///  cần kiểm chứng lại trên thiết bị thật với phiên bản LiveContainer đang dùng.)
    func lcSourceJSON(baseURL: String) -> [String: Any] {
        let items: [[String: Any]] = guestCache.values.map { g in
            let dl = "\(baseURL)/lc/ipa/\(g.appID.uuidString).ipa"
            let date = Self.ymd.string(from: g.preparedAt)
            return [
                "name": g.name,
                "bundleIdentifier": g.bundleID,
                "developerName": "MacUtil",
                "version": g.version,
                "versionDate": date,
                "downloadURL": dl,
                "size": g.size,
                "localizedDescription": "Guest app phục vụ bởi MacUtil cho LiveContainer.",
                "versions": [[
                    "version": g.version,
                    "date": date,
                    "downloadURL": dl,
                    "size": g.size,
                ]],
            ]
        }
        return [
            "name": "MacUtil — LiveContainer",
            "identifier": "com.macutil.livecontainer.source",
            "apps": items,
        ]
    }

    /// File IPA guest theo id (SignServer stream bytes). nil nếu chưa chuẩn bị / mất file.
    func guestIPAFileURL(id: String) -> URL? {
        guard let uuid = UUID(uuidString: id), let g = guestCache[uuid] else { return nil }
        let u = URL(fileURLWithPath: g.localPath)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// baseURL dự phòng khi request không kèm Host header.
    func lcFallbackBaseURL() -> String {
        "http://\(macLANAddress() ?? "127.0.0.1"):\(serverPort)"
    }
    public func deleteTeam(_ t: SignTeam) { teams.removeAll { $0.teamID == t.teamID }; persist() }
    public func deleteDevice(_ d: SignDevice) { devices.removeAll { $0.udid == d.udid }; persist() }

    // MARK: - Ký + cài

    public func signAndInstall(app: SignApp, device: SignDevice) {
        Task { await performSign(app: app, device: device, quiet: false) }
    }

    /// Ký + cài, await được (để scheduler gọi tuần tự). quiet=true: dùng cho auto-refresh nền.
    @discardableResult
    func performSign(app: SignApp, device: SignDevice, quiet: Bool) async -> Bool {
        guard let team = teams.first(where: { $0.teamID == app.teamID }) else {
            if !quiet { setStatus("App '\(app.name)' chưa gắn team hợp lệ.") }
            return false
        }
        guard !isBusy else { return false }
        isBusy = true
        lastError = nil
        if !quiet { log = "" }
        appendLog("=== \(quiet ? "[auto] " : "")Ký \(app.name) → \(device.name) (team \(team.teamID)) ===\n")
        let logCb: (String) -> Void = { s in Task { @MainActor [weak self] in self?.appendLog(s) } }
        do {
            let ipa = try await resolveIPA(app, log: logCb)
            let appName = app.name, udid = device.udid
            let bundleID = try await Task.detached(priority: .userInitiated) {
                try XcodeSigner.signAndInstall(ipa: ipa, team: team, appName: appName, udid: udid, log: logCb)
            }.value
            let now = Date()
            let rec = SignRecord(appID: app.id, deviceUDID: device.udid, signedBundleID: bundleID,
                                 signedAt: now, expiresAt: now.addingTimeInterval(7*24*3600),
                                 status: "ok", log: log)
            records.removeAll { $0.appID == app.id && $0.deviceUDID == device.udid }
            records.append(rec); persist()
            isBusy = false
            setStatus("✓ Đã cài \(app.name) lên \(device.name)." + (quiet ? "" : " Trust trên iPhone để mở."))
            return true
        } catch {
            appendLog("\n✗ LỖI: \(error)\n")
            lastError = "\(error)"
            isBusy = false
            if !quiet { setStatus("✗ \(error)") }
            return false
        }
    }

    /// Lấy file IPA: path local, release mới nhất của GitHub repo, hoặc URL tải trực tiếp.
    private func resolveIPA(_ app: SignApp, log: @escaping (String) -> Void) async throws -> URL {
        if let path = app.sourcePath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let repo = app.githubRepo, !repo.isEmpty {
            log("→ Lấy IPA mới nhất từ GitHub \(repo)...\n")
            let token = app.githubToken?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasToken = !(token ?? "").isEmpty
            if hasToken { log("  (dùng token cho repo private)\n") }

            var apiReq = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
            apiReq.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            if hasToken { apiReq.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization") }
            let (data, apiResp) = try await URLSession.shared.data(for: apiReq)
            if let code = (apiResp as? HTTPURLResponse)?.statusCode, !(200..<300).contains(code) {
                let hint = (code == 404 && !hasToken) ? " — repo private cần token (hoặc repo chưa có release)." : ""
                throw SignError("GitHub trả HTTP \(code) khi đọc release của \(repo).\(hint)")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let assets = json["assets"] as? [[String: Any]],
                  let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".ipa") == true }) else {
                throw SignError("Không tìm thấy asset .ipa trong release mới nhất của \(repo).")
            }

            let tmp: URL
            if hasToken, let assetAPI = asset["url"] as? String, let u = URL(string: assetAPI) {
                // Repo private: phải tải qua asset API + Accept octet-stream (browser_download_url
                // cần phiên đăng nhập). GitHub redirect sang CDN — strip Authorization để CDN không 400.
                var dlReq = URLRequest(url: u)
                dlReq.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
                dlReq.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
                (tmp, _) = try await Self.ghDownloadSession.download(for: dlReq)
            } else {
                guard let urlStr = asset["browser_download_url"] as? String, let url = URL(string: urlStr) else {
                    throw SignError("Asset .ipa không có link tải hợp lệ.")
                }
                (tmp, _) = try await URLSession.shared.download(from: url)
            }
            return try Self.moveDownloadToSupport(tmp)
        }
        if let urlStr = app.ipaURL, !urlStr.isEmpty {
            guard let url = URL(string: urlStr) else { throw SignError("URL IPA không hợp lệ: \(urlStr)") }
            log("→ Tải IPA trực tiếp từ \(urlStr)...\n")
            let (tmp, _) = try await URLSession.shared.download(from: url)
            return try Self.moveDownloadToSupport(tmp)
        }
        throw SignError("App chưa có nguồn IPA (file local, GitHub repo, hoặc URL).")
    }

    /// Session tải asset GitHub private: strip header Authorization khi GitHub redirect sang CDN
    /// (S3/Azure) — nếu giữ lại, storage backend thường trả 400.
    private static let ghDownloadSession = URLSession(
        configuration: .default, delegate: GHRedirectStripper(), delegateQueue: nil)

    /// Di chuyển file IPA vừa tải về thư mục hỗ trợ với tên duy nhất.
    private static func moveDownloadToSupport(_ tmp: URL) throws -> URL {
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

/// Khi tải asset GitHub private, GitHub redirect (302) sang CDN bằng signed URL tự xác thực.
/// Ta gỡ header `Authorization` trên redirect để CDN không từ chối request (400).
private final class GHRedirectStripper: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        var req = request
        req.setValue(nil, forHTTPHeaderField: "Authorization")
        completionHandler(req)
    }
}
