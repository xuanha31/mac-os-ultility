import SwiftUI
import CleanerModule

@MainActor
final class CleanerViewModel: ObservableObject {
    @Published var targets: [CleanTarget] = []
    @Published var selected: Set<URL> = []
    @Published var isBusy = false
    @Published var statusMessage = ""

    private let cleaner = TempCleaner()

    init() {
        targets = cleaner.defaultTargets()
        selected = Set(targets.filter { $0.exists }.map { $0.id })
    }

    var totalSelectedBytes: UInt64 {
        targets.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.sizeBytes }
    }

    func scan() {
        isBusy = true
        statusMessage = "Đang quét…"
        let current = targets
        let cleaner = self.cleaner
        Task.detached {
            let scanned = cleaner.scan(current)
            await MainActor.run {
                self.targets = scanned
                self.isBusy = false
                self.statusMessage = "Đã quét xong."
            }
        }
    }

    func clean(dryRun: Bool) {
        isBusy = true
        statusMessage = dryRun ? "Đang tính (dry-run)…" : "Đang dọn…"
        let toClean = targets.filter { selected.contains($0.id) }
        let allTargets = targets
        let cleaner = self.cleaner
        Task.detached {
            var freed: UInt64 = 0
            var failedCount = 0
            for target in toClean {
                let result = cleaner.clean(target, dryRun: dryRun)
                freed += result.freedBytes
                failedCount += result.failedItems.count
            }
            let rescanned = cleaner.scan(allTargets)
            await MainActor.run {
                self.targets = rescanned
                self.isBusy = false
                let verb = dryRun ? "Sẽ giải phóng" : "Đã giải phóng"
                let suffix = failedCount > 0 ? " (\(failedCount) mục bị bỏ qua do thiếu quyền)" : ""
                self.statusMessage = "\(verb) ~\(Format.bytes(freed))\(suffix)"
            }
        }
    }
}

struct CleanerView: View {
    @StateObject private var viewModel = CleanerViewModel()
    @State private var dryRun = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Dọn dẹp file tạm")
                .font(.largeTitle.bold())

            Text("Chọn mục muốn dọn rồi bấm Quét để tính dung lượng. ⚠️ Nên đóng các app liên quan trước khi dọn.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List {
                ForEach(viewModel.targets) { target in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { viewModel.selected.contains(target.id) },
                            set: { isOn in
                                if isOn { viewModel.selected.insert(target.id) }
                                else { viewModel.selected.remove(target.id) }
                            }
                        ))
                        .labelsHidden()
                        .disabled(!target.exists)

                        VStack(alignment: .leading) {
                            Text(target.name).font(.headline)
                            Text(target.url.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        if target.exists {
                            Text(Format.bytes(target.sizeBytes)).monospacedDigit()
                        } else {
                            Text("Không tồn tại").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(minHeight: 220)

            HStack {
                Toggle("Dry-run (chỉ tính, không xoá)", isOn: $dryRun)
                Spacer()
                Text("Đã chọn: \(Format.bytes(viewModel.totalSelectedBytes))")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Quét") { viewModel.scan() }
                    .disabled(viewModel.isBusy)

                Button(dryRun ? "Tính (dry-run)" : "Dọn ngay") {
                    viewModel.clean(dryRun: dryRun)
                }
                .disabled(viewModel.isBusy || viewModel.selected.isEmpty)
                .tint(dryRun ? .accentColor : .red)

                if viewModel.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Text(viewModel.statusMessage).foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }
}
