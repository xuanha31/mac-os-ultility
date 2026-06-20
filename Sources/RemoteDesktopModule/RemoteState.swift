import Foundation
import Core

// RD-03: Quản lý nhiều phiên remote (VNC/RDP) + profile. Mô phỏng SSHState.

@MainActor
public final class RemoteState: ObservableObject {
    @Published public var profiles: [RemoteProfile] = []
    @Published public var sessions: [UUID: any RemoteSession] = [:]
    @Published public var selectedSessionID: UUID?
    @Published public var sessionStates: [UUID: RemoteSessionState] = [:]
    @Published public var statusMessage = ""
    /// Các phiên đang hiển thị ở cửa sổ tách riêng (embedded area hiện placeholder).
    @Published public var detachedSessionIDs: Set<UUID> = []

    public let store = RemoteProfileStore()

    public init() {
        profiles = store.load()
    }

    // MARK: - Profile

    public func addProfile(_ profile: RemoteProfile, password: String?) {
        if let pwd = password, !pwd.isEmpty { try? store.setPassword(pwd, for: profile) }
        profiles.append(profile)
        store.save(profiles)
    }

    /// Sửa profile (giữ nguyên id). password == nil/"" → giữ mật khẩu cũ trong Keychain.
    public func updateProfile(_ profile: RemoteProfile, password: String?) {
        if let pwd = password, !pwd.isEmpty { try? store.setPassword(pwd, for: profile) }
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        store.save(profiles)
    }

    public func deleteProfile(at offsets: IndexSet) {
        for idx in offsets {
            let p = profiles[idx]
            store.deleteSecrets(for: p)
            closeSession(id: p.id)
        }
        profiles = profiles.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        store.save(profiles)
    }

    // MARK: - Session

    public func openSession(for profile: RemoteProfile) {
        if sessions[profile.id] != nil {
            selectedSessionID = profile.id
            return
        }
        let session = makeSession(for: profile)
        session.onStateChange = { [weak self] newState in
            // Phiên có thể đổi state từ thread nền → đưa về main.
            Task { @MainActor in self?.sessionStates[profile.id] = newState }
        }
        sessions[profile.id] = session
        sessionStates[profile.id] = .connecting
        selectedSessionID = profile.id
        session.connect()
    }

    public func closeSession(id: UUID) {
        sessions[id]?.disconnect()
        sessions.removeValue(forKey: id)
        sessionStates.removeValue(forKey: id)
        detachedSessionIDs.remove(id)
        if selectedSessionID == id { selectedSessionID = sessions.keys.first }
    }

    public func session(_ id: UUID) -> (any RemoteSession)? { sessions[id] }

    public func setDetached(_ id: UUID, _ on: Bool) {
        if on { detachedSessionIDs.insert(id) } else { detachedSessionIDs.remove(id) }
    }

    /// Tạo phiên đúng loại. Phase 1/2 thay placeholder bằng VNCSession/RDPSession.
    private func makeSession(for profile: RemoteProfile) -> any RemoteSession {
        switch profile.kind {
        case .vnc:
            return VNCSession(profile: profile, store: store)
        case .rdp:
            #if HAS_FREERDP
            return RDPSession(profile: profile, store: store)
            #else
            return PlaceholderSession(profile: profile,
                                      message: "RDP cần FreeRDP — cài bằng: brew install freerdp")
            #endif
        }
    }
}
