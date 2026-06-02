import Foundation
import Combine
#if canImport(AppKit)
import AppKit
#endif

/// Nền tảng chống treo sau sleep/wake (xem docs/ARCHITECTURE.md §3).
///
/// Mọi module có timer (Monitor) hoặc kết nối mạng (DB/SSH/Git về sau) nên
/// subscribe `events` để: tạm dừng khi `.willSleep`, resume + reconnect khi `.didWake`.
public final class SleepWakeCoordinator: ObservableObject {

    public enum Event {
        case willSleep
        case didWake
    }

    /// Stream sự kiện sleep/wake cho các module subscribe.
    public let events = PassthroughSubject<Event, Never>()

    @Published public private(set) var isAsleep = false

    private var observers: [NSObjectProtocol] = []

    public init() {
        #if canImport(AppKit)
        let center = NSWorkspace.shared.notificationCenter

        observers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Log.core.info("System will sleep")
            self.isAsleep = true
            self.events.send(.willSleep)
        })

        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Log.core.info("System did wake")
            self.isAsleep = false
            self.events.send(.didWake)
        })
        #endif
    }

    deinit {
        #if canImport(AppKit)
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        #endif
    }
}
