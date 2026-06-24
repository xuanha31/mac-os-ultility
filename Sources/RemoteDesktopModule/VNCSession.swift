import Foundation
import AppKit
import Core
import RoyalVNCKit

// RD Phase 1: phiên VNC dùng RoyalVNCKit.
// - VNCCAFramebufferView (NSView sẵn có) render framebuffer + xử lý chuột/bàn phím.
// - Bật useDisplayLink → view tự render qua CVDisplayLink (không cần forward từng frame).
// - Delegate có thể bị gọi off-main → tách proxy NSObject riêng, hop về main cho UI.

@MainActor
final class VNCSession: RemoteSession {
    let id: UUID
    let profile: RemoteProfile
    var onStateChange: ((RemoteSessionState) -> Void)?

    private let username: String
    private let password: String
    private let container = NSView()

    private var connection: VNCConnection?
    private var framebufferView: VNCCAFramebufferView?
    private var proxy: VNCDelegateProxy?

    // Auto-reconnect khi rớt mạng (không khi user tự đóng).
    private var userClosed = false
    private var reconnectAttempt = 0
    private var reconnectWork: DispatchWorkItem?

    init(profile: RemoteProfile, store: RemoteProfileStore) {
        self.id = profile.id
        self.profile = profile
        self.username = profile.username
        self.password = store.password(for: profile) ?? ""
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
    }

    func makeView() -> NSView { container }

    func connect() {
        userClosed = false
        let settings = VNCConnection.Settings(
            isDebugLoggingEnabled: false,
            hostname: profile.host,
            port: UInt16(clamping: profile.port),
            isShared: true,
            isScalingEnabled: true,
            // Event-driven render: chỉ vẽ lại khi server gửi framebuffer update (qua
            // didUpdateFramebuffer), thay vì dựng lại CGImage ~60fps mỗi nhịp CVDisplayLink.
            // Tránh CPU cao liên tục khi màn hình remote đứng yên.
            useDisplayLink: false,
            inputMode: .forwardKeyboardShortcutsEvenIfInUseLocally,
            isClipboardRedirectionEnabled: true,
            colorDepth: .depth24Bit,
            frameEncodings: .default
        )

        let conn = VNCConnection(settings: settings)
        let proxy = VNCDelegateProxy(username: username, password: password)
        proxy.onState = { [weak self] st in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self else { return }
                switch st {
                case .connected:
                    self.reconnectAttempt = 0
                    self.onStateChange?(.connected)
                case .disconnected, .failed:
                    if self.userClosed { self.onStateChange?(st) } else { self.scheduleReconnect() }
                case .connecting:
                    self.onStateChange?(.connecting)
                }
            } }
        }
        proxy.onFramebuffer = { [weak self] fb, c in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.attachFramebuffer(fb, connection: c) } }
        }
        conn.delegate = proxy   // delegate là weak → phải giữ proxy & conn.
        connection = conn
        self.proxy = proxy

        onStateChange?(.connecting)
        conn.connect()
    }

    func disconnect() {
        userClosed = true                 // user chủ động đóng → không auto-reconnect
        reconnectWork?.cancel(); reconnectWork = nil
        connection?.disconnect()
        connection = nil
        proxy = nil
        framebufferView?.removeFromSuperview()
        framebufferView = nil
    }

    /// Kết nối lại sau khi rớt mạng, backoff tăng dần (tối đa 20s), thử tới khi có mạng/user đóng.
    private func scheduleReconnect() {
        guard !userClosed else { return }
        reconnectWork?.cancel()
        reconnectAttempt += 1
        let delay = min(Double(reconnectAttempt) * 2.0, 20.0)
        onStateChange?(.failed("Mất kết nối — tự kết nối lại sau \(Int(delay))s (lần \(reconnectAttempt))…"))
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.userClosed else { return }
            self.connect()   // tạo connection mới
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func attachFramebuffer(_ framebuffer: VNCFramebuffer, connection: VNCConnection) {
        framebufferView?.removeFromSuperview()

        let view = VNCCAFramebufferView(frame: container.bounds,
                                        framebuffer: framebuffer,
                                        connection: connection)
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        framebufferView = view
        proxy?.framebufferView = view
        container.window?.makeFirstResponder(view)
    }
}

/// Cầu nối VNCConnectionDelegate (có thể bị gọi off-main) → callback cho VNCSession.
/// NSObject vì VNCConnectionDelegate là @objc trên macOS.
final class VNCDelegateProxy: NSObject, VNCConnectionDelegate {
    var onState: ((RemoteSessionState) -> Void)?
    var onFramebuffer: ((VNCFramebuffer, VNCConnection) -> Void)?
    weak var framebufferView: VNCCAFramebufferView?

    private let username: String
    private let password: String

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func connection(_ connection: VNCConnection,
                    stateDidChange connectionState: VNCConnection.ConnectionState) {
        let st: RemoteSessionState
        switch connectionState.status {
        case .connecting, .disconnecting:
            st = .connecting
        case .connected:
            st = .connected
        case .disconnected:
            st = connectionState.error.map { .failed("\($0)") } ?? .disconnected
        }
        onState?(st)
    }

    func connection(_ connection: VNCConnection,
                    credentialFor authenticationType: VNCAuthenticationType,
                    completion: @escaping (VNCCredential?) -> Void) {
        if authenticationType.requiresUsername {
            completion(VNCUsernamePasswordCredential(username: username, password: password))
        } else if authenticationType.requiresPassword {
            completion(VNCPasswordCredential(password: password))
        } else {
            completion(nil)
        }
    }

    func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {
        onFramebuffer?(framebuffer, connection)
    }

    func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {
        onFramebuffer?(framebuffer, connection)
    }

    func connection(_ connection: VNCConnection,
                    didUpdateFramebuffer framebuffer: VNCFramebuffer,
                    x: UInt16, y: UInt16, width: UInt16, height: UInt16) {
        // useDisplayLink = false → đây là đường render chính: view chỉ vẽ lại khi có
        // update thật từ server (tiết kiệm CPU so với render 60fps qua CVDisplayLink).
        framebufferView?.connection(connection, didUpdateFramebuffer: framebuffer,
                                    x: x, y: y, width: width, height: height)
    }

    func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {
        framebufferView?.connection(connection, didUpdateCursor: cursor)
    }
}
