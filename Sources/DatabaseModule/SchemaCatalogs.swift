import Foundation

// Danh sách nhóm cố định cho cây schema (giống SQL Developer).
// Hiện ngay khi kết nối; lazy-load object khi bung từng folder.

enum OracleSchema {
    static let categories: [SchemaCategory] = [
        .init(id: "TABLE",             title: "Tables",             objectType: "TABLE"),
        .init(id: "VIEW",              title: "Views",              objectType: "VIEW"),
        .init(id: "INDEX",             title: "Indexes",            objectType: "INDEX"),
        .init(id: "PACKAGE",           title: "Packages",           objectType: "PACKAGE"),
        .init(id: "PROCEDURE",         title: "Procedures",         objectType: "PROCEDURE"),
        .init(id: "FUNCTION",          title: "Functions",          objectType: "FUNCTION"),
        .init(id: "TRIGGER",           title: "Triggers",           objectType: "TRIGGER"),
        .init(id: "TYPE",              title: "Types",              objectType: "TYPE"),
        .init(id: "SEQUENCE",          title: "Sequences",          objectType: "SEQUENCE"),
        .init(id: "MATERIALIZED VIEW", title: "Materialized Views", objectType: "MATERIALIZED VIEW"),
        .init(id: "SYNONYM",           title: "Synonyms",           objectType: "SYNONYM"),
        .init(id: "DATABASE LINK",     title: "Database Links",     objectType: "DATABASE LINK"),
        .init(id: "JAVA CLASS",        title: "Java",               objectType: "JAVA CLASS"),
        .init(id: "DIRECTORY",         title: "Directories",        objectType: "DIRECTORY"),
    ]
}

enum MySQLSchema {
    static let categories: [SchemaCategory] = [
        .init(id: "TABLE",     title: "Tables",     objectType: "BASE TABLE"),
        .init(id: "VIEW",      title: "Views",      objectType: "VIEW"),
        .init(id: "PROCEDURE", title: "Procedures", objectType: "PROCEDURE"),
        .init(id: "FUNCTION",  title: "Functions",  objectType: "FUNCTION"),
    ]
}

enum RedisSchema {
    static let categories: [SchemaCategory] = [
        .init(id: "KEY", title: "Keys", objectType: "KEY"),
    ]
}
