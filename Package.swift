// swift-tools-version: 5.9
import PackageDescription

// MacUtil — ứng dụng tiện ích macOS (xem docs/ARCHITECTURE.md).
//
// Increment hiện tại: các module KHÔNG phụ thuộc package ngoài (build được ngay):
//   Core, MonitorModule, CleanerModule, KeyRemapModule + app shell MacUtil.
// Các module cần dependency ngoài (DatabaseModule, SSHModule, GitManagerModule)
// và privileged helper (FanControlModule) sẽ thêm ở increment sau.
let package = Package(
    name: "MacUtil",
    platforms: [
        .macOS(.v13) // cần cho NavigationSplitView, SMAppService (về sau)
    ],
    products: [
        .executable(name: "MacUtil", targets: ["MacUtil"])
    ],
    targets: [
        .target(name: "Core"),
        .target(name: "MonitorModule", dependencies: ["Core"]),
        .target(name: "CleanerModule", dependencies: ["Core"]),
        .target(name: "KeyRemapModule", dependencies: ["Core"]),
        .target(name: "GitManagerModule", dependencies: ["Core"]),
        .executableTarget(
            name: "MacUtil",
            dependencies: ["Core", "MonitorModule", "CleanerModule", "KeyRemapModule", "GitManagerModule"]
        ),
        .testTarget(
            name: "MacUtilTests",
            dependencies: ["Core", "MonitorModule", "CleanerModule", "KeyRemapModule", "GitManagerModule"]
        )
    ]
)
