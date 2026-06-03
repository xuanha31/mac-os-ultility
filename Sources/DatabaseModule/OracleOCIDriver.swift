#if HAS_OCI
import Foundation
import COracleOCI
import Core

// DB-06/07/08 (Oracle cũ < 12.1): driver dùng Oracle Call Interface (OCI) qua Instant Client.
// Kết nối được mọi phiên bản Oracle mà client 19.x hỗ trợ (11.2+).
// Chỉ biên dịch khi đã cài Instant Client + SDK (xem docs/ORACLE-OCI-SETUP.md).
//
// Cách tiếp cận generic SQL client: define mọi cột thành chuỗi (SQLT_STR),
// để OCI tự convert NUMBER/DATE/... → text. Đủ cho xem dữ liệu + chạy proc.

public actor OracleOCIDriver: DatabaseDriver {
    public let dbType: DatabaseType = .oracle
    private var connected = false

    private let profile: ConnectionProfile
    private let password: String
    /// Trần số dòng lấy về mỗi query (cấu hình từ UI). Giống "first rows" của SQL Developer.
    private var fetchLimit = 250

    // OCI handles
    private var env: OpaquePointer?
    private var err: OpaquePointer?
    private var server: OpaquePointer?
    private var svc: OpaquePointer?
    private var session: OpaquePointer?

    public init(profile: ConnectionProfile, password: String) {
        self.profile = profile
        self.password = password
    }

    // MARK: - Connect

    public func connect() async throws {
        // 1. Tạo môi trường OCI
        // charset AL32UTF8 = 873 → OCI tự convert dữ liệu server sang UTF-8
        // (sửa lỗi tiếng Việt hiện thành "?"). Dùng OCIEnvNlsCreate thay OCIEnvCreate.
        let utf8: UInt16 = 873
        var e: OpaquePointer?
        guard OCIEnvNlsCreate(&e, UInt32(OCI_DEFAULT | OCI_THREADED), nil, nil, nil, nil, 0, nil, utf8, utf8) == OCI_SUCCESS,
              let envH = e else {
            throw DBError.queryFailed("OCIEnvNlsCreate thất bại")
        }
        env = envH

        err    = try allocHandle(type: UInt32(OCI_HTYPE_ERROR))
        server = try allocHandle(type: UInt32(OCI_HTYPE_SERVER))
        svc    = try allocHandle(type: UInt32(OCI_HTYPE_SVCCTX))
        session = try allocHandle(type: UInt32(OCI_HTYPE_SESSION))

        // 2. Attach tới server qua connect string "//host:port/service"
        let connStr = "//\(profile.host):\(profile.port)/\(profile.database)"
        let rc = connStr.withCString { cstr -> Int32 in
            OCIServerAttach(server, err, UnsafeRawPointer(cstr).assumingMemoryBound(to: UInt8.self),
                            Int32(connStr.utf8.count), UInt32(OCI_DEFAULT))
        }
        try check(rc, context: "OCIServerAttach (\(connStr))")

        // 3. svc.server = server
        OCIAttrSet(UnsafeMutableRawPointer(svc), UInt32(OCI_HTYPE_SVCCTX),
                   UnsafeMutableRawPointer(server), 0, UInt32(OCI_ATTR_SERVER), err)

        // 4. session.username / .password
        try setSessionString(profile.username, attr: UInt32(OCI_ATTR_USERNAME))
        try setSessionString(password, attr: UInt32(OCI_ATTR_PASSWORD))

        // 5. Bắt đầu session
        try check(OCISessionBegin(svc, err, session, UInt32(OCI_CRED_RDBMS), UInt32(OCI_DEFAULT)),
                  context: "OCISessionBegin")

        // 6. svc.session = session
        OCIAttrSet(UnsafeMutableRawPointer(svc), UInt32(OCI_HTYPE_SVCCTX),
                   UnsafeMutableRawPointer(session), 0, UInt32(OCI_ATTR_SESSION), err)

        connected = true
        Log.database.info("Oracle (OCI) connected to \(self.profile.host, privacy: .public)")
    }

    public func disconnect() async {
        if let svc, let err, let session {
            OCISessionEnd(svc, err, session, UInt32(OCI_DEFAULT))
        }
        if let server, let err {
            OCIServerDetach(server, err, UInt32(OCI_DEFAULT))
        }
        freeHandle(session, type: UInt32(OCI_HTYPE_SESSION))
        freeHandle(svc,     type: UInt32(OCI_HTYPE_SVCCTX))
        freeHandle(server,  type: UInt32(OCI_HTYPE_SERVER))
        freeHandle(err,     type: UInt32(OCI_HTYPE_ERROR))
        if let env { OCIHandleFree(UnsafeMutableRawPointer(env), UInt32(OCI_HTYPE_ENV)) }
        env = nil; self.err = nil; server = nil; svc = nil; session = nil
        connected = false
    }

    // MARK: - Query (SELECT)

    public func query(_ sql: String) async throws -> DBResultSet {
        try await runQuery(sql, limit: fetchLimit)
    }

    public func setRowLimit(_ limit: Int) { fetchLimit = max(1, limit) }

    private func sourceText(owner: String, name: String, type: String) async throws -> String {
        // Thử theo owner hiện tại trước.
        var rs = try await runQuery(
            "SELECT TEXT FROM ALL_SOURCE WHERE OWNER='\(owner)' AND NAME='\(name)' AND TYPE='\(type)' ORDER BY LINE",
            limit: 100_000)
        // Nếu rỗng (object/body có thể thuộc schema khác mà user đọc được) → tìm theo tên.
        if rs.rows.isEmpty {
            rs = try await runQuery(
                "SELECT TEXT FROM ALL_SOURCE WHERE NAME='\(name)' AND TYPE='\(type)' ORDER BY OWNER, LINE",
                limit: 100_000)
        }
        return rs.rows.compactMap { ($0["TEXT"] ?? nil) }.joined().trimmingCharacters(in: .newlines)
    }

    /// Source code đầy đủ — ghép ALL_SOURCE (code) hoặc ALL_VIEWS (view).
    public func objectSource(_ object: DBSchemaObject) async throws -> String {
        let owner = profile.username.uppercased()
        let name = object.name
        let type = object.type.uppercased()
        switch type {
        case "VIEW":
            let rs = try await runQuery(
                "SELECT TEXT FROM ALL_VIEWS WHERE OWNER='\(owner)' AND VIEW_NAME='\(name)'", limit: 1)
            let body = (rs.rows.first?["TEXT"] ?? nil) ?? ""
            return "CREATE OR REPLACE VIEW \(name) AS\n\(body);"
        case "PACKAGE":
            // Lấy cả spec (PACKAGE) lẫn body (PACKAGE BODY).
            let spec = try await sourceText(owner: owner, name: name, type: "PACKAGE")
            let bodyTxt = try await sourceText(owner: owner, name: name, type: "PACKAGE BODY")
            var out = ""
            if !spec.isEmpty {
                out += "-- ===== PACKAGE SPEC =====\nCREATE OR REPLACE " + spec + "\n/\n"
            }
            if !bodyTxt.isEmpty {
                out += "\n-- ===== PACKAGE BODY =====\nCREATE OR REPLACE " + bodyTxt + "\n/"
            } else {
                out += "\n-- (Không có PACKAGE BODY hoặc không có quyền xem)"
            }
            return out.isEmpty ? "-- Không lấy được source package \(name)" : out
        case "PACKAGE SPEC":
            let spec = try await sourceText(owner: owner, name: name, type: "PACKAGE")
            guard !spec.isEmpty else { return "-- Không lấy được spec của \(name)" }
            return "CREATE OR REPLACE " + spec + "\n/"
        case "PACKAGE BODY", "PROCEDURE", "FUNCTION", "TRIGGER", "TYPE", "TYPE BODY":
            let body = try await sourceText(owner: owner, name: name, type: type)
            guard !body.isEmpty else { return "-- Không lấy được source của \(type) \(name)" }
            return "CREATE OR REPLACE " + body + "\n/"
        default:
            return "SELECT * FROM \(name) WHERE ROWNUM <= \(fetchLimit)"
        }
    }

    private func runQuery(_ rawSQL: String, limit: Int) async throws -> DBResultSet {
        guard connected else { throw DBError.notConnected }
        let sql = Self.sanitize(rawSQL)
        var stmt: OpaquePointer? = try allocHandle(type: UInt32(OCI_HTYPE_STMT))
        defer { freeHandle(stmt, type: UInt32(OCI_HTYPE_STMT)) }

        try sql.withCString { c in
            try check(OCIStmtPrepare(stmt, err, UnsafeRawPointer(c).assumingMemoryBound(to: UInt8.self),
                                     UInt32(sql.utf8.count), UInt32(OCI_NTV_SYNTAX), UInt32(OCI_DEFAULT)),
                      context: "OCIStmtPrepare")
        }

        // Xác định statement type (SELECT hay không)
        var stmtType: UInt16 = 0
        OCIAttrGet(UnsafeRawPointer(stmt), UInt32(OCI_HTYPE_STMT), &stmtType, nil,
                   UInt32(OCI_ATTR_STMT_TYPE), err)

        let isSelect = (Int32(stmtType) == OCI_STMT_SELECT)
        let iters: UInt32 = isSelect ? 0 : 1
        // Non-SELECT (INSERT/UPDATE/DELETE/DDL/PLSQL) → tự commit để thay đổi được lưu.
        let mode = UInt32(isSelect ? OCI_DEFAULT : OCI_COMMIT_ON_SUCCESS)
        try check(OCIStmtExecute(svc, stmt, err, iters, 0, nil, nil, mode),
                  context: "OCIStmtExecute")

        guard isSelect else { return DBResultSet(columns: [], rows: []) }

        // Số cột
        var colCount: UInt32 = 0
        OCIAttrGet(UnsafeRawPointer(stmt), UInt32(OCI_HTYPE_STMT), &colCount, nil,
                   UInt32(OCI_ATTR_PARAM_COUNT), err)

        // Array fetch: lấy nhiều dòng/round-trip (nhanh hơn fetch từng dòng nhiều lần).
        let bufSize = 2000          // bytes/ô
        let arraySize = 100         // dòng mỗi lần fetch
        let maxRows = limit         // chặn trần để không treo với bảng lớn

        var columns: [String] = []
        var buffers: [UnsafeMutableRawPointer] = []
        var indicators: [UnsafeMutablePointer<Int16>] = []

        for i in 1...Int(colCount) where colCount > 0 {
            var paramH: UnsafeMutableRawPointer?
            OCIParamGet(UnsafeRawPointer(stmt), UInt32(OCI_HTYPE_STMT), err, &paramH, UInt32(i))
            var namePtr: UnsafeMutablePointer<UInt8>?
            var nameLen: UInt32 = 0
            OCIAttrGet(paramH, UInt32(OCI_DTYPE_PARAM), &namePtr, &nameLen, UInt32(OCI_ATTR_NAME), err)
            let name = namePtr.flatMap {
                String(bytes: UnsafeBufferPointer(start: $0, count: Int(nameLen)), encoding: .utf8)
            } ?? "COL\(i)"
            columns.append(name)

            let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize * arraySize, alignment: 16)
            let ind = UnsafeMutablePointer<Int16>.allocate(capacity: arraySize)
            ind.initialize(repeating: 0, count: arraySize)
            buffers.append(buf)
            indicators.append(ind)
            var defH: OpaquePointer?
            OCIDefineByPos(stmt, &defH, err, UInt32(i), buf, Int32(bufSize),
                           UInt16(SQLT_STR), ind, nil, nil, UInt32(OCI_DEFAULT))
        }
        defer {
            buffers.forEach { $0.deallocate() }
            indicators.forEach { $0.deallocate() }
        }

        var rows: [DBRow] = []
        var prevCum: UInt32 = 0
        fetchLoop: while rows.count < maxRows {
            let rc = OCIStmtFetch2(stmt, err, UInt32(arraySize), UInt16(OCI_FETCH_NEXT), 0, UInt32(OCI_DEFAULT))
            if rc != OCI_SUCCESS, rc != OCI_SUCCESS_WITH_INFO, rc != OCI_NO_DATA {
                try check(rc, context: "OCIStmtFetch2")
            }
            // Số dòng nhận trong lần fetch này = delta của ROW_COUNT tích lũy
            var cum: UInt32 = 0
            OCIAttrGet(UnsafeRawPointer(stmt), UInt32(OCI_HTYPE_STMT), &cum, nil,
                       UInt32(OCI_ATTR_ROW_COUNT), err)
            let batch = Int(cum) - Int(prevCum)
            prevCum = cum
            if batch <= 0 { break }

            for r in 0..<batch {
                var dict: DBRow = [:]
                for (ci, col) in columns.enumerated() {
                    if indicators[ci][r] == -1 {
                        dict[col] = nil
                    } else {
                        let p = buffers[ci].advanced(by: r * bufSize).assumingMemoryBound(to: CChar.self)
                        dict[col] = String(cString: p)
                    }
                }
                rows.append(dict)
                if rows.count >= maxRows { break fetchLoop }
            }
            if rc == OCI_NO_DATA { break }
        }
        return DBResultSet(columns: columns, rows: rows)
    }

    // MARK: - Schema (ALL_OBJECTS)

    // Folder cố định kiểu SQL Developer — hiện ngay khi kết nối, không query.
    public func schemaCategories() async -> [SchemaCategory] {
        OracleSchema.categories
    }

    // Lazy-load: chỉ query loại được bung.
    public func listObjects(_ category: SchemaCategory) async throws -> [DBSchemaObject] {
        let owner = profile.username.uppercased()
        let sql: String
        if category.objectType == "DATABASE LINK" {
            sql = "SELECT DB_LINK AS NAME FROM ALL_DB_LINKS WHERE OWNER IN ('\(owner)', 'PUBLIC') ORDER BY DB_LINK"
        } else {
            sql = """
                SELECT OBJECT_NAME AS NAME FROM ALL_OBJECTS \
                WHERE OWNER = '\(owner)' AND OBJECT_TYPE = '\(category.objectType)' \
                ORDER BY OBJECT_NAME
                """
        }
        let rs = try await runQuery(sql, limit: 100_000)
        return rs.rows.compactMap { row in
            guard let name = (row["NAME"] ?? nil), !name.isEmpty else { return nil }
            return DBSchemaObject(id: "\(category.id):\(name)", name: name, type: category.objectType)
        }
    }

    // MARK: - Execute (PL/SQL block, DDL, CALL proc)

    public func execute(_ statement: String) async throws {
        _ = try await query(statement)  // query() xử lý cả non-SELECT (iters=1)
    }

    public func healthCheck() async {
        guard connected else { return }
        do { _ = try await query("SELECT 1 FROM DUAL") }
        catch {
            Log.database.warning("Oracle OCI health check failed: \(error, privacy: .public)")
            await disconnect()
            try? await connect()
        }
    }

    /// Bỏ `;` cuối câu SQL thường (OCI không nhận). Giữ nguyên cho PL/SQL block.
    static func sanitize(_ sql: String) -> String {
        var s = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = s.uppercased()
        let isPLSQL = upper.hasPrefix("BEGIN") || upper.hasPrefix("DECLARE")
        if !isPLSQL {
            while s.hasSuffix(";") {
                s.removeLast()
                s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return s
    }

    // MARK: - OCI helpers

    private func allocHandle(type: UInt32) throws -> OpaquePointer {
        var raw: UnsafeMutableRawPointer?
        let rc = OCIHandleAlloc(UnsafeRawPointer(env), &raw, type, 0, nil)
        guard rc == OCI_SUCCESS, let raw else {
            throw DBError.queryFailed("OCIHandleAlloc thất bại (type \(type))")
        }
        return OpaquePointer(raw)
    }

    private func freeHandle(_ h: OpaquePointer?, type: UInt32) {
        if let h { OCIHandleFree(UnsafeMutableRawPointer(h), type) }
    }

    private func setSessionString(_ value: String, attr: UInt32) throws {
        try value.withCString { c in
            let rc = OCIAttrSet(UnsafeMutableRawPointer(session), UInt32(OCI_HTYPE_SESSION),
                                UnsafeMutableRawPointer(mutating: c), UInt32(value.utf8.count), attr, err)
            try check(rc, context: "OCIAttrSet(\(attr))")
        }
    }

    /// Kiểm tra mã trả về; nếu lỗi, đọc message từ error handle.
    private func check(_ code: Int32, context: String) throws {
        if code == OCI_SUCCESS || code == OCI_SUCCESS_WITH_INFO { return }
        var errcode: Int32 = 0
        var msg = [UInt8](repeating: 0, count: 1024)
        OCIErrorGet(UnsafeMutableRawPointer(err), 1, nil, &errcode, &msg, 1024, UInt32(OCI_HTYPE_ERROR))
        let text = String(cString: msg).trimmingCharacters(in: .whitespacesAndNewlines)
        throw DBError.queryFailed("\(context): ORA-\(errcode) \(text)")
    }
}
#endif
