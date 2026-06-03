import Foundation
import RediStack
import NIOPosix
import NIOCore
import Core

// DB-05: Redis driver qua RediStack.

public actor RedisDriver: DatabaseDriver {
    public let dbType: DatabaseType = .redis
    private var connection: RedisConnection?
    private let profile: ConnectionProfile
    private let password: String
    private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    public init(profile: ConnectionProfile, password: String) {
        self.profile = profile
        self.password = password
    }

    deinit { try? eventLoopGroup.syncShutdownGracefully() }

    public func connect() async throws {
        let dbIndex = Int(profile.database)
        let config = try RedisConnection.Configuration(
            hostname: profile.host,
            port: profile.port,
            password: password.isEmpty ? nil : password,
            initialDatabase: dbIndex
        )
        let conn = try await RedisConnection.make(
            configuration: config,
            boundEventLoop: eventLoopGroup.next()
        ).get()
        self.connection = conn
        Log.database.info("Redis connected to \(self.profile.host, privacy: .public)")
    }

    public func disconnect() async {
        _ = try? await connection?.close().get()
        connection = nil
    }

    /// Chạy lệnh Redis thô (vd: "SET foo bar" / "GET foo").
    public func query(_ command: String) async throws -> DBResultSet {
        let parts = command.split(separator: " ").map(String.init)
        guard !parts.isEmpty else { return DBResultSet(columns: ["result"], rows: []) }
        let cmd = parts[0].uppercased()
        let args: [RESPValue] = parts.dropFirst().map { .bulkString(ByteBuffer(string: $0)) }
        let resp = try await send(command: cmd, arguments: args)
        return DBResultSet(columns: ["result"], rows: [["result": respToString(resp)]])
    }

    public func setRowLimit(_ limit: Int) {}
    public func objectSource(_ object: DBSchemaObject) async throws -> String {
        "GET \(object.name)"
    }

    public func schemaCategories() async -> [SchemaCategory] { RedisSchema.categories }

    /// DB-05: Keyspace browser — KEYS * + TYPE + TTL per key.
    public func listObjects(_ category: SchemaCategory) async throws -> [DBSchemaObject] {
        let keysResp = try await send(command: "KEYS", arguments: [.bulkString(ByteBuffer(string: "*"))])
        guard case .array(let arr) = keysResp else { return [] }
        let keys: [String] = arr.compactMap {
            if case .bulkString(let buf) = $0, let b = buf {
                return String(buffer: b)
            }
            return nil
        }
        var objects: [DBSchemaObject] = []
        for key in keys.prefix(200) {
            let typeResp = try? await send(command: "TYPE", arguments: [.bulkString(ByteBuffer(string: key))])
            let ttlResp  = try? await send(command: "TTL",  arguments: [.bulkString(ByteBuffer(string: key))])
            let typeStr: String
            if case .simpleString(var buf) = typeResp { typeStr = String(buffer: buf) }
            else { typeStr = "unknown" }
            let ttl: Int = (ttlResp.flatMap { if case .integer(let i) = $0 { return i } else { return nil } }) ?? -1
            let ttlLabel = ttl < 0 ? "no expire" : "\(ttl)s"
            objects.append(DBSchemaObject(id: key, name: key, type: typeStr.uppercased(),
                                          source: "TYPE: \(typeStr)  TTL: \(ttlLabel)"))
        }
        return objects
    }

    public func execute(_ statement: String) async throws {
        _ = try await query(statement)
    }

    public func healthCheck() async {
        guard connection != nil else { return }
        do {
            _ = try await send(command: "PING", arguments: [])
        } catch {
            Log.database.warning("Redis health check failed: \(error, privacy: .public)")
            await disconnect()
            try? await connect()
        }
    }

    // MARK: - Internal helper

    private func send(command: String, arguments: [RESPValue]) async throws -> RESPValue {
        guard let conn = connection else { throw DBError.notConnected }
        return try await conn.send(command: command, with: arguments).get()
    }

    private func respToString(_ v: RESPValue) -> String? {
        switch v {
        case .simpleString(var b): return String(buffer: b)
        case .bulkString(let b):
            guard var buf = b else { return nil }
            return String(buffer: buf)
        case .integer(let i):     return String(i)
        case .error(let e):       return e.message
        case .array(let arr):     return arr.map { respToString($0) ?? "nil" }.joined(separator: "\n")
        case .null:               return nil
        }
    }
}
