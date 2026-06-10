import Foundation
import Combine
import Core

/// State giới hạn sạc pin qua BCLM (firmware Intel).
///
/// BCLM là cơ chế firmware: ghi MỘT LẦN giá trị ngưỡng, firmware tự dừng sạc ở đó và
/// máy chạy bằng adapter. Không cần poll để cưỡng chế. Ghi cần root → đi qua
/// privileged helper sau lần cấp quyền đầu tiên.
@MainActor
public final class BatteryState: ObservableObject {

    /// Ngưỡng người dùng đang chọn (local — đổi không tác động tới firmware cho tới khi Áp dụng).
    @Published public var maxPercent: Int = 80
    /// Giá trị BCLM thực tế đang nằm trong firmware (100 = không giới hạn).
    @Published public private(set) var appliedLimit: Int = 100
    @Published public private(set) var snapshot: BatterySnapshot?
    @Published public private(set) var controlAvailable = false
    @Published public private(set) var isBusy = false
    @Published public var statusMessage = ""

    /// Đang có giới hạn (BCLM < 100).
    public var isLimitEnabled: Bool { appliedLimit < 100 }
    /// Ngưỡng đang chọn khác với ngưỡng đã áp dụng → cần bấm "Áp dụng".
    public var needsApply: Bool { isLimitEnabled && maxPercent != appliedLimit }

    private let limiter = BatteryChargeLimiter()
    private var pollTimer: Timer?

    public init() {
        controlAvailable = limiter.isSupported()
        snapshot = BatteryReader.snapshot()
        if let cur = limiter.currentLimit() {
            appliedLimit = cur
            if cur < 100 { maxPercent = cur }   // phản ánh đúng trạng thái thực tế
        }
        if !controlAvailable {
            statusMessage = "Máy không có khoá BCLM — không hỗ trợ giới hạn sạc."
        }
        startPolling()
    }

    // MARK: - Hành động

    /// Bật giới hạn ở ngưỡng đang chọn.
    public func enableLimit() { applyLimit(maxPercent) }

    /// Tắt giới hạn (BCLM = 100).
    public func disableLimit() { applyLimit(100) }

    /// Áp dụng ngưỡng đang chọn (khi đã bật mà đổi %).
    public func applyCurrent() { applyLimit(maxPercent) }

    private func applyLimit(_ percent: Int) {
        guard controlAvailable else {
            statusMessage = "Máy không hỗ trợ giới hạn sạc (không có BCLM)."
            return
        }
        isBusy = true
        do {
            try limiter.setMaxChargeLevel(percent)
            appliedLimit = percent
            statusMessage = percent >= 100
                ? "Đã bỏ giới hạn — sạc bình thường tới 100%."
                : "Đã đặt giới hạn sạc tối đa \(percent)%. Máy sẽ ngừng sạc ở mức này."
        } catch {
            statusMessage = "\(error)"
        }
        isBusy = false
    }

    // MARK: - Hiển thị (đọc, không cần quyền)

    private func startPolling() {
        // 5s để tốc độ sạc (W) cập nhật kịp khi cắm/rút sạc. Đọc IOPS + AppleSmartBattery
        // + SMC đều nhẹ nên poll nhanh không đáng kể.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshDisplay() }
        }
    }

    public func refreshDisplay() {
        snapshot = BatteryReader.snapshot()
        if let cur = limiter.currentLimit() { appliedLimit = cur }
    }
}
