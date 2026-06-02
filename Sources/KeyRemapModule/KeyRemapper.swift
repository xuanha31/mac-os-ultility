import Foundation
import Core

/// Đổi phím modifier qua `hidutil` (IOKit HID remapping) — phương án nhẹ,
/// không cần quyền Accessibility. (xem docs/features/06-key-remap.md)
///
/// Lưu ý: `hidutil --set` chỉ áp dụng cho phiên đăng nhập hiện tại; dùng
/// `LoginPersistence` để giữ sau reboot.
public struct KeyRemapper {

    /// Mã HID usage (page 0x07 — keyboard), dạng `0x700000000 | usageID`.
    public enum HIDKey: UInt64 {
        case leftCommand  = 0x7000000E3
        case rightCommand = 0x7000000E7
        case leftShift    = 0x7000000E1
        case rightShift   = 0x7000000E5
    }

    public enum KeyRemapError: Error, CustomStringConvertible {
        case commandFailed(status: Int32, output: String)

        public var description: String {
            switch self {
            case .commandFailed(let status, let output):
                return "hidutil thất bại (status \(status)): \(output)"
            }
        }
    }

    public init() {}

    /// Đổi Command ↔ Shift (cả trái lẫn phải).
    @discardableResult
    public func swapCommandShift() throws -> String {
        try run(json: KeyRemapper.swapCommandShiftJSON)
    }

    /// Khôi phục mặc định (xoá mọi remap).
    @discardableResult
    public func reset() throws -> String {
        try run(json: #"{"UserKeyMapping":[]}"#)
    }

    /// JSON dùng cho cả lệnh trực tiếp lẫn LaunchAgent.
    public static let swapCommandShiftJSON: String =
        buildMappingJSON([
            (.leftCommand, .leftShift),
            (.leftShift, .leftCommand),
            (.rightCommand, .rightShift),
            (.rightShift, .rightCommand)
        ])

    /// Tạo JSON UserKeyMapping từ danh sách (src → dst).
    public static func buildMappingJSON(_ pairs: [(HIDKey, HIDKey)]) -> String {
        let entries = pairs.map { src, dst in
            "{\"HIDKeyboardModifierMappingSrc\":\(src.rawValue),\"HIDKeyboardModifierMappingDst\":\(dst.rawValue)}"
        }.joined(separator: ",")
        return "{\"UserKeyMapping\":[\(entries)]}"
    }

    @discardableResult
    private func run(json: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property", "--set", json]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)

        guard process.terminationStatus == 0 else {
            Log.keyRemap.error("hidutil failed: \(output, privacy: .public)")
            throw KeyRemapError.commandFailed(status: process.terminationStatus, output: output)
        }
        return output
    }
}
