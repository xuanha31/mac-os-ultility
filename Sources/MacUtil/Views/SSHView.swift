import SwiftUI
import SSHModule
import SwiftTerm
import NIOCore
import Citadel

// SSH-04/05: SSH Manager với terminal (SwiftTerm) + multi-tab sessions.

struct SSHView: View {
    @ObservedObject var state: SSHState
    @State private var execCommand = ""
    @State private var execResult = ""
    @State private var showExec = false

    var body: some View {
        HSplitView {
            sidebarPanel.frame(minWidth: 220, maxWidth: 280)
            mainPanel
        }
    }

    private func openAddProfileWindow() {
        let sshState = state
        presentInWindow(title: "Thêm SSH Host", width: 440, height: 380) { dismiss in
            AddSSHProfileSheet(store: sshState.store) { profile, pwd, pp in
                sshState.addProfile(profile, password: pwd, passphrase: pp)
                dismiss()
            } onCancel: { dismiss() }
        }
    }

    // MARK: - Sidebar

    private var sidebarPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SSH Hosts").font(.headline).padding(.horizontal)
                Spacer()
                Button { openAddProfileWindow() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).padding(.trailing, 8)
            }
            .padding(.vertical, 8)
            Divider()
            List(state.profiles) { profile in
                profileRow(profile)
                    .contextMenu {
                        Button("Mở terminal") { state.openSession(for: profile) }
                        Divider()
                        Button("Xóa", role: .destructive) {
                            if let idx = state.profiles.firstIndex(of: profile) {
                                state.deleteProfile(at: IndexSet(integer: idx))
                            }
                        }
                    }
            }
            .listStyle(.sidebar)
        }
    }

    private func profileRow(_ p: SSHProfile) -> some View {
        let sessionState = state.sessionStates[p.id] ?? .disconnected
        return HStack(spacing: 8) {
            Image(systemName: "terminal")
            VStack(alignment: .leading, spacing: 2) {
                Text(p.displayName).font(.body.bold()).lineLimit(1)
                Text("\(p.host):\(p.port) · \(p.authMethod.rawValue)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            stateIndicator(sessionState)
        }
        .contentShape(Rectangle())
        .onTapGesture { state.openSession(for: p) }
    }

    private func stateIndicator(_ s: SSHSessionState) -> some View {
        let color: SwiftUI.Color = {
            switch s {
            case .connected:                 return SwiftUI.Color.green
            case .connecting, .reconnecting: return SwiftUI.Color.orange
            case .disconnected:              return SwiftUI.Color.secondary
            }
        }()
        return Circle().fill(color).frame(width: 8, height: 8)
    }

    // MARK: - Main panel

    private var mainPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider()
            if let id = state.selectedSessionID, let session = state.sessions[id] {
                sessionContent(session: session, id: id)
            } else {
                emptyState
            }
            if !state.statusMessage.isEmpty {
                Text(state.statusMessage).font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 4)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("SSH Manager").font(.largeTitle.bold())
            Spacer()
            if state.isBusy { ProgressView().controlSize(.small) }
            if state.selectedSessionID != nil {
                Button("Exec lệnh nhanh…") { showExec.toggle() }
                Button("Đóng tab") {
                    if let id = state.selectedSessionID { state.closeSession(id: id) }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: - Tab bar + terminal

    private func sessionContent(session: SSHSession, id: UUID) -> some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(state.sessions.keys), id: \.self) { sid in
                        if let s = state.sessions[sid] {
                            tabButton(session: s, id: sid)
                        }
                    }
                }
            }
            .background(.bar)
            Divider()
            // Bố cục như MobaXterm: SFTP trái · Terminal+Monitor phải (Monitor dưới).
            HSplitView {
                VStack(spacing: 0) {
                    Label("Files (SFTP)", systemImage: "folder")
                        .font(.caption.bold()).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 6).background(.bar)
                    Divider()
                    SFTPPanel(state: state, sessionID: id)
                }
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)

                VSplitView {
                    VStack(spacing: 0) {
                        Label("Terminal", systemImage: "terminal")
                            .font(.caption.bold()).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 6).background(.bar)
                        Divider()
                        CommandConsoleView(state: state, sessionID: id)
                    }
                    .frame(minHeight: 200)

                    VStack(spacing: 0) {
                        Label("Monitor server", systemImage: "gauge.with.dots.needle.67percent")
                            .font(.caption.bold()).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 6).background(.bar)
                        Divider()
                        ServerMonitorPanel(state: state, sessionID: id)
                    }
                    .frame(minHeight: 160, idealHeight: 220)
                }
            }
        }
    }

    private func tabButton(session: SSHSession, id: UUID) -> some View {
        let isSelected = state.selectedSessionID == id
        return HStack(spacing: 6) {
            Circle()
                .fill((state.sessionStates[id] ?? .disconnected) == .connected ? Color.green : .secondary)
                .frame(width: 7, height: 7)
            Text(session.profile.displayName).font(.callout).lineLimit(1)
            Button { state.closeSession(id: id) } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { state.selectedSessionID = id }
    }

    private var execPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Exec lệnh nhanh").font(.headline)
            HStack {
                TextField("Lệnh (vd: uptime)", text: $execCommand)
                    .textFieldStyle(.roundedBorder)
                Button("Chạy") {
                    guard let id = state.selectedSessionID else { return }
                    let cmd = execCommand
                    Task {
                        do { execResult = try await state.exec(cmd, sessionID: id) }
                        catch { execResult = "Lỗi: \(error)" }
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("Đóng") { showExec = false; execResult = "" }
            }
            if !execResult.isEmpty {
                ScrollView {
                    Text(execResult).font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Chọn host ở sidebar để mở terminal.").foregroundStyle(.secondary)
            Button("Thêm SSH host") { openAddProfileWindow() }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Terminal View (SwiftTerm, SSH-04)
// withTTY (interactive shell) cần macOS 15.0 (Citadel API constraint).
// Trên macOS 14, terminal hiện placeholder + exec nhanh vẫn hoạt động.

struct TerminalSessionView: NSViewRepresentable {
    let session: SSHSession
    let sessionState: SSHSessionState

    func makeNSView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        context.coordinator.setup(tv: tv)
        return tv
    }

    func updateNSView(_ tv: TerminalView, context: Context) {
        if sessionState == .connected && !context.coordinator.shellActive {
            context.coordinator.openShell(session: session, tv: tv)
        }
    }

    func makeCoordinator() -> TerminalCoordinator { TerminalCoordinator() }
}

@MainActor
final class TerminalCoordinator: NSObject {
    weak var terminalView: TerminalView?
    var shellActive = false
    private var ttyWriter: (any Sendable)?  // TTYStdinWriter on macOS 15+

    func setup(tv: TerminalView) { terminalView = tv }

    func openShell(session: SSHSession, tv: TerminalView) {
        guard !shellActive else { return }
        shellActive = true
        if #available(macOS 15.0, *) {
            openShellMacOS15(session: session, tv: tv)
        } else {
            tv.feed(text: "\r\n[Interactive shell requires macOS 15+. Use 'Exec' button above.]\r\n")
            shellActive = false
        }
    }

    @available(macOS 15.0, *)
    private func openShellMacOS15(session: SSHSession, tv: TerminalView) {
        Task {
            do {
                try await session.openTTY { [weak self] inbound, outbound in
                    await MainActor.run { self?.ttyWriter = outbound }
                    for try await chunk in inbound {
                        let slice = ArraySlice(chunk)
                        await MainActor.run { tv.feed(byteArray: slice) }
                    }
                }
            } catch {
                await MainActor.run { tv.feed(text: "\r\n[Shell closed: \(error)]\r\n") }
            }
            shellActive = false
        }
    }
}

extension TerminalCoordinator: TerminalViewDelegate {
    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = ByteBuffer(bytes: Array(data))
        Task { @MainActor [weak self] in
            guard let writer = self?.ttyWriter else { return }
            if #available(macOS 15.0, *), let w = writer as? TTYStdinWriter {
                try? await w.write(bytes)
            }
        }
    }
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    nonisolated func bell(source: TerminalView) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    nonisolated func clipboardCopy(source: TerminalView, content: Data) {}
    nonisolated func iTermContent(source: TerminalView, content: Data) {}
    nonisolated func mouseModeChanged(source: TerminalView) {}
    nonisolated func colorChanged(source: TerminalView, idx: Int?) {}
}

// MARK: - Add SSH Profile Sheet

struct AddSSHProfileSheet: View {
    let store: SSHProfileStore
    let onSave: (SSHProfile, String?, String?) -> Void
    let onCancel: () -> Void

    @State private var profile = SSHProfile()
    @State private var password = ""
    @State private var passphrase = ""
    @State private var portText = "22"

    private enum Field: Hashable { case name, host, port, username, group, credential }
    @FocusState private var focus: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Thêm SSH Host").font(.title2.bold())
            formFields
            HStack {
                Spacer()
                Button("Hủy", action: onCancel)
                Button("Lưu") {
                    onSave(
                        profile,
                        profile.authMethod == .password ? password : nil,
                        profile.authMethod == .privateKey ? passphrase : nil
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(profile.host.isEmpty || profile.username.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { activateSheet { focus = .name } }
    }

    private var formFields: some View {
        VStack(spacing: 10) {
            sshRow("Tên hiển thị") {
                TextField("vd: Server Production", text: $profile.name)
                    .focused($focus, equals: .name).onSubmit { focus = .host }
            }
            sshRow("Host / IP") {
                TextField("192.168.1.1 hoặc hostname", text: $profile.host)
                    .focused($focus, equals: .host).onSubmit { focus = .port }
            }
            HStack(spacing: 0) {
                Text("Port")
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .trailing)
                    .padding(.trailing, 12)
                TextField("", text: $portText)
                    .frame(width: 60)
                    .focused($focus, equals: .port)
                    .onSubmit { focus = .username }
                    .onChange(of: portText) { _, v in
                        let clean = v.filter(\.isNumber)
                        portText = clean
                        if let p = Int(clean) { profile.port = p }
                    }
                Text("Username")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                TextField("", text: $profile.username)
                    .focused($focus, equals: .username)
                    .onSubmit { focus = .group }
                    .textFieldStyle(.roundedBorder)
            }
            sshRow("Nhóm / Tag") {
                TextField("dev, prod…", text: $profile.group)
                    .focused($focus, equals: .group)
            }
            sshRow("Xác thực") {
                Picker("", selection: $profile.authMethod) {
                    ForEach(SSHAuthMethod.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented)
            }
            if profile.authMethod == .password {
                sshRow("Password") {
                    SecureField("", text: $password)
                        .focused($focus, equals: .credential)
                }
            } else {
                sshRow("Private key") {
                    TextField("~/.ssh/id_ed25519", text: $profile.privateKeyPath)
                        .focused($focus, equals: .credential)
                }
                sshRow("Passphrase") {
                    SecureField("(để trống nếu không có)", text: $passphrase)
                }
            }
        }
        .onAppear { portText = String(profile.port) }
    }

    @ViewBuilder
    private func sshRow<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
                .padding(.trailing, 12)
            content()
                .textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - #4: SFTP panel (kéo-thả upload, duyệt, tải về)

struct SFTPPanel: View {
    @ObservedObject var state: SSHState
    let sessionID: UUID

    @State private var path = "."
    @State private var entries: [String] = []
    @State private var busy = false
    @State private var status = ""
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Thư mục:").foregroundStyle(.secondary)
                TextField("đường dẫn (vd /home/user)", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { refresh() }
                Button("Đi") { refresh() }
                Button { uploadViaPanel() } label: { Label("Tải lên…", systemImage: "arrow.up.doc") }
                if busy { ProgressView().controlSize(.small) }
            }
            .padding(8)
            Divider()
            List(entries, id: \.self) { name in
                HStack(spacing: 8) {
                    Image(systemName: name.hasSuffix("/") ? "folder.fill" : "doc")
                        .foregroundStyle(name.hasSuffix("/") ? .blue : .secondary)
                    Text(name)
                    Spacer()
                }
                .contentShape(Rectangle())
                .contextMenu {
                    if !name.hasSuffix("/") {
                        Button("Tải về…") { download(name) }
                    }
                }
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(.blue, lineWidth: 3)
                        .overlay(Text("Thả để upload").font(.headline).foregroundStyle(.blue))
                }
            }
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary).padding(6)
            }
        }
        // Kéo-thả file từ Finder vào để upload.
        .onDrop(of: ["public.file-url"], isTargeted: $dropTargeted) { providers in
            handleDrop(providers); return true
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        busy = true; status = "Đang tải danh sách…"
        Task {
            do {
                entries = try await state.listRemote(sessionID, path: path)
                status = "\(entries.count) mục"
            } catch { status = "Lỗi: \(error)" }
            busy = false
        }
    }

    private func uploadViaPanel() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return }
        upload(urls: p.urls)
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { if !urls.isEmpty { upload(urls: urls) } }
    }

    private func upload(urls: [URL]) {
        busy = true; status = "Đang upload \(urls.count) file…"
        Task {
            var ok = 0
            for url in urls {
                do { try await state.upload(sessionID, localURL: url, toDir: path); ok += 1 }
                catch { status = "Lỗi upload \(url.lastPathComponent): \(error)" }
            }
            status = "Đã upload \(ok)/\(urls.count) file."
            busy = false
            refresh()
        }
    }

    private func download(_ name: String) {
        let p = NSSavePanel()
        p.nameFieldStringValue = name
        guard p.runModal() == .OK, let dest = p.url else { return }
        let remote = (path.hasSuffix("/") ? path : path + "/") + name
        busy = true; status = "Đang tải về…"
        Task {
            do { try await state.download(sessionID, remotePath: remote, toLocal: dest); status = "Đã tải về \(name)." }
            catch { status = "Lỗi tải về: \(error)" }
            busy = false
        }
    }
}

// MARK: - #4: Server monitor panel (như MobaXterm)

struct ServerMonitorPanel: View {
    @ObservedObject var state: SSHState
    let sessionID: UUID

    @State private var stats: SSHState.ServerStats?
    @State private var timer: Timer?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let s = stats {
                    if let cpu = s.cpuPercent { bar("CPU", value: cpu, text: String(format: "%.0f%%", cpu), color: .blue) }
                    if let used = s.memUsed, let total = s.memTotal, total > 0 {
                        bar("RAM", value: used / total * 100,
                            text: "\(Int(used)) / \(Int(total)) MB", color: .green)
                    }
                    if let disk = s.diskPercent { bar("Disk /", value: disk, text: String(format: "%.0f%%", disk), color: .orange) }
                    if !s.uptime.isEmpty {
                        Text(s.uptime).font(.callout.monospaced()).foregroundStyle(.secondary)
                    }
                    Divider()
                    Text("Raw output").font(.caption.bold()).foregroundStyle(.secondary)
                    Text(s.raw).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Đang lấy thông tin server…").foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .onAppear { refresh(); start() }
        .onDisappear { timer?.invalidate() }
    }

    private func bar(_ label: String, value: Double, text: String, color: SwiftUI.Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(label).font(.headline); Spacer(); Text(text).monospacedDigit().foregroundStyle(color) }
            ProgressView(value: max(0, min(100, value)), total: 100).tint(color)
        }
    }

    private func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in refresh() }
    }

    private func refresh() {
        Task { stats = await state.serverStats(sessionID) }
    }
}

// MARK: - Command console (chạy trên macOS 14 — không cần PTY)

struct CommandConsoleView: View {
    @ObservedObject var state: SSHState
    let sessionID: UUID

    @State private var output = "Gõ lệnh rồi Enter. (Lưu ý: lệnh tương tác như vi/top -d cần PTY/macOS 15.)\n"
    @State private var command = ""
    @State private var cwd = "~"
    @State private var running = false
    @State private var history: [String] = []
    @State private var historyIndex = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(output)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.green)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: output) { _, _ in
                    withAnimation { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
            Divider()
            HStack(spacing: 6) {
                Text("\(cwd) $").font(.system(.caption, design: .monospaced)).foregroundStyle(.green)
                TextField("nhập lệnh…", text: $command)
                    .textFieldStyle(.plain)
                    .font(.system(.caption, design: .monospaced))
                    .focused($focused)
                    .onSubmit { run() }
                if running { ProgressView().controlSize(.mini) }
                Button("Clear") { output = "" }.controlSize(.small)
            }
            .padding(8)
            .background(.bar)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { focused = true }
    }

    private func run() {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, !running else { return }
        history.append(c); historyIndex = history.count
        output += "\n\(cwd) $ \(c)\n"
        command = ""; running = true
        // Giữ thư mục hiện tại + lấy pwd mới sau khi chạy.
        let full = "cd \(cwd) 2>/dev/null; \(c) 2>&1; printf '\\n@@PWD@@:%s' \"$(pwd)\""
        Task {
            do {
                let out = try await state.exec(full, sessionID: sessionID)
                if let r = out.range(of: "@@PWD@@:") {
                    let newCwd = out[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !newCwd.isEmpty { cwd = newCwd }
                    output += String(out[..<r.lowerBound])
                } else {
                    output += out
                }
            } catch {
                output += "Lỗi: \(error)\n"
            }
            running = false
        }
    }
}
