import SwiftUI
import AppKit
import UserNotifications
import MonitorModule
import ClipboardModule

/// AppDelegate để ép activation policy `.regular`.
/// Cần thiết khi chạy qua `swift run` (executable trần, không phải .app bundle):
/// macOS mặc định không cho process trần trở thành active app → không nhận keyboard.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Activate nhiều lần (launch qua `open` đôi khi không nhận focus ngay).
        activateMainWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.activateMainWindow() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4)  { self.activateMainWindow() }

        // Cho phép notification hiện cả khi app đang foreground + xin quyền sớm.
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

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

    func applicationDidBecomeActive(_ notification: Notification) {
        activateMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        activateMainWindow()
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
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 820, minHeight: 520)
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
            MenuBarView(
                monitor: appState.monitor,
                clipboard: appState.clipboard,
                openMainWindow: {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
                }
            )
        } label: {
            // Label hiển thị CPU% trực tiếp trên bar
            MenuBarLabel(monitor: appState.monitor)
        }
        .menuBarExtraStyle(.window)
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
}
