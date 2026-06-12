import SwiftUI
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

    private var appsSection: some View {
        ProCard {
            HStack {
                CardHeader(icon: "app.badge", title: "apps")
                Button { showAddApp = true } label: { Label("Thêm app", systemImage: "plus") }
                    .controlSize(.small)
                    .disabled(state.teams.isEmpty)
            }
            ForEach(state.apps) { app in
                appRow(app)
                Divider().overlay(Theme.border)
            }
            if state.apps.isEmpty {
                Text("Chưa có app. Thêm app (file IPA hoặc GitHub repo) và gắn team.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func appRow(_ app: SignApp) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
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

    var body: some View {
        Form {
            TextField("Tên app", text: $name)
            HStack {
                TextField("Đường dẫn IPA (tùy chọn)", text: $sourcePath)
                Button("Chọn…") { pickIPA() }
            }
            TextField("GitHub repo (owner/repo, tùy chọn)", text: $githubRepo)
            SecureField("GitHub token (chỉ cần cho repo private)", text: $githubToken)
            Picker("Team / Apple ID", selection: $teamID) {
                Text("— chọn —").tag("")
                ForEach(state.teams) { t in Text("\(t.appleID) (\(t.teamID))").tag(t.teamID) }
            }
            HStack {
                Spacer()
                Button("Hủy") { dismiss() }
                Button("Thêm") {
                    state.addApp(SignApp(
                        name: name.isEmpty ? "App" : name,
                        sourcePath: sourcePath.isEmpty ? nil : sourcePath,
                        githubRepo: githubRepo.isEmpty ? nil : githubRepo,
                        githubToken: githubToken.isEmpty ? nil : githubToken,
                        teamID: teamID))
                    dismiss()
                }
                .disabled(teamID.isEmpty || (sourcePath.isEmpty && githubRepo.isEmpty))
            }
        }
        .padding()
        .frame(width: 460)
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
