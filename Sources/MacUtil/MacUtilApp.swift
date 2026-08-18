import SwiftUI
import AppKit
import UserNotifications
import MonitorModule
import ClipboardModule

/// Điều khiển icon MacUtil trên Dock: chỉ hiện khi còn cửa sổ app đang mở.
/// Đóng hết cửa sổ → `.accessory` (biến khỏi Dock + ⌘Tab, vẫn còn icon trên thanh menu).
/// Mở lại từ menu bar → `.regular` để cửa sổ nhận được keyboard focus như app bình thường.
enum DockPolicy {
    /// ID của WindowGroup chính — dùng cho `openWindow(id:)` khi cửa sổ đã bị đóng hẳn.
    static let mainWindowID = "macutil.main"

    /// Cửa sổ chính đang sống (nil = đã đóng, SwiftUI đã huỷ NSWindow). Weak để không giữ
    /// cửa sổ sau khi đóng. Cần ref riêng vì `NSApp.windows` không cho biết cửa sổ nào là
    /// cửa sổ chính — SheetWindow và cửa sổ remote tách cũng là NSWindow titled.
    private(set) static weak var mainWindow: NSWindow?

    static func registerMainWindow(_ window: NSWindow?) {
        guard let window else { return }
        mainWindow = window
        showInDock()
    }

    /// Cửa sổ "thật" của app. Bỏ NSPanel vì đó là HUD chụp màn hình + popover của
    /// MenuBarExtra — chúng không tính là "MacUtil đang mở".
    private static func hasVisibleWindow(excluding closing: NSWindow?) -> Bool {
        NSApp.windows.contains { win in
            win !== closing && win.isVisible && win.canBecomeMain && !(win is NSPanel)
        }
    }

    static func showInDock() {
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
    }

    /// Đồng bộ policy theo cửa sổ đang mở. `closing` là cửa sổ vừa nhận `willClose`
    /// (lúc đó `isVisible` của nó vẫn còn true nên phải loại thủ công).
    static func sync(excluding closing: NSWindow? = nil) {
        let wanted: NSApplication.ActivationPolicy =
            hasVisibleWindow(excluding: closing) ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
    }
}

/// AppDelegate để ép activation policy `.regular`.
/// Cần thiết khi chạy qua `swift run` (executable trần, không phải .app bundle):
/// macOS mặc định không cho process trần trở thành active app → không nhận keyboard.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        // Đóng cửa sổ cuối cùng → rời Dock. `willClose` bắn TRƯỚC khi cửa sổ rời màn hình
        // nên phải loại nó khỏi phép đếm (isVisible của nó vẫn còn true).
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            let closing = note.object as? NSWindow
            DispatchQueue.main.async { DockPolicy.sync(excluding: closing) }
        }

        // Mở cửa sổ phụ (SheetWindow, cửa sổ remote tách) khi đang ở chế độ menu-bar-only
        // → quay lại Dock, không thì cửa sổ đó không có icon và không nhận được menu app.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main
        ) { _ in DockPolicy.showInDock() }

        // Cửa sổ chính có thể KHÔNG mở lúc launch (macOS khôi phục trạng thái "đã đóng"
        // của lần chạy trước). Chốt policy theo cửa sổ thật sau khi SwiftUI dựng scene xong,
        // không ép `.regular` vô điều kiện — không thì Dock có icon mà chẳng có cửa sổ nào.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { DockPolicy.sync() }
        // Activate nhiều lần (launch qua `open` đôi khi không nhận focus ngay).
        activateMainWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.activateMainWindow() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4)  { self.activateMainWindow() }

        // Cho phép notification hiện cả khi app đang foreground + xin quyền sớm.
        // UNUserNotificationCenter CHỈ dùng được trong .app bundle hợp lệ (có CFBundleIdentifier).
        // Khi chạy như executable trần (swift run / binary trực tiếp) bundleIdentifier == nil →
        // gọi currentNotificationCenter sẽ abort() ngay lúc launch. Bỏ qua để không crash.
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        } else {
            NSLog("[MacUtil] Chạy ngoài .app bundle → bỏ qua UNUserNotificationCenter. Dùng ./run-app.sh để có notification.")
        }

        // Hiện HUD nổi khi chụp xong (chắc chắn, không cần quyền).
        NotificationCenter.default.addObserver(
            forName: ClipboardState.captureCompletedNotification, object: nil, queue: .main
        ) { note in
            let text = (note.userInfo?["text"] as? String) ?? "Đã chụp — ảnh ở clipboard"
            Task { @MainActor in CaptureHUD.show("\(text) — ⌘V để dán") }
        }
    }

    // Hiện banner kể cả khi app đang chạy foreground.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }

    // Đóng cửa sổ chính KHÔNG thoát app — app sống tiếp ở thanh menu.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Đang ở chế độ chỉ-menu-bar (không có cửa sổ nào) → click icon menu bar cũng làm app
        // active; đừng dựng lại cửa sổ, không thì icon Dock hiện lại ngoài ý muốn.
        guard NSApp.activationPolicy() == .regular else { return }
        // CHỈ kéo cửa sổ chính lên khi chưa có cửa sổ nào là key (vd mở app từ nền). Nếu đang
        // dùng cửa sổ remote tách/fullscreen (Space riêng), ép cửa sổ chính lên front sẽ khiến
        // macOS nhảy Space về app chính → bỏ qua.
        guard NSApp.keyWindow == nil else { return }
        activateMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Cửa sổ chính đã bị đóng hẳn → chỉ SwiftUI dựng lại được (`openWindow`), AppKit
        // không có gì để `makeKeyAndOrderFront`. Nhờ MenuBarContent làm hộ.
        if DockPolicy.mainWindow?.isVisible != true {
            NotificationCenter.default.post(name: .openMainWindow, object: nil)
        } else {
            activateMainWindow()
        }
        return true
    }

    /// Đưa cửa sổ chính thành key + main + foreground để control hiển thị "active" (không mờ).
    private func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let win = NSApp.windows.first(where: { $0.canBecomeMain }) {
            win.isOpaque = true
            win.backgroundColor = .windowBackgroundColor
            win.makeKeyAndOrderFront(nil)
            win.orderFrontRegardless()
        }
    }
}

@main
struct MacUtilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        // Giữ `WindowGroup` (không dùng `Window`): `Window` khôi phục trạng thái "đã đóng"
        // của lần chạy trước → launch xong không có cửa sổ nào. `WindowGroup` luôn mở 1 cửa sổ.
        // Đổi lại phải tự chống mở trùng — xem `MenuBarContent.openMainWindow`.
        WindowGroup(id: DockPolicy.mainWindowID) {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 820, minHeight: 520)
                .background(MainWindowBinder())
        }
        .windowResizability(.contentMinSize)
        .commands {
            // Cmd+Shift+V — Clipboard Manager (giống Win+V)
            CommandMenu("Clipboard") {
                Button("Mở Clipboard Manager") {
                    NotificationCenter.default.post(name: .openClipboard, object: nil)
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])

                Divider()

                // Lưu ý: KHÔNG dùng ⌘⇧3/4 vì đó là shortcut hệ thống macOS (lưu file ra Desktop).
                Button("Chụp toàn màn hình → clipboard") {
                    appState.clipboard.captureFullScreen()
                }
                .keyboardShortcut("1", modifiers: [.command, .shift])

                Button("Chụp vùng chọn → clipboard") {
                    appState.clipboard.captureSelection()
                }
                .keyboardShortcut("2", modifiers: [.command, .shift])
            }
        }

        // Icon + thông tin trên thanh menu macOS (góc phải trên).
        MenuBarExtra {
            MenuBarContent(appState: appState)
        } label: {
            // Label hiển thị CPU% trực tiếp trên bar
            MenuBarLabel(monitor: appState.monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

/// View rỗng chỉ để nắm NSWindow của cửa sổ chính (SwiftUI không expose trực tiếp).
private struct MainWindowBinder: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Lúc makeNSView chạy, view chưa gắn vào window → phải đợi 1 vòng runloop.
        DispatchQueue.main.async { DockPolicy.registerMainWindow(nsView.window) }
    }
}

/// Bọc `MenuBarView` để lấy `openWindow` từ environment. Cần vì khi đóng cửa sổ chính,
/// SwiftUI huỷ luôn NSWindow → `makeKeyAndOrderFront` không còn gì để gọi; phải nhờ
/// `openWindow(id:)` dựng lại scene.
private struct MenuBarContent: View {
    @ObservedObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarView(
            monitor: appState.monitor,
            clipboard: appState.clipboard,
            power: appState.power,
            battery: appState.battery,
            openMainWindow: showMainWindow
        )
        // MenuBarExtra luôn sống kể cả khi không còn cửa sổ nào → là chỗ duy nhất còn giữ
        // được `openWindow`. AppDelegate bắn notification này khi app bị reopen từ Launchpad.
        .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in
            showMainWindow()
        }
    }

    private func showMainWindow() {
        DockPolicy.showInDock()
        // Cửa sổ chính còn sống → chỉ đưa lên trước. Gọi `openWindow` lúc này sẽ đẻ
        // thêm cửa sổ thứ hai vì đây là WindowGroup.
        if let win = DockPolicy.mainWindow, win.isVisible {
            win.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: DockPolicy.mainWindowID)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Label cho MenuBarExtra — hiện icon + CPU% cập nhật trực tiếp.
private struct MenuBarLabel: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        // SF Symbol + phần trăm CPU
        let pct = Int((monitor.metrics.cpuUsage * 100).rounded())
        Image(systemName: "gauge.with.dots.needle.67percent")
        Text(" \(pct)%")
    }
}

extension Notification.Name {
    static let openClipboard = Notification.Name("com.macutil.openClipboard")
    static let openMainWindow = Notification.Name("com.macutil.openMainWindow")
}
