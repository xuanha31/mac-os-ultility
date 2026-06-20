# Tính năng 7 — Remote Desktop (VNC + RDP)

## Mục tiêu
Điều khiển máy từ xa qua **VNC** và **RDP** ngay trong app, hiển thị màn hình remote ở
panel chính và cho phép **tách phiên ra cửa sổ riêng**. Đặt cạnh SSH trong sidebar.

## Kiến trúc
Module mới `RemoteDesktopModule` (mô phỏng SSHModule):
- `RemoteProfile` + `RemoteProfileStore` — cấu hình host (VNC/RDP), secret lưu Keychain
  (service `com.macutil.remote`).
- `RemoteState` — `@MainActor ObservableObject`: `sessions: [UUID: any RemoteSession]`,
  `selectedSessionID`, `sessionStates`, `detachedSessionIDs`.
- `RemoteSession` (protocol) — phiên **sở hữu NSView của nó** → nhúng/tách chỉ là chuyển
  superview, không kết nối lại.
  - `VNCSession` — RoyalVNCKit, dùng `VNCCAFramebufferView` (NSView sẵn có).
  - `RDPSession` — FreeRDP 3.x qua C-interop (`CFreeRDP`), GDI framebuffer → `CGImage`.
- UI: `RemoteDesktopView` (sidebar + tab + màn hình), nút **"Tách ra cửa sổ"** dùng
  `presentInWindow`. Điều hướng: `Feature.remote` trong `ContentView`.

## Phụ thuộc & cách build

### VNC — RoyalVNCKit (SwiftPM)
- Pin theo **revision** tag 1.0.0 (`60a92e1…`) vì:
  - 1.1.0 kéo CryptoSwift theo branch fork → SwiftPM từ chối khi pin version.
  - C target bundled (libtomcrypt/libtommath) dùng `unsafeFlags` → chỉ được phép khi pin
    branch/revision.
- **Bug thread-safety (đã có cách vá):** `VNCConnection.clientToServerMessageQueue`
  (`Queue<T>` — Array không khóa) bị enqueue từ main thread (input) đua với dequeue ở
  send-loop Task nền → crash `removeFirst()` khi di chuột/gõ phím. Có cả ở 1.0.0 lẫn 1.1.0.
  Sửa bằng fork + vá (Queue dùng `NSLock`):
  1. Fork `github.com/royalapplications/royalvnc` về tài khoản của bạn (GitHub UI).
  2. `./scripts/setup-royalvnc-fork.sh <url-fork>` — clone, tạo branch `threadsafe-queue`
     từ tag 1.0.0, áp `docs/patches/royalvnc-queue-threadsafe.patch`, push.
  3. Pin `Package.swift`: `.package(url: "<url-fork>", branch: "threadsafe-queue")`.
- Lần đầu fetch dính git config `safe.bareRepository=explicit`. Khắc phục bằng env (không
  sửa file cấu hình):
  ```
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all swift package resolve
  ```
  Sau khi resolve, `swift build` chạy bình thường (không cần override).

### RDP — FreeRDP (Homebrew, C-interop)
- Cài: `brew install freerdp` (đã có 3.27 trên máy Intel `/usr/local`).
- `Package.swift` tự dò header `<prefix>/include/freerdp3/freerdp/freerdp.h` (Intel
  `/usr/local` hoặc Apple Silicon `/opt/homebrew`):
  - `hasFreeRDP` bật → thêm target `CFreeRDP` (shim phơi bày header) + define `HAS_FREERDP`
    + cờ `-Xcc -I…freerdp3 -I…winpr3`.
  - MacUtil link `-lfreerdp3 -lfreerdp-client3 -lwinpr3` + rpath.
  - Nếu chưa cài → RDP tắt, app vẫn build (RDPSession bỏ qua, hiện hướng dẫn cài).
- Callback C (`@convention(c)`, không capture) tra ngược `RDPClient` qua registry theo con
  trỏ `rdpContext`.

## Rủi ro / việc còn lại
- **[Unverified]** Đường render + input của RDP đã build+link nhưng **cần kiểm thử với máy
  Windows thật** (bật Remote Desktop). VNC cần test với máy bật Screen Sharing/VNC server.
- RDP cert đang **auto-accept** (`FreeRDP_AutoAcceptCertificate`) → nên thêm xác nhận
  người dùng (cảnh báo bảo mật).
- RDP keyboard hiện gửi theo **unicode** (đủ cho gõ ký tự); phím tổ hợp/đặc biệt nên bổ
  sung scancode sau.
- **Phân phối máy khác:** FreeRDP link theo path Homebrew tuyệt đối
  (`/usr/local/opt/freerdp/lib/…`). Muốn đóng `.app` chạy máy khác phải bundle dylib vào
  `Contents/Frameworks` + `install_name_tool` đổi sang `@rpath` + ký lại. RoyalVNCKit là
  Swift thuần nên SwiftPM tự xử lý.

## Task

| ID | Task | Trạng thái | Ghi chú |
|----|------|-----------|---------|
| RD-01 | Model `RemoteProfile` + Keychain store | ✅ DONE | `RemoteProfile.swift` |
| RD-02 | Protocol `RemoteSession` + `RemoteState` đa phiên | ✅ DONE | tab + detach |
| RD-03 | UI `RemoteDesktopView` (sidebar/tab/màn hình) + tách cửa sổ | ✅ DONE | `presentInWindow` |
| RD-04 | VNC qua RoyalVNCKit | ✅ DONE | `VNCSession` |
| RD-04b | Vá race Queue (fork RoyalVNCKit + NSLock) cho input | 🟦 chờ fork | `docs/patches/`, `scripts/setup-royalvnc-fork.sh` |
| RD-05 | RDP qua FreeRDP (C-interop + GDI render + input) | ✅ BUILD OK (chờ test runtime) | `CFreeRDP`, `RDPSession` |
| RD-06 | Bundle + ký dylib FreeRDP để phân phối máy khác | ⬜ TODO | install_name_tool + codesign |
| RD-07 | Hỏi xác nhận certificate RDP thay vì auto-accept | ⬜ TODO | bảo mật |
