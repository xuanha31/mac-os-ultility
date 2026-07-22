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

/// Chế độ cài của 1 app.
public enum InstallMode: String, Codable, Hashable {
    case native          // devicectl cài trực tiếp lên iPhone (tốn 1 slot Apple ID free)
    case liveContainer   // guest app chạy DƯỚI LiveContainer — KHÔNG devicectl, KHÔNG tốn slot
}

/// App cần ký: nguồn IPA (file local hoặc GitHub repo) + bundle id gốc.
public struct SignApp: Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var sourcePath: String?            // đường dẫn IPA local
    public var githubRepo: String?            // "owner/repo" — lấy release mới nhất
    public var githubToken: String?           // PAT để tải release của repo private (tùy chọn)
    public var ipaURL: String?                // URL tải IPA trực tiếp (http/https)
    public var teamID: String                 // team/account dùng để ký (bỏ trống với guest)
    public var installMode: InstallMode       // native | liveContainer (guest)
    public var isLiveContainerHost: Bool      // true nếu app này CHÍNH LÀ LiveContainer (cài native)

    public init(id: UUID = UUID(), name: String, sourcePath: String? = nil,
                githubRepo: String? = nil, githubToken: String? = nil,
                ipaURL: String? = nil, teamID: String,
                installMode: InstallMode = .native, isLiveContainerHost: Bool = false) {
        self.id = id; self.name = name; self.sourcePath = sourcePath
        self.githubRepo = githubRepo; self.githubToken = githubToken
        self.ipaURL = ipaURL; self.teamID = teamID
        self.installMode = installMode; self.isLiveContainerHost = isLiveContainerHost
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, sourcePath, githubRepo, githubToken, ipaURL, teamID, installMode, isLiveContainerHost
    }

    // Decode "thứ lỗi": store cũ (sign-store.json) chưa có installMode/isLiveContainerHost → mặc định native.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        sourcePath = try c.decodeIfPresent(String.self, forKey: .sourcePath)
        githubRepo = try c.decodeIfPresent(String.self, forKey: .githubRepo)
        githubToken = try c.decodeIfPresent(String.self, forKey: .githubToken)
        ipaURL = try c.decodeIfPresent(String.self, forKey: .ipaURL)
        teamID = try c.decodeIfPresent(String.self, forKey: .teamID) ?? ""
        installMode = try c.decodeIfPresent(InstallMode.self, forKey: .installMode) ?? .native
        isLiveContainerHost = try c.decodeIfPresent(Bool.self, forKey: .isLiveContainerHost) ?? false
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

/// Thông tin 1 guest IPA đã chuẩn bị cho LiveContainer (phục vụ qua HTTP repo / AirDrop).
public struct GuestIPAInfo: Hashable {
    public let appID: UUID
    public let name: String
    public let bundleID: String
    public let version: String
    public let localPath: String
    public let size: Int
    public let preparedAt: Date

    public init(appID: UUID, name: String, bundleID: String, version: String,
                localPath: String, size: Int, preparedAt: Date) {
        self.appID = appID; self.name = name; self.bundleID = bundleID
        self.version = version; self.localPath = localPath
        self.size = size; self.preparedAt = preparedAt
    }
}

/// Lỗi của quá trình ký/cài.
public struct SignError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
