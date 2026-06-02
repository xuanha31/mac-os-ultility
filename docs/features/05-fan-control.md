# Tính năng 5 — Fan Control (điều khiển tốc độ quạt) ⚠️

> **Đây là tính năng RỦI RO NHẤT.** Sai có thể gây quá nhiệt phần cứng.

## Mục tiêu
Cho phép chỉnh tốc độ quay quạt (manual) và reset về chế độ auto.

## Cách làm kỹ thuật
- Ghi **SMC key** điều khiển quạt:
  - `F0Tg` = target speed của quạt 0
  - bit `FS! ` = ép chế độ manual (bỏ ép = trả về auto)
- Mã tham khảo chuẩn: **`smcFanControl`** (open source).
- Ghi SMC **cần quyền root** → phải có **privileged helper tool**, đăng ký qua **`SMAppService`** (API hiện đại thay cho `SMJobBless`). Helper nằm trong module `SystemControl/PrivilegedHelper`.
- **Lớp HAL (Hardware Abstraction Layer)**: `FanController` protocol với fallback — nếu không ghi được thì disable UI điều khiển + báo người dùng.

## Rủi ro & lưu ý — ĐỌC KỸ
- ⚠️ **An toàn nhiệt:** luôn ép giới hạn `min`/`max` theo dải quạt báo từ SMC; có nút **"Reset về Auto"** rõ ràng; tự động trả auto khi app thoát/crash.
- **[Inference / Unverified] Apple Silicon (chip M):** điều khiển quạt qua SMC bị hạn chế/khác key, **có thể không hoạt động**. KHÔNG đảm bảo. Phải kiểm chứng thực tế từng đời chip; nếu fail → disable tính năng cho máy đó.
- MacBook Air (Intel/AS) **không có quạt** → ẩn tính năng.
- Phụ thuộc: privileged helper hoạt động + app được ký (code signing) để helper được tin cậy.

## Task

| ID | Task | Trạng thái | Ghi chú |
|----|------|-----------|---------|
| FAN-01 | Định nghĩa protocol `FanController` (HAL) + fallback | ⬜ TODO | |
| FAN-02 | Tạo privileged helper + đăng ký qua SMAppService | ⬜ TODO | phụ thuộc code signing |
| FAN-03 | Ghi SMC `F0Tg` + bit `FS!` (Intel) | 🔬 NEEDS_VERIFY | kiểm chứng trên Mac Intel |
| FAN-04 | Cơ chế giới hạn min/max + nút Reset Auto | ⬜ TODO | bắt buộc vì an toàn |
| FAN-05 | Tự trả Auto khi app thoát/crash | ⬜ TODO | |
| FAN-06 | Phát hiện MacBook Air (không quạt) → ẩn | ⬜ TODO | |
| FAN-07 | Kiểm chứng trên Apple Silicon → disable nếu fail | 🔬 NEEDS_VERIFY | |
| FAN-08 | UI điều khiển (slider + chế độ auto/manual) | ⬜ TODO | |
