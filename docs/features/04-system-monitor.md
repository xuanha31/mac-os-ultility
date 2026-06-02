# Tính năng 4 — System Monitor (CPU / RAM / quạt / mạng)

## Mục tiêu
Hiển thị realtime: CPU load, RAM, tốc độ quạt, tốc độ mạng (up/down).

## API / thư viện

| Chỉ số | Cách lấy | Thư viện |
|--------|----------|----------|
| CPU load | `host_statistics64` (Mach) | Mach API trực tiếp |
| RAM | `host_statistics` + `vm_statistics64`; per-process `task_info` | Mach API |
| Tốc độ mạng | `getifaddrs` đọc counter byte → tính delta theo thời gian | Foundation/C |
| Tốc độ quạt (đọc) | SMC qua IOKit (`AppleSMC`, key `F0Ac`...) | `SMCKit` (beltex) hoặc tự bọc IOKit |

Tham khảo mã nguồn mở SMC: `SMCKit`, `osx-cpu-temp`, `iStats`, `smcFanControl`.

## Cách làm kỹ thuật
- Module `MonitorModule` chạy timer (`DispatchSourceTimer`) chu kỳ ~1s, đẩy giá trị qua publisher (Combine) cho UI.
- Tốc độ mạng = (bytes_now − bytes_prev) / Δt cho từng interface.
- Đọc quạt qua SMC — chỉ ĐỌC (điều khiển nằm ở tính năng 5).

## Rủi ro & lưu ý
- **[Unverified]** Đọc SMC trên **Apple Silicon** khác key và hạn chế hơn Intel; `SMCKit` chủ yếu được biết chạy tốt trên Intel → cần kiểm chứng trên chip M. Thiết kế: nếu không đọc được quạt → ẩn widget quạt thay vì crash.
- **Sleep/wake:** dừng timer khi sleep, resume khi wake (xem ARCHITECTURE §3) — tránh tích lũy tick gây giật.
- Giữ tần suất cập nhật hợp lý để app nhẹ (đừng đọc SMC quá dày).

## Task

| ID | Task | Trạng thái | Ghi chú |
|----|------|-----------|---------|
| MON-01 | Đọc CPU load qua Mach | ⬜ TODO | |
| MON-02 | Đọc RAM (tổng/đã dùng) qua Mach | ⬜ TODO | |
| MON-03 | Tốc độ mạng up/down qua getifaddrs (delta) | ⬜ TODO | |
| MON-04 | Tích hợp SMCKit / IOKit: đọc tốc độ quạt | 🔬 NEEDS_VERIFY | kiểm chứng Intel trước |
| MON-05 | Đọc nhiệt độ CPU (bonus, cùng SMC) | ⬜ TODO | |
| MON-06 | Timer + publisher (Combine) đẩy realtime cho UI | ⬜ TODO | |
| MON-07 | UI dashboard (biểu đồ/widget) | ⬜ TODO | |
| MON-08 | Fallback ẩn widget quạt nếu không đọc được (Apple Silicon) | 🔬 NEEDS_VERIFY | |
| MON-09 | Xử lý sleep/wake cho timer | ⬜ TODO | |
