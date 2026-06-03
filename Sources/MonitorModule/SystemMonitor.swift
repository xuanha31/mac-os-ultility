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
    /// MON-04: có đọc được tốc độ quạt qua SMC không.
    @Published public private(set) var fanSpeedSupported = false

    /// Lịch sử mẫu để vẽ biểu đồ CPU/RAM (giữ tối đa `historyLimit` điểm).
    @Published public private(set) var history: [MetricSample] = []
    public struct MetricSample: Identifiable, Sendable {
        public let id: Int
        public let cpu: Double           // 0...1
        public let memFraction: Double   // 0...1
    }
    private var sampleCounter = 0
    private let historyLimit = 60

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

        let cpuTemp = SMCReader.cpuTemperature()

        // MON-04: đọc tốc độ quạt qua SMC.
        var fans: [Double] = []
        let fanCount = SMCReader.fanCount()
        if fanCount > 0 {
            for i in 0..<fanCount {
                if let rpm = SMCReader.fanSpeed(index: i), rpm > 0 { fans.append(rpm) }
            }
        }

        let result = SystemMetrics(
            cpuUsage: min(max(cpuUsage, 0), 1),
            memoryUsed: mem?.used ?? 0,
            memoryTotal: mem?.total ?? 0,
            netRxBytesPerSec: rxRate,
            netTxBytesPerSec: txRate,
            cpuTemperatureCelsius: cpuTemp,
            fanRPMs: fans
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.metrics = result
            self.fanSpeedSupported = !fans.isEmpty
            self.sampleCounter += 1
            self.history.append(MetricSample(id: self.sampleCounter,
                                             cpu: result.cpuUsage,
                                             memFraction: result.memoryUsedFraction))
            if self.history.count > self.historyLimit {
                self.history.removeFirst(self.history.count - self.historyLimit)
            }
        }
    }
}
