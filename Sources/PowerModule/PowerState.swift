import Foundation
import Combine
import Core
#if canImport(AppKit)
import AppKit
#endif

/// State chia sẻ cho tính năng nguồn (menu bar).
/// - Chống tự ngủ: bật/tắt `caffeinate -d -i -m -s`.
/// - Hibernate khi khoá: CHỈ kích hoạt khi MÀN HÌNH ĐÃ TẮT *và* ĐANG KHOÁ.
///   Lưu hibernatemode cũ → đặt 25 → tạm dừng app → ngủ; khi máy thức dậy thì
///   chạy lại app + khôi phục hibernatemode (qua SleepWakeCoordinator).
@MainActor
public final class PowerState: ObservableObject {
    private static let hibernateOnLockKey = "PowerState.hibernateOnLockEnabled"

    @Published public private(set) var isPreventingSleep = false
    @Published public private(set) var isHibernating = false
    @Published public private(set) var isHibernateOnLockEnabled: Bool
    @Published public var statusMessage = ""

    private let controller = PowerController()
    private var caffeinateProcess: Process?
    private var suspendedPIDs: [pid_t] = []
    private var previousHibernateMode: Int?
    // Giá trị pmset (scope pin) trước khi hibernate, để khôi phục khi thức dậy.
    private var previousTCPKeepAlive: Int?
    private var previousStandbyDelayLow: Int?
    private var cancellables = Set<AnyCancellable>()
    private var distributedObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    // Điều kiện hibernate = màn hình ĐÃ TẮT và ĐANG KHOÁ. Theo dõi độc lập 2 cờ
    // vì thứ tự "khoá" và "tắt màn hình" không cố định (tuỳ cấu hình máy).
    private var isScreenLocked = false
    private var isDisplayAsleep = false

    public init(sleepWake: SleepWakeCoordinator) {
        isHibernateOnLockEnabled = UserDefaults.standard.bool(forKey: Self.hibernateOnLockKey)

        // Khi máy thức dậy: chạy lại app đã tạm dừng + khôi phục hibernatemode.
        sleepWake.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                if case .didWake = event { self?.handleWake() }
            }
            .store(in: &cancellables)

        #if canImport(AppKit)
        // Trạng thái KHOÁ / MỞ KHOÁ màn hình (distributed notifications).
        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setScreenLocked(true) }
        })
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setScreenLocked(false) }
        })

        // Trạng thái TẮT / SÁNG màn hình (workspace notifications).
        // Khi user ấn phím để nhập mật khẩu → màn hình SÁNG → không hibernate nữa.
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setDisplayAsleep(true) }
        })
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setDisplayAsleep(false) }
        })
        #endif
    }

    deinit {
        #if canImport(AppKit)
        let distributed = DistributedNotificationCenter.default()
        distributedObservers.forEach { distributed.removeObserver($0) }
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { workspace.removeObserver($0) }
        #endif
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

    // MARK: - Hibernate khi khoá màn hình

    public func setHibernateOnLock(_ on: Bool) {
        isHibernateOnLockEnabled = on
        UserDefaults.standard.set(on, forKey: Self.hibernateOnLockKey)
        statusMessage = on
            ? "Đã bật hibernate khi khoá màn hình."
            : "Đã tắt hibernate khi khoá màn hình."
    }

    private func setScreenLocked(_ locked: Bool) {
        isScreenLocked = locked
        if locked { evaluateHibernateOnLock() }
    }

    private func setDisplayAsleep(_ asleep: Bool) {
        isDisplayAsleep = asleep
        if asleep { evaluateHibernateOnLock() }
    }

    /// Chỉ hibernate khi màn hình ĐÃ TẮT và ĐANG KHOÁ.
    /// Lúc user sáng màn hình để nhập mật khẩu (isDisplayAsleep == false) sẽ không
    /// bao giờ vào nhánh hibernate → tránh vòng lặp wake↔sleep gây nhấp nháy.
    private func evaluateHibernateOnLock() {
        guard isHibernateOnLockEnabled,
              isScreenLocked,
              isDisplayAsleep,
              !isHibernating
        else { return }
        hibernateNow(lockScreenFirst: false)
    }

    // MARK: - Hibernate

    public func hibernateNow() {
        hibernateNow(lockScreenFirst: true)
    }

    private func hibernateNow(lockScreenFirst: Bool) {
        guard !isHibernating else { return }
        isHibernating = true

        // Caffeinate giữ sleep-assertion sẽ chặn máy ngủ lại sau dark wake → tắt trước.
        if isPreventingSleep {
            setPreventSleep(false)
        }

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

        // 2b. Giảm hao pin khi ngủ: tắt wake-for-network (tcpkeepalive=0) + rút ngắn
        //     standby từ 3h → 10 phút. Chỉ đặt scope pin (-b); lưu giá trị cũ để khôi
        //     phục khi thức dậy. Best-effort: lỗi cũng không chặn hibernate.
        previousTCPKeepAlive   = controller.currentPowerValue("tcpkeepalive")   ?? 1
        previousStandbyDelayLow = controller.currentPowerValue("standbydelaylow") ?? 10800
        try? controller.setPowerValue("tcpkeepalive",   value: 0,   scope: "-b")
        try? controller.setPowerValue("standbydelaylow", value: 600, scope: "-b")

        // 3. Tạm dừng mọi app người dùng (tự chạy lại khi wake).
        suspendedPIDs = controller.suspendAllApps()

        // 4. Khoá màn hình + đưa máy vào hibernate.
        if lockScreenFirst {
            controller.lockScreen()
        }
        controller.sleepNow()
        statusMessage = "Đang đưa máy vào hibernate…"
    }

    private func handleWake() {
        // Lưu ý: .didWake chỉ phát khi wake ĐẦY ĐỦ do người dùng (ấn nút/phím),
        // KHÔNG phát cho dark/maintenance wake → ở đây luôn là người dùng muốn dùng
        // máy lại. Resume app + khôi phục hibernatemode như bình thường.
        if !suspendedPIDs.isEmpty {
            controller.resumeApps(suspendedPIDs)
            suspendedPIDs = []
        }
        if let mode = previousHibernateMode {
            controller.restoreHibernateMode(mode)
            previousHibernateMode = nil
        }
        // Khôi phục tcpkeepalive + standbydelaylow về giá trị trước khi hibernate.
        if let v = previousTCPKeepAlive {
            controller.restorePowerValue("tcpkeepalive", value: v, scope: "-b")
            previousTCPKeepAlive = nil
        }
        if let v = previousStandbyDelayLow {
            controller.restorePowerValue("standbydelaylow", value: v, scope: "-b")
            previousStandbyDelayLow = nil
        }
        // Sau khi user thức máy, màn hình chắc chắn đang SÁNG → reset cờ để không
        // hibernate lại cho tới khi màn hình tắt lần nữa (đề phòng thiếu screensDidWake).
        isDisplayAsleep = false
        isHibernating = false
        statusMessage = ""
    }
}
