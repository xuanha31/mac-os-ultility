import Foundation
import Combine
import Core

/// Phát các chỉ số hệ thống realtime qua `@Published metrics`.
/// Tự dừng/tiếp tục theo sleep/wake nếu được nối với `SleepWakeCoordinator`.
///
/// Thiết kế concurrency: timer chạy trên `queue` (nền) để đọc/tính delta;
/// mọi cập nhật `@Published` được đẩy về main qua `DispatchQueue.main.async`.
public final class SystemMonitor: ObservableObject {

    @Published public private(set) var metrics = SystemMetrics.zero
    @Published public private(set) var isRunning = false
    /// Đọc tốc độ quạt qua SMC chưa hỗ trợ ở increment này (xem MON-04 / docs).
    @Published public private(set) var fanSpeedSupported = false

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.macutil.monitor")
    private var interval: TimeInterval = 1.0

    // State tính delta — chỉ truy cập trên `queue`.
    private var prevCPU: CPUTicks?
    private var prevNet: NetBytes?
    private var prevSampleTime: CFAbsoluteTime?

    private var cancellables = Set<AnyCancellable>()

    public init() {}

    /// Nối với coordinator để tự pause khi sleep, resume khi wake.
    public func bind(to coordinator: SleepWakeCoordinator) {
        coordinator.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                switch event {
                case .willSleep: self?.pause()
                case .didWake: self?.resume()
                }
            }
            .store(in: &cancellables)
    }

    /// Gọi từ main thread.
    public func start(interval: TimeInterval = 1.0) {
        self.interval = interval
        guard timer == nil else { return }
        queue.async { [weak self] in self?.resetDeltaState() }

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: interval)
        source.setEventHandler { [weak self] in self?.sample() }
        timer = source
        source.resume()
        isRunning = true
        Log.monitor.debug("SystemMonitor started")
    }

    /// Gọi từ main thread.
    public func stop() {
        timer?.cancel()
        timer = nil
        isRunning = false
        Log.monitor.debug("SystemMonitor stopped")
    }

    private func pause() {
        guard isRunning else { return }
        stop()
    }

    private func resume() {
        start(interval: interval)
    }

    /// Chạy trên `queue`.
    private func resetDeltaState() {
        prevCPU = nil
        prevNet = nil
        prevSampleTime = nil
    }

    /// Chạy trên `queue`; đẩy kết quả về main.
    private func sample() {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = prevSampleTime.map { now - $0 } ?? 0

        // CPU usage = busyDelta / totalDelta giữa 2 mẫu.
        var cpuUsage = 0.0
        let currentCPU = MachStats.cpuTicks()
        if let cur = currentCPU, let prev = prevCPU {
            let totalDelta = cur.total >= prev.total ? cur.total - prev.total : 0
            let busyDelta = cur.busy >= prev.busy ? cur.busy - prev.busy : 0
            cpuUsage = totalDelta > 0 ? Double(busyDelta) / Double(totalDelta) : 0
        }
        prevCPU = currentCPU

        let mem = MachStats.memory()

        // Network: tính delta, xử lý wrap counter 32-bit, chia cho dt.
        var rxRate = 0.0
        var txRate = 0.0
        let currentNet = MachStats.networkBytes()
        if let prev = prevNet, dt > 0 {
            let rxDelta = currentNet.rx >= prev.rx ? currentNet.rx - prev.rx : 0
            let txDelta = currentNet.tx >= prev.tx ? currentNet.tx - prev.tx : 0
            rxRate = Double(rxDelta) / dt
            txRate = Double(txDelta) / dt
        }
        prevNet = currentNet
        prevSampleTime = now

        let result = SystemMetrics(
            cpuUsage: min(max(cpuUsage, 0), 1),
            memoryUsed: mem?.used ?? 0,
            memoryTotal: mem?.total ?? 0,
            netRxBytesPerSec: rxRate,
            netTxBytesPerSec: txRate
        )

        DispatchQueue.main.async { [weak self] in
            self?.metrics = result
        }
    }
}
