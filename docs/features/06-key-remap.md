# Tính năng 6 — Key Remap (đổi phím Command ↔ Shift)

## Mục tiêu
Đổi phím modifier, ví dụ Command → Shift và Shift → Command. Giữ hiệu lực sau reboot.

## Cách làm kỹ thuật — 2 phương án

### Phương án A (khuyến nghị): `hidutil`
- Dùng IOKit HID key remapping qua `hidutil`. **Nhẹ nhất**, không cần intercept event, không cần quyền Accessibility.
- Mã usage (HID):
  - Left Command = `0x7000000E3`, Right Command = `0x7000000E7`
  - Left Shift = `0x7000000E1`, Right Shift = `0x7000000E5`
- Lệnh đổi (ví dụ): `hidutil property --set '{"UserKeyMapping":[...]}'`
- **Giữ sau reboot:** tạo **LaunchAgent** chạy lệnh khi đăng nhập (vì `hidutil --set` chỉ áp dụng cho phiên hiện tại).

### Phương án B: `CGEventTap`
- Bắt event bàn phím và ghi lại modifier → linh hoạt hơn (vd remap có điều kiện) nhưng **cần quyền Accessibility** và nặng hơn.
- Chỉ dùng nếu cần logic phức tạp ngoài tầm hidutil.

## Rủi ro & lưu ý
- Cần nút **"Khôi phục mặc định"** (xóa UserKeyMapping) — tránh người dùng kẹt phím.
- **[Inference]** Đổi modifier có thể ảnh hưởng shortcut hệ thống → cảnh báo người dùng trước khi áp dụng.
- Quản lý LaunchAgent: tạo/xóa `~/Library/LaunchAgents/<id>.plist`.

## Task

| ID | Task | Trạng thái | Ghi chú |
|----|------|-----------|---------|
| KEY-01 | Hàm áp dụng remap qua hidutil (Command ↔ Shift) | 🟦 IN_PROGRESS | `KeyRemapper.swapCommandShift()` |
| KEY-02 | Nút khôi phục mặc định (clear mapping) | 🟦 IN_PROGRESS | `KeyRemapper.reset()` |
| KEY-03 | Tạo/xóa LaunchAgent để giữ sau reboot | 🟦 IN_PROGRESS | `LoginPersistence` |
| KEY-04 | UI chọn cặp phím remap (mở rộng ngoài Cmd/Shift) | 🟦 IN_PROGRESS | `KeyRemapView` custom section; 10 HIDKey |
| KEY-05 | (Tùy chọn) Phương án CGEventTap cho remap nâng cao | ⬜ TODO | cần Accessibility |
