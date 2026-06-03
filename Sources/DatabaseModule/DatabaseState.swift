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
    /// Tên bảng nếu query hiện tại là SELECT bảng đơn → cho phép sửa grid (qua ROWID).
    @Published public var editableTable: String?
    /// Các cột hiển thị (ẩn cột ROWID kỹ thuật).
    public var visibleColumns: [String] {
        (queryResult?.columns ?? []).filter { $0 != SingleTableEdit.rowidColumn }
    }
    public var isEditable: Bool { editableTable != nil }
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
    }

    public func addWorksheet() {
        stashActive()
        let ws = Worksheet(id: UUID(), title: "SQL \(worksheets.count + 1)")
        worksheets.append(ws)
        activeWorksheet = ws.id
        queryText = ""; queryResult = nil; editableTable = nil
    }

    public func switchWorksheet(_ id: UUID) {
        guard id != activeWorksheet else { return }
        stashActive()
        activeWorksheet = id
        queryText = savedText[id] ?? ""
        queryResult = (savedResult[id] ?? nil)
        editableTable = (savedEditable[id] ?? nil)
    }

    public func closeWorksheet(_ id: UUID) {
        guard worksheets.count > 1 else { return }
        worksheets.removeAll { $0.id == id }
        savedText[id] = nil; savedResult[id] = nil; savedEditable[id] = nil
        if activeWorksheet == id, let firstWS = worksheets.first {
            activeWorksheet = firstWS.id
            queryText = savedText[firstWS.id] ?? ""
            queryResult = (savedResult[firstWS.id] ?? nil)
            editableTable = (savedEditable[firstWS.id] ?? nil)
        }
    }

    private func stashActive() {
        savedText[activeWorksheet] = queryText
        savedResult[activeWorksheet] = queryResult
        savedEditable[activeWorksheet] = editableTable
    }

    // MARK: - Profile management

    public func addProfile(_ profile: ConnectionProfile, password: String) {
        try? store.setPassword(password, for: profile)
        profiles.append(profile)
        store.saveProfiles(profiles)
    }

    public func deleteProfile(at offsets: IndexSet) {
        for idx in offsets { store.deletePassword(for: profiles[idx]) }
        profiles = profiles.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        store.saveProfiles(profiles)
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

    public func disconnect() {
        guard let drv = driver else { return }
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

    // MARK: - Query

    public func runQuery() {
        guard let drv = driver, !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isBusy = true
        statusMessage = "Đang chạy query…"
        let userSQL = queryText
        let limit = rowLimit
        // #3: nếu là SELECT bảng đơn (Oracle) → chèn ROWID để sửa được trên grid.
        let editInfo = (selectedProfile?.type == .oracle) ? SingleTableEdit.detect(userSQL) : nil
        let sql = editInfo.map { SingleTableEdit.injectRowID(userSQL, info: $0) } ?? userSQL
        Task {
            do {
                let result = try await drv.query(sql)
                let rows = Array(result.rows.prefix(limit))
                self.queryResult = DBResultSet(columns: result.columns, rows: rows)
                self.editableTable = editInfo?.table
                self.statusMessage = "\(rows.count) hàng" + (result.rows.count > limit ? " (giới hạn \(limit))" : "")
                    + (editInfo != nil ? " · sửa trực tiếp được" : "")
            } catch {
                self.editableTable = nil
                self.statusMessage = "Lỗi: \(error)"
            }
            self.isBusy = false
        }
    }

    // MARK: - #3: Sửa dữ liệu trực tiếp qua ROWID

    /// Cập nhật một dòng theo ROWID. `values` = cột hiển thị → giá trị mới.
    public func updateRow(rowid: String, values: [String: String?]) {
        guard let table = editableTable else { return }
        let sets = values.map { "\($0.key) = \(SingleTableEdit.literal($0.value))" }.joined(separator: ", ")
        guard !sets.isEmpty else { return }
        let sql = "UPDATE \(table) SET \(sets) WHERE ROWID = '\(rowid)'"
        runDML(sql, success: "Đã cập nhật 1 dòng.")
    }

    public func deleteRow(rowid: String) {
        guard let table = editableTable else { return }
        runDML("DELETE FROM \(table) WHERE ROWID = '\(rowid)'", success: "Đã xóa 1 dòng.")
    }

    public func insertRow(values: [String: String?]) {
        guard let table = editableTable else { return }
        let cols = values.keys.sorted()
        let colList = cols.joined(separator: ", ")
        let valList = cols.map { SingleTableEdit.literal(values[$0] ?? nil) }.joined(separator: ", ")
        runDML("INSERT INTO \(table) (\(colList)) VALUES (\(valList))", success: "Đã thêm 1 dòng.")
    }

    private func runDML(_ sql: String, success: String) {
        guard let drv = driver else { return }
        isBusy = true
        Task {
            do {
                try await drv.execute(sql)
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
        guard let drv = driver, !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isBusy = true
        let stmt = queryText
        Task {
            do {
                try await drv.execute(stmt)
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
