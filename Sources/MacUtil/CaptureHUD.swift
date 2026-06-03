import AppKit
import SwiftUI

/// HUD nổi tạm thời báo "đã chụp" — hiện kể cả khi app ẩn/không focus, không cần quyền.
@MainActor
enum CaptureHUD {
    private static var panel: NSPanel?
    private static var dismissWork: DispatchWorkItem?

    static func show(_ text: String) {
        // Đóng HUD cũ nếu còn.
        dismissWork?.cancel()
        panel?.orderOut(nil)

        let hud = HUDView(text: text)
        let host = NSHostingView(rootView: hud)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)

        let p = NSPanel(contentRect: host.frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.contentView = host

        // Đặt giữa-trên màn hình chính.
        if let screen = NSScreen.main {
            let size = host.fittingSize
            let x = screen.frame.midX - size.width / 2
            let y = screen.frame.maxY - size.height - 120
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }
        p.orderFrontRegardless()
        panel = p

        let work = DispatchWorkItem {
            panel?.orderOut(nil)
            panel = nil
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }
}

private struct HUDView: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2).foregroundStyle(.green)
            Text(text).font(.callout.weight(.medium)).foregroundStyle(.white)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 12))
        .fixedSize()
    }
}
