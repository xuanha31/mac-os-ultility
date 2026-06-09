import Foundation

/// Lưu cấu hình ký (teams/devices/apps/records) ra JSON trong Application Support.
/// KHÔNG lưu mật khẩu Apple ID — account do Xcode giữ; ta chỉ tham chiếu team/cert.
struct SignStore: Codable {
    var teams: [SignTeam] = []
    var devices: [SignDevice] = []
    var apps: [SignApp] = []
    var records: [SignRecord] = []

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacUtil", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sign-store.json")
    }

    static func load() -> SignStore {
        guard let data = try? Data(contentsOf: fileURL),
              let store = try? JSONDecoder().decode(SignStore.self, from: data) else {
            return SignStore()
        }
        return store
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(self) {
            try? data.write(to: Self.fileURL)
        }
    }
}
