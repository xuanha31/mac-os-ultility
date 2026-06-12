import SwiftUI
import FanControlModule

// FAN-08: UI điều khiển quạt (slider, auto/manual mode).

struct FanView: View {
    @ObservedObject var state: FanState

    var body: some View {
        ProScreen(title: "Quạt") {
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
                ProCard {
                    Label("Thiết bị này không hỗ trợ điều chỉnh tốc độ quạt (Apple Silicon). Hiện chỉ đọc.",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !state.statusMessage.isEmpty {
                Text(state.statusMessage)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Spacer()
            if state.isBusy { ProgressView().controlSize(.small) }
            Button("Làm mới") { state.refresh() }
                .tint(Theme.accent)
        }
    }

    private var emptyState: some View {
        ProCard {
            VStack(spacing: 12) {
                Image(systemName: "fanblades")
                    .font(.system(size: 48))
                    .foregroundStyle(Theme.textTertiary)
                Text("Không tìm thấy quạt.\nMacBook Air (Apple Silicon) không có quạt.")
                    .multilineTextAlignment(.center)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
        }
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
        // Thanh tiến trình tốc độ hiện tại
        let fraction = fan.maxRPM > fan.minRPM
            ? (fan.currentRPM - fan.minRPM) / (fan.maxRPM - fan.minRPM)
            : 0
        ProCard {
            CardHeader(icon: "fanblades", title: "Quạt \(fan.id + 1)",
                       value: "\(Int(fan.currentRPM)) RPM",
                       valueColor: fanColor(fraction: fraction))

            StatBar(fraction: max(0, min(1, fraction)), color: fanColor(fraction: fraction))

            HStack {
                Text("Min: \(Int(fan.minRPM))")
                    .font(Theme.mono(11, .regular))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Text("Max: \(Int(fan.maxRPM))")
                    .font(Theme.mono(11, .regular))
                    .foregroundStyle(Theme.textTertiary)
            }

            if controlEnabled {
                Divider().overlay(Theme.border)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Đặt tốc độ tối thiểu: \(Int(targetRPM)) RPM")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                    Slider(value: $targetRPM, in: fan.minRPM...fan.maxRPM, step: 100)
                        .tint(Theme.accent)
                    HStack {
                        Button("Áp dụng") { onSetMin(targetRPM) }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                        Button("Reset Auto") { onReset() }
                    }
                }
            }
        }
    }

    private func fanColor(fraction: Double) -> Color {
        fraction < 0.5 ? Theme.green : fraction < 0.8 ? Theme.orange : Theme.red
    }
}
