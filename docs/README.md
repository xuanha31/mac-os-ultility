# MacUtil — Tài liệu dự án

> Ứng dụng tiện ích cho macOS: quản lý database, SSH, dọn dẹp hệ thống, giám sát & điều khiển phần cứng, đổi phím, và quản lý Git repo.
>
> **Tên app: `MacUtil`** (đã chốt).

## Mục tiêu tổng thể

- **Nhẹ** (ưu tiên native Swift/SwiftUI, không dùng Electron).
- **Không treo sau khi macbook sleep → wake**.
- Hỗ trợ **Mac Intel trước**, **Apple Silicon (chip M) sau**.

## Trạng thái code hiện tại

> ⚠️ **[Unverified] Code được viết trên Windows → CHƯA biên dịch/kiểm thử.** Bắt buộc build trên Mac (xem [BUILD.md](./BUILD.md)). Task đã viết code đánh dấu 🟦 trong [TASKS.md](./TASKS.md); chỉ chuyển ✅ sau khi build & chạy thật thành công.

| Increment | Nội dung | Phụ thuộc ngoài | Trạng thái |
|-----------|----------|-----------------|------------|
| 1 | Core (Keychain/Logger/SleepWake) + Monitor (CPU/RAM/mạng) + Cleaner + KeyRemap + app shell | Không | 🟦 code xong |
| 2 | Git Manager (local scan + GitLab/GitHub list & merge MR/PR) | Không (`git` CLI + `URLSession`) | 🟦 code xong |
| 3+ | Database (MySQL/Redis/Oracle), SSH, Fan control | Có (package ngoài / privileged helper) | ⬜ chưa làm |

Cấu trúc nguồn: `Sources/{Core,MonitorModule,CleanerModule,KeyRemapModule,GitManagerModule,MacUtil}`, test ở `Tests/MacUtilTests`.

## Mục lục tài liệu

| Tài liệu | Nội dung |
|----------|----------|
| [ARCHITECTURE.md](./ARCHITECTURE.md) | Kiến trúc tổng thể, tech stack, danh sách module, vấn đề chung (sleep/wake, quyền, phân phối) |
| [BUILD.md](./BUILD.md) | **Cách build & chạy** trên Mac (`swift build` / `swift run` / `swift test`) |
| [TASKS.md](./TASKS.md) | **Bảng theo dõi task tổng** theo milestone — theo dõi tiến độ khi code |
| [features/01-database.md](./features/01-database.md) | Kết nối MySQL / Oracle / Redis, SQL editor, xem cấu trúc, chạy procedure/package |
| [features/02-ssh-manager.md](./features/02-ssh-manager.md) | Quản lý SSH session (như MobaXterm) |
| [features/03-temp-cleaner.md](./features/03-temp-cleaner.md) | Dọn dẹp file tạm của macOS |
| [features/04-system-monitor.md](./features/04-system-monitor.md) | Giám sát CPU / RAM / tốc độ quạt / tốc độ mạng |
| [features/05-fan-control.md](./features/05-fan-control.md) | Điều khiển tốc độ quạt (⚠️ rủi ro) |
| [features/06-key-remap.md](./features/06-key-remap.md) | Đổi phím (Command ↔ Shift) |
| [features/07-git-manager.md](./features/07-git-manager.md) | Quản lý Git repo, auto-scan, merge MR/PR (GitLab + GitHub) |

## Quy ước trạng thái task

Mỗi task có một ID (vd `DB-01`) và một trạng thái. Dùng các icon sau trong toàn bộ tài liệu để dễ theo dõi khi code:

| Icon | Trạng thái | Ý nghĩa |
|------|------------|---------|
| ⬜ | `TODO` | Chưa bắt đầu |
| 🟦 | `IN_PROGRESS` | Đang làm |
| ✅ | `DONE` | Hoàn thành |
| ⛔ | `BLOCKED` | Bị chặn (ghi rõ lý do/phụ thuộc) |
| 🔬 | `NEEDS_VERIFY` | Cần kiểm chứng thực tế trên máy đích trước khi chốt |

**Quy ước cập nhật:** khi code, đổi icon ở cột Trạng thái trong file feature tương ứng **và** trong [TASKS.md](./TASKS.md). Ghi số commit/PR vào cột Ghi chú nếu cần.

## Quy ước nhãn độ tin cậy (theo reality filter)

Trong tài liệu, các nhận định chưa kiểm chứng được gắn nhãn:
- `[Inference]` — suy luận từ pattern đã biết.
- `[Unverified]` — chưa xác minh, cần kiểm chứng thực tế.
