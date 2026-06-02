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

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .monitor:  return "gauge.with.dots.needle.67percent"
        case .cleaner:  return "trash"
        case .keyRemap: return "keyboard"
        case .database: return "cylinder.split.1x2"
        case .ssh:      return "terminal"
        case .git:      return "arrow.triangle.branch"
        case .fan:      return "fanblades"
        }
    }

    /// Tính năng đã có ở increment hiện tại.
    var isAvailable: Bool {
        switch self {
        case .monitor, .cleaner, .keyRemap, .git: return true
        case .database, .ssh, .fan:              return false
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
                    .foregroundStyle(feature.isAvailable ? .primary : .secondary)
                    .tag(feature)
            }
            .navigationTitle("MacUtil")
            .frame(minWidth: 220)
        } detail: {
            switch selection ?? .monitor {
            case .monitor:  MonitorView(monitor: appState.monitor)
            case .cleaner:  CleanerView()
            case .keyRemap: KeyRemapView()
            case .database: ComingSoonView(feature: .database, taskPrefix: "DB-*")
            case .ssh:      ComingSoonView(feature: .ssh, taskPrefix: "SSH-*")
            case .git:      GitView()
            case .fan:      ComingSoonView(feature: .fan, taskPrefix: "FAN-*")
            }
        }
    }
}
