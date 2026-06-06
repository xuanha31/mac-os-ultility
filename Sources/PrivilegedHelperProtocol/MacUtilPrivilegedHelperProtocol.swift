import Foundation

public enum MacUtilHelperConstants {
    public static let machServiceName = "com.macutil.helper"
    public static let daemonPlistName = "com.macutil.helper.plist"
}

@objc public protocol MacUtilPrivilegedHelperProtocol: NSObjectProtocol {
    func setHibernateMode(_ mode: Int32, withReply reply: @escaping (Bool, String) -> Void)
    func setMaxChargeLevel(_ percent: Int32, withReply reply: @escaping (Bool, String) -> Void)
}
