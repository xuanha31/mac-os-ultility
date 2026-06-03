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
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selection: Feature? = .monitor

    var body: some View {
        NavigationSplitView {
            List(Feature.allCases, selection: $selection) { feature in
                Label(feature.rawValue, systemImage: feature.systemImage)
                    .tag(feature)
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
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openClipboard)) { _ in
            selection = .clipboard
        }
    }
}
