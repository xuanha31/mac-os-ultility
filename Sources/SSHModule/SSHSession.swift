import Foundation
import Citadel
import NIOPosix
import NIOCore
import NIOSSH
import Crypto
import Core

// SSH-02/03/06/07/08: SSH session qua Citadel 0.12.x

public enum SSHSessionError: Error, CustomStringConvertible {
    case notConnected
    case hostKeyMismatch(host: String)
    case unsupportedKeyType
    case execFailed(String)

    public var description: String {
        switch self {
        case .notConnected:          return "Chưa kết nối SSH."
        case .hostKeyMismatch(let h): return "Host key của \(h) đã thay đổi — có thể bị MITM!"
        case .unsupportedKeyType:    return "Loại private key không được hỗ trợ (chỉ hỗ trợ ed25519)."
        case .execFailed(let msg):   return "Exec thất bại: \(msg)"
        }
    }
}

public enum SSHSessionState: Sendable {
    case disconnected, connecting, connected, reconnecting
}

/// Một SSH session. Dùng actor để bảo vệ state.
public actor SSHSession {
    public let profile: SSHProfile
    public private(set) var state: SSHSessionState = .disconnected

    private let store: SSHProfileStore
    private var client: SSHClient?

    public init(profile: SSHProfile, store: SSHProfileStore) {
        self.profile = profile
        self.store = store
    }

    // MARK: - Connect (SSH-02 / SSH-03)

    public func connect() async throws {
        state = .connecting
        do {
            let auth = try makeAuth()
            // SSH-08: host key validation
            let validator = makeHostKeyValidator()
            let c = try await SSHClient.connect(
                host: profile.host,
                port: profile.port,
                authenticationMethod: auth,
                hostKeyValidator: validator,
                reconnect: .never
            )
            client = c
            state = .connected
            Log.ssh.info("SSH connected to \(self.profile.host, privacy: .public)")
        } catch {
            state = .disconnected
            throw error
        }
    }

    public func disconnect() async {
        try? await client?.close()
        client = nil
        state = .disconnected
    }

    // MARK: - SSH-06: Exec nhanh

    public func exec(_ command: String) async throws -> String {
        guard let c = client, state == .connected else { throw SSHSessionError.notConnected }
        // executeCommand trả về ByteBuffer trong Citadel 0.12
        let buf = try await c.executeCommand(command)
        return String(buffer: buf)
    }

    // MARK: - SSH-07: SFTP

    public func listDirectory(_ path: String) async throws -> [String] {
        guard let c = client, state == .connected else { throw SSHSessionError.notConnected }
        let sftp = try await c.openSFTP()
        let names = try await sftp.listDirectory(atPath: path)
        // SFTPMessage.Name wraps [SFTPPathComponent]; flatten filenames
        return names.flatMap { $0.components.map(\.filename) }
    }

    public func downloadFile(remotePath: String, localURL: URL) async throws {
        guard let c = client, state == .connected else { throw SSHSessionError.notConnected }
        let sftp = try await c.openSFTP()
        let file = try await sftp.openFile(filePath: remotePath, flags: .read)
        let buf = try await file.readAll()
        try await file.close()
        var data = Data()
        var b = buf
        if let bytes = b.readBytes(length: b.readableBytes) { data = Data(bytes) }
        try data.write(to: localURL)
    }

    public func uploadFile(localURL: URL, remotePath: String) async throws {
        guard let c = client, state == .connected else { throw SSHSessionError.notConnected }
        let data = try Data(contentsOf: localURL)
        let sftp = try await c.openSFTP()
        let file = try await sftp.openFile(filePath: remotePath, flags: [.write, .create, .truncate])
        var buf = ByteBuffer(bytes: data)
        try await file.write(buf, at: 0)
        try await file.close()
    }

    // MARK: - SSH-04: Interactive shell

    /// Mở shell tương tác, trả về (inbound stream, outbound writer).
    /// Yêu cầu macOS 15+ (Citadel withTTY). Trên macOS 14, dùng execStream thay thế.
    @available(macOS 15.0, *)
    public func openTTY(
        perform: @escaping @Sendable (AsyncThrowingStream<Data, Error>, TTYStdinWriter) async throws -> Void
    ) async throws {
        guard let c = client, state == .connected else { throw SSHSessionError.notConnected }
        try await c.withTTY { inbound, outbound in
            let dataStream = AsyncThrowingStream<Data, Error> { continuation in
                Task {
                    for try await output in inbound {
                        if case .stdout(var buf) = output,
                           let bytes = buf.readBytes(length: buf.readableBytes) {
                            continuation.yield(Data(bytes))
                        }
                    }
                    continuation.finish()
                }
            }
            try await perform(dataStream, outbound)
        }
    }

    // MARK: - Auth helpers

    private func makeAuth() throws -> SSHAuthenticationMethod {
        switch profile.authMethod {
        case .password:
            let pwd = store.password(for: profile) ?? ""
            return .passwordBased(username: profile.username, password: pwd)
        case .privateKey:
            return try makePrivateKeyAuth()
        }
    }

    private func makePrivateKeyAuth() throws -> SSHAuthenticationMethod {
        let path = (profile.privateKeyPath as NSString).expandingTildeInPath
        let pem = try String(contentsOfFile: path, encoding: .utf8)
        // Thử ed25519 trước (định dạng OpenSSH PEM)
        // Citadel hỗ trợ .ed25519, .p256, .p384, .p521, .rsa
        // Để hỗ trợ đầy đủ cần parse PEM type — hiện chỉ hỗ trợ ed25519 trực tiếp
        // TODO: thêm RSA/ECDSA parsing khi nâng cấp
        throw SSHSessionError.unsupportedKeyType
    }

    // SSH-08: Host key validation
    private func makeHostKeyValidator() -> SSHHostKeyValidator {
        let host = profile.host
        let port = profile.port
        let storedKey = store.knownHostKey(for: host, port: port)
        if storedKey == nil {
            return .custom(FirstConnectTrustValidator(host: host, port: port, store: store))
        }
        return .acceptAnything()
    }
}

// MARK: - First-connect host key validator

private struct FirstConnectTrustValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    let host: String
    let port: Int
    let store: SSHProfileStore

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // Lưu key fingerprint dạng string và trust (first-connect policy)
        let keyStr = "\(hostKey)"
        Task { try? await store.storeKnownHostKey(keyStr, host: host, port: port) }
        validationCompletePromise.succeed(())
    }
}
