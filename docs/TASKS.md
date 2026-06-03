# TASKS — Bảng theo dõi tổng

> Trạng thái: ⬜ TODO · 🟦 IN_PROGRESS · ✅ DONE · ⛔ BLOCKED · 🔬 NEEDS_VERIFY
>
> **Cập nhật:** đổi icon ở đây **và** trong file feature tương ứng khi code. Chi tiết task xem trong từng file `features/`.
>
> ℹ️ **Increment 1–3 đã viết code** (Core + Monitor + Cleaner + KeyRemap + Git + Database + SSH + Fan shell). Các task 🟦 = code viết xong nhưng **chưa build/kiểm thử trên Mac**. Chỉ chuyển ✅ sau khi build & chạy thật thành công.

## Tiến độ tổng quan

| Nhóm | Tổng | ✅ | 🟦 | 🔬 | ⬜ |
|------|------|----|----|----|----|
| M0 — Khung dự án | 6 | 0 | 6 | 0 | 0 |
| Database (DB) | 11 | 0 | 10 | 1 | 0 |
| SSH | 9 | 0 | 9 | 0 | 0 |
| Cleaner (CLN) | 6 | 0 | 6 | 0 | 0 |
| Monitor (MON) | 9 | 0 | 6 | 2 | 1 |
| Fan (FAN) | 8 | 0 | 3 | 2 | 3 |
| Key remap (KEY) | 5 | 0 | 5 | 0 | 0 |
| Git (GIT) | 14 | 0 | 14 | 0 | 0 |
| **Tổng** | **68** | **0** | **59** | **5** | **4** |

---

## M0 — Khung dự án (làm trước tiên)

| ID | Task | Trạng thái | Ghi chú |
|----|------|-----------|---------|
| INF-01 | Khung app (dùng SPM executable thay .xcodeproj cho dev) | 🟦 IN_PROGRESS | .xcodeproj/ký để sau (M5) |
| INF-02 | Thiết lập SPM modules (Core + feature modules) | 🟦 IN_PROGRESS | `Package.swift` cập nhật thêm DB/SSH/Fan |
| INF-03 | `Core`: Keychain wrapper | 🟦 IN_PROGRESS | `Sources/Core/Keychain.swift` |
| INF-04 | `Core`: Logger | 🟦 IN_PROGRESS | Thêm log.database, log.ssh, log.fan |
| INF-05 | `Core`: SleepWakeCoordinator | 🟦 IN_PROGRESS | NSWorkspace xong; NWPathMonitor để sau |
| INF-06 | App shell SwiftUI + điều hướng | 🟦 IN_PROGRESS | NavigationSplitView — tất cả feature đã wire |

---

## Milestone & thứ tự đề xuất

- **M1 — Giá trị nhanh, ít rủi ro:** ✅ Database (DB-01→11) + SSH (SSH-01→09) — Code xong
- **M2 — Hệ thống:** ✅ Monitor (MON-01→09) + Cleaner (CLN-01→06) + Key remap (KEY-01→05) — Code xong
- **M3 — Phần cứng rủi ro:** Fan (FAN-01→08) — Protocol + UI xong; SMC write + helper còn lại
- **M4 — Git:** ✅ GIT-01→14 — Code xong
- **M5 — Hoàn thiện:** ký + notarize, test sleep/wake toàn diện, tối ưu nhẹ

---

## Danh sách task theo nhóm

### Database — chi tiết: [features/01-database.md](./features/01-database.md)
| ID | Task | Trạng thái |
|----|------|-----------|
| DB-01 | Protocol `DatabaseDriver` chung | 🟦 IN_PROGRESS |
| DB-02 | MySQLNIO: connect + SELECT | 🟦 IN_PROGRESS |
| DB-03 | MySQL: fetch schema (INFORMATION_SCHEMA), SHOW CREATE | 🟦 IN_PROGRESS |
| DB-04 | MySQL: chạy procedure (`CALL`) | 🟦 IN_PROGRESS |
| DB-05 | Tích hợp RediStack: connect + lệnh cơ bản + xem keyspace | 🟦 IN_PROGRESS |
| DB-06 | Đánh giá & chọn driver Oracle | 🟦 IN_PROGRESS | OracleNIO 1.0.0-beta.3 (tools 5.9) |
| DB-07 | Oracle: connect + SELECT | 🟦 IN_PROGRESS |
| DB-08 | Oracle: xem ALL_SOURCE (package/procedure) + chạy proc | 🟦 IN_PROGRESS |
| DB-09 | SQL editor UI (syntax highlight) + bảng kết quả phân trang | 🟦 IN_PROGRESS |
| DB-10 | Lưu connection profile vào Keychain | 🟦 IN_PROGRESS |
| DB-11 | Xử lý sleep/wake: pool health-check + reconnect | 🟦 IN_PROGRESS |

### SSH — chi tiết: [features/02-ssh-manager.md](./features/02-ssh-manager.md)
| ID | Task | Trạng thái |
|----|------|-----------|
| SSH-01 | Model `SSHProfile` + lưu/đọc Keychain | 🟦 IN_PROGRESS |
| SSH-02 | Tích hợp Citadel: connect bằng password | 🟦 IN_PROGRESS |
| SSH-03 | Connect bằng private key (+ passphrase) | 🟦 IN_PROGRESS |
| SSH-04 | Tích hợp SwiftTerm: terminal tương tác | 🟦 IN_PROGRESS |
| SSH-05 | Quản lý nhiều session/tab | 🟦 IN_PROGRESS |
| SSH-06 | Exec lệnh nhanh (không mở shell) | 🟦 IN_PROGRESS |
| SSH-07 | SFTP: duyệt + upload/download file | 🟦 IN_PROGRESS |
| SSH-08 | Xác thực host key (known_hosts) | 🟦 IN_PROGRESS |
| SSH-09 | Xử lý sleep/wake: phát hiện chết + reconnect | 🟦 IN_PROGRESS |

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
| MON-05 | Nhiệt độ CPU (bonus) | 🟦 IN_PROGRESS | SMCReader.swift; cần kiểm thử trên Mac thật |
| MON-06 | Timer + publisher realtime | 🟦 IN_PROGRESS |
| MON-07 | UI dashboard | 🟦 IN_PROGRESS |
| MON-08 | Fallback ẩn quạt (Apple Silicon) | 🔬 NEEDS_VERIFY |
| MON-09 | Sleep/wake cho timer | 🟦 IN_PROGRESS |

### Fan — chi tiết: [features/05-fan-control.md](./features/05-fan-control.md)
| ID | Task | Trạng thái |
|----|------|-----------|
| FAN-01 | Protocol `FanController` (HAL) + fallback | 🟦 IN_PROGRESS |
| FAN-02 | Privileged helper (SMAppService) | ⬜ TODO |
| FAN-03 | Ghi SMC F0Tg + FS! (Intel) | 🔬 NEEDS_VERIFY |
| FAN-04 | Giới hạn min/max + Reset Auto | 🟦 IN_PROGRESS |
| FAN-05 | Tự trả Auto khi thoát/crash | 🟦 IN_PROGRESS |
| FAN-06 | Phát hiện MacBook Air (ẩn) | ⬜ TODO |
| FAN-07 | Kiểm chứng Apple Silicon | 🔬 NEEDS_VERIFY |
| FAN-08 | UI điều khiển (slider, auto/manual) | 🟦 IN_PROGRESS |

### Key remap — chi tiết: [features/06-key-remap.md](./features/06-key-remap.md)
| ID | Task | Trạng thái |
|----|------|-----------|
| KEY-01 | Remap qua hidutil (Cmd ↔ Shift) | 🟦 IN_PROGRESS |
| KEY-02 | Khôi phục mặc định | 🟦 IN_PROGRESS |
| KEY-03 | LaunchAgent giữ sau reboot | 🟦 IN_PROGRESS |
| KEY-04 | UI chọn cặp phím (mở rộng ngoài Cmd/Shift) | 🟦 IN_PROGRESS |
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
| GIT-10 | Auto-scan định kỳ + ETag | 🟦 IN_PROGRESS |
| GIT-11 | UI master-detail | 🟦 IN_PROGRESS |
| GIT-12 | Dialog xác nhận merge | 🟦 IN_PROGRESS |
| GIT-13 | Chỉ hiện method cho phép | 🟦 IN_PROGRESS |
| GIT-14 | Sleep/wake + timeout | 🟦 IN_PROGRESS |
