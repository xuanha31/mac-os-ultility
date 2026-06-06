// swift-tools-version: 5.9
import PackageDescription
import Foundation

// MacUtil — ứng dụng tiện ích macOS (xem docs/ARCHITECTURE.md).

// OCI (Oracle cũ < 12.1): chỉ bật khi đã cài Oracle Instant Client + SDK.
// Dò oci.h; nếu chưa có → bỏ qua, app vẫn build bình thường (xem docs/ORACLE-OCI-SETUP.md).
let ociRoot = "\(NSHomeDirectory())/oracle/instantclient"
let ociInclude = "\(ociRoot)/sdk/include"
let hasOCI = FileManager.default.fileExists(atPath: "\(ociInclude)/oci.h")

let package = Package(
    name: "MacUtil",
    platforms: [
        .macOS(.v14) // Citadel (SSH) yêu cầu macOS 14+; NavigationSplitView có từ macOS 13
    ],
    products: [
        .executable(name: "MacUtil", targets: ["MacUtil"])
    ],
    dependencies: [
        // M1 — Database
        .package(url: "https://github.com/vapor/mysql-nio.git",        from: "1.7.0"),
        .package(url: "https://github.com/swift-server/RediStack.git", from: "1.4.0"),
        // oracle-nio: dùng beta.3 (swift-tools 5.9) vì rc.1+ yêu cầu tools 6.1.
        .package(url: "https://github.com/lovetodream/oracle-nio.git", exact: "1.0.0-beta.3"),
        // M1 — SSH
        .package(url: "https://github.com/orlandos-nl/Citadel.git",   from: "0.7.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-nio.git",        from: "2.0.0"),
    ],
    targets: [
        .target(name: "Core"),
        .target(name: "MonitorModule",   dependencies: ["Core"]),
        .target(name: "CleanerModule",   dependencies: ["Core"]),
        .target(name: "KeyRemapModule",  dependencies: ["Core"]),
        .target(name: "GitManagerModule",dependencies: ["Core"]),
        .target(
            name: "DatabaseModule",
            dependencies: [
                "Core",
                .product(name: "MySQLNIO",  package: "mysql-nio"),
                .product(name: "RediStack", package: "RediStack"),
                .product(name: "OracleNIO", package: "oracle-nio"),
            ] + (hasOCI ? [.target(name: "COracleOCI")] : []),
            swiftSettings: hasOCI ? [
                .define("HAS_OCI"),
                // -Xcc -I để clang importer tìm thấy oci.h khi build module COracleOCI
                .unsafeFlags(["-Xcc", "-I\(ociInclude)"]),
            ] : []
        ),
        .target(
            name: "SSHModule",
            dependencies: [
                "Core",
                .product(name: "Citadel",   package: "Citadel"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .target(name: "FanControlModule",  dependencies: ["Core"]),
        .target(name: "ClipboardModule",   dependencies: ["Core"]),
        .target(name: "PrivilegedHelperProtocol"),
        .target(name: "PrivilegedHelperClient", dependencies: ["PrivilegedHelperProtocol"]),
        .target(name: "PowerModule",       dependencies: ["Core", "PrivilegedHelperClient"]),
        .target(name: "BatteryModule",     dependencies: ["Core", "PrivilegedHelperClient"]),
        // Helper cũ để debug ghi BCLM trực tiếp; app dùng MacUtilPrivilegedHelper.
        .executableTarget(name: "BatteryHelper"),
        .executableTarget(name: "MacUtilPrivilegedHelper", dependencies: ["PrivilegedHelperProtocol"]),
        .executableTarget(
            name: "MacUtil",
            dependencies: [
                "Core", "MonitorModule", "CleanerModule", "KeyRemapModule",
                "GitManagerModule", "DatabaseModule", "SSHModule", "FanControlModule", "ClipboardModule",
                "PowerModule", "BatteryModule",
                .product(name: "Citadel",   package: "Citadel"),
                .product(name: "NIOCore",   package: "swift-nio"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            linkerSettings: hasOCI ? [
                .unsafeFlags([
                    "-L\(ociRoot)", "-lclntsh",
                    "-Xlinker", "-rpath", "-Xlinker", ociRoot,
                ])
            ] : []
        ),
        .testTarget(
            name: "MacUtilTests",
            dependencies: [
                "Core", "MonitorModule", "CleanerModule", "KeyRemapModule",
                "GitManagerModule", "DatabaseModule", "SSHModule", "FanControlModule",
                "PowerModule", "BatteryModule",
            ]
        )
    ] + (hasOCI ? [
        // C target phơi bày oci.h — chỉ thêm khi đã cài Instant Client SDK.
        .target(
            name: "COracleOCI",
            cSettings: [.unsafeFlags(["-I\(ociInclude)"])]
        )
    ] : [])
)
