import Foundation

// #2: Chạy procedure/function với tham số (Oracle).

public struct ProcArg: Identifiable, Sendable, Hashable {
    public let id: Int          // POSITION
    public let name: String     // ARGUMENT_NAME ("" = return value của function)
    public let inOut: String    // IN / OUT / IN/OUT
    public let dataType: String
    public var isIn: Bool { inOut.uppercased().contains("IN") }
    public var isOut: Bool { inOut.uppercased().contains("OUT") }
}

enum ProcedureCall {
    /// Sinh literal đúng kiểu cho tham số IN.
    static func literal(_ value: String, type: String) -> String {
        if value.isEmpty { return "NULL" }
        let t = type.uppercased()
        if t.contains("CHAR") || t.contains("CLOB") || t.contains("RAW") {
            return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        }
        if t.contains("DATE") || t.contains("TIMESTAMP") {
            return "TO_DATE('\(value.replacingOccurrences(of: "'", with: "''"))','YYYY-MM-DD HH24:MI:SS')"
        }
        // NUMBER/INTEGER/FLOAT… để nguyên (số). Nếu người dùng gõ chữ, Oracle sẽ báo lỗi rõ.
        return value
    }

    /// Tạo câu lệnh chạy. `values`: tên arg → giá trị (chỉ IN).
    /// - Function không OUT  → SELECT name(args) FROM DUAL (hiện kết quả ở grid).
    /// - Còn lại            → anonymous PL/SQL block.
    static func build(object name: String, isFunction: Bool, args: [ProcArg],
                      values: [String: String]) -> (sql: String, isSelect: Bool) {
        let inArgs = args.filter { $0.id >= 1 }   // bỏ return (position 0)
        let hasOut = inArgs.contains { $0.isOut }

        // Danh sách biểu thức tham số theo thứ tự POSITION.
        func argExpr(_ a: ProcArg) -> String {
            if a.isOut && !a.isIn { return "v_out_\(a.id)" }      // OUT → biến
            return literal(values[a.name] ?? "", type: a.dataType)
        }
        let argList = inArgs.sorted { $0.id < $1.id }.map(argExpr).joined(separator: ", ")
        let callExpr = argList.isEmpty ? name : "\(name)(\(argList))"

        if isFunction && !hasOut {
            return ("SELECT \(callExpr) AS RESULT FROM DUAL", true)
        }

        // Anonymous block (procedure, hoặc có OUT).
        var decls: [String] = []
        var outLogs: [String] = []
        for a in inArgs where a.isOut {
            decls.append("  v_out_\(a.id) \(plsqlType(a.dataType));")
            outLogs.append("  DBMS_OUTPUT.PUT_LINE('\(a.name) = ' || v_out_\(a.id));")
        }
        var block = "DECLARE\n"
        if isFunction { block += "  v_result \(plsqlType(args.first { $0.id == 0 }?.dataType ?? "VARCHAR2"));\n" }
        block += decls.joined(separator: "\n")
        block += "\nBEGIN\n"
        if isFunction { block += "  v_result := \(callExpr);\n  DBMS_OUTPUT.PUT_LINE('RESULT = ' || v_result);\n" }
        else { block += "  \(callExpr);\n" }
        block += outLogs.joined(separator: "\n")
        block += "\nEND;"
        return (block, false)
    }

    /// Map kiểu Oracle → khai báo biến PL/SQL đơn giản.
    private static func plsqlType(_ type: String) -> String {
        let t = type.uppercased()
        if t.contains("NUMBER") || t.contains("INTEGER") || t.contains("FLOAT") { return "NUMBER" }
        if t.contains("DATE") || t.contains("TIMESTAMP") { return "DATE" }
        return "VARCHAR2(4000)"
    }
}
