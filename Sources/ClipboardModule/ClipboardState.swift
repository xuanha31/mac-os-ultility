import Foundation
import AppKit
import Combine
import UserNotifications

/// ViewModel cho Clipboard Manager + Screenshot.
@MainActor
public final class ClipboardState: ObservableObject {
    // MARK: - Clipboard history

    @Published public var history: [ClipboardItem] = []
    @Published public var searchText = ""
    @Published public var filterType: FilterType = .all
    @Published public var statusMessage = ""

    // MARK: - Screenshot state

    @Published public var lastScreenshot: Data?
    @Published public var isCaptureInProgress = false

    // MARK: - Config

    public var maxHistory: Int = 50

    public enum FilterType: String, CaseIterable {
        case all    = "Tất cả"
        case text   = "Văn bản"
        case image  = "Ảnh"
        case file   = "File"
    }

    // MARK: - Private

    private let monitor = ClipboardMonitor()
    private var cancellables = Set<AnyCancellable>()

    public init() {
        monitor.itemPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] item in self?.addItem(item) }
            .store(in: &cancellables)
        monitor.start()
    }

    // MARK: - Filtered history

    public var filteredHistory: [ClipboardItem] {
        history.filter { item in
            let matchesType: Bool = {
                switch filterType {
                case .all:   return true
                case .text:  return item.content.isText
                case .image: return item.content.isImage
                case .file:
                    if case .fileURL = item.content { return true }
                    return false
                }
            }()
            guard matchesType else { return false }
            guard !searchText.isEmpty else { return true }
            return item.content.displayTitle.localizedCaseInsensitiveContains(searchText)
        }
    }

    // MARK: - Actions

    /// Đưa item lên clipboard để dán lại (sau đó chuyển sang app đích và bấm ⌘V).
    public func paste(_ item: ClipboardItem) {
        item.writeToClipboard()
        history.removeAll { $0.id == item.id }
        history.insert(item, at: 0)
        setStatus("✓ Đã copy vào clipboard — chuyển sang app cần dán và bấm ⌘V.")
    }

    /// Xóa một item.
    public func delete(_ item: ClipboardItem) {
        history.removeAll { $0.id == item.id }
    }

    /// Xóa toàn bộ lịch sử.
    public func clearAll() {
        history.removeAll()
        setStatus("Đã xóa lịch sử clipboard.")
    }

    // MARK: - Screenshot

    /// Chụp toàn màn hình → clipboard + lưu vào history.
    public func captureFullScreen() {
        guard ScreenshotCapture.hasScreenRecordingPermission() else {
            ScreenshotCapture.requestScreenRecordingPermission()
            setStatus("Cần quyền 'Screen Recording'. Mở System Settings → Privacy → Screen Recording, bật MacUtil rồi mở lại app.")
            return
        }
        guard let data = ScreenshotCapture.captureMainDisplay() else {
            setStatus("Chụp màn hình thất bại (kiểm tra quyền Screen Recording).")
            return
        }
        ScreenshotCapture.copyImageToClipboard(data)
        lastScreenshot = data
        let item = ClipboardItem(content: .image(data), source: "Screenshot")
        addItem(item)
        setStatus("✓ Đã chụp toàn màn hình — ảnh đã ở clipboard, bấm ⌘V để dán.")
        Self.notifyCaptured("Đã chụp toàn màn hình", body: "Ảnh đã có trong clipboard. Bấm ⌘V để dán.")
    }

    /// Chụp vùng chọn (interactive).
    public func captureSelection() {
        isCaptureInProgress = true
        setStatus("Đang chờ chọn vùng chụp…")
        ScreenshotCapture.captureSelectionToClipboard { [weak self] success in
            Task { @MainActor [weak self] in
                self?.isCaptureInProgress = false
                if success {
                    // ClipboardMonitor sẽ tự phát hiện và thêm vào history
                    self?.setStatus("✓ Đã chụp vùng chọn — ảnh đã ở clipboard, bấm ⌘V để dán.")
                    ClipboardState.notifyCaptured("Đã chụp vùng chọn", body: "Ảnh đã có trong clipboard. Bấm ⌘V để dán.")
                } else {
                    self?.setStatus("Hủy chụp màn hình.")
                }
            }
        }
    }

    /// Copy văn bản tùy ý vào clipboard.
    public func copyText(_ text: String) {
        ScreenshotCapture.copyTextToClipboard(text)
        setStatus("Đã copy văn bản.")
    }

    // MARK: - Thông báo chụp xong (#3)

    /// Tên notification để lớp UI (MacUtil) hiện HUD nổi.
    public static let captureCompletedNotification = Notification.Name("com.macutil.captureCompleted")

    /// Báo đã chụp: âm thanh + HUD nổi (qua NotificationCenter) + system notification (nếu được cấp quyền).
    nonisolated static func notifyCaptured(_ title: String, body: String) {
        DispatchQueue.main.async {
            NSSound(named: "Grab")?.play() ?? NSSound(named: "Pop")?.play()
            // HUD nổi — luôn hiện, không cần quyền.
            NotificationCenter.default.post(name: ClipboardState.captureCompletedNotification,
                                            object: nil, userInfo: ["text": title])
            // System notification (banner trong Notification Center) — nếu đã cấp quyền.
            let center = UNUserNotificationCenter.current()
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                guard granted else { return }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            }
        }
    }

    // MARK: - Private helpers

    private func addItem(_ item: ClipboardItem) {
        // Bỏ trùng nội dung (text) — không thêm nếu giống item mới nhất
        if let first = history.first,
           case .text(let existing) = first.content,
           case .text(let new) = item.content,
           existing == new { return }

        history.insert(item, at: 0)
        if history.count > maxHistory {
            history = Array(history.prefix(maxHistory))
        }
    }

    private func setStatus(_ msg: String) {
        statusMessage = msg
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if statusMessage == msg { statusMessage = "" }
        }
    }
}
