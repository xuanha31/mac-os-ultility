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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Đổi phím")
                    .font(.largeTitle.bold())

                Text("Đổi phím modifier qua hidutil (không cần quyền Accessibility). Hỗ trợ preset Command ↔ Shift và tạo remap tùy chỉnh.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                presetSection
                customSection

                if !viewModel.statusMessage.isEmpty {
                    Label(viewModel.statusMessage, systemImage: viewModel.isError ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(viewModel.isError ? .red : .green)
                }

                Text("Lưu ý: đổi modifier có thể ảnh hưởng phím tắt hệ thống. Dùng nút Khôi phục nếu cần.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }

    private var presetSection: some View {
        GroupBox("Preset nhanh") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("Đổi Command ↔ Shift") { viewModel.swap() }
                        .buttonStyle(.borderedProminent)
                    Button("Khôi phục mặc định") { viewModel.reset() }
                }

                Toggle("Giữ sau khi khởi động lại (LaunchAgent)",
                       isOn: Binding(
                        get: { viewModel.persistAcrossReboot },
                        set: { viewModel.togglePersistence($0) }
                       ))
            }
            .padding(8)
        }
    }

    private var customSection: some View {
        GroupBox("Remap tùy chỉnh") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Từ phím").font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: $viewModel.newFrom) {
                            ForEach(KeyRemapper.HIDKey.allCases) { key in
                                Text(key.description).tag(key)
                            }
                        }
                        .frame(width: 180)
                    }

                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                        .padding(.top, 18)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sang phím").font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: $viewModel.newTo) {
                            ForEach(KeyRemapper.HIDKey.allCases) { key in
                                Text(key.description).tag(key)
                            }
                        }
                        .frame(width: 180)
                    }

                    Button("Thêm") { viewModel.addMapping() }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 18)
                }

                if viewModel.customMappings.isEmpty {
                    Text("Chưa có remap tùy chỉnh nào.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                } else {
                    List {
                        ForEach(Array(viewModel.customMappings.enumerated()), id: \.offset) { idx, pair in
                            HStack {
                                Text(pair.from.description)
                                    .frame(width: 160, alignment: .leading)
                                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                Text(pair.to.description)
                                    .frame(width: 160, alignment: .leading)
                            }
                        }
                        .onDelete { offsets in viewModel.removeMapping(at: offsets) }
                    }
                    .frame(height: min(CGFloat(viewModel.customMappings.count) * 36 + 8, 200))
                    .listStyle(.inset)
                }
            }
            .padding(8)
        }
    }
}
