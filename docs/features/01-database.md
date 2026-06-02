# Tính năng 1 — Database Client (MySQL / Oracle / Redis)

## Mục tiêu
Kết nối MySQL, Oracle, Redis; thực hiện SELECT, xem cấu trúc bảng, chạy package/procedure — trải nghiệm giống SQL Developer / MySQL Workbench.

## Thư viện đề xuất

| DB | Thư viện | Ghi chú |
|----|----------|---------|
| MySQL | `MySQLNIO` / `MySQLKit` (swift-server) | Async, không cần client ngoài |
| Redis | `RediStack` (swift-server) | Dựa trên SwiftNIO, trưởng thành |
| Oracle | `OracleNIO` (community) **hoặc** Oracle Instant Client (OCI) qua C bridging | ⚠️ xem rủi ro |
| SQL editor UI | `CodeEditor` (SwiftUI) hoặc bọc `NSTextView` | Syntax highlight |

## Cách làm kỹ thuật

- **Lớp trừu tượng `DatabaseDriver`** (protocol chung): `connect / disconnect / query / fetchSchema / executeProcedure` → 3 DB dùng chung UI.
- **Xem cấu trúc bảng / source procedure-package** = truy vấn metadata:
  - MySQL: `INFORMATION_SCHEMA.*`, `SHOW CREATE TABLE`, `CALL proc(...)`
  - Oracle: `ALL_OBJECTS`, `ALL_TAB_COLUMNS`, `ALL_SOURCE` (xem source), `BEGIN pkg.proc(...); END;`
  - Redis: không có schema; hiển thị key-space, type, TTL.
- **Credential** lưu Keychain.
- **Sleep/wake:** áp dụng connection pool + health-check (xem ARCHITECTURE §3); query có timeout.

## Rủi ro & lưu ý
- **[Unverified]** Oracle không có driver Swift chính thức. `OracleNIO` (community) là hướng sạch nhưng cần đánh giá độ trưởng thành thực tế; phương án chắc chắn hơn = nhúng Instant Client (libOCI) hoặc ODBC (nặng hơn).
- Kết quả query lớn → cần phân trang / lazy load để giữ app nhẹ.

## Task

| ID | Task | Trạng thái | Ghi chú |
|----|------|-----------|---------|
| DB-01 | Định nghĩa protocol `DatabaseDriver` chung | ⬜ TODO | |
| DB-02 | Tích hợp MySQLNIO: connect + SELECT | ⬜ TODO | |
| DB-03 | MySQL: fetch schema (INFORMATION_SCHEMA), SHOW CREATE | ⬜ TODO | |
| DB-04 | MySQL: chạy procedure (`CALL`) | ⬜ TODO | |
| DB-05 | Tích hợp RediStack: connect + lệnh cơ bản + xem keyspace | ⬜ TODO | |
| DB-06 | Đánh giá & chọn driver Oracle (OracleNIO vs OCI vs ODBC) | 🔬 NEEDS_VERIFY | |
| DB-07 | Oracle: connect + SELECT | ⬜ TODO | phụ thuộc DB-06 |
| DB-08 | Oracle: xem ALL_SOURCE (package/procedure) + chạy proc | ⬜ TODO | phụ thuộc DB-06 |
| DB-09 | SQL editor UI (syntax highlight) + bảng kết quả phân trang | ⬜ TODO | |
| DB-10 | Lưu connection profile vào Keychain | ⬜ TODO | |
| DB-11 | Xử lý sleep/wake: pool health-check + reconnect | ⬜ TODO | |
