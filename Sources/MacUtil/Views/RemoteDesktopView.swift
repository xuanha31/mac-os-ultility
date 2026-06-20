import SwiftUI
import AppKit
import RemoteDesktopModule

// RD-04: UI Remote Desktop (VNC/RDP) — sidebar + tab + màn hình remote, tách cửa sổ.
// Mô phỏng bố cục SSHView (Sources/MacUtil/Views/SSHView.swift).

struct RemoteDesktopView: View {
    @ObservedObject var state: RemoteState
    @State private var showSidebar = true

    var body: some View {
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
        let remoteState = state
        presentInWindow(title: "Thêm host Remote", width: 440, height: 360) { dismiss in
            AddRemoteProfileSheet(store: remoteState.store) { profile, pwd in
                remoteState.addProfile(profile, password: pwd)
                dismiss()
            } onCancel: { dismiss() }
        }
    }

    private func openEditProfileWindow(_ profile: RemoteProfile) {
        let remoteState = state
        presentInWindow(title: "Sửa host Remote", width: 440, height: 360) { dismiss in
            AddRemoteProfileSheet(store: remoteState.store, editing: profile) { updated, pwd in
                remoteState.updateProfile(updated, password: pwd)
                dismiss()
            } onCancel: { dismiss() }
        }
    }

    private func detachSession(id: UUID) {
        guard let session = state.session(id) else { return }
        state.setDetached(id, true)
        let remoteState = state
        presentInWindow(title: session.profile.displayName, width: 1024, height: 720) { _ in
            RemoteDetachedView(session: session) {
                remoteState.setDetached(id, false)
            }
        }
    }

    // MARK: - Sidebar

    private var sidebarPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("REMOTE HOSTS")
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
                        Button("Mở màn hình") { state.openSession(for: profile) }
                        Button("Sửa…") { openEditProfileWindow(profile) }
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

    private func profileRow(_ p: RemoteProfile) -> some View {
        let st = state.sessionStates[p.id] ?? .disconnected
        return HStack(spacing: 8) {
            Image(systemName: p.kind == .vnc ? "display" : "pc")
                .foregroundStyle(Theme.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.displayName).font(.body.bold()).lineLimit(1)
                    .foregroundStyle(Theme.textPrimary)
                Text("\(p.kind.rawValue) · \(p.host):\(p.port)")
                    .font(Theme.mono(11, .regular)).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            stateIndicator(st)
        }
        .contentShape(Rectangle())
        .onTapGesture { state.openSession(for: p) }
    }

    private func stateIndicator(_ s: RemoteSessionState) -> some View {
        let color: SwiftUI.Color = {
            switch s {
            case .connected:  return Theme.green
            case .connecting: return Theme.orange
            case .failed:     return Theme.red
            case .disconnected: return Theme.textTertiary
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
            Text("REMOTE DESKTOP")
                .font(.system(size: 18, weight: .semibold)).kerning(0.5)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if let id = state.selectedSessionID {
                Button("Tách ra cửa sổ") { detachSession(id: id) }
                    .disabled(state.detachedSessionIDs.contains(id))
                Button("Đóng tab") { state.closeSession(id: id) }
            }
        }
        .tint(Theme.accent)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.surface)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "display").font(.system(size: 40)).foregroundStyle(Theme.textTertiary)
            Text("Chọn một host bên trái để mở màn hình remote (VNC/RDP).")
                .font(.callout).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Tab bar + screen

    private func sessionContent(session: any RemoteSession, id: UUID) -> some View {
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

            if state.detachedSessionIDs.contains(id) {
                VStack(spacing: 10) {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.system(size: 36)).foregroundStyle(Theme.textTertiary)
                    Text("Phiên đang ở cửa sổ riêng.")
                        .font(.callout).foregroundStyle(Theme.textSecondary)
                    Button("Đưa về cửa sổ chính") { state.setDetached(id, false) }
                        .tint(Theme.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            } else {
                RemoteSessionView(session: session)
                    .id(id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func tabButton(session: any RemoteSession, id: UUID) -> some View {
        let isSelected = state.selectedSessionID == id
        let connected = (state.sessionStates[id] ?? .disconnected) == .connected
        return HStack(spacing: 6) {
            Circle()
                .fill(connected ? Theme.green : Theme.textTertiary)
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
}

// MARK: - Host framebuffer NSView trong SwiftUI

/// Bọc NSView của phiên (do session sở hữu) vào SwiftUI. Khi nhúng ở app chính
/// hay ở cửa sổ tách, view được chuyển superview qua addSubview (chỉ 1 nơi mount
/// tại một thời điểm nhờ detachedSessionIDs).
struct RemoteSessionView: NSViewRepresentable {
    let session: any RemoteSession

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        mount(into: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        mount(into: nsView)
    }

    private func mount(into container: NSView) {
        let v = session.makeView()
        guard v.superview !== container else { return }
        v.removeFromSuperview()
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: container.topAnchor),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
    }
}

/// Nội dung cửa sổ tách: hiển thị màn hình remote; báo reattach khi cửa sổ đóng.
struct RemoteDetachedView: View {
    let session: any RemoteSession
    let onReattach: () -> Void

    var body: some View {
        RemoteSessionView(session: session)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .onDisappear { onReattach() }
    }
}

// MARK: - Add Remote Profile Sheet (mô phỏng AddSSHProfileSheet)

struct AddRemoteProfileSheet: View {
    let store: RemoteProfileStore
    let onSave: (RemoteProfile, String?) -> Void
    let onCancel: () -> Void
    let isEditing: Bool

    @State private var profile: RemoteProfile
    @State private var password = ""
    @State private var portText: String

    private enum Field: Hashable { case name, host, port, username, group, password }
    @FocusState private var focus: Field?

    init(store: RemoteProfileStore,
         editing: RemoteProfile? = nil,
         onSave: @escaping (RemoteProfile, String?) -> Void,
         onCancel: @escaping () -> Void) {
        self.store = store
        self.onSave = onSave
        self.onCancel = onCancel
        self.isEditing = editing != nil
        let initial = editing ?? RemoteProfile()
        _profile = State(initialValue: initial)
        _portText = State(initialValue: String(initial.port))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEditing ? "Sửa host Remote" : "Thêm host Remote").font(.title2.bold())
            formFields
            HStack {
                Spacer()
                Button("Hủy", action: onCancel)
                Button("Lưu") {
                    onSave(profile, password.isEmpty ? nil : password)
                }
                .buttonStyle(.borderedProminent)
                .disabled(profile.host.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { activateSheet { focus = .name } }
    }

    private var formFields: some View {
        VStack(spacing: 10) {
            row("Loại") {
                Picker("", selection: $profile.kind) {
                    ForEach(RemoteKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented)
                .onChange(of: profile.kind) { _, kind in
                    // Đổi port mặc định khi đổi loại (nếu người dùng chưa sửa tay).
                    profile.port = kind.defaultPort
                    portText = String(kind.defaultPort)
                }
            }
            row("Tên hiển thị") {
                TextField("vd: PC phòng máy", text: $profile.name)
                    .focused($focus, equals: .name).onSubmit { focus = .host }
            }
            row("Host / IP") {
                TextField("192.168.1.10 hoặc hostname", text: $profile.host)
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
                TextField("(RDP)", text: $profile.username)
                    .focused($focus, equals: .username)
                    .onSubmit { focus = .group }
                    .textFieldStyle(.roundedBorder)
            }
            row("Nhóm / Tag") {
                TextField("dev, prod…", text: $profile.group)
                    .focused($focus, equals: .group)
            }
            row("Password") {
                SecureField(isEditing ? "(để trống nếu giữ nguyên)" : "(VNC password / RDP password)",
                            text: $password)
                    .focused($focus, equals: .password)
            }
        }
        .onAppear { portText = String(profile.port) }
    }

    @ViewBuilder
    private func row<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
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
