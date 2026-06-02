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
swift run MacUtil     # chạy app (cửa sổ SwiftUI)
swift test            # chạy unit test
```

> App hiện là **executable SwiftPM** để dev nhanh. Một số API (NSWorkspace sleep/wake, hidutil)
> chạy tốt khi `swift run`. Việc **ký + notarize + privileged helper (fan control)** sẽ cần
> bọc trong **Xcode app target** ở giai đoạn sau (M3/M5) — xem ARCHITECTURE §5.

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
