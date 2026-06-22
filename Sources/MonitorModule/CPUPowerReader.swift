import Foundation
import IOKit.pwr_mgt

// Đọc giới hạn tốc độ CPU (CPU_Speed_Limit) do power-management plugin phơi bày —
// cùng nguồn với `pmset -g therm`. 100 = không bị bóp; < 100 = CPU đang bị
// throttle (nhiệt cao / SMC kẹt / thiếu nguồn). Không cần quyền đặc biệt.
// Apple Silicon có thể trả nil (chỉ Intel/T2 mới có chỉ số này).
enum CPUPowerReader {

    /// % giới hạn tốc độ CPU (0...100). nil nếu máy không hỗ trợ.
    static func speedLimit() -> Int? {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyCPUPowerStatus(&unmanaged) == kIOReturnSuccess,
              let dict = unmanaged?.takeRetainedValue() as? [String: Any]
        else { return nil }
        // key "CPU_Speed_Limit" — xem kIOPMCPUPowerLimitProcessorSpeedKey trong IOPM.h
        guard let limit = dict["CPU_Speed_Limit"] as? Int else { return nil }
        return limit
    }
}
