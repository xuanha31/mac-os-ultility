#!/usr/bin/env bash
# install-power-probe.sh — cài/gỡ LaunchDaemon lấy mẫu pin.
#
#   sudo ./scripts/install-power-probe.sh install     # bắt đầu đo
#   sudo ./scripts/install-power-probe.sh uninstall   # dừng đo (giữ lại dữ liệu)
#   sudo ./scripts/install-power-probe.sh status
#
# Dùng LaunchDaemon (system) chứ không phải LaunchAgent, vì trong dark wake phiên
# đăng nhập của người dùng có thể chưa dựng lên → agent sẽ không chạy và ta mất
# đúng những mẫu cần nhất.
#
# Script được COPY sang /usr/local/libexec thay vì chạy thẳng từ ~/Desktop: TCC
# chặn daemon đọc thư mục Desktop trừ khi được cấp Full Disk Access.
set -euo pipefail

LABEL="com.macutil.powerprobe"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
TARGET="/usr/local/libexec/macutil-power-probe.sh"
LOG_FILE="/var/log/macutil-power.tsv"
INTERVAL="${POWER_PROBE_INTERVAL:-10}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/power-probe.sh"

action="${1:-status}"

need_root() {
    if [[ $EUID -ne 0 ]]; then echo "Cần sudo: sudo $0 $action" >&2; exit 1; fi
}

case "$action" in
install)
    need_root
    [[ -f "$SRC" ]] || { echo "Không thấy $SRC" >&2; exit 1; }

    install -d -m 755 /usr/local/libexec
    install -m 755 -o root -g wheel "$SRC" "$TARGET"

    cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>              <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${TARGET}</string>
    </array>
    <key>StartInterval</key>      <integer>${INTERVAL}</integer>
    <key>RunAtLoad</key>          <true/>
    <key>ProcessType</key>        <string>Background</string>
    <key>LowPriorityIO</key>      <true/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>POWER_PROBE_LOG</key><string>${LOG_FILE}</string>
    </dict>
    <key>StandardErrorPath</key>  <string>/var/log/macutil-power.err</string>
</dict>
</plist>
PLIST_EOF
    chown root:wheel "$PLIST"; chmod 644 "$PLIST"

    launchctl bootout  system "$PLIST" 2>/dev/null || true
    launchctl bootstrap system "$PLIST"
    launchctl enable "system/${LABEL}"

    touch "$LOG_FILE"; chmod 644 "$LOG_FILE"
    echo "Đã cài. Lấy mẫu mỗi ${INTERVAL}s → ${LOG_FILE}"
    echo "Sáng mai chạy:  ./scripts/power-report.sh"
    ;;

uninstall)
    need_root
    launchctl bootout system "$PLIST" 2>/dev/null || true
    rm -f "$PLIST" "$TARGET"
    echo "Đã gỡ daemon. Dữ liệu vẫn còn ở ${LOG_FILE}"
    ;;

status)
    if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
        echo "Daemon: ĐANG CHẠY (mỗi ${INTERVAL}s)"
    else
        echo "Daemon: chưa cài"
    fi
    if [[ -s "$LOG_FILE" ]]; then
        n=$(( $(wc -l < "$LOG_FILE") - 1 ))
        echo "Mẫu đã ghi: ${n}"
        echo "Mới nhất:   $(tail -1 "$LOG_FILE" | cut -f2,3,6,7 | tr '\t' ' ')"
    else
        echo "Chưa có mẫu nào."
    fi
    ;;

*) echo "Dùng: $0 {install|uninstall|status}" >&2; exit 2 ;;
esac
