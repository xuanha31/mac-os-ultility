import Foundation
import IOKit

// Đọc/ghi Apple SMC qua IOKit cho các khoá liên quan sạc pin.
// Layout struct PHẢI khớp chính xác C struct của AppleSMC (theo SMCKit by beltex) —
// giống hệt FanControlModule. Đọc không cần quyền; ghi: trên Intel thường không cần root,
// trên Apple Silicon thường bị từ chối.
//
// ⚠️ [Unverified] Các khoá điều khiển sạc (BCLM, CH0B, CH0C) KHÔNG có tài liệu chính thức
// của Apple — chúng do cộng đồng dịch ngược (AlDente/BatFi…). Hành vi có thể khác theo
// model máy và phiên bản macOS. Luôn kiểm tra canWrite() trước khi tin tưởng.

enum BatterySMC {

    /// Đọc 1 byte đầu của khoá (đa số khoá sạc là UInt8).
    static func readByte(_ key: String) -> UInt8? {
        guard let b = readKey(key), !b.isEmpty else { return nil }
        return b[0]
    }

    /// Ghi danh sách byte vào khoá. Trả về true nếu SMC chấp nhận (result == 0).
    @discardableResult
    static func writeBytes(_ key: String, _ bytes: [UInt8]) -> Bool {
        guard let keyCode = fourCC(key) else { return false }
        return withConnection { conn -> Bool? in
            var info = SMCParamStruct(); info.key = keyCode; info.data8 = 9
            guard let out = call(conn, info), out.result == 0 else { return false }
            let size = Int(out.keyInfo.dataSize)
            var w = SMCParamStruct(); w.key = keyCode
            w.keyInfo.dataSize = out.keyInfo.dataSize
            w.keyInfo.dataType = out.keyInfo.dataType
            w.data8 = 6
            withUnsafeMutableBytes(of: &w.bytes) { ptr in
                for (i, b) in bytes.prefix(size).enumerated() { ptr[i] = b }
            }
            guard let res = call(conn, w) else { return false }
            return res.result == 0
        } ?? false
    }

    // MARK: - Private

    private static func readKey(_ key: String) -> [UInt8]? {
        guard let keyCode = fourCC(key) else { return nil }
        return withConnection { conn -> [UInt8]? in
            var s = SMCParamStruct(); s.key = keyCode; s.data8 = 9
            guard let info = call(conn, s), info.result == 0 else { return nil }
            let size = Int(info.keyInfo.dataSize)
            guard size > 0 else { return nil }
            var s2 = SMCParamStruct(); s2.key = keyCode
            s2.keyInfo.dataSize = UInt32(size); s2.data8 = 5
            guard let out = call(conn, s2), out.result == 0 else { return nil }
            return Array(withUnsafeBytes(of: out.bytes) { Array($0).prefix(size) })
        }
    }

    private static func withConnection<T>(_ body: (io_connect_t) -> T?) -> T? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(svc) }
        var conn: io_connect_t = 0
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
        defer { IOServiceClose(conn) }
        return body(conn)
    }

    private static func call(_ conn: io_connect_t, _ input: SMCParamStruct) -> SMCParamStruct? {
        var inp = input; var out = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.stride
        let rc = withUnsafePointer(to: &inp) { inPtr in
            withUnsafeMutablePointer(to: &out) { outPtr in
                IOConnectCallStructMethod(conn, 2, inPtr, MemoryLayout<SMCParamStruct>.stride, outPtr, &outSize)
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

// MARK: - SMC C struct (khớp chính xác AppleSMC kernel struct — theo SMCKit by beltex)

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
