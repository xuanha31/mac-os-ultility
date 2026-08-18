#!/usr/bin/env bash
# power-wake-detail.sh — mổ xẻ MỘT lần máy tự thức: cái gì đã chạy.
#
# power-report.sh trả lời "hao ở đoạn thức hay đoạn ngủ". Script này trả lời tiếp
# "trong đoạn thức đó thì THẰNG NÀO chạy" — đọc unified log của macOS, không cần
# cài thêm gì (macOS đã ghi sẵn, chỉ cần biết chỗ mà moi).
#
#   ./scripts/power-wake-detail.sh                          # liệt kê các lần thức gần đây
#   ./scripts/power-wake-detail.sh "2026-08-03 08:05:44" 30 # mổ 30s từ mốc đó
set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "================ CÁC LẦN MÁY TỰ THỨC GẦN ĐÂY ================"
    pmset -g log 2>/dev/null \
      | grep -E "DarkWake|Wake from" \
      | grep -oE "^[0-9-]{10} [0-9:]{8}.*due to [^ ]+.*(BATT|AC) \(Charge:[0-9]+%\).*" \
      | sed -E 's/\+0700//' | tail -20
    echo
    echo "Mổ một lần cụ thể:  $0 \"YYYY-MM-DD HH:MM:SS\" [số giây]"
    exit 0
fi

START="$1"
DUR="${2:-30}"
END=$(date -j -v+"${DUR}"S -f "%Y-%m-%d %H:%M:%S" "$START" "+%Y-%m-%d %H:%M:%S")

echo "================ CỬA SỔ ${START} → ${END} (${DUR}s) ================"
echo

echo "--- Tiến trình được launchd sinh mới ---"
/usr/bin/log show --start "$START" --end "$END" \
    --predicate 'process == "launchd" AND eventMessage CONTAINS "xpcproxy spawned with pid"' \
    --style compact 2>/dev/null \
  | grep -oE "\[(system|gui/[0-9]+)/[a-zA-Z0-9._-]+" | sed 's|.*/||' | sort | uniq -c | sort -rn \
  || echo "  (không có)"
echo

echo "--- Power assertion được tạo trong cửa sổ ---"
pmset -g log 2>/dev/null | grep "Created" \
  | awk -v s="$START" -v e="$END" '$0 >= s && $0 <= e' \
  | grep -oE "PID [0-9]+\([A-Za-z0-9._-]+\) Created [A-Za-z]+ \"[^\"]*\"" | sort | uniq -c | sort -rn | head -15 \
  || echo "  (không có)"
echo

echo "--- Tiến trình ồn nhất (số dòng log — proxy cho mức hoạt động) ---"
/usr/bin/log show --start "$START" --end "$END" --style compact 2>/dev/null \
  | awk 'NR>1 {print $4}' | sed -E 's/\[.*//' | sort | uniq -c | sort -rn | head -15
echo

total=$(/usr/bin/log show --start "$START" --end "$END" --style compact 2>/dev/null | wc -l | tr -d ' ')
echo "Tổng dòng log trong ${DUR}s: ${total}"
echo
echo "--- Độ trễ chặn ngủ lại (thủ phạm kéo dài cửa sổ thức) ---"
pmset -g log 2>/dev/null | grep "PM Client Acks" \
  | awk -v s="$START" '$0 >= s' | head -1 \
  | grep -oE "\[[^]]*is slow\([0-9]+ ms\)\]" || echo "  (không có)"
