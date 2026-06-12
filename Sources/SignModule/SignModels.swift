import Foundation

/// Một Apple ID / team dùng để ký (free account). Team ID = trường OU của cert "Apple Development".
/// Account phải được đăng nhập trong Xcode → Settings → Accounts để xcodebuild auto-provisioning dùng được.
public struct SignTeam: Codable, Identifiable, Hashable {
    public var id: String { teamID }          // teamID là duy nhất
    public var teamID: String                 // vd "S65V477X4H" (OU của cert)
    public var appleID: String                // email, vd "hanx2707@gmail.com"
    public var certSHA1: String               // SHA-1 của signing identity trong Keychain
    public var certName: String               // "Apple Development: hanx2707@gmail.com (...)"

    public init(teamID: String, appleID: String, certSHA1: String, certName: String) {
        self.teamID = teamID; self.appleID = appleID
        self.certSHA1 = certSHA1; self.certName = certName
    }
}

/// Thiết bị iOS đích (USB hoặc WiFi qua libimobiledevice/devicectl).
public struct SignDevice: Codable, Identifiable, Hashable {
    public var id: String { udid }
    public var udid: String
    public var name: String

    public init(udid: String, name: String) { self.udid = udid; self.name = name }
}

/// App cần ký: nguồn IPA (file local hoặc GitHub repo) + bundle id gốc.
public struct SignApp: Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var sourcePath: String?            // đường dẫn IPA local
    public var githubRepo: String?            // "owner/repo" — lấy release mới nhất
    public var githubToken: String?           // PAT để tải release của repo private (tùy chọn)
    public var ipaURL: String?                // URL tải IPA trực tiếp (http/https)
    public var teamID: String                 // team/account dùng để ký app này

    public init(id: UUID = UUID(), name: String, sourcePath: String? = nil,
                githubRepo: String? = nil, githubToken: String? = nil,
                ipaURL: String? = nil, teamID: String) {
        self.id = id; self.name = name; self.sourcePath = sourcePath
        self.githubRepo = githubRepo; self.githubToken = githubToken
        self.ipaURL = ipaURL; self.teamID = teamID
    }
}

/// Bản ghi 1 lần cài (theo app + device). Cert free hết hạn sau 7 ngày.
public struct SignRecord: Codable, Identifiable, Hashable {
    public var id: UUID
    public var appID: UUID
    public var deviceUDID: String
    public var signedBundleID: String
    public var signedAt: Date
    public var expiresAt: Date
    public var status: String                 // "ok" | "failed" | "signing"
    public var log: String

    public init(id: UUID = UUID(), appID: UUID, deviceUDID: String, signedBundleID: String,
                signedAt: Date, expiresAt: Date, status: String, log: String) {
        self.id = id; self.appID = appID; self.deviceUDID = deviceUDID
        self.signedBundleID = signedBundleID; self.signedAt = signedAt
        self.expiresAt = expiresAt; self.status = status; self.log = log
    }

    public var daysLeft: Int {
        Calendar.current.dateComponents([.day], from: Date(), to: expiresAt).day ?? 0
    }
}

/// Lỗi của quá trình ký/cài.
public struct SignError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
