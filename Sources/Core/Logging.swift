import Foundation
import os

/// Logger tập trung cho toàn app. Dùng: `Log.monitor.debug("...")`.
public enum Log {
    private static let subsystem = "com.macutil.app"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let core = Logger(subsystem: subsystem, category: "core")
    public static let monitor = Logger(subsystem: subsystem, category: "monitor")
    public static let cleaner = Logger(subsystem: subsystem, category: "cleaner")
    public static let keyRemap = Logger(subsystem: subsystem, category: "keyRemap")
    public static let database = Logger(subsystem: subsystem, category: "database")
    public static let ssh = Logger(subsystem: subsystem, category: "ssh")
    public static let fan = Logger(subsystem: subsystem, category: "fan")

    /// Tạo logger cho category tuỳ ý (module thêm về sau dùng cái này).
    public static func make(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
