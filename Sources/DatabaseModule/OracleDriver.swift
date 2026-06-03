import Foundation
import OracleNIO
import NIOCore
import NIOPosix
import Logging
import Core

// DB-06/07/08: Oracle driver qua OracleNIO 1.0.0-beta.3.

public actor OracleDriver: DatabaseDriver {
    public let dbType: DatabaseType = .oracle
    private var isConnected: Bool = false

    private let profile: ConnectionProfile
    private let password: String
    private var connection: OracleConnection?
    private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let logger = Logger(label: "com.macutil.oracle")

    public init(profile: ConnectionProfile, password: String) {
        self.profile = profile
        self.password = password
    }

    deinit { try? eventLoopGroup.syncShutdownGracefully() }

    public func connect() async throws {
        // Oracle "database" field = service name (vd: ORCLPDB1) hoặc SID.
        let config = OracleConnection.Configuration(
            host: profile.host,
            port: profile.port,
            service: .serviceName(profile.database),
            username: profile.username,
            password: password
        )
        do {
            let conn = try await OracleConnection.connect(
                on: eventLoopGroup.next(),
                configuration: config,
                id: 1,
                logger: logger
            )
            self.connection = conn
            self.isConnected = true
            Log.database.info("Oracle connected to \(self.profile.host, privacy: .public)")
        } catch let error as OracleSQLError where error.code == .serverVersionNotSupported {
            throw DBError.unsupported(
                "Oracle server quá cũ. Driver oracle-nio chỉ hỗ trợ Oracle 12.1 trở lên. "
                + "Server này dùng phiên bản cũ hơn (vd 11g/10g) — cần Oracle Instant Client (OCI) để kết nối."
            )
        }
    }

    public func disconnect() async {
        try? await connection?.close()
        connection = nil
        isConnected = false
    }

    public func query(_ sql: String) async throws -> DBResultSet {
        let conn = try requireConnection()
        let stream = try await conn.execute(OracleStatement(stringLiteral: sql), logger: logger)

        var columns: [String] = []
        var rows: [DBRow] = []
        for try await oracleRow in stream {
            let row = OracleRandomAccessRow(oracleRow)
            if columns.isEmpty {
                columns = row.map(\.columnName)
            }
            var dict: DBRow = [:]
            for cell in row {
                dict[cell.columnName] = cellToString(cell)
            }
            rows.append(dict)
        }
        return DBResultSet(columns: columns, rows: rows)
    }

    public func setRowLimit(_ limit: Int) {}  // oracle-nio không cap; DatabaseState truncate

    public func objectSource(_ object: DBSchemaObject) async throws -> String {
        let owner = profile.username.uppercased()
        let name = object.name
        let type = object.type.uppercased()
        if type == "VIEW" {
            let rs = try await query("SELECT TEXT FROM ALL_VIEWS WHERE OWNER='\(owner)' AND VIEW_NAME='\(name)'")
            let body = (rs.rows.first?["TEXT"] ?? nil) ?? ""
            return "CREATE OR REPLACE VIEW \(name) AS\n\(body);"
        }
        let rs = try await query(
            "SELECT TEXT FROM ALL_SOURCE WHERE OWNER='\(owner)' AND NAME='\(name)' AND TYPE='\(type)' ORDER BY LINE")
        let body = rs.rows.compactMap { ($0["TEXT"] ?? nil) }.joined()
        return body.isEmpty ? "-- Không lấy được source" : "CREATE OR REPLACE " + body.trimmingCharacters(in: .newlines) + "\n/"
    }

    public func schemaCategories() async -> [SchemaCategory] { OracleSchema.categories }

    /// Lazy-load object của một nhóm.
    public func listObjects(_ category: SchemaCategory) async throws -> [DBSchemaObject] {
        let conn = try requireConnection()
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
        let stream = try await conn.execute(OracleStatement(stringLiteral: sql), logger: logger)
        var objects: [DBSchemaObject] = []
        for try await oracleRow in stream {
            let row = OracleRandomAccessRow(oracleRow)
            let name = (try? row["NAME"].decode(String.self)) ?? ""
            guard !name.isEmpty else { continue }
            objects.append(DBSchemaObject(id: "\(category.id):\(name)", name: name, type: category.objectType))
        }
        return objects
    }

    /// DB-08: chạy PL/SQL block / DDL.
    public func execute(_ statement: String) async throws {
        let conn = try requireConnection()
        _ = try await conn.execute(OracleStatement(stringLiteral: statement), logger: logger)
    }

    public func healthCheck() async {
        guard isConnected else { return }
        do {
            _ = try await query("SELECT 1 FROM DUAL")
        } catch {
            Log.database.warning("Oracle health check failed: \(error, privacy: .public)")
            await disconnect()
            try? await connect()
        }
    }

    // MARK: - Helpers

    private func requireConnection() throws -> OracleConnection {
        guard let conn = connection, isConnected else { throw DBError.notConnected }
        return conn
    }

    /// Thử decode cell sang nhiều kiểu → chuỗi hiển thị (SQL client cần text).
    /// Lưu ý: `try?` trên `decode(T?.self)` flatten `T??` → `T?`, nên giá trị unwrap đã là `T`.
    private func cellToString(_ cell: OracleCell) -> String? {
        if let s = try? cell.decode(String?.self)  { return s }
        if let i = try? cell.decode(Int?.self)     { return String(i) }
        if let d = try? cell.decode(Double?.self)  { return String(d) }
        if let b = try? cell.decode(Bool?.self)    { return b ? "true" : "false" }
        return nil
    }
}
