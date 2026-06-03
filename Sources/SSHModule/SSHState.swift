import Foundation
import Combine
import Core

// SSH-05: Quản lý nhiều session/tab + sleep/wake reconnect (SSH-09).

@MainActor
public final class SSHState: ObservableObject {
    @Published public var profiles: [SSHProfile] = []
    @Published public var sessions: [UUID: SSHSession] = [:]
    @Published public var selectedSessionID: UUID?
    @Published public var sessionStates: [UUID: SSHSessionState] = [:]
    @Published public var isBusy = false
    @Published public var statusMessage = ""

    public let store = SSHProfileStore()
    private let sleepWake: SleepWakeCoordinator
    private var cancellables = Set<AnyCancellable>()

    public init(sleepWake: SleepWakeCoordinator) {
        self.sleepWake = sleepWake
        profiles = store.load()
        bindSleepWake()
    }

    // MARK: - Profile management

    public func addProfile(_ profile: SSHProfile, password: String?, passphrase: String?) {
        if let pwd = password, !pwd.isEmpty { try? store.setPassword(pwd, for: profile) }
        if let pp = passphrase, !pp.isEmpty { try? store.setPassphrase(pp, for: profile) }
        profiles.append(profile)
        store.save(profiles)
    }

    public func deleteProfile(at offsets: IndexSet) {
        for idx in offsets {
            let p = profiles[idx]
            store.deleteSecrets(for: p)
            sessions.removeValue(forKey: p.id)
            sessionStates.removeValue(forKey: p.id)
        }
        profiles = profiles.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        store.save(profiles)
    }

    // MARK: - Session management

    public func openSession(for profile: SSHProfile) {
        if sessions[profile.id] != nil {
            selectedSessionID = profile.id
            return
        }
        let session = SSHSession(profile: profile, store: store)
        sessions[profile.id] = session
        selectedSessionID = profile.id
        connect(session: session, profileID: profile.id)
    }

    public func closeSession(id: UUID) {
        guard let session = sessions[id] else { return }
        Task { await session.disconnect() }
        sessions.removeValue(forKey: id)
        sessionStates.removeValue(forKey: id)
        if selectedSessionID == id { selectedSessionID = sessions.keys.first }
    }

    private func connect(session: SSHSession, profileID: UUID) {
        sessionStates[profileID] = .connecting
        isBusy = true
        Task {
            do {
                try await session.connect()
                self.sessionStates[profileID] = .connected
                self.statusMessage = "Đã kết nối."
            } catch {
                self.sessionStates[profileID] = .disconnected
                self.statusMessage = "Lỗi: \(error)"
            }
            self.isBusy = false
        }
    }

    // MARK: - SSH-09: Sleep/wake reconnect

    private func bindSleepWake() {
        sleepWake.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                if case .didWake = event { self?.reconnectAll() }
            }
            .store(in: &cancellables)
    }

    private func reconnectAll() {
        for (id, session) in sessions {
            guard sessionStates[id] == .connected else { continue }
            sessionStates[id] = .reconnecting
            Task {
                await session.disconnect()
                do {
                    try await session.connect()
                    self.sessionStates[id] = .connected
                } catch {
                    self.sessionStates[id] = .disconnected
                    self.statusMessage = "Reconnect thất bại: \(error)"
                }
            }
        }
    }

    // MARK: - Exec helper

    public func exec(_ command: String, sessionID: UUID) async throws -> String {
        guard let session = sessions[sessionID] else { throw SSHSessionError.notConnected }
        return try await session.exec(command)
    }

    // MARK: - SFTP (kéo-thả / duyệt file)

    public func listRemote(_ sessionID: UUID, path: String) async throws -> [String] {
        guard let s = sessions[sessionID] else { throw SSHSessionError.notConnected }
        return try await s.listDirectory(path).sorted()
    }

    public func upload(_ sessionID: UUID, localURL: URL, toDir: String) async throws {
        guard let s = sessions[sessionID] else { throw SSHSessionError.notConnected }
        let remote = (toDir.hasSuffix("/") ? toDir : toDir + "/") + localURL.lastPathComponent
        try await s.uploadFile(localURL: localURL, remotePath: remote)
    }

    public func download(_ sessionID: UUID, remotePath: String, toLocal: URL) async throws {
        guard let s = sessions[sessionID] else { throw SSHSessionError.notConnected }
        try await s.downloadFile(remotePath: remotePath, localURL: toLocal)
    }

    // MARK: - Server monitor (như MobaXterm)

    public struct ServerStats: Sendable {
        public var cpuPercent: Double?     // 0...100
        public var memUsed: Double?        // MB
        public var memTotal: Double?       // MB
        public var diskPercent: Double?    // 0...100 của /
        public var uptime: String
        public var raw: String
    }

    /// Chạy 1 lệnh tổng hợp lấy CPU/RAM/disk/uptime (Linux). Parse sơ bộ.
    public func serverStats(_ sessionID: UUID) async -> ServerStats? {
        let cmd = """
        echo '#CPU'; top -bn1 2>/dev/null | grep -i '%Cpu' | head -1; \
        echo '#MEM'; free -m 2>/dev/null | grep -i '^Mem'; \
        echo '#DISK'; df -P / 2>/dev/null | tail -1; \
        echo '#UP'; uptime 2>/dev/null
        """
        guard let out = try? await exec(cmd, sessionID: sessionID) else { return nil }
        return Self.parseStats(out)
    }

    static func parseStats(_ out: String) -> ServerStats {
        var s = ServerStats(cpuPercent: nil, memUsed: nil, memTotal: nil,
                            diskPercent: nil, uptime: "", raw: out)
        let lines = out.components(separatedBy: "\n")
        var section = ""
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") { section = t; continue }
            if t.isEmpty { continue }
            switch section {
            case "#CPU":
                // "%Cpu(s):  3.2 us,  1.0 sy, ... 95.0 id, ..."
                if let idRange = t.range(of: #"([0-9.]+)\s*id"#, options: .regularExpression) {
                    let idStr = t[idRange].replacingOccurrences(of: "id", with: "").trimmingCharacters(in: .whitespaces)
                    if let idle = Double(idStr) { s.cpuPercent = max(0, 100 - idle) }
                }
            case "#MEM":
                let cols = t.split(separator: " ").compactMap { Double($0) }
                if cols.count >= 2 { s.memTotal = cols[0]; s.memUsed = cols[1] }
            case "#DISK":
                // "/dev/... 100G 40G 60G 40% /"
                if let pctRange = t.range(of: #"([0-9]+)%"#, options: .regularExpression) {
                    let pct = t[pctRange].replacingOccurrences(of: "%", with: "")
                    s.diskPercent = Double(pct)
                }
            case "#UP":
                s.uptime = t
            default: break
            }
        }
        return s
    }
}
