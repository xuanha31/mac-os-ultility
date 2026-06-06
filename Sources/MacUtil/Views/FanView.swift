import SwiftUI
import FanControlModule

// FAN-08: UI điều khiển quạt (slider, auto/manual mode).

struct FanView: View {
    @ObservedObject var state: FanState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if state.fans.isEmpty {
                    emptyState
                } else {
                    ForEach(state.fans) { fan in
                        FanCard(fan: fan, controlEnabled: state.controlEnabled) { rpm in
                            state.setMinSpeed(rpm, fanIndex: fan.id)
                        } onReset: {
                            state.resetToAuto(fanIndex: fan.id)
                        }
                    }
                }
                if !state.fans.isEmpty && !state.controlEnabled {
                    Label("Thiết bị này không hỗ trợ điều chỉnh tốc độ quạt (Apple Silicon). Hiện chỉ đọc.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .padding(.top, 8)
                }
                if !state.statusMessage.isEmpty {
                    Text(state.statusMessage).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(24)
        }
    }

    private var header: some View {
        HStack {
            Text("Quạt").font(.largeTitle.bold())
            Spacer()
            if state.isBusy { ProgressView().controlSize(.small) }
            Button("Làm mới") { state.refresh() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "fanblades").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Không tìm thấy quạt.\nMacBook Air (Apple Silicon) không có quạt.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }
}

struct FanCard: View {
    let fan: FanInfo
    let controlEnabled: Bool
    let onSetMin: (Double) -> Void
    let onReset: () -> Void

    @State private var targetRPM: Double

    init(fan: FanInfo, controlEnabled: Bool, onSetMin: @escaping (Double) -> Void, onReset: @escaping () -> Void) {
        self.fan = fan
        self.controlEnabled = controlEnabled
        self.onSetMin = onSetMin
        self.onReset = onReset
        _targetRPM = State(initialValue: fan.targetRPM ?? fan.minRPM)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Quạt \(fan.id + 1)", systemImage: "fanblades")
                    .font(.headline)
                Spacer()
                Text("\(Int(fan.currentRPM)) RPM")
                    .font(.title3.monospacedDigit().bold())
            }

            // Thanh tiến trình tốc độ hiện tại
            let fraction = fan.maxRPM > fan.minRPM
                ? (fan.currentRPM - fan.minRPM) / (fan.maxRPM - fan.minRPM)
                : 0
            ProgressView(value: max(0, min(1, fraction)))
                .progressViewStyle(.linear)
                .tint(fanColor(fraction: fraction))

            HStack {
                Text("Min: \(Int(fan.minRPM))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("Max: \(Int(fan.maxRPM))").font(.caption).foregroundStyle(.secondary)
            }

            if controlEnabled {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Đặt tốc độ tối thiểu: \(Int(targetRPM)) RPM")
                        .font(.callout)
                    Slider(value: $targetRPM, in: fan.minRPM...fan.maxRPM, step: 100)
                    HStack {
                        Button("Áp dụng") { onSetMin(targetRPM) }
                            .buttonStyle(.borderedProminent)
                        Button("Reset Auto") { onReset() }
                    }
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func fanColor(fraction: Double) -> Color {
        fraction < 0.5 ? .green : fraction < 0.8 ? .orange : .red
    }
}
