import Foundation
import AppKit

// Đảm bảo sheet window trở thành key window để TextField nhận keyboard input.
// macOS SwiftUI issue: sheet trong NavigationSplitView không tự makeKey.
func activateSheet(then action: @escaping () -> Void = {}) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows
            .filter { $0.isVisible && $0 != NSApp.mainWindow }
            .sorted { $0.windowNumber > $1.windowNumber }
            .first?
            .makeKey()
        action()
    }
}

enum Format {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        return f
    }()

    static func bytes(_ value: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(clamping: value))
    }

    static func rate(_ bytesPerSec: Double) -> String {
        let v = bytesPerSec.isFinite && bytesPerSec > 0 ? bytesPerSec : 0
        return byteFormatter.string(fromByteCount: Int64(v)) + "/s"
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", max(0, min(1, fraction)) * 100)
    }
}
