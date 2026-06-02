import Foundation

/// Snapshot các chỉ số hệ thống tại một thời điểm.
public struct SystemMetrics: Equatable, Sendable {
    /// CPU đang dùng, 0.0 ... 1.0
    public var cpuUsage: Double
    public var memoryUsed: UInt64
    public var memoryTotal: UInt64
    /// Tốc độ nhận / gửi mạng (bytes mỗi giây).
    public var netRxBytesPerSec: Double
    public var netTxBytesPerSec: Double

    public init(
        cpuUsage: Double = 0,
        memoryUsed: UInt64 = 0,
        memoryTotal: UInt64 = 0,
        netRxBytesPerSec: Double = 0,
        netTxBytesPerSec: Double = 0
    ) {
        self.cpuUsage = cpuUsage
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.netRxBytesPerSec = netRxBytesPerSec
        self.netTxBytesPerSec = netTxBytesPerSec
    }

    public static let zero = SystemMetrics()

    public var memoryUsedFraction: Double {
        memoryTotal == 0 ? 0 : Double(memoryUsed) / Double(memoryTotal)
    }
}
