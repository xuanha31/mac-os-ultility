# Kiến trúc tổng thể — MacUtil

## 1. Tech stack

| Hạng mục | Lựa chọn | Lý do |
|----------|----------|-------|
| Ngôn ngữ | **Swift** | Native, nhẹ, truy cập trực tiếp IOKit/SMC/Mach/hidutil |
| UI | **SwiftUI** (+ AppKit khi cần) | Nhẹ, dựng nhanh; AppKit cho terminal/text view |
| Quản lý package | **Swift Package Manager (SPM)** | Tách module, không cần CocoaPods |
| Build/test | **Xcode** trên máy Mac | Bắt buộc cho app macOS native |
| Phân phối | **Developer ID + Notarization** | App không sandbox được (xem mục 5) |

> ❌ Không dùng Electron (nặng, mâu thuẫn yêu cầu "nhẹ").

## 2. Cấu trúc module (SPM)

App chính chỉ là một **shell SwiftUI mỏng**, mỗi tính năng là một module Swift Package độc lập, load theo nhu cầu.

```
MacUtilApp                 # App shell (SwiftUI), điều hướng, settings chung
├── Core                   # Tiện ích chung: Keychain, Logger, AppConfig
├── SystemControl          # SMC, hidutil, IOKit — gom các thao tác hệ thống nhạy cảm
│   └── PrivilegedHelper    # Helper chạy root (SMAppService) cho ghi SMC
├── DatabaseModule         # Tính năng 1
├── SSHModule              # Tính năng 2
├── CleanerModule          # Tính năng 3
├── MonitorModule          # Tính năng 4 (đọc CPU/RAM/mạng/quạt)
├── FanControlModule       # Tính năng 5 (ghi quạt — phụ thuộc SystemControl)
├── KeyRemapModule         # Tính năng 6
└── GitManagerModule       # Tính năng 7
```

**Nguyên tắc:** module không phụ thuộc chéo lẫn nhau; chỉ phụ thuộc `Core` và (với fan) `SystemControl`. Giúp app khởi động nhanh và dễ tắt/bật từng tính năng.

## 3. Vấn đề chung: chống treo sau sleep/wake

Đây là yêu cầu bắt buộc, ảnh hưởng tới mọi module có kết nối mạng (DB, SSH, Git) hoặc timer (Monitor).

**Cơ chế chung** (đặt trong `Core`):
- Đăng ký lắng nghe:
  - `NSWorkspace.willSleepNotification` → tạm dừng timer, đánh dấu connection là "cần kiểm tra".
  - `NSWorkspace.didWakeNotification` → resume timer, health-check + reconnect lười (chỉ reconnect khi dùng).
- `NWPathMonitor` → biết mạng đã trở lại sau wake.
- **Mọi socket/connection phải có timeout**; không giữ kết nối vô thời hạn (nguyên nhân treo phổ biến nhất).
- Connection pool có **health-check** trước khi tái sử dụng.

→ Chi tiết áp dụng được ghi trong từng feature có liên quan.

## 4. Quyền hệ thống cần xin

| Quyền | Tính năng cần | Ghi chú |
|-------|---------------|---------|
| **Full Disk Access** | Dọn temp (3), một số path | Người dùng cấp trong System Settings → Privacy |
| **Accessibility** | Key remap nếu dùng `CGEventTap` (6) | Không cần nếu dùng `hidutil` |
| **Privileged helper (root)** | Ghi SMC điều khiển quạt (5) | Đăng ký qua `SMAppService` |
| **Keychain** | Lưu token/credential DB, SSH, Git | Bắt buộc, không lưu plaintext |

## 5. Phân phối: KHÔNG sandbox

**[Inference]** Vì app dùng **privileged helper (ghi SMC)** và truy cập hệ thống sâu (hidutil, đọc SMC, full disk) → **không thể chạy trong App Sandbox** → **không phát hành qua Mac App Store**.

→ Phân phối qua **Developer ID + Notarization** (cần Apple Developer account, ký + công chứng app).

## 6. Lộ trình milestone (tóm tắt)

Chi tiết & trạng thái xem [TASKS.md](./TASKS.md).

1. **M0 — Khung dự án**: tạo Xcode project, SPM modules, app shell, Core (Keychain/Logger/sleep-wake).
2. **M1 — Tính năng giá trị nhanh**: Database + SSH (ít rủi ro phần cứng, dùng được ngay).
3. **M2 — Hệ thống**: System Monitor (đọc) + Temp Cleaner + Key Remap.
4. **M3 — Phần cứng rủi ro**: Fan Control (cần privileged helper + kiểm chứng Intel/Apple Silicon).
5. **M4 — Git Manager**: local scan + GitLab/GitHub API + merge.
6. **M5 — Hoàn thiện**: ký + notarize, kiểm thử sleep/wake toàn diện, tối ưu nhẹ.
