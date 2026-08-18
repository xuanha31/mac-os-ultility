import Foundation

public enum MacUtilHelperConstants {
    public static let machServiceName = "com.macutil.helper"
    public static let daemonPlistName = "com.macutil.helper.plist"
}

@objc public protocol MacUtilPrivilegedHelperProtocol: NSObjectProtocol {
    func setHibernateMode(_ mode: Int32, withReply reply: @escaping (Bool, String) -> Void)
    func setMaxChargeLevel(_ percent: Int32, withReply reply: @escaping (Bool, String) -> Void)
    /// Đặt một giá trị pmset (key/scope được whitelist phía helper).
    /// Dùng cho tcpkeepalive, standbydelaylow… khi vào/ra hibernate.
    func setPowerValue(_ key: String, value: Int32, scope: String, withReply reply: @escaping (Bool, String) -> Void)
    /// `pmset schedule cancelall` — xoá các báo thức đã lên lịch (calaccessd
    /// travelEngine, acmd.alarm…) vốn đánh thức máy giữa đêm.
    func cancelScheduledWakes(withReply reply: @escaping (Bool, String) -> Void)
}
