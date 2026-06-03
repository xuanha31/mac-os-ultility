#!/bin/bash
# Đóng gói MacUtil thành .app bundle và chạy qua `open`.
# Cần thiết vì executable trần (swift run) không nhận keyboard focus đúng cách
# trên macOS — phải là .app bundle để macOS đăng ký như GUI app chuẩn.
set -e

cd "$(dirname "$0")"

CONFIG="${1:-debug}"
APP_NAME="MacUtil"
APP_DIR=".build/${APP_NAME}.app"
BIN_PATH=".build/${CONFIG}/${APP_NAME}"

echo "▶ Building (${CONFIG})…"
swift build -c "${CONFIG}"

echo "▶ Đóng gói ${APP_NAME}.app…"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# App icon
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"
fi

cat > "${APP_DIR}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>MacUtil</string>
    <key>CFBundleDisplayName</key>
    <string>MacUtil</string>
    <key>CFBundleIdentifier</key>
    <string>com.macutil.app</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>MacUtil</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

# Ký app bằng certificate cố định để Keychain "Always Allow" giữ qua mọi lần build.
# Ưu tiên Apple Development; nếu không có thì ad-hoc (sẽ bị hỏi lại keychain mỗi lần).
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -Eo '"Apple Development:[^"]*"' | head -1 | tr -d '"')

if [ -n "${SIGN_ID}" ]; then
    echo "▶ Ký app với: ${SIGN_ID}"
    codesign --force --deep \
        --sign "${SIGN_ID}" \
        --identifier "com.macutil.app" \
        "${APP_DIR}" 2>&1 | sed 's/^/   /' || echo "   ⚠ Ký thất bại, dùng bản chưa ký"
else
    echo "▶ Không có Apple Development cert — ký ad-hoc (keychain sẽ hỏi lại mỗi lần)"
    codesign --force --deep --sign - --identifier "com.macutil.app" "${APP_DIR}" 2>/dev/null || true
fi

echo "▶ Khởi chạy…"
# Đóng instance cũ nếu có
pkill -x "${APP_NAME}" 2>/dev/null || true
sleep 0.5
open "${APP_DIR}"
echo "✓ Đã chạy ${APP_DIR}"
