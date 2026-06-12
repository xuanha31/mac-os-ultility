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
            Divider().overlay(Theme.border)
            HSplitView {
                listPanel.frame(minWidth: 280, maxWidth: 360)
                detailPanel
            }
        }
        .background(Theme.bg)
        .confirmationDialog("Xóa toàn bộ lịch sử clipboard?", isPresented: $showClearConfirm) {
            Button("Xóa tất cả", role: .destructive) { state.clearAll() }
            Button("Hủy", role: .cancel) {}
        }
    }

    // MARK: - Action bar (hiển thị rõ, không dùng .toolbar)

    private var actionBar: some View {
        HStack(spacing: 12) {
            Text("CLIPBOARD")
                .font(.system(size: 18, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(Theme.textPrimary)
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
        .background(Theme.bg)
    }

    private func shortcutBadge(_ text: String) -> some View {
        Text(text)
            .font(Theme.mono(10, .regular))
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - List panel

    private var listPanel: some View {
        VStack(spacing: 0) {
            searchBar
            filterBar
            // Hướng dẫn dán
            Text("Double-click (hoặc nút ⤴) để copy mục vào clipboard, rồi sang app cần dán bấm ⌘V.")
                .font(.caption2).foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 10).padding(.bottom, 4)
            Divider().overlay(Theme.border)
            if state.filteredHistory.isEmpty {
                emptyState
            } else {
                List(state.filteredHistory, selection: $selectedItem) { item in
                    HStack(spacing: 6) {
                        ClipboardRow(item: item)
                        Spacer(minLength: 0)
                        Button { state.paste(item) } label: { Image(systemName: "arrow.up.doc.on.clipboard") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Theme.accent)
                            .help("Copy vào clipboard để dán")
                    }
                    .listRowBackground(Color.clear)
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
                .scrollContentBackground(.hidden)
                .background(Theme.bg)
            }

            if !state.statusMessage.isEmpty {
                Text(state.statusMessage)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface)
            }
        }
        .background(Theme.bg)
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
            TextField("Tìm kiếm…", text: $state.searchText)
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.textPrimary)
            if !state.searchText.isEmpty {
                Button { state.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .padding(.horizontal, 10)
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
                            ? Theme.accent.opacity(0.15)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .foregroundStyle(state.filterType == type ? Theme.accent : Theme.textSecondary)
                    .font(.caption)
            }
            Spacer()
            Text("\(state.filteredHistory.count) mục")
                .font(Theme.mono(10, .regular))
                .foregroundStyle(Theme.textTertiary)
                .padding(.trailing, 8)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clipboard")
                .font(.system(size: 36))
                .foregroundStyle(Theme.textTertiary)
            Text(state.history.isEmpty ? "Chưa có mục nào trong lịch sử." : "Không có kết quả.")
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
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
                        .foregroundStyle(Theme.textTertiary)
                    Text("Chọn mục để xem chi tiết")
                        .foregroundStyle(Theme.textSecondary)
                    Text("Double-click để dán vào clipboard")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
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
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    if let src = item.source {
                        Text(src).font(.caption2).foregroundStyle(Theme.textTertiary)
                    }
                    Text(item.timestamp, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var contentIcon: some View {
        switch item.content {
        case .text:
            Image(systemName: "doc.text").font(.system(size: 14)).foregroundStyle(Theme.accent)
        case .image(let d):
            if let ns = NSImage(data: d) {
                Image(nsImage: ns).resizable().scaledToFill()
                    .clipped()
            } else {
                Image(systemName: "photo").font(.system(size: 14)).foregroundStyle(Theme.purple)
            }
        case .fileURL:
            Image(systemName: "doc.badge.arrow.up").font(.system(size: 14)).foregroundStyle(Theme.orange)
        case .other:
            Image(systemName: "questionmark.square").font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
        }
    }

    private var iconBackground: Color {
        switch item.content {
        case .text:    return Theme.accent.opacity(0.12)
        case .image:   return Theme.purple.opacity(0.12)
        case .fileURL: return Theme.orange.opacity(0.12)
        case .other:   return Theme.surface2
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
                    Text(typeLabel)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    HStack(spacing: 8) {
                        if let src = item.source {
                            Label(src, systemImage: "app").font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Text(item.timestamp, format: .dateTime.day().month().year().hour().minute())
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
                Button("Dán") { onPaste() }.buttonStyle(.borderedProminent).tint(Theme.accent)
                Button(role: .destructive) { onDelete() } label: {
                    Image(systemName: "trash")
                }
                .tint(Theme.red)
            }
            .padding(16)
            Divider().overlay(Theme.border)

            // Content preview
            ScrollView {
                contentPreview.padding(16)
            }
            .scrollContentBackground(.hidden)
        }
        .background(Theme.bg)
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
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .image(let d):
            if let ns = NSImage(data: d) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(nsImage: ns)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 400)
                        .cornerRadius(Theme.radius)
                    Text("\(Int(ns.size.width)) × \(Int(ns.size.height)) px")
                        .font(Theme.mono(11, .regular))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

        case .fileURL(let paths):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(paths, id: \.self) { path in
                    HStack(spacing: 8) {
                        Image(systemName: "doc")
                            .foregroundStyle(Theme.orange)
                        Text(path)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                    }
                }
            }

        case .other(let t):
            Text("Loại: \(t) — không có preview.").foregroundStyle(Theme.textSecondary)
        }
    }
}
