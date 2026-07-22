import SwiftUI
import AppKit
import SignModule
import UniformTypeIdentifiers

struct SignView: View {
    @ObservedObject var state: SignState
    @State private var showAddApp = false

    var body: some View {
        HSplitView {
            // Cột trái: cấu hình
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.gap) {
                    serverSection
                    teamsSection
                    devicesSection
                    appsSection
                    liveContainerSection
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 380)
            .background(Theme.bg)

            // Cột phải: log
            VStack(alignment: .leading, spacing: Theme.gap) {
                HStack(spacing: 8) {
                    Text("NHẬT KÝ")
                        .font(.system(size: 11, weight: .semibold)).kerning(1)
                        .foregroundStyle(Theme.textTertiary)
                    if state.isBusy { ProgressView().scaleEffect(0.6) }
                    Spacer()
                    Button("Xóa log") { state.log = "" }
                        .buttonStyle(.borderless).font(.system(size: 12))
                        .disabled(state.log.isEmpty)
                }
                ScrollView {
                    Text(state.log.isEmpty ? "—" : state.log)
                        .font(Theme.mono(11.5, .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .frame(minWidth: 320)
            .background(Theme.bg)
        }
        .navigationTitle("Sign — ký & cài app iOS")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { state.refreshEnvironment() } label: { Label("Quét lại", systemImage: "arrow.clockwise") }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !state.statusMessage.isEmpty {
                Text(state.statusMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface)
            }
        }
        .sheet(isPresented: $showAddApp) { AddAppSheet(state: state) }
    }

    // MARK: Server (cho app iOS gọi tới)

    private var serverSection: some View {
        ProCard {
            CardHeader(icon: "network", title: "api server",
                       value: state.isServerRunning ? "ON" : "OFF",
                       valueColor: state.isServerRunning ? Theme.green : Theme.textTertiary)
            HStack {
                Circle().fill(state.isServerRunning ? Theme.green : Theme.textTertiary)
                    .frame(width: 8, height: 8)
                Text(state.isServerRunning ? "Đang chạy" : "Đã tắt")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Stepper("Cổng \(state.serverPort)", value: $state.serverPort, in: 1024...65535)
                    .disabled(state.isServerRunning).labelsHidden()
                Text("Cổng \(state.serverPort)")
                    .font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
                Button(state.isServerRunning ? "Tắt" : "Bật") { state.toggleServer() }
            }
            if state.isServerRunning, let ip = state.macLANAddress() {
                Text("App iOS trỏ Server URL → http://\(ip):\(state.serverPort)")
                    .font(Theme.mono(11.5, .regular))
                    .foregroundStyle(Theme.textTertiary).textSelection(.enabled)
            }
            Divider().overlay(Theme.border)
            Toggle(isOn: $state.autoRefreshEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tự động gia hạn")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
                    Text("Tự re-sign khi còn ≤ \(state.refreshThresholdDays) ngày (kiểm tra mỗi giờ). Cần MacUtil mở + iPhone kết nối được.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                }
            }
            if state.autoRefreshEnabled {
                Button("Gia hạn ngay") { Task { await state.runAutoRefresh() } }
                    .controlSize(.small).disabled(state.isBusy)
            }
            Divider().overlay(Theme.border)
            Toggle(isOn: $state.notifyTelegramOnSuccess) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Báo Telegram khi gia hạn thành công")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
                    Text("Mặc định chỉ báo khi THẤT BẠI. Cấu hình token/chat_id trong ~/Library/Application Support/MacUtil/telegram.json")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                }
            }
            Button("Test Telegram") { state.testTelegram() }
                .controlSize(.small)
        }
    }

    // MARK: Teams

    private var teamsSection: some View {
        ProCard {
            CardHeader(icon: "person.crop.circle", title: "apple id / team")
            if state.teams.isEmpty {
                Text("Chưa có team. Thêm từ cert đã đăng nhập trong Xcode bên dưới.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            }
            ForEach(state.teams) { t in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.appleID)
                            .font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
                        Text("Team \(t.teamID)")
                            .font(Theme.mono(11.5, .regular)).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    Button(role: .destructive) { state.deleteTeam(t) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
            Divider().overlay(Theme.border)
            Text("Cert trong Keychain (đăng nhập account ở Xcode → Settings → Accounts trước):")
                .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
            ForEach(state.availableIdentities, id: \.self) { name in
                HStack {
                    Text(name)
                        .font(Theme.mono(11.5, .regular)).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Thêm") { state.addTeam(fromCertNamed: name) }
                        .buttonStyle(.borderless).font(.system(size: 12))
                        .disabled(state.teams.contains { $0.certName == name })
                }
            }
        }
    }

    // MARK: Devices

    private var devicesSection: some View {
        ProCard {
            HStack {
                CardHeader(icon: "iphone", title: "thiết bị")
                Button { state.refreshEnvironment() } label: {
                    Label("Quét lại", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
            ForEach(state.devices) { d in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.name)
                            .font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
                        Text(d.udid)
                            .font(Theme.mono(11.5, .regular)).foregroundStyle(Theme.textTertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button(role: .destructive) { state.deleteDevice(d) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
            if !state.connectedDevices.filter({ d in !state.devices.contains { $0.udid == d.udid } }).isEmpty {
                Divider().overlay(Theme.border)
                Text("Đang kết nối (USB):")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                ForEach(state.connectedDevices.filter { d in !state.devices.contains { $0.udid == d.udid } }) { d in
                    HStack {
                        Text(d.name)
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button("Thêm") { state.addDeviceFromConnected(d) }
                            .buttonStyle(.borderless).font(.system(size: 12))
                    }
                }
            }
            if state.devices.isEmpty && state.connectedDevices.isEmpty {
                Text("Cắm iPhone qua USB rồi bấm 'Quét lại'. Bật Developer Mode trên iPhone.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    // MARK: Apps

    private var nativeApps: [SignApp] { state.apps.filter { $0.installMode == .native } }
    private var guestApps: [SignApp] { state.apps.filter { $0.installMode == .liveContainer } }

    private var appsSection: some View {
        ProCard {
            HStack {
                CardHeader(icon: "app.badge", title: "apps (native)")
                Button { showAddApp = true } label: { Label("Thêm app", systemImage: "plus") }
                    .controlSize(.small)
                    .disabled(state.teams.isEmpty)
            }
            Text("Slot native đang dùng: \(state.usedNativeSlots)/\(state.freeSlotLimit) (Apple ID free). Guest app chạy trong LiveContainer không tính slot.")
                .font(.system(size: 11.5))
                .foregroundStyle(state.usedNativeSlots >= state.freeSlotLimit ? Theme.orange : Theme.textTertiary)
            ForEach(nativeApps) { app in
                appRow(app)
                Divider().overlay(Theme.border)
            }
            if nativeApps.isEmpty {
                Text("Chưa có app native. Thêm app (file IPA hoặc GitHub repo) và gắn team.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func appRow(_ app: SignApp) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(app.name)
                            .font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
                        if app.isLiveContainerHost {
                            Text("LiveContainer host")
                                .font(.system(size: 9.5, weight: .semibold)).kerning(0.5)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.surface).foregroundStyle(Theme.textSecondary)
                                .clipShape(Capsule())
                        }
                    }
                    Text(app.sourcePath ?? app.githubRepo ?? "—")
                        .font(Theme.mono(11.5, .regular)).foregroundStyle(Theme.textTertiary)
                        .lineLimit(1).truncationMode(.middle)
                    if let rec = state.records.first(where: { $0.appID == app.id }) {
                        Text(rec.status == "ok" ? "✓ Còn \(rec.daysLeft) ngày" : rec.status)
                            .font(.system(size: 11))
                            .foregroundStyle(rec.status == "ok" ? (rec.daysLeft <= 2 ? Theme.orange : Theme.green) : Theme.red)
                    }
                }
                Spacer()
                Button(role: .destructive) { state.deleteApp(app) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            // chọn device để cài
            ForEach(state.devices) { d in
                Button {
                    state.signAndInstall(app: app, device: d)
                } label: {
                    Label("Ký + cài lên \(d.name)", systemImage: "square.and.arrow.down.on.square")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(state.isBusy)
            }
        }
    }

    // MARK: LiveContainer (guest app — không tốn slot)

    private var liveContainerSection: some View {
        ProCard {
            CardHeader(icon: "shippingbox", title: "livecontainer (guest)",
                       value: state.isLiveContainerInstalled ? "SẴN SÀNG" : "CHƯA CÀI",
                       valueColor: state.isLiveContainerInstalled ? Theme.green : Theme.orange)

            if state.liveContainerHost == nil {
                Text("Chưa có LiveContainer host. Thêm 1 app native, tick 'Đây là LiveContainer (host)', rồi ký + cài như app thường (tốn 1 slot). Guest app cài qua host này sẽ không tính slot.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            } else if !state.isLiveContainerInstalled {
                Text("Đã khai báo host '\(state.liveContainerHost?.name ?? "")' nhưng chưa cài. Cài host (mục apps native) trước khi nạp guest app.")
                    .font(.system(size: 12)).foregroundStyle(Theme.orange)
            }

            // URL source để dán vào LiveContainer (khi server chạy)
            if let src = state.lcSourceURLString() {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Source (AltStore) — thêm URL này trong LiveContainer:")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                    Text(src)
                        .font(Theme.mono(11.5, .regular)).foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                }
            } else if !guestApps.isEmpty {
                Text("Bật 'api server' ở trên để phục vụ source repo cho LiveContainer (hoặc dùng AirDrop IPA bên dưới).")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
            }

            Divider().overlay(Theme.border)

            ForEach(guestApps) { app in
                guestRow(app)
                Divider().overlay(Theme.border)
            }
            if guestApps.isEmpty {
                Text("Chưa có guest app. Thêm app và chọn chế độ 'Guest trong LiveContainer'.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func guestRow(_ app: SignApp) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
                    if let info = state.guestCache[app.id] {
                        Text("\(info.bundleID) · v\(info.version) · \(info.size / 1024 / 1024) MB")
                            .font(Theme.mono(11, .regular)).foregroundStyle(Theme.green)
                            .lineLimit(1).truncationMode(.middle)
                    } else {
                        Text(app.sourcePath ?? app.githubRepo ?? app.ipaURL ?? "—")
                            .font(Theme.mono(11.5, .regular)).foregroundStyle(Theme.textTertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                Button(role: .destructive) { state.deleteApp(app) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            HStack {
                Button {
                    state.prepareGuest(app)
                } label: {
                    Label(state.guestCache[app.id] == nil ? "Chuẩn bị IPA" : "Cập nhật IPA",
                          systemImage: "arrow.down.doc")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(state.isBusy)

                if let path = state.guestIPAPath(app) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    } label: {
                        Label("Hiện IPA (AirDrop)", systemImage: "paperplane")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Sheet thêm app

private struct AddAppSheet: View {
    @ObservedObject var state: SignState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var sourcePath = ""
    @State private var githubRepo = ""
    @State private var githubToken = ""
    @State private var teamID = ""
    @State private var mode: AddMode = .native

    /// Chế độ cài trong UI (map sang installMode + isLiveContainerHost).
    private enum AddMode: String, CaseIterable, Identifiable {
        case native, lcHost, lcGuest
        var id: String { rawValue }
        var label: String {
            switch self {
            case .native: return "Cài trực tiếp (native)"
            case .lcHost: return "Đây là LiveContainer (host — tốn 1 slot)"
            case .lcGuest: return "Guest trong LiveContainer (không tốn slot)"
            }
        }
    }

    private var needsTeam: Bool { mode != .lcGuest }         // guest phục vụ IPA gốc → không cần ký
    private var guestBlocked: Bool { mode == .lcGuest && state.liveContainerHost == nil }
    private var addDisabled: Bool {
        if sourcePath.isEmpty && githubRepo.isEmpty { return true }
        if needsTeam && teamID.isEmpty { return true }
        if guestBlocked { return true }
        return false
    }

    var body: some View {
        Form {
            TextField("Tên app", text: $name)
            HStack {
                TextField("Đường dẫn IPA (tùy chọn)", text: $sourcePath)
                Button("Chọn…") { pickIPA() }
            }
            TextField("GitHub repo (owner/repo, tùy chọn)", text: $githubRepo)
            SecureField("GitHub token (chỉ cần cho repo private)", text: $githubToken)
            Picker("Chế độ cài", selection: $mode) {
                ForEach(AddMode.allCases) { m in Text(m.label).tag(m) }
            }
            if needsTeam {
                Picker("Team / Apple ID", selection: $teamID) {
                    Text("— chọn —").tag("")
                    ForEach(state.teams) { t in Text("\(t.appleID) (\(t.teamID))").tag(t.teamID) }
                }
            } else {
                Text("Guest app phục vụ IPA gốc — LiveContainer tự ký, không cần team.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
            }
            if guestBlocked {
                Text("⚠️ Chưa có LiveContainer host. Thêm & cài LiveContainer (chế độ host) trước khi thêm guest app.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.orange)
            }
            HStack {
                Spacer()
                Button("Hủy") { dismiss() }
                Button("Thêm") {
                    let installMode: InstallMode = (mode == .lcGuest) ? .liveContainer : .native
                    state.addApp(SignApp(
                        name: name.isEmpty ? "App" : name,
                        sourcePath: sourcePath.isEmpty ? nil : sourcePath,
                        githubRepo: githubRepo.isEmpty ? nil : githubRepo,
                        githubToken: githubToken.isEmpty ? nil : githubToken,
                        teamID: needsTeam ? teamID : "",
                        installMode: installMode,
                        isLiveContainerHost: mode == .lcHost))
                    dismiss()
                }
                .disabled(addDisabled)
            }
        }
        .padding()
        .frame(width: 480)
    }

    private func pickIPA() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            sourcePath = url.path
            if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
        }
    }
}
