import SwiftUI
import AppKit
import CleanerModule

@MainActor
final class DiskScanViewModel: ObservableObject {
    @Published var root: DiskNode?
    @Published var scannedPath = ""

    func chooseAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Quét"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scannedPath = url.path
        let r = DiskScanner.makeRoot(url)
        root = r
        r.loadChildrenIfNeeded()   // nạp cấp 1 ngay
    }
}

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

enum CleanerMode: String, CaseIterable, Identifiable {
    case temp = "Dọn file tạm"
    case disk = "Phân tích dung lượng đĩa"
    var id: String { rawValue }
}

struct CleanerView: View {
    @ObservedObject var cleaner: CleanerViewModel
    @ObservedObject var diskScan: DiskScanViewModel
    @State private var mode: CleanerMode = .temp

    var body: some View {
        ProScreen(title: "Dọn dẹp") {
            Picker("", selection: $mode) {
                ForEach(CleanerMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)

            switch mode {
            case .temp: TempCleanerView(viewModel: cleaner)
            case .disk: DiskScanView(vm: diskScan)
            }
        }
    }
}

// MARK: - #3: Phân tích dung lượng đĩa (cây folder/file)

struct DiskScanView: View {
    @ObservedObject var vm: DiskScanViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            ProCard {
                HStack(spacing: 8) {
                    Button { vm.chooseAndScan() } label: { Label("Chọn thư mục & quét", systemImage: "folder.badge.magnifyingglass") }
                    if !vm.scannedPath.isEmpty {
                        Text(vm.scannedPath).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if let r = vm.root {
                        Text("Tổng: \(Format.bytes(UInt64(max(0, r.size))))")
                            .font(Theme.mono(12.5))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }

            if let root = vm.root {
                ProCard {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(root.children ?? []) { child in
                                DiskNodeRow(node: child, rootSize: root.size, depth: 0)
                            }
                            if root.isLoading && (root.children?.isEmpty ?? true) {
                                HStack {
                                    ProgressView().controlSize(.small)
                                    Text("Đang quét…").font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                                }
                                .padding(8)
                            }
                        }
                    }
                    .frame(minHeight: 240, maxHeight: 480)
                }
            } else {
                ProCard { ContentUnavailableLabel() }
            }
        }
    }
}

/// Một dòng trong cây — tự nạp con khi mở (lazy), không nghẽn.
private struct DiskNodeRow: View {
    @ObservedObject var node: DiskNode
    let rootSize: Int64
    let depth: Int
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: chevron)
                    .font(.caption2).foregroundStyle(Theme.textTertiary).frame(width: 12)
                    .opacity(node.isDirectory ? 1 : 0)
                Image(systemName: node.isDirectory ? "folder.fill" : "doc")
                    .foregroundStyle(node.isDirectory ? Theme.accent : Theme.textTertiary).frame(width: 16)
                Text(node.name).font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 12)
                bar
                Text(Format.bytes(UInt64(max(0, node.size))))
                    .font(Theme.mono(12.5)).foregroundStyle(Theme.textSecondary)
                    .frame(width: 80, alignment: .trailing)
                if node.isLoading { ProgressView().controlSize(.mini) }
            }
            .padding(.vertical, 3)
            .padding(.leading, CGFloat(depth) * 16 + 4)
            .contentShape(Rectangle())
            .onTapGesture { toggle() }
            .contextMenu {
                Button("Hiện trong Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
                Button("Copy đường dẫn") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(node.url.path, forType: .string)
                }
            }

            if expanded {
                ForEach(node.children ?? []) { child in
                    DiskNodeRow(node: child, rootSize: rootSize, depth: depth + 1)
                }
            }
        }
    }

    private var chevron: String { expanded ? "chevron.down" : "chevron.right" }

    private func toggle() {
        guard node.isDirectory else { return }
        expanded.toggle()
        if expanded { node.loadChildrenIfNeeded() }
    }

    private var fraction: Double { rootSize > 0 ? Double(node.size) / Double(rootSize) : 0 }

    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(barColor)
                    .frame(width: max(2, geo.size.width * fraction))
            }
        }
        .frame(width: 90, height: 6)
    }

    private var barColor: Color { fraction > 0.5 ? Theme.red : fraction > 0.2 ? Theme.orange : Theme.green }
}

private struct ContentUnavailableLabel: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "internaldrive").font(.system(size: 40)).foregroundStyle(Theme.textTertiary)
            Text("Chọn một thư mục để phân tích dung lượng (folder/file lớn xếp lên đầu).")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 24)
    }
}

// MARK: - Dọn file tạm (giữ nguyên)

struct TempCleanerView: View {
    @ObservedObject var viewModel: CleanerViewModel
    @State private var dryRun = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Text("Chọn mục muốn dọn rồi bấm Quét để tính dung lượng. ⚠️ Nên đóng các app liên quan trước khi dọn.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ProCard(spacing: 0) {
                ForEach(Array(viewModel.targets.enumerated()), id: \.element.id) { idx, target in
                    if idx > 0 {
                        Divider().overlay(Theme.border)
                    }
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { viewModel.selected.contains(target.id) },
                            set: { isOn in
                                if isOn { viewModel.selected.insert(target.id) }
                                else { viewModel.selected.remove(target.id) }
                            }
                        ))
                        .labelsHidden()
                        .disabled(!target.exists)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(target.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(target.url.path)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        if target.exists {
                            Text(Format.bytes(target.sizeBytes))
                                .font(Theme.mono(12.5))
                                .foregroundStyle(Theme.textSecondary)
                        } else {
                            Text("Không tồn tại")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }

            ProCard {
                HStack {
                    Toggle("Dry-run (chỉ tính, không xoá)", isOn: $dryRun)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text("Đã chọn: \(Format.bytes(viewModel.totalSelectedBytes))")
                        .font(Theme.mono(12.5))
                        .foregroundStyle(Theme.textPrimary)
                }

                Divider().overlay(Theme.border)

                HStack(spacing: 8) {
                    Button("Quét") { viewModel.scan() }
                        .disabled(viewModel.isBusy)

                    Button(dryRun ? "Tính (dry-run)" : "Dọn ngay") {
                        viewModel.clean(dryRun: dryRun)
                    }
                    .disabled(viewModel.isBusy || viewModel.selected.isEmpty)
                    .tint(dryRun ? Theme.accent : Theme.red)

                    if viewModel.isBusy { ProgressView().controlSize(.small) }
                    Spacer()
                    Text(viewModel.statusMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}
