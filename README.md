# MacUtil

Ứng dụng tiện ích cho **macOS** (Swift + SwiftUI): quản lý database, SSH, dọn dẹp hệ thống, giám sát & điều khiển phần cứng, đổi phím, và quản lý Git repo.

> ⚠️ **Code viết trên Windows, CHƯA build/kiểm thử.** Build trên Mac để xác minh — xem [docs/BUILD.md](docs/BUILD.md).

## Quick start (trên Mac)

```bash
swift build
swift run MacUtil
swift test
```

Yêu cầu: macOS 13+, Swift 5.9+ (Xcode 15+).

## Tính năng đã có code

- **Giám sát hệ thống** — CPU, RAM, tốc độ mạng (Mach/getifaddrs).
- **Dọn dẹp** — quét + dry-run + xoá file tạm có chọn lọc.
- **Đổi phím** — Command ↔ Shift qua `hidutil`, tùy chọn giữ sau reboot.
- **Git Manager** — quét repo local, liệt kê & merge MR/PR (GitLab + GitHub).

Chưa làm: Database, SSH, điều khiển quạt (cần package ngoài / privileged helper).

## Tài liệu

Toàn bộ tài liệu & bảng theo dõi task trong [docs/](docs/README.md):
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — kiến trúc, tech stack, module.
- [docs/TASKS.md](docs/TASKS.md) — bảng theo dõi 68 task theo trạng thái.
- [docs/features/](docs/) — chi tiết từng tính năng.
