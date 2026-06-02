# Tính năng 3 — Temp Cleaner (dọn file tạm macOS)

## Mục tiêu
Quét và dọn các file tạm/cache để giải phóng dung lượng, an toàn.

## Thư viện / API
- `FileManager` (Foundation) — đủ, không cần thư viện ngoài.

## Các đường dẫn tạm phổ biến
- `NSTemporaryDirectory()`
- `~/Library/Caches/`
- `/private/var/folders/...` (cache hệ thống của user)
- Log cũ: `~/Library/Logs/`
- Cache theo app cụ thể (cấu hình danh sách target)

## Cách làm kỹ thuật
- **Scanner**: duyệt các target → tính dung lượng, gom theo nhóm.
- **Quan trọng — an toàn:** luôn **liệt kê + cho người dùng xem trước và chọn** mục muốn xóa; không xóa mù. Có "dry run".
- Xóa qua `FileManager.removeItem`; mục cần quyền cao → bỏ qua + báo rõ.
- Hiển thị tổng dung lượng giải phóng được.

## Rủi ro & lưu ý
- ⚠️ Một số path cần **Full Disk Access** (người dùng cấp trong System Settings → Privacy). Phát hiện thiếu quyền → hướng dẫn cấp.
- ⚠️ Không đụng vào thư mục hệ thống quan trọng; whitelist target rõ ràng thay vì quét bừa.
- **[Inference]** Xóa cache khi app khác đang chạy có thể gây lỗi tạm cho app đó → khuyến nghị đóng app liên quan.

## Task

| ID | Task | Trạng thái | Ghi chú |
|----|------|-----------|---------|
| CLN-01 | Định nghĩa danh sách target (whitelist) | ⬜ TODO | |
| CLN-02 | Scanner: duyệt + tính dung lượng theo nhóm | ⬜ TODO | |
| CLN-03 | UI xem trước + chọn mục (checkbox) | ⬜ TODO | |
| CLN-04 | Thực hiện xóa an toàn + báo dung lượng giải phóng | ⬜ TODO | |
| CLN-05 | Phát hiện thiếu Full Disk Access + hướng dẫn cấp | ⬜ TODO | |
| CLN-06 | Chế độ dry-run | ⬜ TODO | |
