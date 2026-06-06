# MacUtil

Ứng dụng tiện ích cho **macOS** (Swift + SwiftUI): giám sát hệ thống, dọn dẹp, đổi phím, quản lý database, SSH terminal, quản lý Git repo, điều khiển quạt và clipboard/screenshot.

> ⚠️ **Code viết trên Windows, cần build/kiểm thử trên Mac để xác minh** — xem [docs/BUILD.md](docs/BUILD.md).

## Quick start (trên Mac)

```bash
./run-app.sh        # build + chạy app (giữ được keyboard focus)
swift build         # chỉ build
swift test          # chạy test
```

> Dùng `./run-app.sh` thay vì `swift run MacUtil` để app nhận đúng keyboard focus.

### Cài vào /Applications

`run-app.sh` đóng gói `.app` vào `.build/MacUtil.app`. Để cài vào Launchpad/Applications:

```bash
cp -R /Users/hanx/Desktop/Data/MyProject/MacOS/mac-os-ultility/.build/MacUtil.app /Applications/
```

Yêu cầu: macOS 14+, Swift 5.9+ (Xcode 15+).

## Tính năng

- **Giám sát hệ thống** — CPU, RAM, tốc độ mạng, đọc cảm biến qua SMC; biểu đồ realtime (Swift Charts).
- **Dọn dẹp** — quét file tạm + dry-run + xoá có chọn lọc; quét dung lượng đĩa (disk scan).
- **Đổi phím** — Command ↔ Shift qua `hidutil`, tùy chọn giữ sau reboot.
- **Database** — kết nối & truy vấn MySQL, Redis, Oracle (NIO + tùy chọn OCI cho Oracle cũ); duyệt schema, chạy procedure, sửa bảng đơn.
- **SSH** — quản lý profile, terminal tương tác (Citadel + SwiftTerm).
- **Git Manager** — quét repo local, liệt kê & merge MR/PR (GitLab + GitHub).
- **Quạt** — đọc & điều khiển tốc độ quạt qua SMC.
- **Clipboard** — lịch sử clipboard + chụp màn hình (screenshot).

## Module

| Module | Mô tả |
|---|---|
| `Core` | Keychain, logging, login item, điều phối sleep/wake |
| `MonitorModule` | Mach stats, SMC reader, system metrics |
| `CleanerModule` | Disk scanner, temp cleaner |
| `KeyRemapModule` | Remap phím, persistence sau reboot |
| `DatabaseModule` | Driver MySQL/Redis/Oracle (+OCI), schema, procedure |
| `SSHModule` | Profile, session SSH/terminal |
| `GitManagerModule` | Quét repo, provider GitHub/GitLab, correlator |
| `FanControlModule` | Đọc/điều khiển quạt |
| `ClipboardModule` | Theo dõi clipboard, chụp màn hình |

## Tài liệu

Toàn bộ tài liệu & bảng theo dõi task trong [docs/](docs/README.md):
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — kiến trúc, tech stack, module.
- [docs/BUILD.md](docs/BUILD.md) — hướng dẫn build trên Mac.
- [docs/TASKS.md](docs/TASKS.md) — bảng theo dõi task theo trạng thái.
- [docs/ORACLE-OCI-SETUP.md](docs/ORACLE-OCI-SETUP.md) — cài Oracle Instant Client cho OCI.
- [docs/features/](docs/) — chi tiết từng tính năng.
