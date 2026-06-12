import Foundation

/// Lưu các SQL worksheet (tab) THEO TỪNG CONNECTION (profile.id) ra JSON trong
/// Application Support — mở lại app vẫn còn script + tab như MySQL Workbench.
///
/// Chỉ lưu *nội dung script* + danh sách tab + tab đang mở; KHÔNG lưu kết quả query.
/// File: ~/Library/Application Support/MacUtil/db-worksheets.json
///   { "<profileID-uuid>": { "worksheets": [{id,title,text}], "activeID": "<uuid>" }, ... }
public struct WorksheetStore {
    /// Một tab đã lưu.
    public struct Item: Codable {
        public var id: UUID
        public var title: String
        public var text: String
    }

    /// Bộ tab của một connection.
    public struct Workspace: Codable {
        public var worksheets: [Item]
        public var activeID: UUID
    }

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacUtil", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("db-worksheets.json")
    }

    public init() {}

    /// Toàn bộ map: profileID(uuidString) → Workspace.
    func loadAll() -> [String: Workspace] {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let all = try? JSONDecoder().decode([String: Workspace].self, from: data) else {
            return [:]
        }
        return all
    }

    func workspace(for profileID: UUID) -> Workspace? {
        loadAll()[profileID.uuidString]
    }

    func update(profileID: UUID, workspace: Workspace) {
        var all = loadAll()
        all[profileID.uuidString] = workspace
        save(all)
    }

    func remove(profileID: UUID) {
        var all = loadAll()
        all[profileID.uuidString] = nil
        save(all)
    }

    private func save(_ all: [String: Workspace]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(all) {
            try? data.write(to: Self.fileURL)
        }
    }
}
