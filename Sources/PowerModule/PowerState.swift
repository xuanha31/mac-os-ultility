import Foundation
import Combine
import Core

/// State chia sẻ cho tính năng nguồn (menu bar).
/// - Chống tự ngủ: bật/tắt `caffeinate -d -i -m -s`.
/// - Hibernate: lưu hibernatemode cũ → đặt 25 → tạm dừng app → khoá màn hình → ngủ;
///   khi máy thức dậy thì chạy lại app + khôi phục hibernatemode (qua SleepWakeCoordinator).
@MainActor
public final class PowerState: ObservableObject {
    @Published public private(set) var isPreventingSleep = false
    @Published public private(set) var isHibernating = false
    @Published public var statusMessage = ""

    private let controller = PowerController()
    private var caffeinateProcess: Process?
    private var suspendedPIDs: [pid_t] = []
    private var previousHibernateMode: Int?
    private var cancellables = Set<AnyCancellable>()

    public init(sleepWake: SleepWakeCoordinator) {
        // Khi máy thức dậy: chạy lại app đã tạm dừng + khôi phục hibernatemode.
        sleepWake.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                if case .didWake = event { self?.handleWake() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Chống tự ngủ (toggle on/off)

    public func togglePreventSleep() { setPreventSleep(!isPreventingSleep) }

    public func setPreventSleep(_ on: Bool) {
        if on {
            guard caffeinateProcess == nil else { return }
            do {
                caffeinateProcess = try controller.startCaffeinate()
                isPreventingSleep = true
                statusMessage = "Đang chống tự ngủ (caffeinate -d -i -m -s)."
            } catch {
                statusMessage = "Lỗi caffeinate: \(error)"
            }
        } else {
            caffeinateProcess?.terminate()
            caffeinateProcess = nil
            isPreventingSleep = false
            statusMessage = "Đã tắt chống tự ngủ."
        }
    }

    // MARK: - Hibernate

    public func hibernateNow() {
        guard !isHibernating else { return }
        isHibernating = true

        // 1. Lưu hibernatemode hiện tại để khôi phục sau khi thức dậy.
        previousHibernateMode = controller.currentHibernateMode()

        // 2. Đặt hibernatemode 25 qua privileged helper. Thất bại → dừng, không đụng tới app.
        do {
            try controller.setHibernateMode(25)
        } catch {
            statusMessage = "Lỗi hibernate: \(error)"
            isHibernating = false
            previousHibernateMode = nil
            return
        }

        // 3. Tạm dừng mọi app người dùng (tự chạy lại khi wake).
        suspendedPIDs = controller.suspendAllApps()

        // 4. Khoá màn hình + đưa máy vào hibernate.
        controller.lockScreen()
        controller.sleepNow()
        statusMessage = "Đang đưa máy vào hibernate…"
    }

    private func handleWake() {
        if !suspendedPIDs.isEmpty {
            controller.resumeApps(suspendedPIDs)
            suspendedPIDs = []
        }
        if let mode = previousHibernateMode {
            controller.restoreHibernateMode(mode)
            previousHibernateMode = nil
        }
        isHibernating = false
        statusMessage = ""
    }
}
