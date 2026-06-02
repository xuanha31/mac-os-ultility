import SwiftUI

/// Placeholder cho các tính năng sẽ thêm ở increment sau.
struct ComingSoonView: View {
    let feature: Feature
    let taskPrefix: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: feature.systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(feature.rawValue)
                .font(.title.bold())
            Text("Tính năng này sẽ được thêm ở increment sau (cần thư viện ngoài / privileged helper).")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text("Theo dõi task: \(taskPrefix) trong docs/TASKS.md")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
