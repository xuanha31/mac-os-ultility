import Foundation

// Phát hiện SELECT bảng đơn (FROM chỉ 1 bảng, không JOIN) để cho phép sửa trực tiếp grid qua ROWID.

public enum SingleTableEdit {
    public static let rowidColumn = "MACUTIL_ROWID"

    public struct Info: Sendable {
        public let table: String   // tên bảng (có thể schema.table)
        public let ref: String     // alias nếu có, nếu không thì = table
    }

    /// Trả về Info nếu query là `SELECT * FROM <bảng> [alias] [WHERE/ORDER...]` đơn giản.
    public static func detect(_ sql: String) -> Info? {
        var s = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix(";") { s.removeLast(); s = s.trimmingCharacters(in: .whitespaces) }
        let lower = s.lowercased()
        guard lower.hasPrefix("select ") else { return nil }
        // Loại các trường hợp phức tạp (không sửa được an toàn).
        for kw in [" join ", " group by ", " distinct ", " union ", " minus ", "("] {
            if lower.contains(kw) { return nil }
        }
        guard let fromR = lower.range(of: " from ") else { return nil }
        // Select-list phải là "*" (xem toàn bộ bảng).
        let selectList = s[s.index(s.startIndex, offsetBy: 7)..<fromR.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        guard selectList == "*" else { return nil }

        let after = String(s[fromR.upperBound...]).trimmingCharacters(in: .whitespaces)
        let tokens = after.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        guard let table = tokens.first, !table.contains(",") else { return nil }

        let stop: Set<String> = ["where", "order", "group", "fetch", "start", "connect", "having", "union", "minus"]
        var ref = table
        if tokens.count >= 2 {
            let t1 = tokens[1].lowercased()
            if !stop.contains(t1) { ref = tokens[1] }   // có alias
        }
        return Info(table: table, ref: ref)
    }

    /// Chèn ROWID vào query để grid biết khóa từng dòng.
    /// `SELECT * FROM t ...` → `SELECT t.ROWID AS "MACUTIL_ROWID", t.* FROM t ...`
    public static func injectRowID(_ sql: String, info: Info) -> String {
        var s = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix(";") { s.removeLast(); s = s.trimmingCharacters(in: .whitespaces) }
        guard let fromR = s.lowercased().range(of: " from ") else { return sql }
        let fromPart = String(s[fromR.lowerBound...])   // " from t ..."
        return "SELECT \(info.ref).ROWID AS \"\(rowidColumn)\", \(info.ref).*\(fromPart)"
    }

    /// Escape giá trị thành SQL literal. nil/"" → NULL.
    public static func literal(_ value: String?) -> String {
        guard let v = value, !v.isEmpty else { return "NULL" }
        return "'" + v.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
