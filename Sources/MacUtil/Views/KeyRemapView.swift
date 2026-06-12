import SwiftUI
import KeyRemapModule

@MainActor
final class KeyRemapViewModel: ObservableObject {
    @Published var statusMessage = ""
    @Published var isError = false
    @Published var persistAcrossReboot = false

    // Custom mapping state
    @Published var customMappings: [(from: KeyRemapper.HIDKey, to: KeyRemapper.HIDKey)] = []
    @Published var newFrom: KeyRemapper.HIDKey = .leftCommand
    @Published var newTo: KeyRemapper.HIDKey = .leftControl

    private let remapper = KeyRemapper()
    private let persistence = LoginPersistence()

    init() {
        persistAcrossReboot = persistence.isInstalled
    }

    func swap() {
        do {
            try remapper.swapCommandShift()
            setStatus("Đã đổi Command ↔ Shift cho phiên hiện tại.", error: false)
            if persistAcrossReboot { try? persistence.install(hidutilJSON: KeyRemapper.swapCommandShiftJSON) }
        } catch {
            setStatus("Lỗi: \(error)", error: true)
        }
    }

    func reset() {
        do {
            try remapper.reset()
            try? persistence.remove()
            persistAcrossReboot = false
            customMappings = []
            setStatus("Đã khôi phục phím mặc định.", error: false)
        } catch {
            setStatus("Lỗi: \(error)", error: true)
        }
    }

    func togglePersistence(_ on: Bool) {
        do {
            if on {
                let json = customMappings.isEmpty
                    ? KeyRemapper.swapCommandShiftJSON
                    : KeyRemapper.buildMappingJSON(customMappings.map { ($0.from, $0.to) })
                try persistence.install(hidutilJSON: json)
                setStatus("Sẽ tự áp dụng remap mỗi lần đăng nhập.", error: false)
            } else {
                try persistence.remove()
                setStatus("Đã tắt giữ remap sau reboot.", error: false)
            }
            persistAcrossReboot = on
        } catch {
            setStatus("Lỗi: \(error)", error: true)
            persistAcrossReboot = persistence.isInstalled
        }
    }

    func addMapping() {
        guard newFrom != newTo else {
            setStatus("Phím nguồn và đích không được giống nhau.", error: true)
            return
        }
        customMappings.append((from: newFrom, to: newTo))
        applyCustom()
    }

    func removeMapping(at offsets: IndexSet) {
        customMappings.remove(atOffsets: offsets)
        applyCustom()
    }

    private func applyCustom() {
        guard !customMappings.isEmpty else { return }
        do {
            try remapper.applyCustomMapping(customMappings.map { ($0.from, $0.to) })
            setStatus("Đã áp dụng \(customMappings.count) remap tùy chỉnh.", error: false)
            if persistAcrossReboot {
                let json = KeyRemapper.buildMappingJSON(customMappings.map { ($0.from, $0.to) })
                try? persistence.install(hidutilJSON: json)
            }
        } catch {
            setStatus("Lỗi: \(error)", error: true)
        }
    }

    private func setStatus(_ message: String, error: Bool) {
        statusMessage = message
        isError = error
    }
}

struct KeyRemapView: View {
    @ObservedObject var viewModel: KeyRemapViewModel

    var body: some View {
        ProScreen(title: "Đổi phím") {
            Text("Đổi phím modifier qua hidutil (không cần quyền Accessibility). Hỗ trợ preset Command ↔ Shift và tạo remap tùy chỉnh.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            presetSection
            customSection

            if !viewModel.statusMessage.isEmpty {
                Label(viewModel.statusMessage, systemImage: viewModel.isError ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.system(size: 12.5))
                    .foregroundStyle(viewModel.isError ? Theme.red : Theme.green)
            }

            Text("Lưu ý: đổi modifier có thể ảnh hưởng phím tắt hệ thống. Dùng nút Khôi phục nếu cần.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var presetSection: some View {
        ProCard {
            CardHeader(icon: "command", title: "preset nhanh")

            HStack(spacing: Theme.gap) {
                Button("Đổi Command ↔ Shift") { viewModel.swap() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                Button("Khôi phục mặc định") { viewModel.reset() }
            }

            Toggle("Giữ sau khi khởi động lại (LaunchAgent)",
                   isOn: Binding(
                    get: { viewModel.persistAcrossReboot },
                    set: { viewModel.togglePersistence($0) }
                   ))
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .tint(Theme.accent)
        }
    }

    private var customSection: some View {
        ProCard {
            CardHeader(icon: "keyboard", title: "remap tùy chỉnh")

            HStack(spacing: Theme.gap) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Từ phím")
                        .font(.system(size: 11, weight: .semibold)).kerning(1)
                        .foregroundStyle(Theme.textTertiary)
                    Picker("", selection: $viewModel.newFrom) {
                        ForEach(KeyRemapper.HIDKey.allCases) { key in
                            Text(key.description).tag(key)
                        }
                    }
                    .labelsHidden()
                    .tint(Theme.accent)
                    .frame(width: 180)
                }

                Image(systemName: "arrow.right")
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 18)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Sang phím")
                        .font(.system(size: 11, weight: .semibold)).kerning(1)
                        .foregroundStyle(Theme.textTertiary)
                    Picker("", selection: $viewModel.newTo) {
                        ForEach(KeyRemapper.HIDKey.allCases) { key in
                            Text(key.description).tag(key)
                        }
                    }
                    .labelsHidden()
                    .tint(Theme.accent)
                    .frame(width: 180)
                }

                Button("Thêm") { viewModel.addMapping() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .padding(.top, 18)
            }

            if viewModel.customMappings.isEmpty {
                Text("Chưa có remap tùy chỉnh nào.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                List {
                    ForEach(Array(viewModel.customMappings.enumerated()), id: \.offset) { idx, pair in
                        HStack {
                            Text(pair.from.description)
                                .font(Theme.mono(12.5))
                                .foregroundStyle(Theme.textPrimary)
                                .frame(width: 160, alignment: .leading)
                            Image(systemName: "arrow.right").foregroundStyle(Theme.textTertiary)
                            Text(pair.to.description)
                                .font(Theme.mono(12.5))
                                .foregroundStyle(Theme.textPrimary)
                                .frame(width: 160, alignment: .leading)
                        }
                        .listRowBackground(Theme.surface2)
                    }
                    .onDelete { offsets in viewModel.removeMapping(at: offsets) }
                }
                .frame(height: min(CGFloat(viewModel.customMappings.count) * 36 + 8, 200))
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.radius))
            }
        }
    }
}
