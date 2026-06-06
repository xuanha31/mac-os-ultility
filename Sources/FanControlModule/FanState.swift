import Foundation
import Combine
import Core

@MainActor
public final class FanState: ObservableObject {
    @Published public var fans: [FanInfo] = []
    @Published public var isBusy = false
    @Published public var statusMessage = ""
    @Published public var controlEnabled = false

    private let controller = SMCFanController()
    private var refreshTimer: Timer?
    private var writeCheckDone = false

    public init() { startRefreshing() }

    public func refresh() {
        isBusy = true
        Task {
            do {
                fans = try await controller.fans()
                if fans.isEmpty {
                    statusMessage = "Không tìm thấy quạt (MacBook Air hoặc SMC không hỗ trợ)."
                } else {
                    statusMessage = ""
                    if !writeCheckDone {
                        writeCheckDone = true
                        controlEnabled = controller.canWrite()
                    }
                }
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
                statusMessage = "Đã đặt min RPM quạt \(fanIndex + 1): \(Int(rpm))"
                refresh()
            } catch {
                statusMessage = "Lỗi: \(error)"
                if let fe = error as? FanError, case .smcWriteFailed = fe {
                    controlEnabled = false
                }
            }
        }
    }

    public func resetToAuto(fanIndex: Int) {
        Task {
            do {
                try await controller.resetToAuto(fanIndex: fanIndex)
                statusMessage = "Quạt \(fanIndex + 1) khôi phục Auto."
                refresh()
            } catch {
                statusMessage = "Lỗi: \(error)"
            }
        }
    }

    private func startRefreshing() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }
}
