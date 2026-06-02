import Foundation

enum Format {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        return f
    }()

    static func bytes(_ value: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(clamping: value))
    }

    static func rate(_ bytesPerSec: Double) -> String {
        let v = bytesPerSec.isFinite && bytesPerSec > 0 ? bytesPerSec : 0
        return byteFormatter.string(fromByteCount: Int64(v)) + "/s"
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", max(0, min(1, fraction)) * 100)
    }
}
