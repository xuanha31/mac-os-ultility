import SwiftUI
import Charts
import MonitorModule

struct MonitorView: View {
    @ObservedObject var monitor: SystemMonitor

    private var metrics: SystemMetrics { monitor.metrics }
    private let window = 60   // số mẫu hiển thị trên biểu đồ

    var body: some View {
        ProScreen(title: "System Monitor") {
            // CPU + RAM realtime
            HStack(spacing: Theme.gap) {
                chartCard(icon: "cpu", title: "cpu", color: Theme.accent,
                          valueText: Format.percent(metrics.cpuUsage),
                          values: monitor.history.map { $0.cpu })
                chartCard(icon: "memorychip", title: "ram", color: Theme.green,
                          valueText: Format.percent(metrics.memoryUsedFraction),
                          values: monitor.history.map { $0.memFraction })
            }

            // Bộ nhớ chi tiết
            ProCard {
                CardHeader(icon: "memorychip", title: "mem",
                           value: Format.percent(metrics.memoryUsedFraction))
                StatBar(fraction: metrics.memoryUsedFraction, color: Theme.green)
                StatRow(label: "used",
                        value: "\(Format.bytes(metrics.memoryUsed)) / \(Format.bytes(metrics.memoryTotal))")
            }

            // Mạng
            HStack(spacing: Theme.gap) {
                netCard(icon: "arrow.down", title: "down", rate: metrics.netRxBytesPerSec, color: Theme.purple)
                netCard(icon: "arrow.up",   title: "up",   rate: metrics.netTxBytesPerSec, color: Theme.orange)
            }

            // Nhiệt độ CPU
            if let temp = metrics.cpuTemperatureCelsius {
                ProCard {
                    CardHeader(icon: "thermometer.medium", title: "temp",
                               value: String(format: "%.0f°C", temp),
                               valueColor: temp > 80 ? Theme.red : Theme.textPrimary)
                    StatBar(fraction: min(temp / 100.0, 1.0),
                            color: temp > 80 ? Theme.red : Theme.orange)
                }
            }

            // Tốc độ quạt
            if monitor.fanSpeedSupported {
                ProCard {
                    CardHeader(icon: "fanblades", title: "fan")
                    ForEach(Array(metrics.fanRPMs.enumerated()), id: \.offset) { idx, rpm in
                        StatRow(label: "fan \(idx + 1)", value: "\(Int(rpm)) RPM")
                    }
                }
            } else {
                ProCard {
                    CardHeader(icon: "fanblades", title: "fan")
                    Text("Không đọc được qua SMC (máy không có quạt — vd MacBook Air, hoặc cần quyền).")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Card biểu đồ (sparkline)

    private func chartCard(icon: String, title: String, color: Color,
                           valueText: String, values: [Double]) -> some View {
        // Lấy tối đa `window` mẫu cuối, vẽ theo chỉ số 0..<window (trượt trái→phải).
        let recent = Array(values.suffix(window))
        let points = Array(recent.enumerated())   // (index, value)
        return ProCard {
            CardHeader(icon: icon, title: title, value: valueText)
            Chart {
                ForEach(points, id: \.offset) { idx, v in
                    AreaMark(x: .value("t", idx), y: .value("v", v * 100))
                        .foregroundStyle(LinearGradient(
                            colors: [color.opacity(0.32), color.opacity(0)],
                            startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("t", idx), y: .value("v", v * 100))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 1.8))
                        .interpolationMethod(.monotone)
                }
            }
            .chartXScale(domain: 0...(window - 1))
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { v in
                    AxisGridLine().foregroundStyle(Theme.border)
                    AxisValueLabel {
                        if let i = v.as(Int.self) {
                            Text("\(i)").font(Theme.mono(9, .regular))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            }
            .chartXAxis(.hidden)
            .frame(height: 64)
        }
    }

    // MARK: - Card mạng

    private func netCard(icon: String, title: String, rate: Double, color: Color) -> some View {
        ProCard {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 16)
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold)).kerning(1)
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 8)
            }
            Text(Format.rate(rate))
                .font(Theme.mono(20))
                .foregroundStyle(Theme.textPrimary)
        }
    }
}
