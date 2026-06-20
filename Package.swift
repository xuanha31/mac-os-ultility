// swift-tools-version: 5.9
import PackageDescription
import Foundation

// MacUtil — ứng dụng tiện ích macOS (xem docs/ARCHITECTURE.md).

// OCI (Oracle cũ < 12.1): chỉ bật khi đã cài Oracle Instant Client + SDK.
// Dò oci.h; nếu chưa có → bỏ qua, app vẫn build bình thường (xem docs/ORACLE-OCI-SETUP.md).
let ociRoot = "\(NSHomeDirectory())/oracle/instantclient"
let ociInclude = "\(ociRoot)/sdk/include"
let hasOCI = FileManager.default.fileExists(atPath: "\(ociInclude)/oci.h")

// FreeRDP (RDP): bật khi đã cài qua Homebrew. Dò header ở Intel (/usr/local) hoặc
// Apple Silicon (/opt/homebrew). Nếu chưa cài → RDP tắt, app vẫn build (xem docs).
let brewPrefixes = ["/usr/local", "/opt/homebrew"]
let freerdpPrefix = brewPrefixes.first {
    FileManager.default.fileExists(atPath: "\($0)/include/freerdp3/freerdp/freerdp.h")
}
let hasFreeRDP = freerdpPrefix != nil
// Cờ -I cho clang importer (freerdp3 + winpr3).
let freerdpIncludeFlags: [String] = freerdpPrefix.map {
    ["-I\($0)/include/freerdp3", "-I\($0)/include/winpr3"]
} ?? []

// Linker settings cho MacUtil — gộp OCI + FreeRDP tuỳ máy.
var macUtilLinker: [LinkerSetting] = []
if hasOCI {
    macUtilLinker.append(.unsafeFlags([
        "-L\(ociRoot)", "-lclntsh",
        "-Xlinker", "-rpath", "-Xlinker", ociRoot,
    ]))
}
if let p = freerdpPrefix {
    macUtilLinker.append(.unsafeFlags([
        "-L\(p)/lib", "-lfreerdp3", "-lfreerdp-client3", "-lwinpr3",
        "-Xlinker", "-rpath", "-Xlinker", "\(p)/lib",
    ]))
}

// Dependencies của RemoteDesktopModule (VNC luôn có; CFreeRDP tuỳ máy).
var remoteDeps: [Target.Dependency] = [
    "Core",
    .product(name: "RoyalVNCKit", package: "royalvnc"),
]
if hasFreeRDP { remoteDeps.append(.target(name: "CFreeRDP")) }

let remoteSwiftSettings: [SwiftSetting] = hasFreeRDP
    ? [.define("HAS_FREERDP"), .unsafeFlags(freerdpIncludeFlags.flatMap { ["-Xcc", $0] })]
    : []

var dbDeps: [Target.Dependency] = [
    "Core",
    .product(name: "MySQLNIO",  package: "mysql-nio"),
    .product(name: "RediStack", package: "RediStack"),
    .product(name: "OracleNIO", package: "oracle-nio"),
]
if hasOCI { dbDeps.append(.target(name: "COracleOCI")) }

let dbSwiftSettings: [SwiftSetting] = hasOCI
    ? [.define("HAS_OCI"), .unsafeFlags(["-Xcc", "-I\(ociInclude)"])]
    : []

// Danh sách target (dựng bằng var + append để manifest dễ type-check).
var targets: [Target] = [
    .target(name: "Core"),
    .target(name: "MonitorModule",   dependencies: ["Core"]),
    .target(name: "CleanerModule",   dependencies: ["Core"]),
    .target(name: "KeyRemapModule",  dependencies: ["Core"]),
    .target(name: "GitManagerModule", dependencies: ["Core"]),
    .target(name: "SignModule",      dependencies: ["Core"]),
    .target(name: "DatabaseModule", dependencies: dbDeps, swiftSettings: dbSwiftSettings),
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
    .target(name: "RemoteDesktopModule", dependencies: remoteDeps, swiftSettings: remoteSwiftSettings),
    .target(name: "PrivilegedHelperProtocol"),
    .target(name: "PrivilegedHelperClient", dependencies: ["PrivilegedHelperProtocol"]),
    .target(name: "PowerModule",   dependencies: ["Core", "PrivilegedHelperClient"]),
    .target(name: "BatteryModule", dependencies: ["Core", "PrivilegedHelperClient"]),
    // Helper cũ để debug ghi BCLM trực tiếp; app dùng MacUtilPrivilegedHelper.
    .executableTarget(name: "BatteryHelper"),
    .executableTarget(name: "MacUtilPrivilegedHelper", dependencies: ["PrivilegedHelperProtocol"]),
    .executableTarget(
        name: "MacUtil",
        dependencies: [
            "Core", "MonitorModule", "CleanerModule", "KeyRemapModule",
            "GitManagerModule", "DatabaseModule", "SSHModule", "FanControlModule", "ClipboardModule",
            "RemoteDesktopModule",
            "PowerModule", "BatteryModule", "SignModule",
            .product(name: "Citadel",   package: "Citadel"),
            .product(name: "NIOCore",   package: "swift-nio"),
            .product(name: "SwiftTerm", package: "SwiftTerm"),
        ],
        linkerSettings: macUtilLinker
    ),
    .testTarget(
        name: "MacUtilTests",
        dependencies: [
            "Core", "MonitorModule", "CleanerModule", "KeyRemapModule",
            "GitManagerModule", "DatabaseModule", "SSHModule", "FanControlModule",
            "PowerModule", "BatteryModule",
        ]
    ),
]

// C target phơi bày oci.h — chỉ thêm khi đã cài Instant Client SDK.
if hasOCI {
    targets.append(.target(name: "COracleOCI", cSettings: [.unsafeFlags(["-I\(ociInclude)"])]))
}
// C target phơi bày header FreeRDP — chỉ thêm khi đã cài FreeRDP.
if hasFreeRDP {
    targets.append(.target(name: "CFreeRDP", cSettings: [.unsafeFlags(freerdpIncludeFlags)]))
}

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
        // RD — VNC: fork của RoyalVNCKit 1.0.0 + vá Queue thread-safe (branch
        // threadsafe-queue) để sửa race input↔send-loop gây crash. Pin theo branch
        // (unstable) cũng để SwiftPM chấp nhận unsafeFlags của C lib bundled.
        // (Gốc: github.com/royalapplications/royalvnc — xem docs/features/07-remote-desktop.md)
        .package(url: "https://github.com/xuanha31/royalvnc.git",
                 branch: "threadsafe-queue"),
    ],
    targets: targets
)
