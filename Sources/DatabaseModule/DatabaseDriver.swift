import Foundation

// DB-01: Protocol chung cho mọi database driver (MySQL / Oracle / Redis).
// Mọi driver implement protocol này; UI dùng `DatabaseDriver` không biết chi tiết backend.

public enum DBError: Error, CustomStringConvertible {
    case notConnected
    case queryFailed(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .notConnected:          return "Chưa kết nối database."
        case .queryFailed(let msg):  return "Query thất bại: \(msg)"
        case .unsupported(let msg):  return "Không hỗ trợ: \(msg)"
        }
    }
}

/// Một hàng kết quả: map tên cột → giá trị string.
public typealias DBRow = [String: String?]

/// Kết quả của một câu query SELECT.
public struct DBResultSet: Sendable {
    public let columns: [String]
    public let rows: [DBRow]
    public init(columns: [String], rows: [DBRow]) {
        self.columns = columns; self.rows = rows
    }
}

/// Thông tin một object trong schema (bảng, view, procedure...).
public struct DBSchemaObject: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let type: String  // "TABLE", "VIEW", "PROCEDURE", "KEY", ...
    public let source: String?  // DDL / source text nếu có
    public init(id: String, name: String, type: String, source: String? = nil) {
        self.id = id; self.name = name; self.type = type; self.source = source
    }
}

/// Một nhóm object cố định trong cây schema (Tables, Views, Packages...) — như SQL Developer.
/// `objectType` dùng để lọc khi lazy-load (vd ALL_OBJECTS.OBJECT_TYPE với Oracle).
public struct SchemaCategory: Identifiable, Sendable, Hashable {
    public let id: String        // khóa duy nhất, vd "TABLE"
    public let title: String     // nhãn hiển thị, vd "Tables"
    public let objectType: String
    public init(id: String, title: String, objectType: String) {
        self.id = id; self.title = title; self.objectType = objectType
    }
}

/// Giao diện chung cho mọi database driver.
public protocol DatabaseDriver: AnyObject, Sendable {
    var dbType: DatabaseType { get }
    // isConnected được mỗi driver quản lý riêng (actor-isolated).
    // DatabaseState dùng flag riêng để track state UI.

    func connect() async throws
    func disconnect() async

    /// Chạy query SELECT; trả kết quả dạng bảng.
    func query(_ sql: String) async throws -> DBResultSet

    /// Đặt số dòng tối đa lấy về mỗi query (mặc định 250). Cấu hình từ UI.
    func setRowLimit(_ limit: Int) async

    /// Lấy source code đầy đủ của một object (package/procedure/function/view/trigger).
    func objectSource(_ object: DBSchemaObject) async throws -> String

    /// Danh sách nhóm cố định hiển thị ngay khi kết nối (không query).
    func schemaCategories() async -> [SchemaCategory]

    /// Lazy-load: lấy object của MỘT nhóm khi người dùng bung folder đó.
    func listObjects(_ category: SchemaCategory) async throws -> [DBSchemaObject]

    /// Chạy stored procedure / anonymous block.
    func execute(_ statement: String) async throws

    /// Health-check sau sleep/wake — reconnect nếu cần.
    func healthCheck() async
}
