import Foundation
import Combine
import Carbon.HIToolbox
import Core
import MonitorModule
import DatabaseModule
import SSHModule
import FanControlModule
import ClipboardModule

/// State chia sẻ toàn app: coordinator sleep/wake + các module.
@MainActor
final class AppState: ObservableObject {
    let sleepWake = SleepWakeCoordinator()
    let monitor = SystemMonitor()
    let database: DatabaseState
    let ssh: SSHState
    let fan = FanState()
    let clipboard = ClipboardState()
    // ViewModel giữ bền để không mất dữ liệu khi chuyển tab (NavigationSplitView tạo lại view).
    let git = GitViewModel()
    let cleaner = CleanerViewModel()
    let diskScan = DiskScanViewModel()
    let keyRemap = KeyRemapViewModel()

    init() {
        database = DatabaseState(sleepWake: sleepWake)
        ssh = SSHState(sleepWake: sleepWake)
        monitor.bind(to: sleepWake)
        monitor.start(interval: 1.0)
        registerGlobalHotKeys()
    }

    /// Phím tắt chụp ảnh chạy toàn hệ thống (kể cả khi app ẩn/không focus).
    /// ⌘⇧1 = toàn màn hình, ⌘⇧2 = vùng chọn. (cmdKey=0x100, shiftKey=0x200)
    private func registerGlobalHotKeys() {
        let mods = cmdKey | shiftKey
        GlobalHotKeys.shared.register(id: 1, keyCode: kVK_ANSI_1, modifiers: mods) { [weak self] in
            Task { @MainActor in self?.clipboard.captureFullScreen() }
        }
        GlobalHotKeys.shared.register(id: 2, keyCode: kVK_ANSI_2, modifiers: mods) { [weak self] in
            Task { @MainActor in self?.clipboard.captureSelection() }
        }
    }
}
