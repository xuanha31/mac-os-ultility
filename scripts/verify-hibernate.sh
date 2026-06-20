#!/usr/bin/env bash
# verify-hibernate.sh — bằng chứng KHÁCH QUAN xem máy có hibernate thật không.
#
# Cách dùng:
#   1) Bật toggle "hibernate khi khoá" trong app.
#   2) ./scripts/verify-hibernate.sh        # xem cấu hình hiện tại + mốc gần nhất
#   3) Gập máy / để máy ngủ vài phút, rồi mở lại.
#   4) ./scripts/verify-hibernate.sh        # đọc lại log: máy đã ngủ kiểu gì
#
# Không cần sudo. macOS tự ghi log (pmset -g log) — script chỉ đọc và diễn giải.
set -euo pipefail

ram_gb=$(sysctl -n hw.memsize | awk '{printf "%.1f", $1/1073741824}')
hibmode=$(pmset -g | awk '/ hibernatemode /{print $2}')
powernap=$(pmset -g | awk '/ powernap /{print $2}')
womp=$(pmset -g | awk '/ womp /{print $2}')
tcp=$(pmset -g | awk '/ tcpkeepalive /{print $2}')

echo "================ CẤU HÌNH NGUỒN ================"
echo "RAM vật lý:        ${ram_gb} GB"
echo "hibernatemode:     ${hibmode}   (25 = ghi RAM ra đĩa + cắt nguồn; 3 = sleep thường, RAM còn điện)"
echo "powernap:          ${powernap}   (1 = có dark wake bảo trì → 'máy vẫn hoạt động')"
echo "womp (wake-on-lan):${womp}"
echo "tcpkeepalive:      ${tcp}   (1 = thức nền giữ mạng)"
echo

echo "================ SLEEPIMAGE (RAM trên đĩa) ================"
if ls -lah /var/vm/sleepimage >/dev/null 2>&1; then
    ls -lah /var/vm/sleepimage | awk '{print "size="$5"  mtime="$6" "$7" "$8}'
    echo "  (size ~ RAM đã dùng nếu hibernate; mtime = lần cuối ghi RAM ra đĩa)"
else
    echo "  (không đọc được trực tiếp — thử: sudo ls -lah /var/vm/sleepimage)"
fi
echo

echo "================ MỐC SLEEP / WAKE / HIBERNATE GẦN NHẤT ================"
echo "Đọc: 'Entering Sleep' = đi ngủ | 'FullWake' = bạn mở máy | 'DarkWake'/'Maintenance' = máy TỰ thức (xấu)"
echo
pmset -g log | grep -iE 'hibernate|Entering Sleep|FullWake|DarkWake|Wake from' | tail -25
