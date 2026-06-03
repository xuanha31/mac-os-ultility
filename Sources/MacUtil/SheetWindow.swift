import AppKit
import SwiftUI

/// Hiện một SwiftUI view trong NSWindow độc lập thay vì `.sheet`.
/// Sheet trong NavigationSplitView không steal focus từ app khác (macOS bug),
/// và executable trần (swift run) không nhận keyboard → dùng NSWindow + .app bundle.

private var openWindows: [UUID: NSWindowController] = [:]

/// Đóng window theo id.
func dismissWindow(_ id: UUID) {
    openWindows[id]?.window?.close()
    openWindows.removeValue(forKey: id)
}

/// Hiện form trong NSWindow riêng. `content` nhận một closure `dismiss`
/// để view tự đóng window (gọi sau khi Lưu/Hủy).
@discardableResult
func presentInWindow<V: View>(
    title: String = "",
    width: CGFloat = 500,
    height: CGFloat = 420,
    @ViewBuilder content: (_ dismiss: @escaping () -> Void) -> V
) -> UUID {
    let id = UUID()
    let dismiss: () -> Void = { dismissWindow(id) }

    // Ép nội dung có kích thước cố định khớp cửa sổ — nếu không, NSHostingController
    // tự co cửa sổ theo ideal size làm ScrollView (ô nhập) bị co về 0.
    let framed = AnyView(content(dismiss).frame(width: width, height: height))
    let hosting = NSHostingController(rootView: framed)
    hosting.sizingOptions = []   // không cho hosting tự đổi kích thước window

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.title = title
    window.contentViewController = hosting
    window.setContentSize(NSSize(width: width, height: height))
    window.isReleasedWhenClosed = false
    window.center()

    let controller = NSWindowController(window: window)
    openWindows[id] = controller

    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)

    NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification,
        object: window,
        queue: .main
    ) { _ in openWindows.removeValue(forKey: id) }

    return id
}
