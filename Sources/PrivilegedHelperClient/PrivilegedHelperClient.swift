import Foundation
import PrivilegedHelperProtocol
import ServiceManagement

public struct PrivilegedHelperClient {
    public enum HelperError: Error, CustomStringConvertible {
        case appBundleRequired
        case daemonPlistMissing(String)
        case commandFailed(String)
        case unavailable(String)

        public var description: String {
            switch self {
            case .appBundleRequired:
                return "Cần chạy MacUtil dưới dạng .app để đăng ký privileged helper."
            case .daemonPlistMissing(let path):
                return "Không tìm thấy LaunchDaemon plist trong app: \(path)"
            case .commandFailed(let message):
                return message
            case .unavailable(let message):
                return "Privileged helper không sẵn sàng: \(message)"
            }
        }
    }

    public init() {}

    public func setHibernateMode(_ mode: Int) throws {
        try call { proxy, reply in
            proxy.setHibernateMode(Int32(mode), withReply: reply)
        }
    }

    public func setMaxChargeLevel(_ percent: Int) throws {
        try call { proxy, reply in
            proxy.setMaxChargeLevel(Int32(percent), withReply: reply)
        }
    }

    private func call(
        _ body: @escaping (MacUtilPrivilegedHelperProtocol, @escaping (Bool, String) -> Void) -> Void
    ) throws {
        do {
            try perform(body)
        } catch HelperError.unavailable {
            try registerDaemonIfNeeded()
            try perform(body)
        }
    }

    private func perform(
        _ body: @escaping (MacUtilPrivilegedHelperProtocol, @escaping (Bool, String) -> Void) -> Void
    ) throws {
        let connection = NSXPCConnection(
            machServiceName: MacUtilHelperConstants.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: MacUtilPrivilegedHelperProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Void, Error> = .failure(HelperError.unavailable("không nhận được phản hồi"))

        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            result = .failure(HelperError.unavailable(error.localizedDescription))
            semaphore.signal()
        } as? MacUtilPrivilegedHelperProtocol

        guard let proxy else {
            throw HelperError.unavailable("không tạo được XPC proxy")
        }

        body(proxy) { ok, message in
            result = ok ? .success(()) : .failure(HelperError.commandFailed(message))
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + 20) == .timedOut {
            throw HelperError.unavailable("timeout khi gọi helper")
        }
        try result.get()
    }

    private func registerDaemonIfNeeded() throws {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            throw HelperError.appBundleRequired
        }

        let plistURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons")
            .appendingPathComponent(MacUtilHelperConstants.daemonPlistName)
        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            throw HelperError.daemonPlistMissing(plistURL.path)
        }

        let service = SMAppService.daemon(plistName: MacUtilHelperConstants.daemonPlistName)
        if service.status != .enabled {
            try service.register()
        }
    }
}
