import Foundation
import Core

/// Đổi phím qua `hidutil` (IOKit HID remapping) — phương án nhẹ,
/// không cần quyền Accessibility. (xem docs/features/06-key-remap.md)
///
/// Lưu ý: `hidutil --set` chỉ áp dụng cho phiên đăng nhập hiện tại; dùng
/// `LoginPersistence` để giữ sau reboot.
public struct KeyRemapper {

    /// Nhóm phím để hiển thị (tiêu đề Section trong Picker).
    public enum KeyCategory: String, CaseIterable, Hashable, Identifiable {
        case modifier      = "Phím chức năng (Modifier)"
        case international  = "Quốc tế / Nhật"
        case letter        = "Chữ cái"
        case number        = "Số"
        case punctuation   = "Dấu câu"
        case control       = "Điều khiển"
        case function      = "Phím F"
        case navigation    = "Điều hướng"
        case keypad        = "Bàn phím số (Keypad)"

        public var id: String { rawValue }
    }

    /// Một phím trên HID keyboard usage page (0x07), kèm metadata để hiển thị
    /// và để "bắt phím khi bấm".
    ///
    /// - `usage`     : mã HID dạng `0x700000000 | usageID` (fn dùng page riêng).
    /// - `macVirtualKeyCode`: macOS virtual keycode (kVK_*) để nhận diện khi
    ///   người dùng bấm phím; `nil` nếu phím không có keycode trên máy thật.
    public struct HIDKey: Identifiable, Hashable, CustomStringConvertible {
        public let usage: UInt64
        public let macVirtualKeyCode: UInt16?
        public let category: KeyCategory
        public let label: String

        public var id: UInt64 { usage }
        /// Giữ tên `rawValue` để tương thích code/test cũ (== `usage`).
        public var rawValue: UInt64 { usage }
        public var description: String { label }

        public init(_ usage: UInt64, _ vk: UInt16?, _ category: KeyCategory, _ label: String) {
            self.usage = usage
            self.macVirtualKeyCode = vk
            self.category = category
            self.label = label
        }

        public static func == (lhs: HIDKey, rhs: HIDKey) -> Bool { lhs.usage == rhs.usage }
        public func hash(into hasher: inout Hasher) { hasher.combine(usage) }

        // MARK: Modifier (giữ nguyên raw value — test phụ thuộc)
        public static let leftCommand  = HIDKey(0x7000000E3, 0x37, .modifier, "Command (trái)")
        public static let rightCommand = HIDKey(0x7000000E7, 0x36, .modifier, "Command (phải)")
        public static let leftShift    = HIDKey(0x7000000E1, 0x38, .modifier, "Shift (trái)")
        public static let rightShift   = HIDKey(0x7000000E5, 0x3C, .modifier, "Shift (phải)")
        public static let leftControl  = HIDKey(0x7000000E0, 0x3B, .modifier, "Control (trái)")
        public static let rightControl = HIDKey(0x7000000E4, 0x3E, .modifier, "Control (phải)")
        public static let leftOption   = HIDKey(0x7000000E2, 0x3A, .modifier, "Option (trái)")
        public static let rightOption  = HIDKey(0x7000000E6, 0x3D, .modifier, "Option (phải)")
        public static let capsLock     = HIDKey(0x700000039, 0x39, .modifier, "Caps Lock")
        public static let fn           = HIDKey(0xFF0000003, 0x3F, .modifier, "Fn")

        static let modifiers: [HIDKey] = [
            .leftCommand, .rightCommand, .leftShift, .rightShift,
            .leftControl, .rightControl, .leftOption, .rightOption,
            .capsLock, .fn
        ]

        // MARK: Quốc tế / Nhật (JIS)
        // [Unverified] mã HID lấy từ USB HID Usage Tables; tính năng "bấm để
        // chọn" là cách xác nhận chắc chắn trên máy thật.
        static let international: [HIDKey] = [
            HIDKey(0x700000091, 0x66, .international, "英数 Eisu (LANG2)"),
            HIDKey(0x700000090, 0x68, .international, "かな Kana (LANG1)"),
            HIDKey(0x700000089, 0x5D, .international, "¥ Yen (International3)"),
            HIDKey(0x700000087, 0x5E, .international, "ろ / _ (International1)"),
            HIDKey(0x70000008A, nil,  .international, "変換 Henkan (International4)"),
            HIDKey(0x70000008B, nil,  .international, "無変換 Muhenkan (International5)"),
            HIDKey(0x700000088, nil,  .international, "かたかな (International2)")
        ]

        // MARK: Chữ cái A–Z
        static let letters: [HIDKey] = [
            HIDKey(0x700000004, 0x00, .letter, "A"), HIDKey(0x700000005, 0x0B, .letter, "B"),
            HIDKey(0x700000006, 0x08, .letter, "C"), HIDKey(0x700000007, 0x02, .letter, "D"),
            HIDKey(0x700000008, 0x0E, .letter, "E"), HIDKey(0x700000009, 0x03, .letter, "F"),
            HIDKey(0x70000000A, 0x05, .letter, "G"), HIDKey(0x70000000B, 0x04, .letter, "H"),
            HIDKey(0x70000000C, 0x22, .letter, "I"), HIDKey(0x70000000D, 0x26, .letter, "J"),
            HIDKey(0x70000000E, 0x28, .letter, "K"), HIDKey(0x70000000F, 0x25, .letter, "L"),
            HIDKey(0x700000010, 0x2E, .letter, "M"), HIDKey(0x700000011, 0x2D, .letter, "N"),
            HIDKey(0x700000012, 0x1F, .letter, "O"), HIDKey(0x700000013, 0x23, .letter, "P"),
            HIDKey(0x700000014, 0x0C, .letter, "Q"), HIDKey(0x700000015, 0x0F, .letter, "R"),
            HIDKey(0x700000016, 0x01, .letter, "S"), HIDKey(0x700000017, 0x11, .letter, "T"),
            HIDKey(0x700000018, 0x20, .letter, "U"), HIDKey(0x700000019, 0x09, .letter, "V"),
            HIDKey(0x70000001A, 0x0D, .letter, "W"), HIDKey(0x70000001B, 0x07, .letter, "X"),
            HIDKey(0x70000001C, 0x10, .letter, "Y"), HIDKey(0x70000001D, 0x06, .letter, "Z")
        ]

        // MARK: Số 1–0
        static let numbers: [HIDKey] = [
            HIDKey(0x70000001E, 0x12, .number, "1"), HIDKey(0x70000001F, 0x13, .number, "2"),
            HIDKey(0x700000020, 0x14, .number, "3"), HIDKey(0x700000021, 0x15, .number, "4"),
            HIDKey(0x700000022, 0x17, .number, "5"), HIDKey(0x700000023, 0x16, .number, "6"),
            HIDKey(0x700000024, 0x1A, .number, "7"), HIDKey(0x700000025, 0x1C, .number, "8"),
            HIDKey(0x700000026, 0x19, .number, "9"), HIDKey(0x700000027, 0x1D, .number, "0")
        ]

        // MARK: Dấu câu
        static let punctuation: [HIDKey] = [
            HIDKey(0x70000002D, 0x1B, .punctuation, "- (gạch ngang)"),
            HIDKey(0x70000002E, 0x18, .punctuation, "= (bằng)"),
            HIDKey(0x70000002F, 0x21, .punctuation, "[ (ngoặc vuông trái)"),
            HIDKey(0x700000030, 0x1E, .punctuation, "] (ngoặc vuông phải)"),
            HIDKey(0x700000031, 0x2A, .punctuation, "\\ (gạch chéo ngược)"),
            HIDKey(0x700000033, 0x29, .punctuation, "; (chấm phẩy)"),
            HIDKey(0x700000034, 0x27, .punctuation, "' (nháy đơn)"),
            HIDKey(0x700000035, 0x32, .punctuation, "` (huyền)"),
            HIDKey(0x700000036, 0x2B, .punctuation, ", (phẩy)"),
            HIDKey(0x700000037, 0x2F, .punctuation, ". (chấm)"),
            HIDKey(0x700000038, 0x2C, .punctuation, "/ (gạch chéo)")
        ]

        // MARK: Điều khiển
        static let controls: [HIDKey] = [
            HIDKey(0x700000028, 0x24, .control, "Return / Enter"),
            HIDKey(0x700000029, 0x35, .control, "Esc"),
            HIDKey(0x70000002A, 0x33, .control, "Delete (xoá lùi)"),
            HIDKey(0x70000002B, 0x30, .control, "Tab"),
            HIDKey(0x70000002C, 0x31, .control, "Space")
        ]

        // MARK: Phím F1–F19
        static let functionKeys: [HIDKey] = [
            HIDKey(0x70000003A, 0x7A, .function, "F1"),  HIDKey(0x70000003B, 0x78, .function, "F2"),
            HIDKey(0x70000003C, 0x63, .function, "F3"),  HIDKey(0x70000003D, 0x76, .function, "F4"),
            HIDKey(0x70000003E, 0x60, .function, "F5"),  HIDKey(0x70000003F, 0x61, .function, "F6"),
            HIDKey(0x700000040, 0x62, .function, "F7"),  HIDKey(0x700000041, 0x64, .function, "F8"),
            HIDKey(0x700000042, 0x65, .function, "F9"),  HIDKey(0x700000043, 0x6D, .function, "F10"),
            HIDKey(0x700000044, 0x67, .function, "F11"), HIDKey(0x700000045, 0x6F, .function, "F12"),
            HIDKey(0x700000068, 0x69, .function, "F13"), HIDKey(0x700000069, 0x6B, .function, "F14"),
            HIDKey(0x70000006A, 0x71, .function, "F15"), HIDKey(0x70000006B, 0x6A, .function, "F16"),
            HIDKey(0x70000006C, 0x40, .function, "F17"), HIDKey(0x70000006D, 0x4F, .function, "F18"),
            HIDKey(0x70000006E, 0x50, .function, "F19")
        ]

        // MARK: Điều hướng
        static let navigation: [HIDKey] = [
            HIDKey(0x700000049, 0x72, .navigation, "Help / Insert"),
            HIDKey(0x70000004A, 0x73, .navigation, "Home"),
            HIDKey(0x70000004B, 0x74, .navigation, "Page Up"),
            HIDKey(0x70000004C, 0x75, .navigation, "Forward Delete (⌦)"),
            HIDKey(0x70000004D, 0x77, .navigation, "End"),
            HIDKey(0x70000004E, 0x79, .navigation, "Page Down"),
            HIDKey(0x70000004F, 0x7C, .navigation, "→ Phải"),
            HIDKey(0x700000050, 0x7B, .navigation, "← Trái"),
            HIDKey(0x700000051, 0x7D, .navigation, "↓ Xuống"),
            HIDKey(0x700000052, 0x7E, .navigation, "↑ Lên")
        ]

        // MARK: Keypad
        static let keypad: [HIDKey] = [
            HIDKey(0x700000054, 0x4B, .keypad, "Keypad /"),
            HIDKey(0x700000055, 0x43, .keypad, "Keypad *"),
            HIDKey(0x700000056, 0x4E, .keypad, "Keypad -"),
            HIDKey(0x700000057, 0x45, .keypad, "Keypad +"),
            HIDKey(0x700000058, 0x4C, .keypad, "Keypad Enter"),
            HIDKey(0x700000059, 0x53, .keypad, "Keypad 1"),
            HIDKey(0x70000005A, 0x54, .keypad, "Keypad 2"),
            HIDKey(0x70000005B, 0x55, .keypad, "Keypad 3"),
            HIDKey(0x70000005C, 0x56, .keypad, "Keypad 4"),
            HIDKey(0x70000005D, 0x57, .keypad, "Keypad 5"),
            HIDKey(0x70000005E, 0x58, .keypad, "Keypad 6"),
            HIDKey(0x70000005F, 0x59, .keypad, "Keypad 7"),
            HIDKey(0x700000060, 0x5B, .keypad, "Keypad 8"),
            HIDKey(0x700000061, 0x5C, .keypad, "Keypad 9"),
            HIDKey(0x700000062, 0x52, .keypad, "Keypad 0"),
            HIDKey(0x700000063, 0x41, .keypad, "Keypad ."),
            HIDKey(0x700000067, 0x51, .keypad, "Keypad =")
        ]

        /// Toàn bộ phím, theo thứ tự nhóm hiển thị.
        public static let all: [HIDKey] =
            modifiers + international + letters + numbers + punctuation
            + controls + functionKeys + navigation + keypad

        /// Các phím thuộc một nhóm (giữ thứ tự khai báo).
        public static func keys(in category: KeyCategory) -> [HIDKey] {
            all.filter { $0.category == category }
        }

        /// Tra phím từ macOS virtual keycode (dùng cho "bắt phím khi bấm").
        public static func from(virtualKeyCode code: UInt16) -> HIDKey? {
            all.first { $0.macVirtualKeyCode == code }
        }
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

    /// Áp dụng danh sách remap tùy chỉnh.
    @discardableResult
    public func applyCustomMapping(_ pairs: [(HIDKey, HIDKey)]) throws -> String {
        try run(json: KeyRemapper.buildMappingJSON(pairs))
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
