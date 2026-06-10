import Foundation
import IOKit
import IOKit.ps

/// Ảnh chụp trạng thái pin tại một thời điểm (đọc qua IOKit Power Sources — không cần quyền).
public struct BatterySnapshot: Sendable, Equatable {
    public let percent: Int        // 0...100
    public let isCharging: Bool
    public let onACPower: Bool     // true = đang cắm adapter
    public let chargingWatts: Double?  // công suất đang NẠP vào pin (W); nil khi không sạc/không đọc được
    public let adapterWatts: Double?   // công suất tối đa adapter đang cắm (W); nil khi không có
}

/// Đọc % pin + trạng thái sạc qua `IOPSCopyPowerSourcesInfo`, và tốc độ sạc (W)
/// qua IORegistry `AppleSmartBattery`. Tất cả đều không cần quyền.
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
            let power = powerDetails()
            return BatterySnapshot(
                percent: percent,
                isCharging: isCharging,
                onACPower: onAC,
                // Gắn thẳng vào dòng nạp (amp > 0), KHÔNG dựa vào cờ isCharging của IOPS
                // vì cờ này có thể lệch. nil = không nạp → UI hiển thị 0 W.
                chargingWatts: power.charging,
                adapterWatts: power.adapter
            )
        }
        return nil
    }

    /// Đọc công suất nạp vào pin và công suất adapter từ `AppleSmartBattery`.
    /// - charging = Voltage(mV) × InstantAmperage(mA) (chỉ khi ampe > 0 = đang nạp).
    /// - adapter  = trường `Watts` trong `AdapterDetails` của nguồn đang cắm.
    private static func powerDetails() -> (charging: Double?, adapter: Double?) {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                              IOServiceMatching("AppleSmartBattery"))
        guard svc != IO_OBJECT_NULL else { return (nil, nil) }
        defer { IOObjectRelease(svc) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return (nil, nil) }

        var chargingW: Double?
        // InstantAmperage chính xác hơn; rơi về Amperage nếu thiếu. Dương = đang nạp.
        if let amp = (dict["InstantAmperage"] as? Int) ?? (dict["Amperage"] as? Int),
           let volt = dict["Voltage"] as? Int, amp > 0 {
            chargingW = Double(amp) / 1000.0 * Double(volt) / 1000.0
        }

        var adapterW: Double?
        if let adapter = dict["AdapterDetails"] as? [String: Any],
           let watts = adapter["Watts"] as? Int, watts > 0 {
            adapterW = Double(watts)
        }
        return (chargingW, adapterW)
    }
}
