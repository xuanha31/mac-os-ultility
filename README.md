# MacUtil

Ứng dụng tiện ích cho **macOS** (Swift + SwiftUI): giám sát hệ thống, dọn dẹp, đổi phím, quản lý database, SSH terminal, quản lý Git repo, điều khiển quạt, clipboard/screenshot, điều khiển từ xa (VNC/RDP) và quản lý nguồn/pin.

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

- **Giám sát hệ thống** — CPU, RAM, tốc độ mạng, nhiệt độ + **giới hạn xung CPU** (`CPU_Speed_Limit`, cảnh báo throttle), tốc độ quạt qua SMC; biểu đồ realtime (Swift Charts).
- **Dọn dẹp** — quét file tạm + dry-run + xoá có chọn lọc; quét dung lượng đĩa (disk scan).
- **Đổi phím** — Command ↔ Shift qua `hidutil`, tùy chọn giữ sau reboot.
- **Database** — kết nối & truy vấn MySQL, Redis, Oracle (NIO + tùy chọn OCI cho Oracle cũ); duyệt schema, chạy procedure, sửa bảng đơn.
- **SSH** — quản lý profile, terminal tương tác (Citadel + SwiftTerm).
- **Remote Desktop** — điều khiển từ xa qua **VNC** & **RDP** (FreeRDP); nhiều phiên, tách cửa sổ riêng. Xem [Remote Desktop (VNC/RDP)](#remote-desktop-vncrdp).
- **Git Manager** — quét repo local, liệt kê & merge MR/PR (GitLab + GitHub).
- **Quạt** — đọc & điều khiển tốc độ quạt qua SMC.
- **Clipboard** — lịch sử clipboard + chụp màn hình (screenshot).
- **Nguồn & Pin** — chống tự ngủ, hibernate khi khoá màn hình, giới hạn % sạc (SMC `BCLM` qua privileged helper).

## Module

| Module | Mô tả |
|---|---|
| `Core` | Keychain, logging, login item, điều phối sleep/wake |
| `MonitorModule` | Mach stats, SMC reader, system metrics |
| `CleanerModule` | Disk scanner, temp cleaner |
| `KeyRemapModule` | Remap phím, persistence sau reboot |
| `DatabaseModule` | Driver MySQL/Redis/Oracle (+OCI), schema, procedure |
| `SSHModule` | Profile, session SSH/terminal |
| `RemoteDesktopModule` | Phiên VNC/RDP (FreeRDP), profile + Keychain, render framebuffer |
| `GitManagerModule` | Quét repo, provider GitHub/GitLab, correlator |
| `FanControlModule` | Đọc/điều khiển quạt |
| `ClipboardModule` | Theo dõi clipboard, chụp màn hình |
| `PowerModule` | Chống ngủ, hibernate, điều phối sleep/wake |
| `BatteryModule` | Giới hạn sạc (SMC `BCLM`) qua privileged helper |

## Remote Desktop (VNC/RDP)

Thêm host ở **Remote (VNC/RDP)** → nút `+`. Chọn loại, nhập host/port/username và mật khẩu (lưu Keychain). Port mặc định: **VNC 5900**, **RDP 3389**.

### Kết nối tới Windows

Bật **Remote Desktop** trên Windows (Settings → System → Remote Desktop), kết nối RDP tới `host:3389`. Windows làm *session takeover*: khoá console local và giao chính session đó cho client.

### Kết nối tới Ubuntu (24.04 / 26.04+)

> ⚠️ Ubuntu 26.04 LTS chạy **Wayland-only**, đã **bỏ xRDP** — chỉ dùng được **gnome-remote-desktop**. (GNOME 50; remote login session đã *persistent* — rớt mạng reconnect vẫn tiếp tục.)

GNOME có **2 chế độ RDP tách biệt** (Settings → System → Remote Desktop):

| | **Desktop Sharing** | **Remote Login** |
|---|---|---|
| Session | Vào **session đang chạy** (mirror — giống Windows) | Tạo **session mới** (headless) |
| Điều kiện | Phải đang đăng nhập local; **khoá màn hình → ngắt** | Đăng nhập được cả khi không có session local |
| Port mặc định | 3389 (→ **3390** nếu bật cả hai) | **3389** |

- **Muốn vào đúng desktop đang chạy** → bật **Desktop Sharing**, kết nối port **3389** (hoặc **3390** nếu bật cả 2 chế độ).
- **Dùng như máy headless** → **Remote Login**; nhưng nếu user đó đang có session local, RDP báo **"Session Already Running"** (buộc log out hoặc force-stop). Log out local trước rồi kết nối; nhờ persistent của GNOME 50, sau đó reconnect tiếp tục được. *Tránh "Force Stop" khi đang có việc dở — mất dữ liệu.*

> 💡 App hiển thị gợi ý port này ngay trong ô tạo profile RDP.

**Bàn phím:** app gửi theo *scancode* (PC/AT set 1) + phím mở rộng (mũi tên, Home/End…) nên gõ được cả trên server Linux (gnome-remote-desktop/xrdp) lẫn Windows.

**Khắc phục màn hình đen/trắng:** đã bật kênh **GFX** + đổ vào `gdi.primary_buffer`. Nếu Remote Login trên Ubuntu 26.04 vẫn đen (lỗi đã báo phía gnome-remote-desktop), thử **Desktop Sharing** để khoanh vùng server vs client.

## Tài liệu

Toàn bộ tài liệu & bảng theo dõi task trong [docs/](docs/README.md):
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — kiến trúc, tech stack, module.
- [docs/BUILD.md](docs/BUILD.md) — hướng dẫn build trên Mac.
- [docs/TASKS.md](docs/TASKS.md) — bảng theo dõi task theo trạng thái.
- [docs/ORACLE-OCI-SETUP.md](docs/ORACLE-OCI-SETUP.md) — cài Oracle Instant Client cho OCI.
- [docs/features/](docs/) — chi tiết từng tính năng.
