import Foundation
import Core
import PrivilegedHelperClient

/// Giới hạn sạc qua khoá SMC `BCLM` (Intel) — đặt % sạc tối đa ở mức firmware.
/// Khi pin đạt BCLM, firmware tự ngừng sạc và máy chạy bằng adapter (pin giữ %).
///
/// - Đọc BCLM: quyền user bình thường.
/// - Ghi BCLM: BẮT BUỘC root → gọi privileged helper qua XPC.
///
/// ⚠️ [Unverified] BCLM không có tài liệu chính thức của Apple; đã xác minh tồn tại +
/// ghi được (với admin) trên máy Intel hiện tại, nhưng hành vi có thể khác theo model.
public struct BatteryChargeLimiter {
    private let helper = PrivilegedHelperClient()

    public enum LimitError: Error, CustomStringConvertible {
        case writeFailed(String)

        public var description: String {
            switch self {
            case .writeFailed(let m): return "Ghi BCLM thất bại: \(m)"
            }
        }
    }

    public init() {}

    /// Máy có khoá BCLM không (đọc được = hỗ trợ).
    public func isSupported() -> Bool { BatterySMC.readByte("BCLM") != nil }

    /// % sạc tối đa hiện tại trong firmware (100 = không giới hạn).
    public func currentLimit() -> Int? { BatterySMC.readByte("BCLM").map(Int.init) }

    /// Đặt % sạc tối đa (ghi BCLM bằng quyền admin). Ném lỗi nếu thất bại/huỷ.
    public func setMaxChargeLevel(_ percent: Int) throws {
        let clamped = min(100, max(20, percent))
        do { try helper.setMaxChargeLevel(clamped) }
        catch { throw LimitError.writeFailed("\(error)") }
        Log.core.info("BCLM set to \(clamped)")
    }

    /// Bỏ giới hạn: BCLM = 100.
    public func resetToDefault() throws { try setMaxChargeLevel(100) }
}
