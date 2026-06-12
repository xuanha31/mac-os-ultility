import SwiftUI
import PowerModule
import BatteryModule

/// Màn hình "Nguồn": chống tự ngủ, hibernate, và giới hạn % sạc pin.
struct PowerView: View {
    @ObservedObject var power: PowerState
    @ObservedObject var battery: BatteryState

    var body: some View {
        ProScreen(title: "Nguồn & Pin") {
            preventSleepCard
            hibernateOnLockCard
            hibernateCard
            batteryLimitCard
        }
    }

    // MARK: - Chống tự ngủ

    private var preventSleepCard: some View {
        ProCard(spacing: Theme.gap) {
            HStack {
                CardHeader(icon: "cup.and.saucer", title: "không tự động ngủ")
                Toggle("", isOn: Binding(
                    get: { power.isPreventingSleep },
                    set: { power.setPreventSleep($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Theme.accent)
            }
            Text("Giữ máy luôn thức bằng `caffeinate -d -i -m -s` (chặn ngủ màn hình, idle, đĩa và hệ thống).")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if power.isPreventingSleep {
                statusLabel("Đang chống tự ngủ.", icon: "checkmark.circle.fill", color: Theme.green)
            }
        }
    }

    // MARK: - Hibernate khi khoá màn hình

    private var hibernateOnLockCard: some View {
        ProCard(spacing: Theme.gap) {
            HStack {
                CardHeader(icon: "lock.zzz", title: "hibernate khi khoá màn hình")
                Toggle("", isOn: Binding(
                    get: { power.isHibernateOnLockEnabled },
                    set: { power.setHibernateOnLock($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Theme.accent)
            }
            Text("Khi macOS khoá phiên làm việc, app tự đổi sang hibernatemode 25 rồi đưa máy vào hibernate. Lần đầu cần cho phép privileged helper; các lần sau không cần nhập mật khẩu.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if power.isHibernateOnLockEnabled {
                statusLabel("Đang bật hibernate khi khoá màn hình.", icon: "checkmark.circle.fill", color: Theme.green)
            }
        }
    }

    // MARK: - Hibernate

    private var hibernateCard: some View {
        ProCard(spacing: Theme.gap) {
            HStack {
                CardHeader(icon: "moon.zzz", title: "hibernate (ngủ đông)")
                Button("Vào hibernate") { power.hibernateNow() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(power.isHibernating)
            }
            Text("Tạm dừng mọi ứng dụng, khoá màn hình rồi đưa máy vào hibernate (ghi RAM ra đĩa). Lần đầu cần cho phép privileged helper; các lần sau không cần nhập mật khẩu.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !power.statusMessage.isEmpty {
                Text(power.statusMessage)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    // MARK: - Giới hạn sạc

    private var batteryLimitCard: some View {
        ProCard(spacing: Theme.gap) {
            HStack {
                CardHeader(icon: battery.isLimitEnabled ? "powerplug" : "battery.100.bolt",
                           title: "giới hạn sạc tối đa")
                if let s = battery.snapshot {
                    let w = s.chargingWatts ?? 0
                    Label(String(format: "%.1f W", w), systemImage: w > 0 ? "bolt.fill" : "bolt.slash")
                        .font(Theme.mono(12.5))
                        .foregroundStyle(w > 0 ? Theme.green : Theme.textSecondary)
                    Text("\(s.percent)%")
                        .font(Theme.mono(16))
                        .foregroundStyle(s.onACPower ? Theme.green : Theme.textPrimary)
                }
                if battery.isBusy { ProgressView().controlSize(.small) }
                Toggle("", isOn: Binding(
                    get: { battery.isLimitEnabled },
                    set: { $0 ? battery.enableLimit() : battery.disableLimit() }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Theme.accent)
                .disabled(!battery.controlAvailable || battery.isBusy)
            }

            if let s = battery.snapshot, s.onACPower {
                HStack(spacing: 6) {
                    if let w = s.chargingWatts {
                        Text(String(format: "Đang nạp %.1f W vào pin", w))
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        Text("Đã cắm adapter — pin không nạp thêm")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if let a = s.adapterWatts {
                        Text(String(format: "(adapter %.0f W)", a)).foregroundStyle(Theme.textTertiary)
                    }
                }
                .font(.system(size: 12.5))
            }

            Stepper(value: $battery.maxPercent, in: 20...100, step: 5) {
                Text("Sạc tối đa tới: \(battery.maxPercent)%")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textPrimary)
            }
            .disabled(!battery.controlAvailable)

            if battery.needsApply {
                Button("Áp dụng \(battery.maxPercent)%") { battery.applyCurrent() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(battery.isBusy)
            }

            Text("Khi đạt ngưỡng, máy ngừng sạc và chạy bằng nguồn điện trực tiếp — pin được giữ ở mức đó để giảm chai. Đổi ngưỡng dùng privileged helper sau khi đã được cho phép.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if battery.isLimitEnabled {
                statusLabel("Đang giới hạn ở \(battery.appliedLimit)%.", icon: "checkmark.circle.fill", color: Theme.green)
            }

            if !battery.controlAvailable {
                statusLabel("Thiết bị không có khoá BCLM — model này không hỗ trợ giới hạn sạc.",
                            icon: "exclamationmark.triangle", color: Theme.orange)
            } else if !battery.statusMessage.isEmpty {
                Text(battery.statusMessage)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    // MARK: - Helper

    private func statusLabel(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 12.5))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
