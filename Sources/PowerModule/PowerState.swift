import Foundation
import Combine
import Core
#if canImport(AppKit)
import AppKit
#endif

/// State chia sẻ cho tính năng nguồn (menu bar).
/// - Chống tự ngủ: bật/tắt `caffeinate -d -i -m -s`.
/// - Hibernate: lưu hibernatemode cũ → đặt 25 → tạm dừng app → khoá màn hình → ngủ;
///   khi máy thức dậy thì chạy lại app + khôi phục hibernatemode (qua SleepWakeCoordinator).
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
    private var cancellables = Set<AnyCancellable>()
    private var workspaceObservers: [NSObjectProtocol] = []

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
        // Bắt đúng sự kiện KHOÁ MÀN HÌNH (lock screen / screensaver có mật khẩu),
        // không phải fast-user-switch như sessionDidResignActiveNotification.
        let distributed = DistributedNotificationCenter.default()
        workspaceObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleSessionInactive() }
        })
        #endif
    }

    deinit {
        #if canImport(AppKit)
        let center = DistributedNotificationCenter.default()
        workspaceObservers.forEach { center.removeObserver($0) }
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

    private func handleSessionInactive() {
        guard isHibernateOnLockEnabled, !isHibernating else { return }
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
        isHibernating = false
        statusMessage = ""
    }
}
