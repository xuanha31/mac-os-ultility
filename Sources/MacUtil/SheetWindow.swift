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
    fixedSize: Bool = true,
    @ViewBuilder content: (_ dismiss: @escaping () -> Void) -> V
) -> UUID {
    let id = UUID()
    let dismiss: () -> Void = { dismissWindow(id) }

    // Form: ép kích thước cố định — nếu không NSHostingController tự co cửa sổ theo ideal
    // size làm ScrollView (ô nhập) bị co về 0.
    // fixedSize=false: nội dung fill theo cửa sổ (vd màn hình remote co giãn khi resize).
    let inner = content(dismiss)
    let framed = fixedSize
        ? AnyView(inner.frame(width: width, height: height))
        : AnyView(inner.frame(maxWidth: .infinity, maxHeight: .infinity))
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
    if !fixedSize {
        // Cửa sổ fill (vd màn hình remote): cho nút xanh phóng to TOÀN màn hình + giữ
        // kích thước nhỏ tối thiểu hợp lý khi kéo. Nội dung tự co giãn theo cửa sổ.
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = NSSize(width: 480, height: 320)
    }

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
