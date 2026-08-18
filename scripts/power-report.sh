#!/usr/bin/env bash
# power-report.sh — trả lời "một đêm mất bao nhiêu % pin, mất vào đâu".
#
# Nguyên tắc: power-probe.sh lấy mẫu đều mỗi INTERVAL giây, nhưng lúc máy
# standby/hibernate thì không mẫu nào được ghi. Vì vậy:
#   - hai mẫu cách nhau ~INTERVAL  → máy ĐANG THỨC trong khoảng đó
#   - hai mẫu cách nhau rất xa     → máy ĐÃ NGỦ trong khoảng đó
#
# GIỚI HẠN ĐÃ BIẾT — đọc trước khi tin con số:
#   1) Fuel gauge chỉ làm mới sau vài phút. Một cửa sổ dark wake ~50s thường đọc
#      ra ĐÚNG một giá trị mAh → cột "mAh" của các lần thức hay bằng 0. Đó là
#      hạn chế của cảm biến, KHÔNG phải bằng chứng dark wake không tốn điện.
#   2) Vì (1), phần điện dark wake tiêu thụ bị dồn sang đoạn standby kế tiếp.
#      Đoạn "standby" thực chất = ghi hibernate image + ngủ + đọc image lại.
#   Muốn tách bạch phải so hai đêm có cấu hình khác nhau, không suy từ một đêm.
#
# Cách dùng:
#   ./scripts/power-report.sh                                  # 24h gần nhất
#   ./scripts/power-report.sh --since "2026-08-03 18:00" --until "2026-08-04 08:00"
set -euo pipefail

LOG_FILE="${POWER_PROBE_LOG:-/var/log/macutil-power.tsv}"
INTERVAL="${POWER_PROBE_INTERVAL:-10}"
SINCE=""; UNTIL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --since)    SINCE="$2"; shift 2 ;;
        --until)    UNTIL="$2"; shift 2 ;;
        --log)      LOG_FILE="$2"; shift 2 ;;
        --interval) INTERVAL="$2"; shift 2 ;;
        *) echo "Tham số lạ: $1" >&2; exit 2 ;;
    esac
done

if [[ ! -s "$LOG_FILE" ]]; then
    echo "Chưa có dữ liệu: $LOG_FILE"
    echo "Cài bộ đo trước:  sudo ./scripts/install-power-probe.sh install"
    exit 1
fi

to_epoch() { date -j -f "%Y-%m-%d %H:%M:%S" "$1" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M" "$1" +%s; }
[[ -n "$SINCE" ]] && SINCE_E=$(to_epoch "$SINCE") || SINCE_E=$(( $(date +%s) - 86400 ))
[[ -n "$UNTIL" ]] && UNTIL_E=$(to_epoch "$UNTIL") || UNTIL_E=$(date +%s)

# Bảng tra nguyên nhân thức từ pmset, gán nhãn cho mỗi lần máy tỉnh.
REASONS=$(mktemp); trap 'rm -f "$REASONS"' EXIT
pmset -g log 2>/dev/null \
  | grep -E "^[0-9]{4}-[0-9]{2}-[0-9]{2}.*(DarkWake|Wake)[[:space:]]" \
  | grep -oE "^[0-9-]{10} [0-9:]{8}.*due to [^ ]+" \
  | while IFS= read -r line; do
        e=$(date -j -f "%Y-%m-%d %H:%M:%S" "${line:0:19}" +%s 2>/dev/null) || continue
        printf '%s\t%s\n' "$e" "${line##*due to }"
    done > "$REASONS" || true

awk -v since="$SINCE_E" -v until="$UNTIL_E" -v interval="$INTERVAL" -v reasons="$REASONS" '
BEGIN {
    FS = OFS = "\t"
    awake_max = interval * 4      # gap lớn hơn mức này → đã ngủ
    darkwake_max = 300            # cửa sổ thức ngắn hơn 5 phút → máy TỰ thức
    while ((getline line < reasons) > 0) { split(line, r, "\t"); rt[++nr] = r[1]; rw[nr] = r[2] }
}
function reason_at(t,   i, best, bestd, d) {
    best = "—"; bestd = 121
    for (i = 1; i <= nr; i++) { d = rt[i] - t; if (d < 0) d = -d; if (d < bestd) { bestd = d; best = rw[i] } }
    return best
}
function hms(s) { return sprintf("%dh%02dm%02ds", s/3600, (s%3600)/60, s%60) }

# ---- kết thúc một lượt chạy pin: in kết quả rồi reset ----
function close_run(   i, gross, dur, denom) {
    if (run_first_e == 0) return
    dur = run_last_e - run_first_e
    gross = run_sleep_mah + run_dark_mah + run_user_mah
    if (dur < 600) { reset_run(); return }        # bỏ lượt vụn dưới 10 phút

    nrun++
    printf "\n================ LƯỢT CHẠY PIN #%d ================\n", nrun
    printf "Từ   %s   %s mAh (%.2f%%)\n", run_first_iso, run_first_mah, run_first_pct
    printf "Đến  %s   %s mAh (%.2f%%)\n", run_last_iso,  run_last_mah,  run_last_pct
    printf "Kéo dài %s — hao %d mAh (%.2f Wh) = %.2f điểm %%  →  %.2f %%/giờ\n\n",
           hms(dur), run_first_mah - run_last_mah,
           (run_first_mah - run_last_mah) * run_last_mv / 1000000.0,
           run_first_pct - run_last_pct,
           (dur > 0 ? (run_first_pct - run_last_pct) * 3600 / dur : 0)

    denom = (gross > 0) ? gross : 1
    printf "%-26s %12s %8s %9s %11s\n", "Trạng thái", "Thời lượng", "mAh", "% hao", "Công suất TB"
    printf "%-26s %12s %8d %8.1f%% %8.0f mW\n", "Ngủ (hibernate/standby)", hms(run_sleep_s), run_sleep_mah,
           run_sleep_mah*100.0/denom, (run_sleep_s>0 ? run_sleep_mah*run_last_mv/1000.0*3600/run_sleep_s : 0)
    printf "%-26s %12s %8d %8.1f%% %8.0f mW\n", "Máy TỰ thức (dark wake)", hms(run_dark_s), run_dark_mah,
           run_dark_mah*100.0/denom, (run_dark_s>0 ? run_dark_mah*run_last_mv/1000.0*3600/run_dark_s : 0)
    if (run_user_s > 0)
        printf "%-26s %12s %8d %8.1f%% %8.0f mW\n", "Người dùng dùng máy", hms(run_user_s), run_user_mah,
               run_user_mah*100.0/denom, run_user_mah*run_last_mv/1000.0*3600/run_user_s

    if (n_dark > 0) {
        printf "\n  Các lần máy TỰ thức (%d lần, %s tổng):\n", n_dark, hms(run_dark_s)
        printf "  %-3s %-10s %9s %7s  %s\n", "#", "Lúc", "Kéo dài", "mAh", "Nguyên nhân"
        for (i = 1; i <= n_dark; i++)
            printf "  %-3d %-10s %9s %7d  %s\n", i, substr(d_iso[i],12), hms(d_dur[i]), d_mah[i], reason_at(d_start[i])
    }
    if (n_gap > 0) {
        printf "\n  Các đoạn ngủ (%d đoạn):\n", n_gap
        printf "  %-3s %-10s %9s %7s %11s\n", "#", "Lúc", "Kéo dài", "mAh", "Công suất"
        for (i = 1; i <= n_gap; i++)
            printf "  %-3d %-10s %9s %7d %8.0f mW\n", i, substr(g_iso[i],12), hms(g_dur[i]), g_mah[i],
                   (g_dur[i]>0 ? g_mah[i]*run_last_mv/1000.0*3600/g_dur[i] : 0)
    }
    reset_run()
}
function reset_run() {
    run_first_e = 0; run_last_e = 0; prev_e = 0; win_start = 0; win_mah = 0
    run_sleep_s = 0; run_sleep_mah = 0; run_dark_s = 0; run_dark_mah = 0
    run_user_s = 0; run_user_mah = 0; n_dark = 0; n_gap = 0
}
function close_window(end_e,   dur) {
    if (win_start == 0) return
    dur = end_e - win_start
    if (dur <= darkwake_max) {
        run_dark_s += dur; run_dark_mah += win_mah
        n_dark++; d_iso[n_dark] = win_iso; d_start[n_dark] = win_start; d_dur[n_dark] = dur; d_mah[n_dark] = win_mah
    } else {
        run_user_s += dur; run_user_mah += win_mah
    }
    win_start = 0; win_mah = 0
}

NR == 1 { next }
$1 < since || $1 > until { next }
$7 == "Yes" { close_window(prev_e); close_run(); next }     # cắm sạc → đóng lượt
{
    e = $1; mah = $3; mv = $4
    if (prev_e > 0) {
        gap = e - prev_e; lost = prev_mah - mah
        if (gap <= awake_max) {
            if (win_start == 0) { win_start = prev_e; win_iso = prev_iso }
            win_mah += lost
        } else {
            close_window(prev_e)
            run_sleep_s += gap; run_sleep_mah += lost
            n_gap++; g_iso[n_gap] = prev_iso; g_dur[n_gap] = gap; g_mah[n_gap] = lost
        }
    }
    if (run_first_e == 0) { run_first_e = e; run_first_mah = mah; run_first_pct = $6; run_first_iso = $2 }
    run_last_e = e; run_last_mah = mah; run_last_pct = $6; run_last_mv = mv; run_last_iso = $2
    prev_e = e; prev_mah = mah; prev_iso = $2
}
END {
    close_window(prev_e); close_run()
    if (nrun == 0) { print "Không có lượt chạy pin nào (>10 phút) trong khoảng này."; exit }
    printf "\n----------------------------------------------------------------\n"
    printf "LƯU Ý ĐỌC SỐ: gauge pin chỉ làm mới sau vài phút, nên cửa sổ dark wake\n"
    printf "~50s thường hiện 0 mAh — phần điện nó tiêu bị dồn sang đoạn ngủ kế tiếp.\n"
    printf "Đoạn \"ngủ\" vì thế = ghi hibernate image + ngủ thật + đọc image lại.\n"
    printf "Không kết luận \"ngủ tốn nhiều hơn dark wake\" chỉ từ bảng này.\n"
}' "$LOG_FILE"
