# TASKS — Bảng theo dõi tổng

> Trạng thái: ⬜ TODO · 🟦 IN_PROGRESS · ✅ DONE · ⛔ BLOCKED · 🔬 NEEDS_VERIFY
>
> **Cập nhật:** đổi icon ở đây **và** trong file feature tương ứng khi code. Chi tiết task xem trong từng file `features/`.
>
> ℹ️ **Increment 1 đã viết code** (Core + Monitor + Cleaner + KeyRemap + app shell). Các task 🟦 = code viết xong nhưng **chưa build/kiểm thử trên Mac** (đang dev trên Windows — xem [BUILD.md](./BUILD.md)). Chỉ chuyển ✅ sau khi build & chạy thật thành công.

## Tiến độ tổng quan

| Nhóm | Tổng | ✅ | 🟦 | 🔬 | ⬜ |
|------|------|----|----|----|----|
| M0 — Khung dự án | 6 | 0 | 5 | 0 | 1 |
| Database (DB) | 11 | 0 | 0 | 1 | 10 |
| SSH | 9 | 0 | 0 | 0 | 9 |
| Cleaner (CLN) | 6 | 0 | 6 | 0 | 0 |
| Monitor (MON) | 9 | 0 | 5 | 2 | 2 |
| Fan (FAN) | 8 | 0 | 0 | 2 | 6 |
| Key remap (KEY) | 5 | 0 | 3 | 0 | 2 |
| Git (GIT) | 14 | 0 | 13 | 0 | 1 |
| **Tổng** | **68** | **0** | **32** | **5** | **31** |

---

## M0 — Khung dự án (làm trước tiên)

| ID | Task | Trạng thái | Ghi chú |
|----|------|-----------|---------|
| INF-01 | Khung app (dùng SPM executable thay .xcodeproj cho dev) | 🟦 IN_PROGRESS | .xcodeproj/ký để sau (M5) |
| INF-02 | Thiết lập SPM modules (Core + feature modules) | 🟦 IN_PROGRESS | `Package.swift` xong |
| INF-03 | `Core`: Keychain wrapper | 🟦 IN_PROGRESS | `Sources/Core/Keychain.swift` |
| INF-04 | `Core`: Logger | 🟦 IN_PROGRESS | `Sources/Core/Logging.swift` |
| INF-05 | `Core`: SleepWakeCoordinator | 🟦 IN_PROGRESS | NSWorkspace xong; NWPathMonitor để sau |
| INF-06 | App shell SwiftUI + điều hướng | 🟦 IN_PROGRESS | NavigationSplitView |

---

## Milestone & thứ tự đề xuất

- **M1 — Giá trị nhanh, ít rủi ro:** Database (DB-01→11) + SSH (SSH-01→09)
- **M2 — Hệ thống:** Monitor (MON-01→09) + Cleaner (CLN-01→06) + Key remap (KEY-01→05)
- **M3 — Phần cứng rủi ro:** Fan (FAN-01→08) — cần privileged helper + kiểm chứng
- **M4 — Git:** GIT-01→14
- **M5 — Hoàn thiện:** ký + notarize, test sleep/wake toàn diện, tối ưu nhẹ

---

## Danh sách task theo nhóm

### Database — chi tiết: [features/01-database.md](./features/01-database.md)
| ID | Task | Trạng thái |
|----|------|-----------|
| DB-01 | Protocol `DatabaseDriver` chung | ⬜ TODO |
| DB-02 | MySQLNIO: connect + SELECT | ⬜ TODO |
| DB-03 | MySQL: fetch schema | ⬜ TODO |
| DB-04 | MySQL: chạy procedure | ⬜ TODO |
| DB-05 | RediStack: connect + keyspace | ⬜ TODO |
| DB-06 | Chọn driver Oracle | 🔬 NEEDS_VERIFY |
| DB-07 | Oracle: connect + SELECT | ⬜ TODO |
| DB-08 | Oracle: ALL_SOURCE + chạy proc | ⬜ TODO |
| DB-09 | SQL editor + bảng kết quả phân trang | ⬜ TODO |
| DB-10 | Connection profile → Keychain | ⬜ TODO |
| DB-11 | Sleep/wake: pool health-check | ⬜ TODO |

### SSH — chi tiết: [features/02-ssh-manager.md](./features/02-ssh-manager.md)
| ID | Task | Trạng thái |
|----|------|-----------|
| SSH-01 | Model `SSHProfile` + Keychain | ⬜ TODO |
| SSH-02 | Citadel: connect password | ⬜ TODO |
| SSH-03 | Connect private key + passphrase | ⬜ TODO |
| SSH-04 | SwiftTerm: terminal tương tác | ⬜ TODO |
| SSH-05 | Nhiều session/tab | ⬜ TODO |
| SSH-06 | Exec lệnh nhanh | ⬜ TODO |
| SSH-07 | SFTP duyệt + up/download | ⬜ TODO |
| SSH-08 | Xác thực host key | ⬜ TODO |
| SSH-09 | Sleep/wake: reconnect | ⬜ TODO |

### Cleaner — chi tiết: [features/03-temp-cleaner.md](./features/03-temp-cleaner.md)
| ID | Task | Trạng thái |
|----|------|-----------|
| CLN-01 | Whitelist target | 🟦 IN_PROGRESS |
| CLN-02 | Scanner + tính dung lượng | 🟦 IN_PROGRESS |
| CLN-03 | UI xem trước + chọn | 🟦 IN_PROGRESS |
| CLN-04 | Xóa an toàn + báo dung lượng | 🟦 IN_PROGRESS |
| CLN-05 | Phát hiện thiếu Full Disk Access | 🟦 IN_PROGRESS |
| CLN-06 | Dry-run | 🟦 IN_PROGRESS |

### Monitor — chi tiết: [features/04-system-monitor.md](./features/04-system-monitor.md)
| ID | Task | Trạng thái |
|----|------|-----------|
| MON-01 | CPU load (Mach) | 🟦 IN_PROGRESS |
| MON-02 | RAM (Mach) | 🟦 IN_PROGRESS |
| MON-03 | Tốc độ mạng (getifaddrs delta) | 🟦 IN_PROGRESS |
| MON-04 | Đọc quạt (SMC) | 🔬 NEEDS_VERIFY |
| MON-05 | Nhiệt độ CPU (bonus) | ⬜ TODO |
| MON-06 | Timer + publisher realtime | 🟦 IN_PROGRESS |
| MON-07 | UI dashboard | 🟦 IN_PROGRESS |
| MON-08 | Fallback ẩn quạt (Apple Silicon) | 🔬 NEEDS_VERIFY |
| MON-09 | Sleep/wake cho timer | 🟦 IN_PROGRESS |

### Fan — chi tiết: [features/05-fan-control.md](./features/05-fan-control.md)
| ID | Task | Trạng thái |
|----|------|-----------|
| FAN-01 | Protocol `FanController` (HAL) + fallback | ⬜ TODO |
| FAN-02 | Privileged helper (SMAppService) | ⬜ TODO |
| FAN-03 | Ghi SMC F0Tg + FS! (Intel) | 🔬 NEEDS_VERIFY |
| FAN-04 | Giới hạn min/max + Reset Auto | ⬜ TODO |
| FAN-05 | Tự trả Auto khi thoát/crash | ⬜ TODO |
| FAN-06 | Phát hiện MacBook Air (ẩn) | ⬜ TODO |
| FAN-07 | Kiểm chứng Apple Silicon | 🔬 NEEDS_VERIFY |
| FAN-08 | UI điều khiển (slider, auto/manual) | ⬜ TODO |

### Key remap — chi tiết: [features/06-key-remap.md](./features/06-key-remap.md)
| ID | Task | Trạng thái |
|----|------|-----------|
| KEY-01 | Remap qua hidutil (Cmd ↔ Shift) | 🟦 IN_PROGRESS |
| KEY-02 | Khôi phục mặc định | 🟦 IN_PROGRESS |
| KEY-03 | LaunchAgent giữ sau reboot | 🟦 IN_PROGRESS |
| KEY-04 | UI chọn cặp phím (mở rộng ngoài Cmd/Shift) | ⬜ TODO |
| KEY-05 | (Tùy chọn) CGEventTap nâng cao | ⬜ TODO |

### Git — chi tiết: [features/07-git-manager.md](./features/07-git-manager.md)
| ID | Task | Trạng thái |
|----|------|-----------|
| GIT-01 | LocalRepoScanner: quét .git | 🟦 IN_PROGRESS |
| GIT-02 | git fetch (nút Quét+Fetch) + parse status | 🟦 IN_PROGRESS |
| GIT-03 | RepoCorrelator: origin URL → provider | 🟦 IN_PROGRESS |
| GIT-04 | Protocol `GitHostProvider` | 🟦 IN_PROGRESS |
| GIT-05 | GitHubProvider: list PR + CI | 🟦 IN_PROGRESS |
| GIT-06 | GitHubProvider: merge | 🟦 IN_PROGRESS |
| GIT-07 | GitLabProvider: list MR + pipeline | 🟦 IN_PROGRESS |
| GIT-08 | GitLabProvider: merge | 🟦 IN_PROGRESS |
| GIT-09 | PAT → Keychain | 🟦 IN_PROGRESS |
| GIT-10 | Auto-scan định kỳ + ETag | ⬜ TODO |
| GIT-11 | UI master-detail | 🟦 IN_PROGRESS |
| GIT-12 | Dialog xác nhận merge | 🟦 IN_PROGRESS |
| GIT-13 | Chỉ hiện method cho phép | 🟦 IN_PROGRESS |
| GIT-14 | Sleep/wake + timeout (timeout xong; auto-scan để sau) | 🟦 IN_PROGRESS |
