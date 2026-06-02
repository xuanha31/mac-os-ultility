# Tính năng 2 — SSH Manager (như MobaXterm)

## Mục tiêu
Quản lý nhiều SSH session: lưu cấu hình host, mở terminal, exec lệnh, (tùy chọn) SFTP.

## Thư viện đề xuất

| Mục | Thư viện | Ghi chú |
|-----|----------|---------|
| SSH client | `Citadel` (trên `swift-nio-ssh`) | Cấp cao: exec, shell, SFTP |
| SSH cấp thấp | `apple/swift-nio-ssh` | Nếu cần kiểm soát sâu hơn |
| Terminal UI | `SwiftTerm` (Miguel de Icaza) | Emulator xterm-compatible cho AppKit/SwiftUI |
| Lưu credential | Keychain (Security framework) | Không lưu plaintext |

## Cách làm kỹ thuật
- Model `SSHProfile`: host, port, user, auth (password / private key), nhóm/tag.
- Mở session: `Citadel` tạo connection → gắn vào `SwiftTerm` để có cửa sổ terminal tương tác.
- Hỗ trợ **private key** (đọc từ file, passphrase lưu Keychain).
- Quản lý nhiều tab/session đồng thời.

## Rủi ro & lưu ý
- **Sleep/wake:** SSH socket dễ chết sau sleep → bắt sự kiện disconnect, hiện trạng thái "disconnected", cho reconnect 1 chạm. Không tự giữ socket vô thời hạn.
- Xác thực host key (known_hosts) để tránh MITM — cảnh báo khi key đổi.

## Task

| ID | Task | Trạng thái | Ghi chú |
|----|------|-----------|---------|
| SSH-01 | Model `SSHProfile` + lưu/đọc Keychain | ⬜ TODO | |
| SSH-02 | Tích hợp Citadel: connect bằng password | ⬜ TODO | |
| SSH-03 | Connect bằng private key (+ passphrase) | ⬜ TODO | |
| SSH-04 | Tích hợp SwiftTerm: terminal tương tác | ⬜ TODO | |
| SSH-05 | Quản lý nhiều session/tab | ⬜ TODO | |
| SSH-06 | Exec lệnh nhanh (không mở shell) | ⬜ TODO | |
| SSH-07 | SFTP: duyệt + upload/download file | ⬜ TODO | tùy chọn |
| SSH-08 | Xác thực host key (known_hosts) | ⬜ TODO | |
| SSH-09 | Xử lý sleep/wake: phát hiện chết + reconnect | ⬜ TODO | |
