import SwiftUI

/// Các tính năng hiển thị ở sidebar.
enum Feature: String, CaseIterable, Identifiable {
    case monitor   = "Giám sát hệ thống"
    case cleaner   = "Dọn dẹp"
    case keyRemap  = "Đổi phím"
    case database  = "Database"
    case ssh       = "SSH"
    case git       = "Git"
    case fan       = "Quạt"
    case clipboard = "Clipboard"
    case power     = "Nguồn & Pin"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .monitor:   return "gauge.with.dots.needle.67percent"
        case .cleaner:   return "trash"
        case .keyRemap:  return "keyboard"
        case .database:  return "cylinder.split.1x2"
        case .ssh:       return "terminal"
        case .git:       return "arrow.triangle.branch"
        case .fan:       return "fanblades"
        case .clipboard: return "clipboard"
        case .power:     return "bolt.batteryblock"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selection: Feature? = .monitor

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label(Feature.monitor.rawValue, systemImage: Feature.monitor.systemImage)
                    .tag(Feature.monitor)

                Section("Công cụ") {
                    ForEach([Feature.database, .ssh, .git]) { f in
                        Label(f.rawValue, systemImage: f.systemImage).tag(f)
                    }
                }

                Section("Tiện ích") {
                    ForEach([Feature.cleaner, .keyRemap, .fan, .clipboard, .power]) { f in
                        Label(f.rawValue, systemImage: f.systemImage).tag(f)
                    }
                }
            }
            .navigationTitle("MacUtil")
            .frame(minWidth: 220)
        } detail: {
            switch selection ?? .monitor {
            case .monitor:   MonitorView(monitor: appState.monitor)
            case .cleaner:   CleanerView(cleaner: appState.cleaner, diskScan: appState.diskScan)
            case .keyRemap:  KeyRemapView(viewModel: appState.keyRemap)
            case .database:  DatabaseView(state: appState.database)
            case .ssh:       SSHView(state: appState.ssh)
            case .git:       GitView(viewModel: appState.git)
            case .fan:       FanView(state: appState.fan)
            case .clipboard: ClipboardView(state: appState.clipboard)
            case .power:     PowerView(power: appState.power, battery: appState.battery)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openClipboard)) { _ in
            selection = .clipboard
        }
    }
}
