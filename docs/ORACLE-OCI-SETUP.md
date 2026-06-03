# Cài Oracle Instant Client (OCI) để hỗ trợ Oracle cũ (< 12.1)

> `oracle-nio` (driver thuần Swift) chỉ nói được Oracle 12.1+. Để kết nối server cũ
> (vd 11.2 — chính là server đang báo `serverVersionNotSupported`), MacUtil dùng
> **Oracle Instant Client (OCI)** qua C bridging. OCI 19.8 client kết nối được server 11.2+.
>
> ✅ **Đã cài sẵn trên máy này** tại `~/oracle/instantclient` (19.8, x86_64).
> `Package.swift` dò `~/oracle/instantclient/sdk/include/oci.h` → tự bật OCI (`HAS_OCI`).
> Phần dưới là hướng dẫn cài lại nếu cần (vd máy khác). Bản đã cài dùng `~/oracle`
> (không cần sudo) thay cho `/opt` trong hướng dẫn gốc.

## 0. Thông tin máy bạn
- macOS 14.7 · **x86_64 (Intel)** → tải bản **macOS x64**.
- ⚠️ Oracle **không có** Instant Client cho Apple Silicon (arm64); bản macOS cuối là **19.8** (x64). Máy bạn Intel nên OK.

## 1. Tải 2 gói (cần đăng nhập tài khoản Oracle miễn phí)

Trang: https://www.oracle.com/database/technologies/instant-client/macos-intel-x86-downloads.html

Tải **đúng 2 gói** (cùng version, vd 19.8.0.0.0):
1. **Basic** — `instantclient-basic-macos.x64-19.8.0.0.0dbru.zip`
2. **SDK** — `instantclient-sdk-macos.x64-19.8.0.0.0dbru.zip`  ← bắt buộc (chứa `oci.h`)

## 2. Giải nén vào /opt/oracle

```bash
# Tạo thư mục (cần sudo cho /opt)
sudo mkdir -p /opt/oracle
sudo chown $(whoami) /opt/oracle

# Giải nén cả 2 gói vào /opt/oracle (giả sử file ở ~/Downloads)
cd /opt/oracle
unzip ~/Downloads/instantclient-basic-macos.x64-19.8.0.0.0dbru.zip
unzip ~/Downloads/instantclient-sdk-macos.x64-19.8.0.0.0dbru.zip
# → tạo thư mục /opt/oracle/instantclient_19_8

# Tạo symlink cố định để Package.swift trỏ tới (không phụ thuộc version)
ln -sfn /opt/oracle/instantclient_19_8 /opt/oracle/instantclient
```

## 3. Gỡ quarantine (macOS chặn dylib tải từ mạng)

```bash
sudo xattr -dr com.apple.quarantine /opt/oracle/instantclient_19_8
```

## 4. Kiểm tra đúng cấu trúc

```bash
ls -l /opt/oracle/instantclient/sdk/include/oci.h     # phải tồn tại
ls -l /opt/oracle/instantclient/libclntsh.dylib       # phải tồn tại (hoặc libclntsh.dylib.19.1)
```

Nếu chỉ có `libclntsh.dylib.19.1` mà không có `libclntsh.dylib`:
```bash
cd /opt/oracle/instantclient && ln -sf libclntsh.dylib.19.1 libclntsh.dylib
```

## 5. Build lại MacUtil

```bash
cd <thư mục dự án>
./run-app.sh debug
```

`Package.swift` tự phát hiện `oci.h` → bật target OCI (định nghĩa `HAS_OCI`).
Nếu thấy dòng `▶ OCI enabled` khi build là thành công.

## 6. Kết nối Oracle trong app
- **Host**: IP server (vd 10.14.136.133)
- **Port**: 1521
- **Database / Schema**: **service name** (vd `gold`) — OCI dùng `//host:port/service`
- **Username / Password**: tài khoản DB

## Gỡ lỗi
- `image not found: libclntsh.dylib` khi chạy: kiểm tra symlink ở bước 4, và quarantine bước 3.
- `oci.h not found` khi build: thiếu gói **SDK** (bước 1.2) hoặc sai đường dẫn symlink (bước 2).
- Build vẫn chạy bình thường nếu chưa cài — chỉ là Oracle cũ chưa kết nối được; MySQL/Redis không ảnh hưởng.
