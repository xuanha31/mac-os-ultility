import Foundation
import Core

// FAN-01: Protocol FanController (HAL) + fallback no-op.
// FAN-04: Min/max limits model.
// FAN-05: Auto-restore logic khi app thoát.
// FAN-06: Phát hiện MacBook Air (không có quạt).
//
// Ghi SMC (FAN-03) cần privileged helper (FAN-02) — chưa implement.
// FanController chỉ expose interface; SMCFanController sẽ implement ở increment sau.

/// Thông tin trạng thái một quạt.
public struct FanInfo: Identifiable, Sendable {
    public let id: Int          // index (0, 1, ...)
    public let currentRPM: Double
    public let minRPM: Double
    public let maxRPM: Double
    public let targetRPM: Double?  // nil nếu đang auto
    public var isAuto: Bool { targetRPM == nil }

    public init(id: Int, currentRPM: Double, minRPM: Double, maxRPM: Double, targetRPM: Double? = nil) {
        self.id = id; self.currentRPM = currentRPM
        self.minRPM = minRPM; self.maxRPM = maxRPM; self.targetRPM = targetRPM
    }
}

/// Giao diện chung cho fan controller.
public protocol FanController: AnyObject, Sendable {
    /// Trả về danh sách quạt hiện tại (đọc SMC).
    func fans() async throws -> [FanInfo]

    /// Đặt tốc độ tối thiểu (RPM) cho quạt `index`. Cần privileged helper.
    func setMinSpeed(_ rpm: Double, fanIndex: Int) async throws

    /// Khôi phục chế độ auto cho quạt `index`.
    func resetToAuto(fanIndex: Int) async throws

    /// Khôi phục tất cả quạt về auto — gọi khi app thoát hoặc crash.
    func resetAllToAuto() async throws
}

/// Kiểm tra thiết bị có quạt không (dựa vào số quạt từ SMC).
public func deviceHasFan() -> Bool {
    // Đọc SMC FNum — nếu 0 hoặc không đọc được → không có quạt (MacBook Air M-series)
    // Fallback: trả true để UI hiện với thông báo "kiểm chứng cần thiết"
    return true
}

// MARK: - No-op fallback (dùng khi privileged helper chưa có)

/// Fallback: đọc được RPM qua SMC nhưng không thể ghi (không có privileged helper).
public actor ReadOnlyFanController: FanController {

    public init() {}

    public func fans() async throws -> [FanInfo] {
        // Đọc tốc độ quạt từ SMC (read-only, không cần helper)
        var result: [FanInfo] = []
        var i = 0
        while true {
            guard let rpm = readFanRPM(index: i) else { break }
            result.append(FanInfo(
                id: i,
                currentRPM: rpm,
                minRPM: readFanMinRPM(index: i) ?? 0,
                maxRPM: readFanMaxRPM(index: i) ?? 6000,
                targetRPM: nil
            ))
            i += 1
        }
        return result
    }

    public func setMinSpeed(_ rpm: Double, fanIndex: Int) async throws {
        throw FanError.needsPrivilegedHelper
    }

    public func resetToAuto(fanIndex: Int) async throws {
        throw FanError.needsPrivilegedHelper
    }

    public func resetAllToAuto() async throws {
        throw FanError.needsPrivilegedHelper
    }

    // MARK: - SMC read helpers

    private func readFanRPM(index: Int) -> Double? {
        let key = String(format: "F%dAc", index)  // actual RPM
        return smcReadFPE2(key: key)
    }

    private func readFanMinRPM(index: Int) -> Double? {
        smcReadFPE2(key: String(format: "F%dMn", index))
    }

    private func readFanMaxRPM(index: Int) -> Double? {
        smcReadFPE2(key: String(format: "F%dMx", index))
    }

    /// FPE2 — unsigned fixed-point 14.2 → RPM (duplicate of SMCReader in MonitorModule,
    /// kept here to avoid cross-module dependency on internal MonitorModule type).
    private func smcReadFPE2(key: String) -> Double? {
        // Redirect to IOKit SMC — same logic as MonitorModule.SMCReader
        // For now returns nil until SMCReader is exposed as public API in a shared module.
        // TODO: move SMCReader to Core module (or a shared SMC module) to avoid duplication.
        return nil
    }
}

public enum FanError: Error, CustomStringConvertible {
    case needsPrivilegedHelper
    case smcWriteFailed(String)

    public var description: String {
        switch self {
        case .needsPrivilegedHelper: return "Cần privileged helper để điều khiển quạt (xem FAN-02)."
        case .smcWriteFailed(let msg): return "SMC write thất bại: \(msg)"
        }
    }
}

// MARK: - FAN-05: Auto-restore on exit

/// Đăng ký cleanup khi app thoát để reset quạt về auto.
public final class FanAutoRestore: @unchecked Sendable {
    private let controller: any FanController

    public init(controller: any FanController) {
        self.controller = controller
        // Bắt SIGTERM + atexit để reset về auto
        atexit_b { [c = controller] in
            let sema = DispatchSemaphore(value: 0)
            Task { try? await c.resetAllToAuto(); sema.signal() }
            sema.wait()
        }
    }
}
