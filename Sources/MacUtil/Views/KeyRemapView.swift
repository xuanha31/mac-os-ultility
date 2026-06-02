import SwiftUI
import KeyRemapModule

@MainActor
final class KeyRemapViewModel: ObservableObject {
    @Published var statusMessage = ""
    @Published var isError = false
    @Published var persistAcrossReboot = false

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
            setStatus("Đã khôi phục phím mặc định.", error: false)
        } catch {
            setStatus("Lỗi: \(error)", error: true)
        }
    }

    func togglePersistence(_ on: Bool) {
        do {
            if on {
                try persistence.install(hidutilJSON: KeyRemapper.swapCommandShiftJSON)
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

    private func setStatus(_ message: String, error: Bool) {
        statusMessage = message
        isError = error
    }
}

struct KeyRemapView: View {
    @StateObject private var viewModel = KeyRemapViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Đổi phím")
                .font(.largeTitle.bold())

            Text("Đổi phím modifier qua hidutil (không cần quyền Accessibility). Hiện hỗ trợ hoán đổi Command ↔ Shift (cả trái và phải).")
                .font(.callout)
                .foregroundStyle(.secondary)

            GroupBox {
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

            if !viewModel.statusMessage.isEmpty {
                Label(viewModel.statusMessage, systemImage: viewModel.isError ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(viewModel.isError ? .red : .green)
            }

            Text("Lưu ý: đổi modifier có thể ảnh hưởng phím tắt hệ thống. Dùng nút Khôi phục nếu cần.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(24)
    }
}
