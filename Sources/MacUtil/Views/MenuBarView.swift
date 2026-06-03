import SwiftUI
import Core
import MonitorModule
import ClipboardModule

// Nội dung dropdown của MenuBarExtra (icon trên thanh menu macOS).
// Truy cập nhanh: chỉ số hệ thống + clipboard gần đây + chụp màn hình.

struct MenuBarView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var clipboard: ClipboardState
    let openMainWindow: () -> Void

    @State private var launchAtLogin = false
    private var metrics: SystemMetrics { monitor.metrics }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statsSection
            Divider()
            actionsSection
            Divider()
            clipboardSection
            Divider()
            footer
        }
        .frame(width: 300)
    }

    // MARK: - Stats

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hệ thống").font(.caption.bold()).foregroundStyle(.secondary)
            statRow("CPU", value: Format.percent(metrics.cpuUsage), fraction: metrics.cpuUsage, color: .blue)
            statRow("RAM", value: "\(Format.bytes(metrics.memoryUsed)) / \(Format.bytes(metrics.memoryTotal))",
                    fraction: metrics.memoryUsedFraction, color: .green)
            if let temp = metrics.cpuTemperatureCelsius {
                statRow("Nhiệt độ", value: String(format: "%.0f°C", temp),
                        fraction: min(temp / 100, 1), color: .orange)
            }
            HStack(spacing: 12) {
                Label(Format.rate(metrics.netRxBytesPerSec), systemImage: "arrow.down")
                Label(Format.rate(metrics.netTxBytesPerSec), systemImage: "arrow.up")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private func statRow(_ label: String, value: String, fraction: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: max(0, min(1, fraction))).progressViewStyle(.linear).tint(color)
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(spacing: 4) {
            actionButton("Chụp toàn màn hình", icon: "rectangle.dashed.badge.record",
                         shortcut: "⌘⇧1") { clipboard.captureFullScreen() }
            actionButton("Chụp vùng chọn", icon: "crop",
                         shortcut: "⌘⇧2") { clipboard.captureSelection() }
            actionButton("Mở Clipboard Manager", icon: "clipboard",
                         shortcut: "⌘⇧V") {
                NotificationCenter.default.post(name: .openClipboard, object: nil)
                openMainWindow()
            }
        }
        .padding(.vertical, 4)
    }

    private func actionButton(_ title: String, icon: String, shortcut: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                Text(shortcut)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    // MARK: - Clipboard

    private var clipboardSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Clipboard gần đây").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Text("\(clipboard.history.count)").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.top, 8)

            if clipboard.history.isEmpty {
                Text("Chưa có mục nào.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            } else {
                ForEach(clipboard.history.prefix(5)) { item in
                    Button {
                        clipboard.paste(item)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: icon(for: item))
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(item.content.displayTitle)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 3)
                }
                .padding(.bottom, 6)
            }
        }
    }

    private func icon(for item: ClipboardItem) -> String {
        switch item.content {
        case .text:    return "doc.text"
        case .image:   return "photo"
        case .fileURL: return "doc"
        case .other:   return "questionmark.square"
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { launchAtLogin },
                set: { on in launchAtLogin = LoginItem.setEnabled(on) ? on : launchAtLogin }
            )) {
                Label("Khởi động cùng macOS", systemImage: "power")
            }
            .toggleStyle(.switch)
            .padding(.horizontal, 12)

            HStack {
                Button("Mở MacUtil") { openMainWindow() }
                Spacer()
                Button("Thoát") { NSApp.terminate(nil) }
                    .foregroundStyle(.red)
            }
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
        .onAppear { launchAtLogin = LoginItem.isEnabled }
    }
}
