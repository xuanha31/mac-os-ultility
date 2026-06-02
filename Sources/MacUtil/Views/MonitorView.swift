import SwiftUI
import MonitorModule

struct MonitorView: View {
    @ObservedObject var monitor: SystemMonitor

    private var metrics: SystemMetrics { monitor.metrics }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Giám sát hệ thống")
                    .font(.largeTitle.bold())

                metricCard(
                    title: "CPU",
                    valueText: Format.percent(metrics.cpuUsage),
                    fraction: metrics.cpuUsage
                )

                metricCard(
                    title: "Bộ nhớ (RAM)",
                    valueText: "\(Format.bytes(metrics.memoryUsed)) / \(Format.bytes(metrics.memoryTotal))",
                    fraction: metrics.memoryUsedFraction
                )

                HStack(spacing: 16) {
                    netCard(title: "Tải xuống", icon: "arrow.down", rate: metrics.netRxBytesPerSec)
                    netCard(title: "Tải lên", icon: "arrow.up", rate: metrics.netTxBytesPerSec)
                }

                if !monitor.fanSpeedSupported {
                    Label("Tốc độ quạt: cần đọc SMC (chưa bật ở bản này — task MON-04).",
                          systemImage: "fanblades")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(24)
        }
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
