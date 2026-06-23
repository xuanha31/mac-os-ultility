import SwiftUI
import AppKit
import KeyRemapModule

@MainActor
final class KeyRemapViewModel: ObservableObject {
    enum CaptureTarget { case from, to }

    @Published var statusMessage = ""
    @Published var isError = false
    @Published var persistAcrossReboot = false

    // Custom mapping state
    @Published var customMappings: [(from: KeyRemapper.HIDKey, to: KeyRemapper.HIDKey)] = []
    @Published var newFrom: KeyRemapper.HIDKey = .leftCommand
    @Published var newTo: KeyRemapper.HIDKey = .leftControl

    /// Đang chờ người dùng bấm phím để chọn (nil = không bắt).
    @Published var capturingTarget: CaptureTarget?
    private var eventMonitor: Any?

    private let remapper = KeyRemapper()
    private let persistence = LoginPersistence()
    private let defaults = UserDefaults.standard
    private let kMappingsKey = "keyRemap.customMappings.v1"   // Data([[UInt64]]) — cặp from/to usage
    private let kActiveKey = "keyRemap.active.v1"             // "none" | "preset" | "custom"

    init() {
        persistAcrossReboot = persistence.isInstalled
        loadAndReapply()
    }

    /// Nạp remap đã lưu và ÁP LẠI. hidutil --set chỉ theo phiên đăng nhập, nên phải áp lại
    /// mỗi lần mở app thì phím mới được giữ (trước đây không lưu → mở lại là mất).
    private func loadAndReapply() {
        if let data = defaults.data(forKey: kMappingsKey),
           let pairs = try? JSONDecoder().decode([[UInt64]].self, from: data) {
            let byUsage = Dictionary(KeyRemapper.HIDKey.all.map { ($0.usage, $0) },
                                     uniquingKeysWith: { a, _ in a })
            customMappings = pairs.compactMap { p in
                guard p.count == 2, let f = byUsage[p[0]], let t = byUsage[p[1]] else { return nil }
                return (from: f, to: t)
            }
        }
        switch defaults.string(forKey: kActiveKey) {
        case "custom" where !customMappings.isEmpty:
            _ = try? remapper.applyCustomMapping(customMappings.map { ($0.from, $0.to) })
        case "preset":
            try? remapper.swapCommandShift()
        default:
            break
        }
    }

    private func saveMappings() {
        let pairs = customMappings.map { [$0.from.usage, $0.to.usage] }
        if let data = try? JSONEncoder().encode(pairs) { defaults.set(data, forKey: kMappingsKey) }
    }

    private func setActive(_ value: String) { defaults.set(value, forKey: kActiveKey) }

    func swap() {
        do {
            try remapper.swapCommandShift()
            setActive("preset")
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
            saveMappings()
            setActive("none")
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
        if customMappings.isEmpty {
            // Không còn remap tùy chỉnh → xoá mapping đang áp dụng.
            try? remapper.reset()
            saveMappings()
            setActive("none")
            setStatus("Đã xoá remap tùy chỉnh.", error: false)
        } else {
            applyCustom()
        }
    }

    // MARK: - Bắt phím khi bấm

    /// Bật chế độ "bấm phím để chọn" cho ô Từ/Sang. Dùng NSEvent *local*
    /// monitor — chỉ hoạt động khi cửa sổ app đang focus, KHÔNG cần quyền
    /// Accessibility.
    func startCapture(_ target: CaptureTarget) {
        stopCapture()
        capturingTarget = target
        setStatus("Đang chờ… bấm phím bất kỳ trên bàn phím (Esc để huỷ).", error: false)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            // Local monitor luôn chạy trên main thread.
            MainActor.assumeIsolated {
                guard let self else { return event }
                return self.handleCapture(event)
            }
        }
    }

    func stopCapture() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        capturingTarget = nil
    }

    /// Trả `nil` để nuốt sự kiện (không cho gõ ra ngoài) sau khi đã chọn.
    private func handleCapture(_ event: NSEvent) -> NSEvent? {
        guard let target = capturingTarget else { return event }

        // Esc để huỷ (vẫn chọn được Esc qua danh sách nhóm "Điều khiển").
        if event.type == .keyDown, event.keyCode == 0x35 {
            stopCapture()
            setStatus("Đã huỷ bắt phím.", error: false)
            return nil
        }

        // flagsChanged: chỉ nhận lúc NHẤN (còn modifier đang bật), bỏ lúc nhả.
        if event.type == .flagsChanged {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.isEmpty { return nil }
        }

        if let key = KeyRemapper.HIDKey.from(virtualKeyCode: event.keyCode) {
            switch target {
            case .from: newFrom = key
            case .to:   newTo = key
            }
            setStatus("Đã chọn phím: \(key.description)", error: false)
            stopCapture()
            return nil
        }

        setStatus("Không nhận dạng được phím vừa bấm (keyCode \(event.keyCode)). Hãy chọn trong danh sách.", error: true)
        stopCapture()
        return nil
    }

    private func applyCustom() {
        guard !customMappings.isEmpty else { return }
        do {
            try remapper.applyCustomMapping(customMappings.map { ($0.from, $0.to) })
            saveMappings()
            setActive("custom")
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
            Text("Đổi phím qua hidutil (không cần quyền Accessibility). Hỗ trợ preset Command ↔ Shift và tạo remap tùy chỉnh cho mọi phím — kể cả phím Nhật (英数/かな/変換…).")
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

            Text("Lưu ý: đổi phím có thể ảnh hưởng phím tắt hệ thống. Dùng nút Khôi phục nếu cần.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onDisappear { viewModel.stopCapture() }
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

            HStack(alignment: .bottom, spacing: Theme.gap) {
                keyField(title: "Từ phím", selection: $viewModel.newFrom, target: .from)

                Image(systemName: "arrow.right")
                    .foregroundStyle(Theme.accent)
                    .padding(.bottom, 6)

                keyField(title: "Sang phím", selection: $viewModel.newTo, target: .to)

                Button("Thêm") { viewModel.addMapping() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }

            if viewModel.capturingTarget != nil {
                Label("Đang chờ… bấm phím bất kỳ trên bàn phím (Esc để huỷ).", systemImage: "dot.radiowaves.left.and.right")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
            } else {
                Text("Mẹo: bấm nút ◉ rồi gõ phím trên bàn phím để chọn nhanh (kể cả phím Nhật), khỏi phải tìm trong danh sách.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if viewModel.customMappings.isEmpty {
                Text("Chưa có remap tùy chỉnh nào.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                List {
                    ForEach(Array(viewModel.customMappings.enumerated()), id: \.offset) { _, pair in
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

    /// Ô chọn 1 phím: Picker chia nhóm + nút bắt phím khi bấm.
    private func keyField(title: String,
                          selection: Binding<KeyRemapper.HIDKey>,
                          target: KeyRemapViewModel.CaptureTarget) -> some View {
        let capturing = viewModel.capturingTarget == target
        return VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold)).kerning(1)
                .foregroundStyle(Theme.textTertiary)

            HStack(spacing: 6) {
                Picker("", selection: selection) {
                    ForEach(KeyRemapper.KeyCategory.allCases) { category in
                        Section(header: Text(category.rawValue)) {
                            ForEach(KeyRemapper.HIDKey.keys(in: category)) { key in
                                Text(key.description).tag(key)
                            }
                        }
                    }
                }
                .labelsHidden()
                .tint(Theme.accent)
                .frame(width: 180)

                Button {
                    if capturing { viewModel.stopCapture() }
                    else { viewModel.startCapture(target) }
                } label: {
                    Image(systemName: capturing ? "record.circle.fill" : "record.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(capturing ? Theme.red : Theme.accent)
                }
                .buttonStyle(.plain)
                .help("Bấm rồi gõ phím trên bàn phím để chọn")
            }
        }
    }
}
