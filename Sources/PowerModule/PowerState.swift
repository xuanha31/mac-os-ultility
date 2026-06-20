import Foundation
import Combine
import Core

/// State chia sẻ cho tính năng nguồn (menu bar).
/// - Chống tự ngủ: bật/tắt `caffeinate -d -i -m -s`.
/// - Hibernate khi khoá/ngủ: đặt `hibernatemode 25` BỀN VỮNG khi bật toggle, để CHÍNH
///   macOS hibernate (ghi RAM ra đĩa rồi cắt nguồn) ở MỌI lần ngủ — kể cả khi gập máy.
///   Khôi phục cấu hình cũ khi tắt toggle. Không phụ thuộc notification khoá màn hình
///   (cách cũ phản ứng theo lock+display-sleep đua với OS sleep → gập máy không kịp đổi
///   hibernatemode, máy chỉ vào sleep thường với RAM còn cấp điện).
@MainActor
public final class PowerState: ObservableObject {
    private static let hibernateOnLockKey   = "PowerState.hibernateOnLockEnabled"
    // Lưu giá trị cũ để khôi phục khi tắt toggle. Dùng UserDefaults để sống sót qua
    // khởi động lại (pmset -a cũng bền vững qua reboot).
    private static let savedHibernateModeKey = "PowerState.savedHibernateMode"
    private static let savedTCPKeepAliveKey  = "PowerState.savedTCPKeepAlive"

    @Published public private(set) var isPreventingSleep = false
    @Published public private(set) var isHibernating = false
    @Published public private(set) var isHibernateOnLockEnabled: Bool
    @Published public var statusMessage = ""

    private let controller = PowerController()
    private var caffeinateProcess: Process?
    private var suspendedPIDs: [pid_t] = []
    // hibernatemode cần khôi phục khi thức dậy, CHỈ cho nút "Vào hibernate" lúc toggle TẮT
    // (đặt 25 tạm thời rồi trả lại). Khi toggle BẬT thì 25 là bền vững → không đụng tới.
    private var oneShotPreviousMode: Int?
    private var cancellables = Set<AnyCancellable>()
    private var distributedObservers: [NSObjectProtocol] = []

    public init(sleepWake: SleepWakeCoordinator) {
        isHibernateOnLockEnabled = UserDefaults.standard.bool(forKey: Self.hibernateOnLockKey)

        // Khi máy thức dậy sau khi bấm nút hibernate: chạy lại app đã tạm dừng + khôi
        // phục hibernatemode một-lần (nếu có). .didWake chỉ phát khi wake đầy đủ do người
        // dùng, không phát cho dark/maintenance wake.
        sleepWake.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                if case .didWake = event { self?.handleWake() }
            }
            .store(in: &cancellables)

        // "Khi KHOÁ màn hình" → ép máy ngủ ngay (→ hibernate vì hibernatemode 25 bền vững).
        // Cần thiết vì chỉ khoá màn hình thì macOS KHÔNG tự ngủ — nhất là khi có app/MDM
        // (Handoff, Spotlight, studentd…) giữ assertion chặn idle-sleep → máy chạy & nóng.
        // sleepNow() là forced sleep nên vượt qua được các assertion idle-preventer đó.
        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleScreenLocked() }
        })
    }

    deinit {
        let distributed = DistributedNotificationCenter.default()
        distributedObservers.forEach { distributed.removeObserver($0) }
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

    // MARK: - Hibernate khi khoá/ngủ (cấu hình bền vững)

    public func setHibernateOnLock(_ on: Bool) {
        let defaults = UserDefaults.standard
        if on {
            // Lưu cấu hình hiện tại để khôi phục khi tắt.
            let prevMode = controller.currentHibernateMode() ?? 3
            let prevTCP  = controller.currentPowerValue("tcpkeepalive") ?? 1

            // Đặt hibernatemode 25 (ghi RAM ra đĩa + cắt nguồn khi ngủ). Helper lỗi → KHÔNG
            // bật toggle, để trạng thái UI khớp với hệ thống.
            do {
                try controller.setHibernateMode(25)
            } catch {
                statusMessage = "Không bật được hibernate khi khoá: \(error)"
                return
            }
            // Tắt wake-for-network (tcpkeepalive=0, scope pin) để máy thật sự cắt nguồn khi
            // ngủ thay vì dark wake giữ mạng. Best-effort: lỗi cũng không chặn.
            try? controller.setPowerValue("tcpkeepalive", value: 0, scope: "-b")

            defaults.set(prevMode, forKey: Self.savedHibernateModeKey)
            defaults.set(prevTCP,  forKey: Self.savedTCPKeepAliveKey)
            isHibernateOnLockEnabled = true
            defaults.set(true, forKey: Self.hibernateOnLockKey)
            statusMessage = "Đã bật: máy sẽ hibernate (ghi RAM ra đĩa rồi cắt nguồn) mỗi khi ngủ, kể cả khi gập máy."
        } else {
            // Khôi phục giá trị đã lưu (nếu có). hibernatemode có thể = 0 hợp lệ nên kiểm
            // tra sự tồn tại của key thay vì giá trị.
            if defaults.object(forKey: Self.savedHibernateModeKey) != nil {
                controller.restoreHibernateMode(defaults.integer(forKey: Self.savedHibernateModeKey))
            }
            if defaults.object(forKey: Self.savedTCPKeepAliveKey) != nil {
                controller.restorePowerValue("tcpkeepalive",
                                             value: defaults.integer(forKey: Self.savedTCPKeepAliveKey),
                                             scope: "-b")
            }
            defaults.removeObject(forKey: Self.savedHibernateModeKey)
            defaults.removeObject(forKey: Self.savedTCPKeepAliveKey)
            isHibernateOnLockEnabled = false
            defaults.set(false, forKey: Self.hibernateOnLockKey)
            statusMessage = "Đã tắt hibernate khi khoá màn hình (khôi phục cấu hình nguồn cũ)."
        }
    }

    // MARK: - Hibernate ngay (nút bấm)

    public func hibernateNow() {
        guard !isHibernating else { return }
        isHibernating = true

        // Caffeinate giữ sleep-assertion sẽ chặn máy ngủ lại → tắt trước.
        if isPreventingSleep { setPreventSleep(false) }

        // Toggle BẬT → hibernatemode đã là 25 (bền vững), không cần đổi/khôi phục.
        // Toggle TẮT → đặt 25 tạm thời, lưu giá trị cũ để trả lại khi thức dậy.
        if !isHibernateOnLockEnabled {
            oneShotPreviousMode = controller.currentHibernateMode()
            do {
                try controller.setHibernateMode(25)
            } catch {
                statusMessage = "Lỗi hibernate: \(error)"
                isHibernating = false
                oneShotPreviousMode = nil
                return
            }
        }

        // Tạm dừng app người dùng (tự chạy lại khi wake), khoá màn hình rồi ngủ.
        suspendedPIDs = controller.suspendAllApps()
        controller.lockScreen()
        controller.sleepNow()
        statusMessage = "Đang đưa máy vào hibernate…"
    }

    /// macOS vừa khoá màn hình. Toggle bật → ép máy ngủ ngay để hibernate.
    private func handleScreenLocked() {
        guard isHibernateOnLockEnabled, !isHibernating else { return }
        isHibernating = true
        // Caffeinate (chống tự ngủ) mâu thuẫn với ý định hibernate-khi-khoá → tắt trước.
        if isPreventingSleep { setPreventSleep(false) }
        controller.sleepNow()   // hibernatemode 25 đã bền vững → ngủ = hibernate, cắt nguồn.
        statusMessage = "Màn hình khoá → đang đưa máy vào hibernate…"
    }

    private func handleWake() {
        if !suspendedPIDs.isEmpty {
            controller.resumeApps(suspendedPIDs)
            suspendedPIDs = []
        }
        // Chỉ khôi phục hibernatemode một-lần (nút bấm lúc toggle tắt). Khi toggle bật,
        // 25 là bền vững nên oneShotPreviousMode = nil → giữ nguyên.
        if let mode = oneShotPreviousMode {
            controller.restoreHibernateMode(mode)
            oneShotPreviousMode = nil
        }
        isHibernating = false
        statusMessage = ""
    }
}
