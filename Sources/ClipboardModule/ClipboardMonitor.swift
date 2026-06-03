import Foundation
import AppKit
import Combine

/// Theo dõi thay đổi NSPasteboard và phát ra ClipboardItem mới qua publisher.
public final class ClipboardMonitor: @unchecked Sendable {
    public let itemPublisher = PassthroughSubject<ClipboardItem, Never>()

    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.macutil.clipboard", qos: .utility)
    private let interval: TimeInterval

    public init(interval: TimeInterval = 0.5) {
        self.interval = interval
    }

    public func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.poll() }
        timer = t
        t.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        if let item = ClipboardItem.fromPasteboard(pb) {
            itemPublisher.send(item)
        }
    }
}
