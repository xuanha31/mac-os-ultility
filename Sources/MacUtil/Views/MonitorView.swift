import SwiftUI
import Charts
import MonitorModule

struct MonitorView: View {
    @ObservedObject var monitor: SystemMonitor

    private var metrics: SystemMetrics { monitor.metrics }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Giám sát hệ thống")
                    .font(.largeTitle.bold())

                // Biểu đồ CPU + RAM realtime
                HStack(spacing: 16) {
                    chartCard(title: "CPU", color: .blue,
                              valueText: Format.percent(metrics.cpuUsage),
                              values: monitor.history.map { $0.cpu })
                    chartCard(title: "RAM", color: .green,
                              valueText: Format.percent(metrics.memoryUsedFraction),
                              values: monitor.history.map { $0.memFraction })
                }

                metricCard(
                    title: "Bộ nhớ (RAM)",
                    valueText: "\(Format.bytes(metrics.memoryUsed)) / \(Format.bytes(metrics.memoryTotal))",
                    fraction: metrics.memoryUsedFraction
                )

                HStack(spacing: 16) {
                    netCard(title: "Tải xuống", icon: "arrow.down", rate: metrics.netRxBytesPerSec)
                    netCard(title: "Tải lên", icon: "arrow.up", rate: metrics.netTxBytesPerSec)
                }

                if let temp = metrics.cpuTemperatureCelsius {
                    metricCard(
                        title: "Nhiệt độ CPU",
                        valueText: String(format: "%.1f °C", temp),
                        fraction: min(temp / 100.0, 1.0)
                    )
                }

                // MON-04: tốc độ quạt
                if monitor.fanSpeedSupported {
                    fanCard
                } else {
                    Label("Tốc độ quạt: không đọc được qua SMC (máy không có quạt — vd MacBook Air, hoặc cần quyền).",
                          systemImage: "fanblades")
                        .font(.callout).foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(24)
        }
    }

    // MARK: - Chart card

    private let window = 60   // số mẫu hiển thị

    private func chartCard(title: String, color: Color, valueText: String,
                           values: [Double]) -> some View {
        // Lấy tối đa `window` mẫu cuối, vẽ theo chỉ số 0..<window (trượt trái→phải).
        let recent = Array(values.suffix(window))
        let points = Array(recent.enumerated())   // (index, value)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(valueText).font(.title3.monospacedDigit().bold()).foregroundStyle(color)
            }
            Chart {
                ForEach(points, id: \.offset) { idx, v in
                    AreaMark(x: .value("t", idx), y: .value("v", v * 100))
                        .foregroundStyle(color.opacity(0.18))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("t", idx), y: .value("v", v * 100))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                }
            }
            .chartXScale(domain: 0...(window - 1))
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { v in
                    AxisGridLine(); AxisValueLabel { if let i = v.as(Int.self) { Text("\(i)%") } }
                }
            }
            .chartXAxis(.hidden)
            .frame(height: 120)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private var fanCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Tốc độ quạt (SMC)", systemImage: "fanblades").font(.headline)
            ForEach(Array(metrics.fanRPMs.enumerated()), id: \.offset) { idx, rpm in
                HStack {
                    Text("Quạt \(idx + 1)").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(rpm)) RPM").font(.title3.monospacedDigit())
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func metricCard(title: String, valueText: String, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(valueText).font(.title3.monospacedDigit())
            }
            ProgressView(value: max(0, min(1, fraction)))
                .progressViewStyle(.linear)
        }
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func netCard(title: String, icon: String, rate: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.headline)
            Text(Format.rate(rate)).font(.title3.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
