import Foundation
import IOKit.ps

/// Ảnh chụp trạng thái pin tại một thời điểm (đọc qua IOKit Power Sources — không cần quyền).
public struct BatterySnapshot: Sendable, Equatable {
    public let percent: Int        // 0...100
    public let isCharging: Bool
    public let onACPower: Bool     // true = đang cắm adapter
}

/// Đọc % pin + trạng thái sạc qua `IOPSCopyPowerSourcesInfo`.
public enum BatteryReader {

    public static func snapshot() -> BatterySnapshot? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for src in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue()
                    as? [String: Any] else { continue }

            let cur = desc[kIOPSCurrentCapacityKey as String] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey as String] as? Int ?? 100
            let isCharging = desc[kIOPSIsChargingKey as String] as? Bool ?? false
            let state = desc[kIOPSPowerSourceStateKey as String] as? String ?? ""

            let percent = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur
            let onAC = (state == (kIOPSACPowerValue as String))
            return BatterySnapshot(percent: percent, isCharging: isCharging, onACPower: onAC)
        }
        return nil
    }
}
