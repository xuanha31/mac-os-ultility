import Foundation
import ServiceManagement

/// Quản lý "khởi động cùng macOS" qua SMAppService (macOS 13+).
public enum LoginItem {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    public static func setEnabled(_ on: Bool) -> Bool {
        do {
            if on {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            Log.app.error("LoginItem toggle failed: \(error, privacy: .public)")
            return false
        }
    }
}
