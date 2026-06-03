import Foundation
import IOKit

// Đọc Apple SMC qua IOKit. Layout struct theo SMCKit (beltex) — phải khớp chính xác C struct
// nếu không IOConnectCallStructMethod trả rỗng. Đọc nhiệt độ CPU (sp78) + tốc độ quạt (fpe2).
// SMC đọc KHÔNG cần quyền đặc biệt (không qua TCC).

enum SMCReader {

    // MARK: - Public API

    static func cpuTemperature() -> Double? {
        withConnection { conn in
            for key in ["TC0P", "TC0C", "TC0D", "TC0E", "TCXC", "Tp09", "TCAD"] {
                if let bytes = readKey(key, conn: conn), bytes.count >= 2 {
                    let t = Double(Int8(bitPattern: bytes[0])) + Double(bytes[1]) / 256.0
                    if t > 0 && t < 125 { return t }
                }
            }
            return nil
        }
    }

    static func fanCount() -> Int {
        (withConnection { conn -> Int? in
            guard let b = readKey("FNum", conn: conn), !b.isEmpty else { return nil }
            return Int(b[0])
        }) ?? 0
    }

    static func fanSpeed(index: Int) -> Double? {
        withConnection { conn in
            guard let b = readKey(String(format: "F%dAc", index), conn: conn), b.count >= 2 else { return nil }
            // fpe2: unsigned fixed-point 14.2
            return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4.0
        }
    }

    // MARK: - Connection

    private static func withConnection<T>(_ body: (io_connect_t) -> T?) -> T? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(svc) }
        var conn: io_connect_t = 0
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
        defer { IOServiceClose(conn) }
        return body(conn)
    }

    // MARK: - Read a key → raw bytes

    private static let kKernelIndex: UInt32 = 2
    private static let kGetKeyInfo: UInt8 = 9
    private static let kReadBytes: UInt8 = 5

    private static func readKey(_ key: String, conn: io_connect_t) -> [UInt8]? {
        guard let keyCode = fourCC(key) else { return nil }

        // 1) Lấy dataSize.
        var inInfo = SMCParamStruct()
        inInfo.key = keyCode
        inInfo.data8 = kGetKeyInfo
        guard let outInfo = call(conn, inInfo), outInfo.result == 0 else { return nil }
        let dataSize = Int(outInfo.keyInfo.dataSize)
        guard dataSize > 0 else { return nil }

        // 2) Đọc bytes.
        var inRead = SMCParamStruct()
        inRead.key = keyCode
        inRead.keyInfo.dataSize = UInt32(dataSize)
        inRead.data8 = kReadBytes
        guard let outRead = call(conn, inRead), outRead.result == 0 else { return nil }

        let arr = withUnsafeBytes(of: outRead.bytes) { Array($0) }
        return Array(arr.prefix(dataSize))
    }

    private static func call(_ conn: io_connect_t, _ input: SMCParamStruct) -> SMCParamStruct? {
        var inp = input
        var out = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.stride
        let rc = withUnsafePointer(to: &inp) { inPtr in
            withUnsafeMutablePointer(to: &out) { outPtr in
                IOConnectCallStructMethod(conn, kKernelIndex,
                                          inPtr, MemoryLayout<SMCParamStruct>.stride,
                                          outPtr, &outSize)
            }
        }
        return rc == KERN_SUCCESS ? out : nil
    }

    private static func fourCC(_ s: String) -> UInt32? {
        let b = Array(s.utf8)
        guard b.count == 4 else { return nil }
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }
}

// MARK: - SMC struct (khớp chính xác C layout của AppleSMC, theo SMCKit)

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
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
