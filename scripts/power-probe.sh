#!/usr/bin/env bash
# power-probe.sh — ghi MỘT mẫu trạng thái pin vào file TSV.
#
# Chạy bởi LaunchDaemon com.macutil.powerprobe mỗi POWER_PROBE_INTERVAL giây.
# Trong lúc máy standby/hibernate thì daemon KHÔNG chạy (máy tắt) → khoảng trống
# giữa hai mẫu chính là thời gian ngủ. Đó là cách ta tách "hao khi ngủ" khỏi
# "hao khi dark wake" mà không cần đoán.
#
# Đơn vị: AppleRawCurrentCapacity tính bằng mAh (3860 mAh full trên máy này)
# → phân giải 0.026%, thay vì 1% của `pmset -g batt`.
#
# launchd StartInterval KHÔNG đặt báo thức RTC — job chỉ chạy khi máy đang thức,
# nên bộ đo này không tự tạo thêm lần thức nào.
set -euo pipefail

LOG_FILE="${POWER_PROBE_LOG:-/var/log/macutil-power.tsv}"
MAX_BYTES=$((32 * 1024 * 1024))

# Header một lần, để report biết thứ tự cột.
if [[ ! -s "$LOG_FILE" ]]; then
    printf 'epoch\tiso\tmah\tmv\tma\tpct\text\tcharging\ttempC\n' > "$LOG_FILE"
fi

# Xoay vòng thô: quá ngưỡng thì giữ nửa cuối.
if [[ -f "$LOG_FILE" ]]; then
    size=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
    if (( size > MAX_BYTES )); then
        tail -n 200000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
fi

# Một lần gọi ioreg, một lần awk — giữ chi phí đo ở mức không đáng kể.
ioreg -rc AppleSmartBattery -d1 2>/dev/null | awk -v ts="$(date +%s)" -v iso="$(date '+%Y-%m-%d %H:%M:%S')" '
function val(line,   v) { sub(/^[^=]*= */, "", line); gsub(/[" ]/, "", line); return line }
# ioreg in Amperage dưới dạng unsigned 64-bit: giá trị âm bị wrap thành ~1.8e19.
function signed(v) { v += 0; if (v > 9.2e18) v -= 18446744073709551616; return v }
/"AppleRawCurrentCapacity"/ { mah = val($0) }
/"Voltage"/                 { if (mv == "") mv = val($0) }
/"InstantAmperage"/         { ma = signed(val($0)) }
/"CurrentCapacity"/         { if (cur == "") cur = val($0) }
/"MaxCapacity"/             { if (max == "") max = val($0) }
/"ExternalConnected"/       { ext = val($0) }
/"IsCharging"/              { chg = val($0) }
/"Temperature"/             { if (tc == "") tc = val($0) }
END {
    if (mah == "") exit 1
    pct = (max > 0) ? cur * 100.0 / max : 0
    printf "%s\t%s\t%s\t%s\t%d\t%.2f\t%s\t%s\t%.2f\n", ts, iso, mah, mv, ma, pct, ext, chg, tc/100.0
}' >> "$LOG_FILE"
