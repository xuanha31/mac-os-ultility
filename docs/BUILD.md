# Build & Run — MacUtil

> ⚠️ Code được viết trên môi trường Windows nên **chưa được biên dịch/kiểm thử**.
> Bắt buộc build trên **máy Mac** để xác minh. Coi đây là `[Unverified]` cho tới khi build thành công.

## Yêu cầu
- macOS 13+ (Ventura trở lên).
- Xcode 15+ **hoặc** Swift toolchain (`swift --version` ≥ 5.9).
- Xcode Command Line Tools (cho các tính năng dùng `git` về sau).

## Chạy nhanh khi phát triển (SPM)

```bash
cd mac-os-ultility
swift build          # biên dịch
swift test           # chạy unit test
```

### ⚠️ Chạy app: DÙNG `./run-app.sh`, KHÔNG dùng `swift run`

```bash
./run-app.sh          # đóng gói .app bundle + open (debug)
./run-app.sh release  # bản release
```

> **Quan trọng:** `swift run MacUtil` tạo một **executable trần**, không phải `.app` bundle.
> macOS **không cho process trần trở thành active app** → các ô input trong cửa sổ/dialog
> **không nhận keyboard** (gõ vào nhưng chữ rơi sang app đang active như VS Code/terminal).
>
> `run-app.sh` đóng gói binary thành `MacUtil.app` (có `Info.plist`) rồi `open` — macOS đăng ký
> như GUI app chuẩn, keyboard focus hoạt động bình thường. Code cũng đã set
> `NSApp.setActivationPolicy(.regular)` trong `AppDelegate` để hỗ trợ thêm.
>
> Việc **ký + notarize + privileged helper (fan control)** sẽ cần bọc trong **Xcode app target**
> ở giai đoạn sau (M3/M5) — xem ARCHITECTURE §5.

## Mở bằng Xcode
`File > Open…` chọn thư mục dự án (Xcode tự nhận `Package.swift`), chọn scheme `MacUtil` → Run.

## Tính năng đã có trong increment này
- **Giám sát hệ thống**: CPU, RAM, tốc độ mạng (Mach/getifaddrs). *Tốc độ quạt chưa bật.*
- **Dọn dẹp**: quét + dry-run + xoá file tạm có chọn lọc.
- **Đổi phím**: Command ↔ Shift qua hidutil, tùy chọn giữ sau reboot.

## Chưa có (increment sau)
- Database / SSH / Git (cần thêm Swift package phụ thuộc).
- Điều khiển quạt (cần privileged helper + kiểm chứng Intel/Apple Silicon).

## Quyền hệ thống có thể cần khi chạy thật
- **Dọn dẹp**: nếu thiếu **Full Disk Access**, một số mục sẽ bị bỏ qua (báo trong kết quả).
- **Đổi phím**: `hidutil` không cần Accessibility.
