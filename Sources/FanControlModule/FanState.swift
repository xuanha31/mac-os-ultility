import Foundation
import Combine
import Core

// ViewModel cho FanControlModule.

@MainActor
public final class FanState: ObservableObject {
    @Published public var fans: [FanInfo] = []
    @Published public var isBusy = false
    @Published public var statusMessage = ""
    @Published public var controlEnabled = false  // true khi có privileged helper

    private let controller: any FanController
    private var refreshTimer: Timer?

    public init() {
        self.controller = ReadOnlyFanController()
        startRefreshing()
    }

    public func refresh() {
        isBusy = true
        Task {
            do {
                fans = try await controller.fans()
                if fans.isEmpty { statusMessage = "Không tìm thấy quạt (MacBook Air hoặc SMC không hỗ trợ)." }
                else { statusMessage = "" }
            } catch {
                statusMessage = "Lỗi đọc quạt: \(error)"
            }
            isBusy = false
        }
    }

    public func setMinSpeed(_ rpm: Double, fanIndex: Int) {
        guard controlEnabled else {
            statusMessage = FanError.needsPrivilegedHelper.description
            return
        }
        Task {
            do {
                try await controller.setMinSpeed(rpm, fanIndex: fanIndex)
                statusMessage = "Đã đặt min RPM quạt \(fanIndex): \(Int(rpm))"
                refresh()
            } catch {
                statusMessage = "Lỗi: \(error)"
            }
        }
    }

    public func resetToAuto(fanIndex: Int) {
        Task {
            do {
                try await controller.resetToAuto(fanIndex: fanIndex)
                statusMessage = "Quạt \(fanIndex) khôi phục Auto."
                refresh()
            } catch {
                statusMessage = "Lỗi: \(error)"
            }
        }
    }

    private func startRefreshing() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }
}
