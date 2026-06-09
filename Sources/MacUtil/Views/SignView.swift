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
                VStack(alignment: .leading, spacing: 16) {
                    serverSection
                    teamsSection
                    devicesSection
                    appsSection
                }
                .padding()
            }
            .frame(minWidth: 380)

            // Cột phải: log
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Nhật ký").font(.headline)
                    if state.isBusy { ProgressView().scaleEffect(0.6) }
                    Spacer()
                    Button("Xóa log") { state.log = "" }.disabled(state.log.isEmpty)
                }
                ScrollView {
                    Text(state.log.isEmpty ? "—" : state.log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
            .frame(minWidth: 320)
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
                    .font(.caption).padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial)
            }
        }
        .sheet(isPresented: $showAddApp) { AddAppSheet(state: state) }
    }

    // MARK: Server (cho app iOS gọi tới)

    private var serverSection: some View {
        GroupBox("API Server (cho app iOS nhiều máy)") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle().fill(state.isServerRunning ? .green : .secondary).frame(width: 8, height: 8)
                    Text(state.isServerRunning ? "Đang chạy" : "Đã tắt").font(.subheadline)
                    Spacer()
                    Stepper("Cổng \(state.serverPort)", value: $state.serverPort, in: 1024...65535)
                        .disabled(state.isServerRunning).labelsHidden()
                    Text("Cổng \(state.serverPort)").font(.caption).foregroundStyle(.secondary)
                    Button(state.isServerRunning ? "Tắt" : "Bật") { state.toggleServer() }
                }
                if state.isServerRunning, let ip = state.macLANAddress() {
                    Text("App iOS trỏ Server URL → http://\(ip):\(state.serverPort)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }

    // MARK: Teams

    private var teamsSection: some View {
        GroupBox("Apple ID / Team") {
            VStack(alignment: .leading, spacing: 8) {
                if state.teams.isEmpty {
                    Text("Chưa có team. Thêm từ cert đã đăng nhập trong Xcode bên dưới.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(state.teams) { t in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(t.appleID).font(.subheadline)
                            Text("Team \(t.teamID)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { state.deleteTeam(t) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                Divider()
                Text("Cert trong Keychain (đăng nhập account ở Xcode → Settings → Accounts trước):")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(state.availableIdentities, id: \.self) { name in
                    HStack {
                        Text(name).font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Thêm") { state.addTeam(fromCertNamed: name) }
                            .buttonStyle(.borderless).font(.caption)
                            .disabled(state.teams.contains { $0.certName == name })
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }

    // MARK: Devices

    private var devicesSection: some View {
        GroupBox("Thiết bị") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(state.devices) { d in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(d.name).font(.subheadline)
                            Text(d.udid).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button(role: .destructive) { state.deleteDevice(d) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                if !state.connectedDevices.filter({ d in !state.devices.contains { $0.udid == d.udid } }).isEmpty {
                    Divider()
                    Text("Đang kết nối (USB):").font(.caption).foregroundStyle(.secondary)
                    ForEach(state.connectedDevices.filter { d in !state.devices.contains { $0.udid == d.udid } }) { d in
                        HStack {
                            Text(d.name).font(.caption)
                            Spacer()
                            Button("Thêm") { state.addDeviceFromConnected(d) }.buttonStyle(.borderless).font(.caption)
                        }
                    }
                }
                if state.devices.isEmpty && state.connectedDevices.isEmpty {
                    Text("Cắm iPhone qua USB rồi bấm 'Quét lại'. Bật Developer Mode trên iPhone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }

    // MARK: Apps

    private var appsSection: some View {
        GroupBox("Apps") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Spacer()
                    Button { showAddApp = true } label: { Label("Thêm app", systemImage: "plus") }
                        .disabled(state.teams.isEmpty)
                }
                ForEach(state.apps) { app in
                    appRow(app)
                    Divider()
                }
                if state.apps.isEmpty {
                    Text("Chưa có app. Thêm app (file IPA hoặc GitHub repo) và gắn team.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }

    private func appRow(_ app: SignApp) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading) {
                    Text(app.name).font(.subheadline)
                    Text(app.sourcePath ?? app.githubRepo ?? "—")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if let rec = state.records.first(where: { $0.appID == app.id }) {
                        Text(rec.status == "ok" ? "✓ Còn \(rec.daysLeft) ngày" : rec.status)
                            .font(.caption2)
                            .foregroundStyle(rec.status == "ok" ? (rec.daysLeft <= 2 ? .orange : .green) : .red)
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
    @State private var teamID = ""

    var body: some View {
        Form {
            TextField("Tên app", text: $name)
            HStack {
                TextField("Đường dẫn IPA (tùy chọn)", text: $sourcePath)
                Button("Chọn…") { pickIPA() }
            }
            TextField("GitHub repo (owner/repo, tùy chọn)", text: $githubRepo)
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
