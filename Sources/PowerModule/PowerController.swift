import Foundation
import Core
import PrivilegedHelperClient
#if canImport(AppKit)
import AppKit
#endif

/// Quản lý nguồn: chống tự ngủ (caffeinate) + hibernate (ghi RAM ra đĩa).
/// Các thao tác đổi cấu hình pmset được chuyển qua privileged helper.
public struct PowerController {
    private let helper = PrivilegedHelperClient()

    public enum PowerError: Error, CustomStringConvertible {
        case commandFailed(status: Int32, output: String)

        public var description: String {
            switch self {
            case .commandFailed(let status, let output):
                return "Lệnh thất bại (status \(status)): \(output)"
            }
        }
    }

    public init() {}

    // MARK: - Chống tự ngủ (caffeinate)

    /// Khởi chạy `caffeinate -d -i -m -s -w <pid>` như tiến trình nền.
    /// - `-d` chặn ngủ màn hình, `-i` chặn ngủ idle, `-m` chặn ngủ đĩa, `-s` chặn ngủ hệ thống.
    /// - `-w <pid app>`: caffeinate TỰ THOÁT khi MacUtil chết (kể cả crash / force-kill),
    ///   tránh để lại tiến trình caffeinate mồ côi giữ assertion chống ngủ → hao pin.
    /// Giữ lại `Process` trả về; gọi `terminate()` để tắt chống ngủ chủ động.
    public func startCaffeinate() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-d", "-i", "-m", "-s",
                             "-w", String(ProcessInfo.processInfo.processIdentifier)]
        try process.run()
        Log.core.info("caffeinate started (pid \(process.processIdentifier))")
        return process
    }

    // MARK: - Tạm dừng / chạy lại ứng dụng

    /// Gửi SIGSTOP cho mọi app người dùng (.regular), trừ chính MacUtil và Finder.
    /// Trả về danh sách pid đã dừng để sau này `resumeApps(_:)`.
    public func suspendAllApps() -> [pid_t] {
        var stopped: [pid_t] = []
        #if canImport(AppKit)
        let me = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  app.processIdentifier > 0,
                  app.processIdentifier != me,
                  app.bundleIdentifier != "com.apple.finder"
            else { continue }
            if kill(app.processIdentifier, SIGSTOP) == 0 {
                stopped.append(app.processIdentifier)
            }
        }
        Log.core.info("Suspended \(stopped.count) apps")
        #endif
        return stopped
    }

    /// Gửi SIGCONT để chạy lại các tiến trình đã tạm dừng.
    public func resumeApps(_ pids: [pid_t]) {
        for pid in pids { _ = kill(pid, SIGCONT) }
        if !pids.isEmpty { Log.core.info("Resumed \(pids.count) apps") }
    }

    // MARK: - Khoá màn hình + ngủ

    /// Khoá màn hình ngay (chuyển về cửa sổ đăng nhập).
    public func lockScreen() {
        let path = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
        guard FileManager.default.isExecutableFile(atPath: path) else {
            Log.core.error("CGSession không tồn tại — bỏ qua khoá màn hình")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-suspend"]
        try? process.run()
    }

    /// Đưa máy vào sleep ngay (không cần admin).
    public func sleepNow() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["sleepnow"]
        try? process.run()
    }

    // MARK: - hibernatemode (cần admin)

    /// Đọc hibernatemode hiện tại từ `pmset -g` (không cần admin).
    public func currentHibernateMode() -> Int? {
        guard let output = try? runPipe("/usr/bin/pmset", ["-g"]) else { return nil }
        for line in output.split(separator: "\n") where line.contains("hibernatemode") {
            if let last = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last,
               let value = Int(last) {
                return value
            }
        }
        return nil
    }

    /// Đặt hibernatemode (25 = hibernate thật: ghi RAM ra đĩa rồi tắt nguồn). Prompt admin.
    public func setHibernateMode(_ mode: Int) throws {
        try helper.setHibernateMode(mode)
    }

    /// Khôi phục hibernatemode về giá trị cũ. Prompt admin (best-effort).
    public func restoreHibernateMode(_ mode: Int) {
        _ = try? helper.setHibernateMode(mode)
    }

    // MARK: - pmset phụ trợ cho hibernate (tcpkeepalive, standbydelaylow…)

    /// Đọc giá trị một setting từ `pmset -g custom`, ưu tiên block "Battery Power"
    /// (batteryScope = true). Không cần admin. nil nếu không đọc được.
    public func currentPowerValue(_ key: String, batteryScope: Bool = true) -> Int? {
        guard let output = try? runPipe("/usr/bin/pmset", ["-g", "custom"]) else { return nil }
        var inTarget = false
        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)
            if line.contains("Battery Power") { inTarget = batteryScope; continue }
            if line.contains("AC Power")      { inTarget = !batteryScope; continue }
            guard inTarget else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, String(parts[0]) == key, let value = Int(parts[1]) {
                return value
            }
        }
        return nil
    }

    /// Đặt một giá trị pmset qua privileged helper (key/scope được whitelist phía helper).
    public func setPowerValue(_ key: String, value: Int, scope: String = "-b") throws {
        try helper.setPowerValue(key, value: value, scope: scope)
    }

    /// Khôi phục một giá trị pmset (best-effort, không ném lỗi).
    public func restorePowerValue(_ key: String, value: Int, scope: String = "-b") {
        _ = try? helper.setPowerValue(key, value: value, scope: scope)
    }

    // MARK: - Helpers

    /// Chạy tiến trình, gom stdout+stderr, ném lỗi nếu status != 0.
    @discardableResult
    private func runPipe(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw PowerError.commandFailed(status: process.terminationStatus, output: output)
        }
        return output
    }
}
