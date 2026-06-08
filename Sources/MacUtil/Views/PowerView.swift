import SwiftUI
import PowerModule
import BatteryModule

/// Màn hình "Nguồn": chống tự ngủ, hibernate, và giới hạn % sạc pin.
struct PowerView: View {
    @ObservedObject var power: PowerState
    @ObservedObject var battery: BatteryState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Nguồn").font(.largeTitle.bold())

                preventSleepCard
                hibernateOnLockCard
                hibernateCard
                batteryLimitCard

                Spacer(minLength: 0)
            }
            .padding(24)
        }
    }

    // MARK: - Chống tự ngủ

    private var preventSleepCard: some View {
        card {
            HStack {
                Label("Không tự động ngủ", systemImage: "cup.and.saucer")
                    .font(.headline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { power.isPreventingSleep },
                    set: { power.setPreventSleep($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            Text("Giữ máy luôn thức bằng `caffeinate -d -i -m -s` (chặn ngủ màn hình, idle, đĩa và hệ thống).")
                .font(.callout).foregroundStyle(.secondary)
            if power.isPreventingSleep {
                Label("Đang chống tự ngủ.", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
            }
        }
    }

    // MARK: - Hibernate khi khoá màn hình

    private var hibernateOnLockCard: some View {
        card {
            HStack {
                Label("Hibernate khi khoá màn hình", systemImage: "lock.zzz")
                    .font(.headline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { power.isHibernateOnLockEnabled },
                    set: { power.setHibernateOnLock($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            Text("Khi macOS khoá phiên làm việc, app tự đổi sang hibernatemode 25 rồi đưa máy vào hibernate. Lần đầu cần cho phép privileged helper; các lần sau không cần nhập mật khẩu.")
                .font(.callout).foregroundStyle(.secondary)
            if power.isHibernateOnLockEnabled {
                Label("Đang bật hibernate khi khoá màn hình.", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
            }
        }
    }

    // MARK: - Hibernate

    private var hibernateCard: some View {
        card {
            HStack {
                Label("Hibernate (ngủ đông)", systemImage: "moon.zzz")
                    .font(.headline)
                Spacer()
                Button("Vào hibernate") { power.hibernateNow() }
                    .buttonStyle(.borderedProminent)
                    .disabled(power.isHibernating)
            }
            Text("Tạm dừng mọi ứng dụng, khoá màn hình rồi đưa máy vào hibernate (ghi RAM ra đĩa). Lần đầu cần cho phép privileged helper; các lần sau không cần nhập mật khẩu.")
                .font(.callout).foregroundStyle(.secondary)
            if !power.statusMessage.isEmpty {
                Text(power.statusMessage).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Giới hạn sạc

    private var batteryLimitCard: some View {
        card {
            HStack {
                Label("Giới hạn sạc tối đa", systemImage:
                        battery.isLimitEnabled ? "powerplug" : "battery.100.bolt")
                    .font(.headline)
                Spacer()
                if let s = battery.snapshot {
                    Text("\(s.percent)%")
                        .font(.title3.monospacedDigit().bold())
                        .foregroundStyle(s.onACPower ? .green : .primary)
                }
                if battery.isBusy { ProgressView().controlSize(.small) }
                Toggle("", isOn: Binding(
                    get: { battery.isLimitEnabled },
                    set: { $0 ? battery.enableLimit() : battery.disableLimit() }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!battery.controlAvailable || battery.isBusy)
            }

            Stepper(value: $battery.maxPercent, in: 20...100, step: 5) {
                Text("Sạc tối đa tới: \(battery.maxPercent)%")
            }
            .disabled(!battery.controlAvailable)

            if battery.needsApply {
                Button("Áp dụng \(battery.maxPercent)%") { battery.applyCurrent() }
                    .buttonStyle(.borderedProminent)
                    .disabled(battery.isBusy)
            }

            Text("Khi đạt ngưỡng, máy ngừng sạc và chạy bằng nguồn điện trực tiếp — pin được giữ ở mức đó để giảm chai. Đổi ngưỡng dùng privileged helper sau khi đã được cho phép.")
                .font(.callout).foregroundStyle(.secondary)

            if battery.isLimitEnabled {
                Label("Đang giới hạn ở \(battery.appliedLimit)%.", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
            }

            if !battery.controlAvailable {
                Label("Thiết bị không có khoá BCLM — model này không hỗ trợ giới hạn sạc.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            } else if !battery.statusMessage.isEmpty {
                Text(battery.statusMessage).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helper

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
