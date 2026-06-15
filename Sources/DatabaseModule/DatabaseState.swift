import Foundation
import Combine
import Core

// ViewModel cho DatabaseModule — bridge giữa DatabaseDriver và SwiftUI views.

@MainActor
public final class DatabaseState: ObservableObject {
    @Published public var profiles: [ConnectionProfile] = []
    @Published public var selectedProfileID: UUID?
    @Published public var isConnected = false
    @Published public var isBusy = false
    @Published public var statusMessage = ""
    /// Folder cố định hiển thị ngay khi kết nối (chưa query).
    @Published public var categories: [SchemaCategory] = []
    /// Object đã lazy-load theo từng nhóm (id nhóm → danh sách).
    @Published public var objectsByCategory: [String: [DBSchemaObject]] = [:]
    /// Nhóm đang tải.
    @Published public var loadingCategories: Set<String> = []
    @Published public var queryResult: DBResultSet?
    @Published public var queryText = ""
    /// Vùng đang bôi đen trong editor (rỗng nếu không chọn) — set từ SQLTextEditor.
    /// Không @Published: chỉ đọc lúc chạy query, tránh re-render mỗi khi di con trỏ.
    public var selectedText: String = ""
    /// Vị trí con trỏ (UTF-16) trong editor — để xác định câu lệnh tại con trỏ.
    public var caretLocation: Int = 0
    /// Bảng kết quả đã "gim" để so sánh (snapshot, chỉ đọc).
    @Published public var pinnedResults: [PinnedResult] = []
    public struct PinnedResult: Identifiable, Sendable {
        public let id: UUID
        public let title: String
        public let result: DBResultSet
    }
    /// Cách hiển thị bảng gim: song song (cạnh nhau) hoặc theo tab.
    public enum PinLayout: String, CaseIterable, Sendable { case sideBySide, tabs }
    @Published public var pinLayout: PinLayout = .sideBySide
    /// Tab kết quả đang xem (chỉ dùng ở chế độ tabs). nil = kết quả live.
    @Published public var activeResultTab: UUID?
    /// Tên bảng nếu query hiện tại là SELECT bảng đơn → cho phép sửa grid.
    @Published public var editableTable: String?
    /// Cách định danh từng dòng của result hiện tại (Oracle: ROWID, MySQL: PRIMARY KEY).
    private var rowKey: RowKey?
    /// Cách khóa dòng để build WHERE khi UPDATE/DELETE.
    private enum RowKey {
        case rowid                    // Oracle — cột MACUTIL_ROWID đã chèn vào result
        case primaryKey([String])     // MySQL — danh sách cột PK (tên cột trong result)
    }
    /// Các cột hiển thị (ẩn cột ROWID kỹ thuật).
    public var visibleColumns: [String] {
        (queryResult?.columns ?? []).filter { $0 != SingleTableEdit.rowidColumn }
    }
    public var isEditable: Bool { editableTable != nil && rowKey != nil }
    /// Số dòng tối đa mỗi query (cấu hình từ UI).
    @Published public var rowLimit: Int = 250 {
        didSet { Task { await driver?.setRowLimit(rowLimit) } }
    }

    // MARK: - #3: Nhiều SQL editor (worksheet)
    public struct Worksheet: Identifiable, Sendable { public let id: UUID; public var title: String }
    @Published public var worksheets: [Worksheet] = []
    @Published public var activeWorksheet: UUID = UUID()
    // Lưu nội dung từng tab khi chuyển.
    private var savedText: [UUID: String] = [:]
    private var savedResult: [UUID: DBResultSet?] = [:]
    private var savedEditable: [UUID: String?] = [:]
    private var savedRowKey: [UUID: RowKey?] = [:]
    // Persist worksheet theo connection (profile.id) — xem WorksheetStore.
    private let wsStore = WorksheetStore()
    /// Profile mà bộ worksheet đang nằm trong RAM thuộc về (nil = chưa gắn, đang tạm).
    private var loadedWorkspaceProfileID: UUID?

    private let store = ProfileStore()
    private var driver: (any DatabaseDriver)?
    private let sleepWake: SleepWakeCoordinator
    private var cancellables = Set<AnyCancellable>()

    public init(sleepWake: SleepWakeCoordinator) {
        self.sleepWake = sleepWake
        profiles = store.loadProfiles()
        let first = Worksheet(id: UUID(), title: "SQL 1")
        worksheets = [first]
        activeWorksheet = first.id
        bindSleepWake()

        // Auto-save: lưu script của tab sau ~1s ngừng gõ (debounce), giống Workbench.
        $queryText
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.persistCurrentWorkspace() }
            .store(in: &cancellables)
    }

    public func addWorksheet() {
        stashActive()
        let ws = Worksheet(id: UUID(), title: "SQL \(worksheets.count + 1)")
        worksheets.append(ws)
        activeWorksheet = ws.id
        queryText = ""; queryResult = nil; editableTable = nil; rowKey = nil
        persistCurrentWorkspace()
    }

    public func switchWorksheet(_ id: UUID) {
        guard id != activeWorksheet else { return }
        stashActive()
        activeWorksheet = id
        queryText = savedText[id] ?? ""
        queryResult = (savedResult[id] ?? nil)
        editableTable = (savedEditable[id] ?? nil)
        rowKey = (savedRowKey[id] ?? nil)
        persistCurrentWorkspace()   // cập nhật activeID đã lưu
    }

    public func closeWorksheet(_ id: UUID) {
        guard worksheets.count > 1 else { return }
        worksheets.removeAll { $0.id == id }
        savedText[id] = nil; savedResult[id] = nil; savedEditable[id] = nil; savedRowKey[id] = nil
        if activeWorksheet == id, let firstWS = worksheets.first {
            activeWorksheet = firstWS.id
            queryText = savedText[firstWS.id] ?? ""
            queryResult = (savedResult[firstWS.id] ?? nil)
            editableTable = (savedEditable[firstWS.id] ?? nil)
            rowKey = (savedRowKey[firstWS.id] ?? nil)
        }
        persistCurrentWorkspace()
    }

    // MARK: - Persist worksheet theo connection

    /// Ghi bộ worksheet hiện tại xuống đĩa, gắn với profile đang nối.
    private func persistCurrentWorkspace() {
        guard let pid = loadedWorkspaceProfileID else { return }   // chưa gắn profile → bỏ qua
        stashActive()
        let items = worksheets.map {
            WorksheetStore.Item(id: $0.id, title: $0.title, text: savedText[$0.id] ?? "")
        }
        wsStore.update(profileID: pid, workspace: .init(worksheets: items, activeID: activeWorksheet))
    }

    /// Nạp bộ worksheet đã lưu của một connection (gọi khi kết nối thành công).
    private func loadWorkspace(for profileID: UUID) {
        guard loadedWorkspaceProfileID != profileID else { return }   // đã đúng profile
        persistCurrentWorkspace()   // lưu bộ của profile trước (no-op nếu chưa gắn)

        if let saved = wsStore.workspace(for: profileID), !saved.worksheets.isEmpty {
            worksheets = saved.worksheets.map { Worksheet(id: $0.id, title: $0.title) }
            savedText = Dictionary(uniqueKeysWithValues: saved.worksheets.map { ($0.id, $0.text) })
            savedResult = [:]; savedEditable = [:]; savedRowKey = [:]
            activeWorksheet = saved.worksheets.contains { $0.id == saved.activeID }
                ? saved.activeID : worksheets[0].id
            queryText = savedText[activeWorksheet] ?? ""
            queryResult = nil; editableTable = nil; rowKey = nil
            loadedWorkspaceProfileID = profileID
        } else if loadedWorkspaceProfileID == nil {
            // Lần đầu kết nối, profile chưa có workspace đã lưu → nhận luôn tab đang gõ dở.
            loadedWorkspaceProfileID = profileID
            persistCurrentWorkspace()
        } else {
            // Chuyển sang profile khác chưa có workspace → mở tab mới tinh.
            let ws = Worksheet(id: UUID(), title: "SQL 1")
            worksheets = [ws]; activeWorksheet = ws.id
            savedText = [ws.id: ""]; savedResult = [:]; savedEditable = [:]; savedRowKey = [:]
            queryText = ""; queryResult = nil; editableTable = nil; rowKey = nil
            loadedWorkspaceProfileID = profileID
            persistCurrentWorkspace()
        }
    }

    private func stashActive() {
        savedText[activeWorksheet] = queryText
        savedResult[activeWorksheet] = queryResult
        savedEditable[activeWorksheet] = editableTable
        savedRowKey[activeWorksheet] = rowKey
    }

    // MARK: - Profile management

    public func addProfile(_ profile: ConnectionProfile, password: String) {
        try? store.setPassword(password, for: profile)
        profiles.append(profile)
        store.saveProfiles(profiles)
    }

    public func deleteProfile(at offsets: IndexSet) {
        for idx in offsets {
            store.deletePassword(for: profiles[idx])
            wsStore.remove(profileID: profiles[idx].id)   // dọn worksheet đã lưu
            if loadedWorkspaceProfileID == profiles[idx].id { loadedWorkspaceProfileID = nil }
        }
        profiles = profiles.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        store.saveProfiles(profiles)
    }

    /// Sửa thông tin một profile đã có (không phải xóa rồi tạo lại).
    /// `password == nil` → giữ nguyên password cũ trong Keychain.
    public func updateProfile(_ profile: ConnectionProfile, password: String?) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx] = profile
        store.saveProfiles(profiles)
        if let password { try? store.setPassword(password, for: profile) }
        // Đang nối chính profile vừa sửa → ngắt để thông tin mới có hiệu lực ở lần nối kế.
        if selectedProfileID == profile.id && isConnected { disconnect() }
    }

    /// Password đã lưu của profile (dùng để prefill khi sửa).
    public func password(for profile: ConnectionProfile) -> String? {
        store.password(for: profile)
    }

    /// Thử kết nối với thông tin nhập vào — KHÔNG đụng tới connection đang mở.
    /// Trả `.success` nếu connect được, `.failure(error)` kèm lý do nếu không.
    public func testConnection(_ profile: ConnectionProfile, password: String) async -> Result<Void, Error> {
        let drv = makeDriver(profile: profile, password: password)
        do {
            try await drv.connect()
            await drv.disconnect()
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    public var selectedProfile: ConnectionProfile? {
        profiles.first { $0.id == selectedProfileID }
    }

    // MARK: - Connection

    public func connect(to profile: ConnectionProfile) {
        let pwd = store.password(for: profile) ?? ""
        isBusy = true
        statusMessage = "Đang kết nối…"
        Task {
            do {
                let drv = makeDriver(profile: profile, password: pwd)
                try await drv.connect()
                await drv.setRowLimit(self.rowLimit)
                self.driver = drv
                self.isConnected = true
                self.selectedProfileID = profile.id
                self.loadWorkspace(for: profile.id)   // khôi phục script/tab của connection này
                self.statusMessage = "Đã kết nối \(profile.name)."
                self.startKeepAlive()   // giữ session sống mỗi 5 phút
                // Chỉ lấy danh sách folder cố định — KHÔNG query object (lazy khi bung).
                self.objectsByCategory = [:]
                self.categories = await drv.schemaCategories()
            } catch {
                self.statusMessage = "Lỗi kết nối: \(error)"
            }
            self.isBusy = false
        }
    }

    /// Kết nối lại profile đang chọn — dùng cho nút "Kết nối lại".
    /// Giữ nguyên cây schema đã tải (DB không đổi), chỉ dựng lại socket.
    public func reconnect() {
        guard let profile = selectedProfile else { return }
        isBusy = true
        statusMessage = "Đang kết nối lại \(profile.name)…"
        Task {
            do {
                try await rebuildConnection()
                self.startKeepAlive()
                if self.categories.isEmpty {
                    self.categories = await self.driver?.schemaCategories() ?? []
                }
                self.statusMessage = "Đã kết nối lại \(profile.name)."
            } catch {
                self.isConnected = false
                self.statusMessage = "Kết nối lại thất bại: \(error)"
            }
            self.isBusy = false
        }
    }

    /// Đóng driver cũ & dựng lại kết nối bằng profile đang chọn. Throws nếu thất bại.
    /// Là lõi dùng chung cho `reconnect()` và auto-reconnect khi chạy query.
    private func rebuildConnection() async throws {
        guard let profile = selectedProfile else { throw DBError.notConnected }
        let pwd = store.password(for: profile) ?? ""
        let newDrv = makeDriver(profile: profile, password: pwd)
        try await newDrv.connect()
        await newDrv.setRowLimit(rowLimit)
        let old = driver
        driver = newDrv
        isConnected = true
        if let old { await old.disconnect() }
    }

    public func disconnect() {
        guard let drv = driver else { return }
        persistCurrentWorkspace()   // chốt script trước khi ngắt
        stopKeepAlive()
        Task {
            await drv.disconnect()
            self.driver = nil
            self.isConnected = false
            self.categories = []
            self.objectsByCategory = [:]
            self.loadingCategories = []
            self.queryResult = nil
            self.editableTable = nil
            self.rowKey = nil
            self.pinnedResults = []
            self.activeResultTab = nil
            self.statusMessage = "Đã ngắt kết nối."
        }
    }

    // MARK: - Schema (lazy theo nhóm)

    /// Lazy-load object của một nhóm khi người dùng bung folder. Cache lại.
    public func loadCategory(_ category: SchemaCategory) {
        guard let drv = driver else { return }
        if objectsByCategory[category.id] != nil || loadingCategories.contains(category.id) { return }
        loadingCategories.insert(category.id)
        Task {
            do {
                let objs = try await drv.listObjects(category)
                self.objectsByCategory[category.id] = objs
            } catch {
                self.objectsByCategory[category.id] = []
                self.statusMessage = "Lỗi tải \(category.title): \(error)"
            }
            self.loadingCategories.remove(category.id)
        }
    }

    /// Tải lại một nhóm (bỏ cache).
    public func reloadCategory(_ category: SchemaCategory) {
        objectsByCategory[category.id] = nil
        loadCategory(category)
    }

    // MARK: - Auto-reconnect

    /// Chạy `op`; nếu lỗi do rớt/đứt kết nối → tự kết nối lại 1 lần rồi thử lại.
    /// `op` đọc `self.driver` tại thời điểm gọi (không capture driver cũ) nên sau khi
    /// dựng lại sẽ chạy trên connection mới.
    private func runWithAutoReconnect<T>(_ op: () async throws -> T) async throws -> T {
        do {
            return try await op()
        } catch {
            guard Self.isConnectionError(error) else { throw error }
            statusMessage = "Mất kết nối — đang kết nối lại…"
            do {
                try await rebuildConnection()
            } catch {
                isConnected = false   // reconnect cũng fail → cập nhật UI cho đúng thực tế
                throw error
            }
            return try await op()     // thử lại 1 lần trên connection mới
        }
    }

    /// Heuristic: lỗi có phải do rớt/đứt kết nối (cần reconnect) hay lỗi SQL thường?
    private static func isConnectionError(_ error: Error) -> Bool {
        if case DBError.notConnected = error { return true }
        let s = "\(error)".lowercased()
        let signals = ["not connected", "chưa kết nối", "connection", "closed",
                       "broken pipe", "reset by peer", "eof", "timed out",
                       "shutdown", "ioerror", "channel"]
        return signals.contains { s.contains($0) }
    }

    // MARK: - Chọn câu lệnh để chạy (bôi đen / tại con trỏ)

    /// SQL thực sự sẽ chạy: ưu tiên vùng bôi đen → câu lệnh tại con trỏ → toàn bộ editor.
    /// Luôn bỏ dấu ';' cuối để gửi đúng 1 câu (MySQL không cho nhiều câu trong 1 query).
    private func sqlToRun() -> String {
        let sel = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Chỉ tin vùng bôi đen nếu nó thực sự nằm trong text hiện tại (tránh selection cũ sau khi đổi tab).
        if !sel.isEmpty, queryText.contains(sel) { return Self.stripTrailingSemis(sel) }
        if let stmt = statementAtCaret() { return Self.stripTrailingSemis(stmt) }
        return Self.stripTrailingSemis(queryText)
    }

    private static func stripTrailingSemis(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix(";") { t.removeLast(); t = t.trimmingCharacters(in: .whitespacesAndNewlines) }
        return t
    }

    /// Câu lệnh chứa con trỏ (tách theo ';', bỏ qua ';' trong chuỗi '…'/"…"/`…`).
    private func statementAtCaret() -> String? {
        let stmts = Self.splitStatements(queryText)
        guard !stmts.isEmpty else { return nil }
        let caret = max(0, min(caretLocation, (queryText as NSString).length))
        // Câu chứa con trỏ (bao gồm vị trí ngay sau ';' = đầu câu kế tiếp).
        for s in stmts where caret >= s.range.location && caret <= NSMaxRange(s.range) {
            let t = s.sql.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        // Con trỏ ở vùng trống → câu không rỗng gần nhất phía trước.
        for s in stmts.reversed() where s.range.location <= caret {
            let t = s.sql.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return nil
    }

    /// Tách text thành các câu lệnh theo ';' (an toàn với ';' trong chuỗi/identifier).
    private static func splitStatements(_ text: String) -> [(sql: String, range: NSRange)] {
        let ns = text as NSString
        let n = ns.length
        let quote: UInt16 = 39, dquote: UInt16 = 34, backtick: UInt16 = 96, semi: UInt16 = 59
        var result: [(String, NSRange)] = []
        var inSingle = false, inDouble = false, inBacktick = false
        var start = 0
        var i = 0
        while i < n {
            let c = ns.character(at: i)
            if inSingle { if c == quote { inSingle = false } }
            else if inDouble { if c == dquote { inDouble = false } }
            else if inBacktick { if c == backtick { inBacktick = false } }
            else if c == quote { inSingle = true }
            else if c == dquote { inDouble = true }
            else if c == backtick { inBacktick = true }
            else if c == semi {
                let r = NSRange(location: start, length: i - start)
                result.append((ns.substring(with: r), r))
                start = i + 1
            }
            i += 1
        }
        if start < n {
            let r = NSRange(location: start, length: n - start)
            result.append((ns.substring(with: r), r))
        }
        return result
    }

    // MARK: - Gim kết quả để so sánh

    /// Snapshot kết quả hiện tại vào danh sách gim (chỉ đọc).
    public func pinCurrentResult() {
        guard let r = queryResult else { return }
        let raw = lastExecutedSQL.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = raw.isEmpty ? "Kết quả gim" : (raw.count > 80 ? String(raw.prefix(80)) + "…" : raw)
        pinnedResults.append(PinnedResult(id: UUID(), title: title, result: r))
    }

    public func unpinResult(_ id: UUID) {
        pinnedResults.removeAll { $0.id == id }
        if activeResultTab == id { activeResultTab = nil }
    }

    /// SQL của lần chạy gần nhất — làm tiêu đề khi gim.
    private var lastExecutedSQL = ""

    // MARK: - Query

    public func runQuery() {
        guard driver != nil else { return }
        let userSQL = sqlToRun()
        guard !userSQL.isEmpty else { return }
        isBusy = true
        statusMessage = "Đang chạy query…"
        lastExecutedSQL = userSQL
        let limit = rowLimit
        let dbType = selectedProfile?.type
        // SELECT * bảng đơn → cho sửa trực tiếp grid.
        // Oracle: chèn ROWID vào SELECT. MySQL: giữ nguyên SQL, định danh dòng qua PRIMARY KEY (lấy sau query).
        let info = SingleTableEdit.detect(userSQL)
        let sql = (dbType == .oracle)
            ? (info.map { SingleTableEdit.injectRowID(userSQL, info: $0) } ?? userSQL)
            : userSQL
        Task {
            do {
                let result = try await runWithAutoReconnect {
                    guard let d = self.driver else { throw DBError.notConnected }
                    return try await d.query(sql)
                }
                let rows = Array(result.rows.prefix(limit))
                self.queryResult = DBResultSet(columns: result.columns, rows: rows)
                await self.configureEditing(dbType: dbType, info: info, columns: result.columns)
                self.statusMessage = "\(rows.count) hàng" + (result.rows.count > limit ? " (giới hạn \(limit))" : "")
                    + (self.isEditable ? " · sửa trực tiếp được" : "")
            } catch {
                self.editableTable = nil
                self.rowKey = nil
                self.statusMessage = "Lỗi: \(error)"
            }
            self.isBusy = false
        }
    }

    // MARK: - #3: Sửa dữ liệu trực tiếp trên grid (Oracle: ROWID, MySQL: PRIMARY KEY)

    /// Xác định cách định danh dòng cho result vừa nhận để bật/tắt sửa grid.
    private func configureEditing(dbType: DatabaseType?, info: SingleTableEdit.Info?, columns: [String]) async {
        editableTable = nil
        rowKey = nil
        guard let info else { return }
        switch dbType {
        case .oracle:
            // ROWID đã được chèn vào result khi build SQL.
            if columns.contains(SingleTableEdit.rowidColumn) {
                editableTable = info.table
                rowKey = .rowid
            }
        case .mysql:
            let pk = await driver?.primaryKeyColumns(forTable: info.table) ?? []
            // Khớp tên cột PK với tên cột thực trong result (không phân biệt hoa/thường).
            let resolved = pk.compactMap { p in columns.first { $0.caseInsensitiveCompare(p) == .orderedSame } }
            if !pk.isEmpty, resolved.count == pk.count {
                editableTable = info.table
                rowKey = .primaryKey(resolved)
            }
        default:
            break
        }
    }

    /// Build mệnh đề WHERE định danh đúng 1 dòng từ giá trị gốc của dòng đó.
    private func keyPredicate(for row: DBRow) -> String? {
        switch rowKey {
        case .rowid:
            guard let rid = (row[SingleTableEdit.rowidColumn] ?? nil) else { return nil }
            return "ROWID = '\(rid.replacingOccurrences(of: "'", with: "''"))'"
        case .primaryKey(let cols):
            guard !cols.isEmpty else { return nil }
            var parts: [String] = []
            for c in cols {
                // PK NULL không định danh được an toàn → từ chối sửa.
                guard let v = (row[c] ?? nil) else { return nil }
                parts.append("\(c) = \(SingleTableEdit.literal(v))")
            }
            return parts.joined(separator: " AND ")
        case .none:
            return nil
        }
    }

    /// Mô tả khóa định danh dòng (hiện trong dialog xác nhận xóa).
    public func rowKeyDescription(for row: DBRow) -> String {
        switch rowKey {
        case .rowid:
            return (row[SingleTableEdit.rowidColumn] ?? nil).map { "ROWID: \($0)" } ?? ""
        case .primaryKey(let cols):
            return cols.compactMap { c in (row[c] ?? nil).map { "\(c)=\($0)" } }.joined(separator: ", ")
        case .none:
            return ""
        }
    }

    /// Cập nhật một dòng. `originalRow` = dòng gốc (để lấy khóa), `values` = cột → giá trị mới.
    public func updateRow(originalRow: DBRow, values: [String: String?]) {
        guard let table = editableTable, let pred = keyPredicate(for: originalRow) else { return }
        let sets = values.map { "\($0.key) = \(SingleTableEdit.literal($0.value))" }.joined(separator: ", ")
        guard !sets.isEmpty else { return }
        runDML("UPDATE \(table) SET \(sets) WHERE \(pred)", success: "Đã cập nhật 1 dòng.")
    }

    public func deleteRow(originalRow: DBRow) {
        guard let table = editableTable, let pred = keyPredicate(for: originalRow) else { return }
        runDML("DELETE FROM \(table) WHERE \(pred)", success: "Đã xóa 1 dòng.")
    }

    public func insertRow(values: [String: String?]) {
        guard let table = editableTable else { return }
        let cols = values.keys.sorted()
        let colList = cols.joined(separator: ", ")
        let valList = cols.map { SingleTableEdit.literal(values[$0] ?? nil) }.joined(separator: ", ")
        runDML("INSERT INTO \(table) (\(colList)) VALUES (\(valList))", success: "Đã thêm 1 dòng.")
    }

    private func runDML(_ sql: String, success: String) {
        guard driver != nil else { return }
        isBusy = true
        Task {
            do {
                try await runWithAutoReconnect {
                    guard let d = self.driver else { throw DBError.notConnected }
                    try await d.execute(sql)
                }
                self.statusMessage = success
                self.runQuery()   // refresh để thấy thay đổi
            } catch {
                self.statusMessage = "Lỗi DML: \(error)"
                self.isBusy = false
            }
        }
    }

    // MARK: - #2: Chạy procedure/function với tham số

    /// Danh sách procedure/function public trong một package.
    public func fetchPackageMembers(_ pkg: String) async -> [String] {
        guard let drv = driver, let owner = selectedProfile?.username.uppercased() else { return [] }
        let sql = """
            SELECT DISTINCT PROCEDURE_NAME FROM ALL_PROCEDURES \
            WHERE OWNER = '\(owner)' AND OBJECT_NAME = '\(pkg)' AND PROCEDURE_NAME IS NOT NULL \
            ORDER BY PROCEDURE_NAME
            """
        guard let rs = try? await drv.query(sql) else { return [] }
        return rs.rows.compactMap { ($0["PROCEDURE_NAME"] ?? nil) }.filter { !$0.isEmpty }
    }

    /// Lấy tham số của procedure/function. `package` != nil khi là member của package.
    public func fetchArguments(_ name: String, package: String? = nil) async -> [ProcArg] {
        guard let drv = driver, let owner = selectedProfile?.username.uppercased() else { return [] }
        let pkgClause = package.map { "PACKAGE_NAME = '\($0)'" } ?? "PACKAGE_NAME IS NULL"
        let sql = """
            SELECT POSITION, ARGUMENT_NAME, IN_OUT, DATA_TYPE FROM ALL_ARGUMENTS \
            WHERE OWNER = '\(owner)' AND OBJECT_NAME = '\(name)' AND \(pkgClause) \
            ORDER BY POSITION
            """
        guard let rs = try? await drv.query(sql) else { return [] }
        return rs.rows.compactMap { row in
            guard let posStr = (row["POSITION"] ?? nil), let pos = Int(posStr) else { return nil }
            return ProcArg(
                id: pos,
                name: (row["ARGUMENT_NAME"] ?? nil) ?? "",
                inOut: (row["IN_OUT"] ?? nil) ?? "IN",
                dataType: (row["DATA_TYPE"] ?? nil) ?? "VARCHAR2"
            )
        }
    }

    /// Sinh câu lệnh gọi + chạy. Function (không OUT) hiện kết quả ở grid; còn lại chạy block.
    public func runProcedureCall(name: String, isFunction: Bool, args: [ProcArg], values: [String: String]) {
        let (sql, isSelect) = ProcedureCall.build(object: name, isFunction: isFunction, args: args, values: values)
        queryText = sql
        if isSelect { runQuery() } else { execute() }
    }

    /// #2: Click package/procedure/function/view → tải source vào editor.
    public func loadObjectSource(_ object: DBSchemaObject) {
        guard let drv = driver else { return }
        isBusy = true
        statusMessage = "Đang tải source \(object.name)…"
        Task {
            do {
                self.queryText = try await drv.objectSource(object)
                self.statusMessage = "Source \(object.name)."
            } catch {
                self.statusMessage = "Lỗi tải source: \(error)"
            }
            self.isBusy = false
        }
    }

    public func execute() {
        guard driver != nil else { return }
        let stmt = sqlToRun()
        guard !stmt.isEmpty else { return }
        isBusy = true
        lastExecutedSQL = stmt
        Task {
            do {
                try await runWithAutoReconnect {
                    guard let d = self.driver else { throw DBError.notConnected }
                    try await d.execute(stmt)
                }
                self.statusMessage = "Thực thi thành công."
            } catch {
                self.statusMessage = "Lỗi: \(error)"
            }
            self.isBusy = false
        }
    }

    // MARK: - #2: Keep-alive (giữ session DB) — chạy mỗi 5 phút, dừng khi Mac sleep

    private var keepAliveTimer: Timer?
    private let keepAliveInterval: TimeInterval = 300   // 5 phút

    private func startKeepAlive() {
        stopKeepAlive()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: keepAliveInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.pingToKeepAlive() }
        }
    }

    private func stopKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }

    /// Ping nhẹ để giữ session sống (healthCheck = SELECT 1 / PING tùy driver).
    private func pingToKeepAlive() {
        guard let drv = driver, isConnected else { return }
        Task { await drv.healthCheck() }
    }

    // MARK: - Sleep/wake

    private func bindSleepWake() {
        sleepWake.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .willSleep:
                    self.stopKeepAlive()                 // Mac ngủ → dừng job
                case .didWake:
                    self.handleWake()
                    if self.isConnected { self.startKeepAlive() }   // thức → chạy lại
                }
            }
            .store(in: &cancellables)
    }

    private func handleWake() {
        guard let drv = driver, isConnected else { return }
        Task { await drv.healthCheck() }
    }

    // MARK: - Factory

    private func makeDriver(profile: ConnectionProfile, password: String) -> any DatabaseDriver {
        switch profile.type {
        case .mysql:  return MySQLDriver(profile: profile, password: password)
        case .redis:  return RedisDriver(profile: profile, password: password)
        case .oracle:
            // Khi có Instant Client (OCI) → dùng OCI (hỗ trợ Oracle cũ < 12.1).
            // Ngược lại fallback oracle-nio (chỉ 12.1+).
            #if HAS_OCI
            return OracleOCIDriver(profile: profile, password: password)
            #else
            return OracleDriver(profile: profile, password: password)
            #endif
        }
    }
}
