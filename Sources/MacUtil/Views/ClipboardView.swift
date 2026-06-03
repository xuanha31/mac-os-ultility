import SwiftUI
import ClipboardModule

// Clipboard Manager + Screenshot — giống Windows + V

struct ClipboardView: View {
    @ObservedObject var state: ClipboardState
    @State private var selectedItem: ClipboardItem?
    @State private var showClearConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            Divider()
            HSplitView {
                listPanel.frame(minWidth: 280, maxWidth: 360)
                detailPanel
            }
        }
        .confirmationDialog("Xóa toàn bộ lịch sử clipboard?", isPresented: $showClearConfirm) {
            Button("Xóa tất cả", role: .destructive) { state.clearAll() }
            Button("Hủy", role: .cancel) {}
        }
    }

    // MARK: - Action bar (hiển thị rõ, không dùng .toolbar)

    private var actionBar: some View {
        HStack(spacing: 12) {
            Text("Clipboard").font(.title2.bold())
            Spacer()
            Button {
                state.captureFullScreen()
            } label: {
                HStack(spacing: 6) {
                    Label("Chụp màn hình", systemImage: "rectangle.dashed.badge.record")
                    shortcutBadge("⌘⇧1")
                }
            }
            .help("Chụp toàn màn hình → clipboard")
            .keyboardShortcut("1", modifiers: [.command, .shift])

            Button {
                state.captureSelection()
            } label: {
                HStack(spacing: 6) {
                    Label("Chụp vùng chọn", systemImage: "crop")
                    shortcutBadge("⌘⇧2")
                }
            }
            .help("Kéo chọn vùng để chụp")
            .keyboardShortcut("2", modifiers: [.command, .shift])
            .disabled(state.isCaptureInProgress)

            Button(role: .destructive) { showClearConfirm = true } label: {
                Label("Xóa lịch sử", systemImage: "trash")
            }
            .help("Xóa toàn bộ lịch sử clipboard")
            .disabled(state.history.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func shortcutBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - List panel

    private var listPanel: some View {
        VStack(spacing: 0) {
            searchBar
            filterBar
            // Hướng dẫn dán
            Text("Double-click (hoặc nút ⤴) để copy mục vào clipboard, rồi sang app cần dán bấm ⌘V.")
                .font(.caption2).foregroundStyle(.tertiary)
                .padding(.horizontal, 10).padding(.bottom, 4)
            Divider()
            if state.filteredHistory.isEmpty {
                emptyState
            } else {
                List(state.filteredHistory, selection: $selectedItem) { item in
                    HStack(spacing: 6) {
                        ClipboardRow(item: item)
                        Spacer(minLength: 0)
                        Button { state.paste(item) } label: { Image(systemName: "arrow.up.doc.on.clipboard") }
                            .buttonStyle(.borderless)
                            .help("Copy vào clipboard để dán")
                    }
                    .tag(item)
                    .contextMenu {
                        Button("Copy vào clipboard (để dán)") { state.paste(item) }
                        Button("Xóa", role: .destructive) {
                            if selectedItem?.id == item.id { selectedItem = nil }
                            state.delete(item)
                        }
                    }
                    .onTapGesture(count: 2) { state.paste(item) }
                }
                .listStyle(.inset)
            }

            if !state.statusMessage.isEmpty {
                Text(state.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Tìm kiếm…", text: $state.searchText)
                .textFieldStyle(.plain)
            if !state.searchText.isEmpty {
                Button { state.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var filterBar: some View {
        HStack(spacing: 4) {
            ForEach(ClipboardState.FilterType.allCases, id: \.self) { type in
                Button(type.rawValue) { state.filterType = type }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        state.filterType == type
                            ? Color.accentColor.opacity(0.15)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .foregroundStyle(state.filterType == type ? .primary : .secondary)
                    .font(.caption)
            }
            Spacer()
            Text("\(state.filteredHistory.count) mục")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.trailing, 8)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clipboard")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(state.history.isEmpty ? "Chưa có mục nào trong lịch sử." : "Không có kết quả.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Detail panel

    private var detailPanel: some View {
        Group {
            if let item = selectedItem {
                ClipboardDetailView(item: item) {
                    state.paste(item)
                } onDelete: {
                    selectedItem = nil
                    state.delete(item)
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "clipboard")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Chọn mục để xem chi tiết")
                        .foregroundStyle(.secondary)
                    Text("Double-click để dán vào clipboard")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Clipboard row

struct ClipboardRow: View {
    let item: ClipboardItem

    var body: some View {
        HStack(spacing: 10) {
            contentIcon
                .frame(width: 32, height: 32)
                .background(iconBackground, in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.content.displayTitle)
                    .font(.callout)
                    .lineLimit(2)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    if let src = item.source {
                        Text(src).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Text(item.timestamp, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var contentIcon: some View {
        switch item.content {
        case .text:
            Image(systemName: "doc.text").font(.system(size: 14)).foregroundStyle(.blue)
        case .image(let d):
            if let ns = NSImage(data: d) {
                Image(nsImage: ns).resizable().scaledToFill()
                    .clipped()
            } else {
                Image(systemName: "photo").font(.system(size: 14)).foregroundStyle(.purple)
            }
        case .fileURL:
            Image(systemName: "doc.badge.arrow.up").font(.system(size: 14)).foregroundStyle(.orange)
        case .other:
            Image(systemName: "questionmark.square").font(.system(size: 14)).foregroundStyle(.secondary)
        }
    }

    private var iconBackground: Color {
        switch item.content {
        case .text:    return .blue.opacity(0.1)
        case .image:   return .purple.opacity(0.1)
        case .fileURL: return .orange.opacity(0.1)
        case .other:   return .secondary.opacity(0.1)
        }
    }
}

// MARK: - Detail view

struct ClipboardDetailView: View {
    let item: ClipboardItem
    let onPaste: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(typeLabel).font(.headline)
                    HStack(spacing: 8) {
                        if let src = item.source {
                            Label(src, systemImage: "app").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(item.timestamp, format: .dateTime.day().month().year().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Dán") { onPaste() }.buttonStyle(.borderedProminent)
                Button(role: .destructive) { onDelete() } label: {
                    Image(systemName: "trash")
                }
            }
            .padding(16)
            Divider()

            // Content preview
            ScrollView {
                contentPreview.padding(16)
            }
        }
    }

    private var typeLabel: String {
        switch item.content {
        case .text:    return "Văn bản"
        case .image:   return "Ảnh"
        case .fileURL: return "File"
        case .other(let t): return t
        }
    }

    @ViewBuilder
    private var contentPreview: some View {
        switch item.content {
        case .text(let s):
            Text(s)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .image(let d):
            if let ns = NSImage(data: d) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(nsImage: ns)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 400)
                        .cornerRadius(8)
                    Text("\(Int(ns.size.width)) × \(Int(ns.size.height)) px")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        case .fileURL(let paths):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(paths, id: \.self) { path in
                    HStack(spacing: 8) {
                        Image(systemName: "doc")
                            .foregroundStyle(.orange)
                        Text(path)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

        case .other(let t):
            Text("Loại: \(t) — không có preview.").foregroundStyle(.secondary)
        }
    }
}
