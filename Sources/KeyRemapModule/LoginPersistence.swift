import Foundation
import Core

/// Giữ remap sau reboot bằng một LaunchAgent chạy `hidutil` lúc đăng nhập.
/// (xem docs/features/06-key-remap.md — task KEY-03)
public struct LoginPersistence {

    public let label: String

    public init(label: String = "com.macutil.keyremap") {
        self.label = label
    }

    private var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist", isDirectory: false)
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Cài LaunchAgent áp dụng `hidutilJSON` mỗi lần đăng nhập.
    public func install(hidutilJSON: String) throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/hidutil</string>
                <string>property</string>
                <string>--set</string>
                <string>\(hidutilJSON)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>
        """

        let dir = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        runLaunchctl(["load", "-w", plistURL.path])
        Log.keyRemap.info("Đã cài LaunchAgent giữ remap: \(label, privacy: .public)")
    }

    /// Gỡ LaunchAgent.
    public func remove() throws {
        if isInstalled {
            runLaunchctl(["unload", "-w", plistURL.path])
            try FileManager.default.removeItem(at: plistURL)
            Log.keyRemap.info("Đã gỡ LaunchAgent: \(label, privacy: .public)")
        }
    }

    @discardableResult
    private func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            Log.keyRemap.error("launchctl lỗi: \(error.localizedDescription, privacy: .public)")
            return -1
        }
    }
}
