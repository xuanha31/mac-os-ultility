import Foundation
import Core
import IOKit

// FAN-01: FanController protocol (HAL)
// FAN-03: SMC write qua IOKit (ghi F#Mn → đặt min RPM; SMC tự điều chỉnh ở trên ngưỡng đó)
// FAN-04: Min/max limits
// FAN-05: Auto-restore khi app thoát

// MARK: - Public types

public struct FanInfo: Identifiable, Sendable {
    public let id: Int
    public let currentRPM: Double
    public let minRPM: Double
    public let maxRPM: Double
    public let targetRPM: Double?  // nil = auto mode
    public var isAuto: Bool { targetRPM == nil }

    public init(id: Int, currentRPM: Double, minRPM: Double, maxRPM: Double, targetRPM: Double? = nil) {
        self.id = id; self.currentRPM = currentRPM
        self.minRPM = minRPM; self.maxRPM = maxRPM; self.targetRPM = targetRPM
    }
}

public protocol FanController: AnyObject, Sendable {
    func fans() async throws -> [FanInfo]
    func setMinSpeed(_ rpm: Double, fanIndex: Int) async throws
    func resetToAuto(fanIndex: Int) async throws
    func resetAllToAuto() async throws
}

public enum FanError: Error, CustomStringConvertible {
    case needsPrivilegedHelper
    case smcWriteFailed(String)
    case smcUnavailable

    public var description: String {
        switch self {
        case .needsPrivilegedHelper: return "Cần quyền admin để điều khiển quạt."
        case .smcWriteFailed(let m): return "SMC write thất bại: \(m)"
        case .smcUnavailable:        return "SMC không khả dụng trên thiết bị này."
        }
    }
}

// MARK: - SMCFanController

/// Đọc/ghi SMC trực tiếp qua IOKit.
/// Đọc (F#Ac, F#Mn, F#Mx, FNum) không cần quyền đặc biệt.
/// Ghi F#Mn (min RPM) không cần root trên Intel Macs; trên Apple Silicon
/// thường bị từ chối → canWrite() trả false → UI chỉ đọc.
public actor SMCFanController: FanController {

    private var originalMins: [Int: Double] = [:]
    private var manualTargets: [Int: Double] = [:]

    public init() {}

    public func fans() async throws -> [FanInfo] {
        let count = smcReadUInt8("FNum") ?? 0
        guard count > 0 else { return [] }
        var result: [FanInfo] = []
        for i in 0..<Int(count) {
            guard let rpm = smcReadFPE2(String(format: "F%dAc", i)) else { continue }
            let minRPM = smcReadFPE2(String(format: "F%dMn", i)) ?? 0
            let maxRPM = smcReadFPE2(String(format: "F%dMx", i)) ?? 6000
            if originalMins[i] == nil { originalMins[i] = minRPM }
            result.append(FanInfo(
                id: i, currentRPM: rpm, minRPM: minRPM, maxRPM: maxRPM,
                targetRPM: manualTargets[i]
            ))
        }
        return result
    }

    public func setMinSpeed(_ rpm: Double, fanIndex: Int) async throws {
        let key = String(format: "F%dMn", fanIndex)
        guard smcWriteFPE2(key, rpm: rpm) else {
            throw FanError.smcWriteFailed("Ghi \(key) thất bại — thiết bị không cho phép hoặc cần quyền root.")
        }
        manualTargets[fanIndex] = rpm
    }

    public func resetToAuto(fanIndex: Int) async throws {
        let original = originalMins[fanIndex] ?? 1200
        let key = String(format: "F%dMn", fanIndex)
        guard smcWriteFPE2(key, rpm: original) else {
            throw FanError.smcWriteFailed("Reset \(key) thất bại.")
        }
        manualTargets.removeValue(forKey: fanIndex)
    }

    public func resetAllToAuto() async throws {
        for idx in manualTargets.keys {
            try? await resetToAuto(fanIndex: idx)
        }
    }

    /// Kiểm tra xem thiết bị có cho phép ghi SMC không.
    /// Thử ghi F0Mn với giá trị hiện tại (no-op nếu giá trị không đổi).
    /// Gọi một lần sau khi fans() thành công.
    public nonisolated func canWrite() -> Bool {
        guard let rpm = smcReadFPE2("F0Mn") else { return false }
        return smcWriteFPE2("F0Mn", rpm: rpm)
    }

    // MARK: - SMC read/write (nonisolated — pure IOKit, không truy cập actor state)

    private nonisolated func smcReadFPE2(_ key: String) -> Double? {
        guard let b = smcReadKey(key), b.count >= 2 else { return nil }
        return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4.0
    }

    private nonisolated func smcReadUInt8(_ key: String) -> UInt8? {
        guard let b = smcReadKey(key), !b.isEmpty else { return nil }
        return b[0]
    }

    @discardableResult
    private nonisolated func smcWriteFPE2(_ key: String, rpm: Double) -> Bool {
        let encoded = UInt16(max(0, rpm) * 4)
        return smcWriteKey(key, bytes: [UInt8(encoded >> 8), UInt8(encoded & 0xFF)])
    }

    private nonisolated func smcReadKey(_ key: String) -> [UInt8]? {
        guard let keyCode = fourCC(key) else { return nil }
        return withSMCConnection { conn -> [UInt8]? in
            var s = SMCParamStruct(); s.key = keyCode; s.data8 = 9
            guard let info = smcCall(conn, s), info.result == 0 else { return nil }
            let size = Int(info.keyInfo.dataSize)
            guard size > 0 else { return nil }
            var s2 = SMCParamStruct(); s2.key = keyCode
            s2.keyInfo.dataSize = UInt32(size); s2.data8 = 5
            guard let out = smcCall(conn, s2), out.result == 0 else { return nil }
            return Array(withUnsafeBytes(of: out.bytes) { Array($0).prefix(size) })
        }
    }

    private nonisolated func smcWriteKey(_ key: String, bytes: [UInt8]) -> Bool {
        guard let keyCode = fourCC(key) else { return false }
        return withSMCConnection { conn -> Bool? in
            var s = SMCParamStruct(); s.key = keyCode; s.data8 = 9
            guard let info = smcCall(conn, s), info.result == 0 else { return false }
            let size = Int(info.keyInfo.dataSize)
            var w = SMCParamStruct(); w.key = keyCode
            w.keyInfo.dataSize = info.keyInfo.dataSize
            w.keyInfo.dataType = info.keyInfo.dataType
            w.data8 = 6
            withUnsafeMutableBytes(of: &w.bytes) { ptr in
                for (i, b) in bytes.prefix(size).enumerated() { ptr[i] = b }
            }
            guard let out = smcCall(conn, w) else { return false }
            return out.result == 0
        } ?? false
    }

    private nonisolated func withSMCConnection<T>(_ body: (io_connect_t) -> T?) -> T? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(svc) }
        var conn: io_connect_t = 0
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
        defer { IOServiceClose(conn) }
        return body(conn)
    }

    private nonisolated func smcCall(_ conn: io_connect_t, _ input: SMCParamStruct) -> SMCParamStruct? {
        var inp = input; var out = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.stride
        let rc = withUnsafePointer(to: &inp) { inPtr in
            withUnsafeMutablePointer(to: &out) { outPtr in
                IOConnectCallStructMethod(conn, 2, inPtr, MemoryLayout<SMCParamStruct>.stride, outPtr, &outSize)
            }
        }
        return rc == KERN_SUCCESS ? out : nil
    }

    private nonisolated func fourCC(_ s: String) -> UInt32? {
        let b = Array(s.utf8)
        guard b.count == 4 else { return nil }
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }
}

// MARK: - FAN-05: Auto-restore on exit

public final class FanAutoRestore: @unchecked Sendable {
    private let controller: any FanController

    public init(controller: any FanController) {
        self.controller = controller
        atexit_b { [c = controller] in
            let sema = DispatchSemaphore(value: 0)
            Task { try? await c.resetAllToAuto(); sema.signal() }
            sema.wait()
        }
    }
}

// MARK: - SMC C struct (layout phải khớp chính xác AppleSMC kernel struct — theo SMCKit by beltex)

private struct SMCVersion {
    var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0
    var reserved: UInt8 = 0; var release: UInt16 = 0
}
private struct SMCPLimitData {
    var version: UInt16 = 0; var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0; var gpuPLimit: UInt32 = 0; var memPLimit: UInt32 = 0
}
private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0
}
private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (
                0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
                0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0)
}
