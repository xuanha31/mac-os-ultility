import SwiftUI
import AppKit
import SSHModule
import SwiftTerm
import NIOCore
import Citadel

// MARK: - Hex màu (Color/NSColor ↔ "RRGGBB") cho ColorPicker terminal
extension SwiftUI.Color {
    init(hexRGB: String) {
        let v = UInt64(hexRGB.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xABB2BF
        self = SwiftUI.Color(.sRGB,
                     red:   Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8)  & 0xFF) / 255,
                     blue:  Double(v         & 0xFF) / 255)
    }
    var hexRGB: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(format: "%02X%02X%02X",
                      Int((ns.redComponent   * 255).rounded()),
                      Int((ns.greenComponent * 255).rounded()),
                      Int((ns.blueComponent  * 255).rounded()))
    }
}

extension NSColor {
    convenience init(hexRGB: String) {
        let v = UInt64(hexRGB.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xABB2BF
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green:   CGFloat((v >> 8)  & 0xFF) / 255,
                  blue:    CGFloat(v         & 0xFF) / 255, alpha: 1)
    }
}

// SSH-04/05: SSH Manager với terminal (SwiftTerm) + multi-tab sessions.

struct SSHView: View {
    @ObservedObject var state: SSHState
    @State private var execCommand = ""
    @State private var execResult = ""
    @State private var showExec = false
    /// Ẩn/hiện panel danh sách SSH host (sidebar trái).
    @State private var showSidebar = true
    /// Màu chữ terminal (hex RRGGBB) — lưu lại, dùng chung mọi session.
    @AppStorage("ssh.terminal.textColor") private var textColorHex = "ABB2BF"

    /// Binding cho ColorPicker (Color ↔ hex lưu trong AppStorage).
    private var textColorBinding: Binding<SwiftUI.Color> {
        Binding(get: { SwiftUI.Color(hexRGB: textColorHex) },
                set: { textColorHex = $0.hexRGB })
    }

    var body: some View {
        // Dùng HStack (KHÔNG HSplitView): HSplitView/NSSplitView crash khi thêm/bớt
        // pane động. mainPanel nằm ngoài `if` → giữ identity, terminal không bị tạo lại.
        HStack(spacing: 0) {
            if showSidebar {
                sidebarPanel
                    .frame(width: 250)
                    .frame(maxHeight: .infinity)
                Divider().overlay(Theme.border)
            }
            mainPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Text("SSH Hosts")
                    .font(.system(size: 11, weight: .semibold)).kerning(1)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal)
                Spacer()
                Button { openAddProfileWindow() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).tint(Theme.accent).padding(.trailing, 8)
            }
            .padding(.vertical, 8)
            .background(Theme.surface)
            Divider().overlay(Theme.border)
            List(state.profiles) { profile in
                profileRow(profile)
                    .listRowBackground(Theme.bg)
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
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
        }
        .background(Theme.bg)
    }

    private func profileRow(_ p: SSHProfile) -> some View {
        let sessionState = state.sessionStates[p.id] ?? .disconnected
        return HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(Theme.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.displayName).font(.body.bold()).lineLimit(1)
                    .foregroundStyle(Theme.textPrimary)
                Text("\(p.host):\(p.port) · \(p.authMethod.rawValue)")
                    .font(Theme.mono(11, .regular)).foregroundStyle(Theme.textTertiary)
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
            case .connected:                 return Theme.green
            case .connecting, .reconnecting: return Theme.orange
            case .disconnected:              return Theme.textTertiary
            }
        }()
        return Circle().fill(color).frame(width: 8, height: 8)
    }

    // MARK: - Main panel

    private var mainPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider().overlay(Theme.border)
            if let id = state.selectedSessionID, let session = state.sessions[id] {
                sessionContent(session: session, id: id)
            } else {
                emptyState
            }
            if !state.statusMessage.isEmpty {
                Text(state.statusMessage).font(.callout).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 12).padding(.vertical, 4)
            }
        }
        .background(Theme.bg)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showSidebar.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.borderless)
            .help(showSidebar ? "Ẩn danh sách host" : "Hiện danh sách host")
            Text("SSH Manager".uppercased())
                .font(.system(size: 18, weight: .semibold)).kerning(0.5)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if state.isBusy { ProgressView().controlSize(.small) }
            if state.selectedSessionID != nil {
                Button("Exec lệnh nhanh…") { showExec.toggle() }
                Button("Đóng tab") {
                    if let id = state.selectedSessionID { state.closeSession(id: id) }
                }
            }
        }
        .tint(Theme.accent)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.surface)
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
            .background(Theme.surface)
            Divider().overlay(Theme.border)
            // Bố cục như MobaXterm: SFTP trái · Terminal+Monitor phải (Monitor dưới).
            HSplitView {
                VStack(spacing: 0) {
                    Label("Files (SFTP)", systemImage: "folder")
                        .font(.system(size: 11, weight: .semibold)).kerning(0.5)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 6).background(Theme.surface)
                    Divider().overlay(Theme.border)
                    SFTPPanel(state: state, sessionID: id)
                }
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)

                VSplitView {
                    VStack(spacing: 0) {
                        HStack(spacing: 6) {
                            Label("Terminal", systemImage: "terminal")
                                .font(.system(size: 11, weight: .semibold)).kerning(0.5)
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Text("Màu chữ").font(.caption2).foregroundStyle(Theme.textSecondary)
                            ColorPicker("", selection: textColorBinding, supportsOpacity: false)
                                .labelsHidden()
                                .help("Chọn màu chữ cho terminal SSH")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 6).background(Theme.surface)
                        Divider().overlay(Theme.border)
                        TerminalSessionView(session: session,
                                            sessionState: state.sessionStates[id] ?? .connecting,
                                            textColorHex: textColorHex)
                            .id(id)
                    }
                    .frame(minHeight: 200)

                    VStack(spacing: 0) {
                        Label("Monitor server", systemImage: "gauge.with.dots.needle.67percent")
                            .font(.system(size: 11, weight: .semibold)).kerning(0.5)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 6).background(Theme.surface)
                        Divider().overlay(Theme.border)
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
                .fill((state.sessionStates[id] ?? .disconnected) == .connected ? Theme.green : Theme.textTertiary)
                .frame(width: 7, height: 7)
            Text(session.profile.displayName).font(.callout).lineLimit(1)
                .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
            Button { state.closeSession(id: id) } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.borderless).tint(Theme.textTertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(isSelected ? Theme.accent.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { state.selectedSessionID = id }
    }

    private var execPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(icon: "terminal", title: "exec lệnh nhanh")
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
            .tint(Theme.accent)
            if !execResult.isEmpty {
                ScrollView {
                    Text(execResult).font(Theme.mono(12.5, .regular))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 200)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius)
                        .strokeBorder(Theme.border, lineWidth: 1)
                )
            }
        }
        .padding(Theme.pad)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal").font(.system(size: 48)).foregroundStyle(Theme.textTertiary)
            Text("Chọn host ở sidebar để mở terminal.").foregroundStyle(Theme.textSecondary)
            Button("Thêm SSH host") { openAddProfileWindow() }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

// MARK: - Terminal View (SwiftTerm, SSH-04)
// withTTY (interactive shell) cần macOS 15.0 (Citadel API constraint).
// Trên macOS 14, terminal hiện placeholder + exec nhanh vẫn hoạt động.

struct TerminalSessionView: NSViewRepresentable {
    let session: SSHSession
    let sessionState: SSHSessionState
    var textColorHex: String = "ABB2BF"

    func makeNSView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        Self.applyDarkTheme(tv)
        context.coordinator.setup(tv: tv)
        return tv
    }

    /// Theme tối (kiểu Termius/One Dark): nền tối + 16 màu ANSI + caret xanh.
    static func applyDarkTheme(_ tv: TerminalView) {
        func ansi(_ hex: UInt32) -> SwiftTerm.Color {
            SwiftTerm.Color(red:   UInt16(hex >> 16 & 0xFF) * 257,
                            green: UInt16(hex >> 8  & 0xFF) * 257,
                            blue:  UInt16(hex       & 0xFF) * 257)
        }
        func ns(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255,
                    green:   CGFloat(hex >> 8  & 0xFF) / 255,
                    blue:    CGFloat(hex       & 0xFF) / 255, alpha: 1)
        }
        // 0-7 thường, 8-15 sáng (palette One Dark).
        let palette: [UInt32] = [
            0x282C34, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
            0x5C6370, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xFFFFFF,
        ]
        tv.installColors(palette.map(ansi))
        tv.nativeBackgroundColor = ns(0x1D2026)
        tv.nativeForegroundColor = ns(0xABB2BF)
        tv.caretColor = ns(0x528BFF)
    }

    func updateNSView(_ tv: TerminalView, context: Context) {
        tv.nativeForegroundColor = NSColor(hexRGB: textColorHex)
        tv.needsDisplay = true
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
    private var ttyWriter: TTYStdinWriter?

    func setup(tv: TerminalView) { terminalView = tv }

    /// Mở shell PTY thật (chạy được trên macOS 14 nhờ Citadel patch nội bộ).
    func openShell(session: SSHSession, tv: TerminalView) {
        guard !shellActive else { return }
        shellActive = true
        let term = tv.getTerminal()
        let cols = term.cols, rows = term.rows
        Task {
            do {
                try await session.openTTY(cols: cols, rows: rows) { [weak self] inbound, outbound in
                    await MainActor.run { self?.ttyWriter = outbound }
                    for try await chunk in inbound {
                        let slice = ArraySlice(chunk)
                        await MainActor.run { tv.feed(byteArray: slice) }
                    }
                }
            } catch {
                await MainActor.run { tv.feed(text: "\r\n[Shell đóng: \(error)]\r\n") }
            }
            shellActive = false
        }
    }
}

extension TerminalCoordinator: TerminalViewDelegate {
    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = ByteBuffer(bytes: Array(data))
        Task { @MainActor [weak self] in
            guard let w = self?.ttyWriter else { return }
            try? await w.write(bytes)
        }
    }
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor [weak self] in
            guard let w = self?.ttyWriter else { return }
            try? await w.changeSize(cols: newCols, rows: newRows, pixelWidth: 0, pixelHeight: 0)
        }
    }
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
                Text("Thư mục:").foregroundStyle(Theme.textSecondary)
                TextField("đường dẫn (vd /home/user)", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { refresh() }
                Button("Đi") { refresh() }
                Button { uploadViaPanel() } label: { Label("Tải lên…", systemImage: "arrow.up.doc") }
                if busy { ProgressView().controlSize(.small) }
            }
            .tint(Theme.accent)
            .padding(8)
            .background(Theme.surface)
            Divider().overlay(Theme.border)
            List(entries, id: \.self) { name in
                HStack(spacing: 8) {
                    Image(systemName: name.hasSuffix("/") ? "folder.fill" : "doc")
                        .foregroundStyle(name.hasSuffix("/") ? Theme.accent : Theme.textTertiary)
                    Text(name).foregroundStyle(Theme.textPrimary)
                    Spacer()
                }
                .listRowBackground(Theme.bg)
                .contentShape(Rectangle())
                .contextMenu {
                    if !name.hasSuffix("/") {
                        Button("Tải về…") { download(name) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.accent, lineWidth: 3)
                        .overlay(Text("Thả để upload").font(.headline).foregroundStyle(Theme.accent))
                }
            }
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(Theme.textSecondary).padding(6)
            }
        }
        .background(Theme.bg)
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
                    if let cpu = s.cpuPercent { bar("CPU", value: cpu, text: String(format: "%.0f%%", cpu), color: Theme.accent) }
                    if let used = s.memUsed, let total = s.memTotal, total > 0 {
                        bar("RAM", value: used / total * 100,
                            text: "\(Int(used)) / \(Int(total)) MB", color: Theme.green)
                    }
                    if let disk = s.diskPercent { bar("Disk /", value: disk, text: String(format: "%.0f%%", disk), color: Theme.orange) }
                    if !s.uptime.isEmpty {
                        Text(s.uptime).font(Theme.mono(12.5, .regular)).foregroundStyle(Theme.textSecondary)
                    }
                    Divider().overlay(Theme.border)
                    Text("Raw output").font(.system(size: 11, weight: .semibold)).kerning(0.5)
                        .foregroundStyle(Theme.textTertiary)
                    Text(s.raw).font(Theme.mono(11, .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Đang lấy thông tin server…").foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(16)
        }
        .background(Theme.bg)
        .onAppear { refresh(); start() }
        .onDisappear { timer?.invalidate() }
    }

    private func bar(_ label: String, value: Double, text: String, color: SwiftUI.Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(text).font(Theme.mono(12.5)).foregroundStyle(color)
            }
            StatBar(fraction: max(0, min(100, value)) / 100, color: color)
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
            Divider().overlay(Theme.border)
            HStack(spacing: 6) {
                Text("\(cwd) $").font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.green)
                TextField("nhập lệnh…", text: $command)
                    .textFieldStyle(.plain)
                    .font(.system(.caption, design: .monospaced))
                    .focused($focused)
                    .onSubmit { run() }
                if running { ProgressView().controlSize(.mini) }
                Button("Clear") { output = "" }.controlSize(.small).tint(Theme.accent)
            }
            .padding(8)
            .background(Theme.surface)
        }
        .background(Theme.bg)
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
