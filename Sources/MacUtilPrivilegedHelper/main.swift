import Foundation
import IOKit
import PrivilegedHelperProtocol

final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: MacUtilPrivilegedHelperProtocol.self)
        connection.exportedObject = PrivilegedHelper()
        connection.resume()
        return true
    }
}

final class PrivilegedHelper: NSObject, MacUtilPrivilegedHelperProtocol {
    func setHibernateMode(_ mode: Int32, withReply reply: @escaping (Bool, String) -> Void) {
        guard (0...25).contains(mode) else {
            reply(false, "hibernatemode không hợp lệ: \(mode)")
            return
        }
        do {
            try run("/usr/bin/pmset", ["-a", "hibernatemode", "\(mode)"])
            reply(true, "")
        } catch {
            reply(false, "\(error)")
        }
    }

    func setMaxChargeLevel(_ percent: Int32, withReply reply: @escaping (Bool, String) -> Void) {
        do {
            let clamped = UInt8(min(100, max(0, percent)))
            let result = try SMCWriter.writeByte(key: "BCLM", value: clamped)
            guard result == 0 else {
                reply(false, "write-result=\(result)")
                return
            }
            reply(true, "")
        } catch {
            reply(false, "\(error)")
        }
    }

    private func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw HelperCommandError.failed(status: process.terminationStatus, output: output)
        }
    }
}

enum HelperCommandError: Error, CustomStringConvertible {
    case failed(status: Int32, output: String)
    case noSMC
    case openSMCFailed(kern_return_t)
    case keyMissing(String)
    case writeFailed

    var description: String {
        switch self {
        case .failed(let status, let output):
            return output.isEmpty ? "Lệnh thất bại, status \(status)" : output
        case .noSMC:
            return "Không tìm thấy AppleSMC."
        case .openSMCFailed(let code):
            return "Không mở được AppleSMC: \(code)"
        case .keyMissing(let key):
            return "Không tìm thấy SMC key \(key)."
        case .writeFailed:
            return "Gọi ghi SMC thất bại."
        }
    }
}

struct SMCVersion { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
struct SMCPLimitData { var version: UInt16 = 0; var length: UInt16 = 0; var cpuPLimit: UInt32 = 0; var gpuPLimit: UInt32 = 0; var memPLimit: UInt32 = 0 }
struct SMCKeyInfoData { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }
struct SMCParamStruct {
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
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

enum SMCWriter {
    static func writeByte(key: String, value: UInt8) throws -> UInt8 {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else { throw HelperCommandError.noSMC }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = 0
        let openResult = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard openResult == KERN_SUCCESS else { throw HelperCommandError.openSMCFailed(openResult) }
        defer { IOServiceClose(connection) }

        func call(_ input: SMCParamStruct) -> SMCParamStruct? {
            var input = input
            var output = SMCParamStruct()
            var size = MemoryLayout<SMCParamStruct>.stride
            let result = withUnsafePointer(to: &input) { inputPointer in
                withUnsafeMutablePointer(to: &output) { outputPointer in
                    IOConnectCallStructMethod(
                        connection,
                        2,
                        inputPointer,
                        MemoryLayout<SMCParamStruct>.stride,
                        outputPointer,
                        &size
                    )
                }
            }
            return result == KERN_SUCCESS ? output : nil
        }

        let code = fourCC(key)
        var info = SMCParamStruct()
        info.key = code
        info.data8 = 9
        guard let metadata = call(info), metadata.result == 0 else {
            throw HelperCommandError.keyMissing(key)
        }

        var write = SMCParamStruct()
        write.key = code
        write.keyInfo.dataSize = metadata.keyInfo.dataSize
        write.keyInfo.dataType = metadata.keyInfo.dataType
        write.data8 = 6
        withUnsafeMutableBytes(of: &write.bytes) { bytes in
            bytes[0] = value
        }

        guard let output = call(write) else { throw HelperCommandError.writeFailed }
        return output.result
    }

    private static func fourCC(_ string: String) -> UInt32 {
        let bytes = Array(string.utf8)
        precondition(bytes.count == 4)
        return UInt32(bytes[0]) << 24
            | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])
    }
}

let listener = NSXPCListener(machServiceName: MacUtilHelperConstants.machServiceName)
let delegate = HelperDelegate()
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
