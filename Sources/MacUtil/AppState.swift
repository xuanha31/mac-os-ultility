import Foundation
import Combine
import Core
import MonitorModule

/// State chia sẻ toàn app: coordinator sleep/wake + monitor hệ thống.
@MainActor
final class AppState: ObservableObject {
    let sleepWake = SleepWakeCoordinator()
    let monitor = SystemMonitor()

    init() {
        monitor.bind(to: sleepWake)
        monitor.start(interval: 1.0)
    }
}
