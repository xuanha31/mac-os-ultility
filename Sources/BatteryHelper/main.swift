import Foundation
import IOKit

// Helper tối giản chạy bằng quyền root (qua osascript "with administrator privileges")
// để ghi khoá SMC `BCLM` — đặt % sạc tối đa ở firmware.
//   BatteryHelper <percent>    → ghi BCLM = percent (0...100), in "write-result=<n>"
// Đọc BCLM không cần helper (app đọc trực tiếp bằng quyền user).

struct SMCVersion { var major: UInt8=0; var minor: UInt8=0; var build: UInt8=0; var reserved: UInt8=0; var release: UInt16=0 }
struct SMCPLimitData { var version: UInt16=0; var length: UInt16=0; var cpuPLimit: UInt32=0; var gpuPLimit: UInt32=0; var memPLimit: UInt32=0 }
struct SMCKeyInfoData { var dataSize: UInt32=0; var dataType: UInt32=0; var dataAttributes: UInt8=0 }
struct SMCParamStruct {
    var key: UInt32=0; var vers=SMCVersion(); var pLimitData=SMCPLimitData(); var keyInfo=SMCKeyInfoData()
    var padding: UInt16=0; var result: UInt8=0; var status: UInt8=0; var data8: UInt8=0; var data32: UInt32=0
    var bytes: (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8) =
        (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

func fourCC(_ s: String) -> UInt32 {
    let b = Array(s.utf8)
    return UInt32(b[0])<<24 | UInt32(b[1])<<16 | UInt32(b[2])<<8 | UInt32(b[3])
}

guard CommandLine.arguments.count >= 2, let raw = Int(CommandLine.arguments[1]) else {
    print("usage: BatteryHelper <percent>"); exit(64)
}
let percent = UInt8(min(100, max(0, raw)))

let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
guard svc != IO_OBJECT_NULL else { print("no-smc"); exit(1) }
var conn: io_connect_t = 0
guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS else { print("open-fail"); exit(1) }

func call(_ input: SMCParamStruct) -> SMCParamStruct? {
    var inp = input; var out = SMCParamStruct()
    var sz = MemoryLayout<SMCParamStruct>.stride
    let rc = withUnsafePointer(to: &inp) { ip in
        withUnsafeMutablePointer(to: &out) { op in
            IOConnectCallStructMethod(conn, 2, ip, MemoryLayout<SMCParamStruct>.stride, op, &sz)
        }
    }
    return rc == KERN_SUCCESS ? out : nil
}

let kc = fourCC("BCLM")
var info = SMCParamStruct(); info.key = kc; info.data8 = 9
guard let meta = call(info), meta.result == 0 else { print("bclm-missing"); exit(2) }

var w = SMCParamStruct()
w.key = kc
w.keyInfo.dataSize = meta.keyInfo.dataSize
w.keyInfo.dataType = meta.keyInfo.dataType
w.data8 = 6
withUnsafeMutableBytes(of: &w.bytes) { $0[0] = percent }

if let out = call(w) {
    print("write-result=\(out.result)")
    exit(out.result == 0 ? 0 : 3)
} else {
    print("write-call-failed"); exit(3)
}
