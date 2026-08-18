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
/// - `hibernatemode 25` chỉ quyết định CÁCH hibernate, KHÔNG quyết định KHI NÀO. Mặc định
///   macOS trì hoãn vào standby/hibernate tới `standbydelayhigh` (24h) khi pin còn trên
///   `highstandbythreshold` (50%) → trong lúc chờ, máy chỉ ngủ nông (RAM còn điện) + dark
///   wake bảo trì hàng giờ làm hao pin. Vì vậy khi bật toggle ta còn ép các tham số standby
///   (scope pin) về mức "hibernate NGAY, bất kể mức pin".
@MainActor
public final class PowerState: ObservableObject {
    private static let hibernateOnLockKey   = "PowerState.hibernateOnLockEnabled"
    // Lưu giá trị cũ để khôi phục khi tắt toggle. Dùng UserDefaults để sống sót qua
    // khởi động lại (pmset -a cũng bền vững qua reboot).
    private static let savedHibernateModeKey = "PowerState.savedHibernateMode"
    private static let savedTCPKeepAliveKey  = "PowerState.savedTCPKeepAlive"
    // Dictionary [key: giá trị cũ] của các tham số standby đã ép, để khôi phục khi tắt.
    private static let savedDeepSleepKey     = "PowerState.savedDeepSleepParams"

    /// Tham số pmset ép máy hibernate SÂU ngay khi ngủ và KHÔNG tự thức dậy.
    /// - forced: giá trị đặt khi BẬT toggle. - fallback: mặc định macOS, dùng làm giá trị
    ///   khôi phục nếu không đọc được giá trị hiện tại lúc bật.
    ///
    /// standbydelay* = 0 + highstandbythreshold = 0 → bỏ cơ chế "pin >50% thì trì hoãn 24h".
    /// powernap/womp/proximitywake = 0 → không dark-wake giữ mạng/bảo trì.
    ///
    /// `darkwakes` và `dwlinterval` KHÔNG có trong `man pmset` nhưng pmset vẫn nhận
    /// (kiểm chứng: key bịa trả về "Usage:", hai key này trả về "must be run as root").
    /// Đây là thứ powernap=0 không chặn được: powerd tự lập lịch RTC mỗi ~1 tiếng qua
    /// CoreSmartPowerNap (log ghi `request=CSPNEvaluation`, wake reason `EC.RTC/Maintenance`),
    /// đo được 8–16 lần thức mỗi đêm. darkwakes=0 nhắm thẳng cơ chế đó; dwlinterval=0 bỏ
    /// khoảng "darkwakelinger" ~15s powerd giữ máy thức thêm nếu vẫn còn lần thức lọt lưới.
    ///
    /// Hai key này không hiện trong `pmset -g custom` nên không đọc được giá trị hiện tại
    /// → luôn khôi phục về mặc định macOS. Dùng scope `-a`: chúng không nhận scope theo nguồn.
    private static let deepSleepParams: [(key: String, forced: Int, fallback: Int, scope: String)] = [
        ("standby",              1, 1,     "-b"),
        ("standbydelayhigh",     0, 86400, "-b"),
        ("standbydelaylow",      0, 10800, "-b"),
        ("highstandbythreshold", 0, 50,    "-b"),
        ("powernap",             0, 1,     "-b"),
        ("womp",                 0, 1,     "-b"),
        ("proximitywake",        0, 1,     "-b"),
        ("darkwakes",            0, 1,     "-a"),
        ("dwlinterval",          0, 15,    "-a"),
    ]

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

            // Ép hibernate NGAY khi ngủ, bỏ cơ chế phụ thuộc mức pin: lưu giá trị cũ rồi đặt
            // giá trị forced. Đọc lỗi → dùng fallback (mặc định macOS) làm giá trị khôi phục.
            // KHÔNG dùng `try?` ở đây. Một key hỏng (vd pmset từ chối `darkwakes` trên
            // máy không hỗ trợ) mà im lặng thì người dùng tưởng đã chặn được dark wake,
            // trong khi máy vẫn thức mỗi tiếng — đúng cái đã tốn hai đêm để phát hiện.
            var savedDeep: [String: Int] = [:]
            var failedKeys: [String] = []
            for param in Self.deepSleepParams {
                savedDeep[param.key] = controller.currentPowerValue(param.key) ?? param.fallback
                do {
                    try controller.setPowerValue(param.key, value: param.forced, scope: param.scope)
                } catch {
                    failedKeys.append(param.key)
                    Log.core.error("pmset \(param.scope) \(param.key) \(param.forced) lỗi: \(error)")
                }
            }

            // Báo thức đã lên lịch vẫn đánh thức máy dù darkwakes=0, vì chúng là RTC alarm
            // do ứng dụng đăng ký chứ không phải dark wake bảo trì. Dọn trước khi ngủ.
            let wakesCleared = controller.cancelScheduledWakes()

            defaults.set(prevMode, forKey: Self.savedHibernateModeKey)
            defaults.set(prevTCP,  forKey: Self.savedTCPKeepAliveKey)
            defaults.set(savedDeep, forKey: Self.savedDeepSleepKey)
            isHibernateOnLockEnabled = true
            defaults.set(true, forKey: Self.hibernateOnLockKey)
            var problems: [String] = []
            if !failedKeys.isEmpty {
                problems.append("pmset từ chối: \(failedKeys.joined(separator: ", "))")
            }
            if !wakesCleared {
                let remaining = controller.scheduledWakes()
                problems.append(remaining.isEmpty
                    ? "không xoá được báo thức (helper cũ? cài lại app)"
                    : "còn \(remaining.count) báo thức: \(remaining.joined(separator: " | "))")
            }
            statusMessage = problems.isEmpty
                ? "Đã bật: hibernate SÂU ngay khi ngủ, không tự thức, không báo thức chờ."
                : "Đã bật hibernate sâu NHƯNG chưa trọn vẹn — " + problems.joined(separator: "; ")
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
            // Khôi phục các tham số standby đã ép về giá trị cũ đã lưu (best-effort).
            // Phải khôi phục ĐÚNG scope đã dùng lúc set, nếu không darkwakes/dwlinterval
            // (scope -a) sẽ bị ghi vào scope pin và kẹt ở 0 trên nguồn AC.
            if let savedDeep = defaults.dictionary(forKey: Self.savedDeepSleepKey) {
                for (key, raw) in savedDeep {
                    guard let value = raw as? Int else { continue }
                    let scope = Self.deepSleepParams.first { $0.key == key }?.scope ?? "-b"
                    controller.restorePowerValue(key, value: value, scope: scope)
                }
            }
            defaults.removeObject(forKey: Self.savedHibernateModeKey)
            defaults.removeObject(forKey: Self.savedTCPKeepAliveKey)
            defaults.removeObject(forKey: Self.savedDeepSleepKey)
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

        // Ba việc phải làm lại ở ĐÚNG thời điểm này, không thể chỉ làm lúc bật toggle:
        // - darkwakes KHÔNG ghi vào PM plist (khác dwlinterval, dù cùng scope -a): đây là
        //   thiết lập runtime nên mất sau mỗi lần reboot. Toggle chỉ chạy khi người dùng
        //   bấm, nên reboot với toggle đang bật sẽ để darkwakes về 1 mà không ai biết.
        // - dwlinterval đặt lại cho chắc, chi phí bằng không.
        // - báo thức bị calaccessd/acmd đăng ký lại liên tục trong ngày, nên danh sách
        //   lúc bật toggle (có thể từ sáng) đã cũ.
        for key in ["darkwakes", "dwlinterval"] {
            do { try controller.setPowerValue(key, value: 0, scope: "-a") } catch {
                Log.core.error("đặt lại \(key)=0 trước khi ngủ lỗi: \(error)")
            }
        }
        controller.cancelScheduledWakes()

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
