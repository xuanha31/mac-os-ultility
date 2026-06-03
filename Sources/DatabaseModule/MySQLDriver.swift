import Foundation
import MySQLNIO
import NIOPosix
import Core

// DB-02 / DB-03 / DB-04: MySQL driver qua MySQLNIO.

public actor MySQLDriver: DatabaseDriver {
    public let dbType: DatabaseType = .mysql
    private var isConnected: Bool = false

    private let profile: ConnectionProfile
    private let password: String
    private var connection: MySQLConnection?
    private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    public init(profile: ConnectionProfile, password: String) {
        self.profile = profile
        self.password = password
    }

    deinit { try? eventLoopGroup.syncShutdownGracefully() }

    // MARK: - DatabaseDriver

    public func connect() async throws {
        let addr = try SocketAddress.makeAddressResolvingHost(profile.host, port: profile.port)
        let conn = try await MySQLConnection.connect(
            to: addr,
            username: profile.username,
            database: profile.database,
            password: password,
            tlsConfiguration: .makeClientConfiguration(),
            on: eventLoopGroup.next()
        ).get()
        self.connection = conn
        self.isConnected = true
        Log.database.info("MySQL connected to \(self.profile.host, privacy: .public)")
    }

    public func disconnect() async {
        try? await connection?.close().get()
        connection = nil
        isConnected = false
    }

    public func query(_ sql: String) async throws -> DBResultSet {
        let conn = try requireConnection()
        let rows = try await conn.query(sql).get()
        guard let first = rows.first else { return DBResultSet(columns: [], rows: []) }
        let cols = first.columnDefinitions.map { $0.name }
        let mapped: [DBRow] = rows.map { row in
            var dict: DBRow = [:]
            for col in row.columnDefinitions {
                dict[col.name] = (try? row.column(col.name)?.string) ?? nil
            }
            return dict
        }
        return DBResultSet(columns: cols, rows: mapped)
    }

    public func setRowLimit(_ limit: Int) {}  // DatabaseState truncate

    public func objectSource(_ object: DBSchemaObject) async throws -> String {
        let kw: String
        switch object.type.uppercased() {
        case "VIEW":      kw = "VIEW"
        case "PROCEDURE": kw = "PROCEDURE"
        case "FUNCTION":  kw = "FUNCTION"
        default:          kw = "TABLE"
        }
        let rs = try await query("SHOW CREATE \(kw) `\(object.name)`")
        // SHOW CREATE trả cột thứ 2 là DDL
        if let row = rs.rows.first, let ddl = row.values.compactMap({ $0 }).last {
            return ddl
        }
        return "-- Không lấy được source"
    }

    public func schemaCategories() async -> [SchemaCategory] { MySQLSchema.categories }

    /// DB-03: Lazy-load object một nhóm qua INFORMATION_SCHEMA.
    public func listObjects(_ category: SchemaCategory) async throws -> [DBSchemaObject] {
        let conn = try requireConnection()
        let db = profile.database
        let sql: String
        switch category.id {
        case "TABLE", "VIEW":
            sql = """
                SELECT TABLE_NAME AS NAME FROM INFORMATION_SCHEMA.TABLES
                WHERE TABLE_SCHEMA = '\(db)' AND TABLE_TYPE = '\(category.objectType)'
                ORDER BY TABLE_NAME
                """
        default: // PROCEDURE / FUNCTION
            sql = """
                SELECT ROUTINE_NAME AS NAME FROM INFORMATION_SCHEMA.ROUTINES
                WHERE ROUTINE_SCHEMA = '\(db)' AND ROUTINE_TYPE = '\(category.objectType)'
                ORDER BY ROUTINE_NAME
                """
        }
        let rows = try await conn.query(sql).get()
        return rows.compactMap { row in
            guard let name = try? row.column("NAME")?.string, !name.isEmpty else { return nil }
            return DBSchemaObject(id: "\(category.id):\(name)", name: name, type: category.objectType)
        }
    }

    /// DB-04: Chạy stored procedure.
    public func execute(_ statement: String) async throws {
        let conn = try requireConnection()
        try await conn.simpleQuery(statement).get()
    }

    /// DB-11: Health check sau sleep/wake.
    public func healthCheck() async {
        guard isConnected else { return }
        do {
            let conn = try requireConnection()
            _ = try await conn.query("SELECT 1").get()
        } catch {
            Log.database.warning("MySQL health check failed, reconnecting: \(error, privacy: .public)")
            await disconnect()
            try? await connect()
        }
    }

    private func requireConnection() throws -> MySQLConnection {
        guard let conn = connection, isConnected else { throw DBError.notConnected }
        return conn
    }
}
