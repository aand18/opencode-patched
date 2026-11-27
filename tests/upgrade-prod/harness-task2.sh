#!/usr/bin/env bash
# Task 2 harness — per-run log + dated timestamps + verdict sentinel.
# RED first: current code appends to a single /tmp/upgrade-prod.log with
# clock-only stamps and no VERDICT line. Runs a prod-untouched --dry-run.
set -u
REPO=/home/dev/opencode-patched
BIN_OLD=/home/dev/.opencode/bin/opencode-v2.2.0-latest-202610290031
MODEL="${GATE_MODEL:-tabbyapi/Qwen3.8-Flash-Next-exl3-3.18bpw_h6_ng8}"
rm -f /tmp/upgrade-prod.log /tmp/upgrade-prod-*.log
PID0=$(ss -tlnpH | grep -oP ':4096\s.*pid=\K[0-9]+' | head -1)
RC=0
OUT=$(cd "$REPO" && ./scripts/upgrade-prod.sh "$BIN_OLD" --model "$MODEL" --prompt-timeout 180 --dry-run 2>&1) || RC=$?
echo "run rc=$RC"
FAIL=0
# 1) per-run log file created (latest-symlink ownership is covered in harness-fix12)
ls -t /tmp/upgrade-prod-*.log 2>/dev/null | head -1
TARGET=$(ls -t /tmp/upgrade-prod-*.log 2>/dev/null | head -1)
[[ -f "$TARGET" ]] || { echo "FAIL: no per-run log"; FAIL=1; }
# 2) dated timestamps
grep -qE '^\[[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]' "$TARGET" 2>/dev/null || { echo "FAIL: no dated timestamps"; FAIL=1; }
# 3) verdict sentinel, final line of the run log
grep -q 'VERDICT: ' "$TARGET" 2>/dev/null || { echo "FAIL: no VERDICT line"; FAIL=1; }
tail -n 1 "$TARGET" 2>/dev/null | grep -q 'VERDICT:' || { echo "FAIL: VERDICT not last line"; FAIL=1; }
# 4) prod untouched
PID1=$(ss -tlnpH | grep -oP ':4096\s.*pid=\K[0-9]+' | head -1)
[[ "$PID0" == "$PID1" ]] || { echo "FAIL: prod pid changed $PID0 -> $PID1"; FAIL=1; }
ss -tlnpH | grep -q ':4097 ' && { echo "FAIL: dev listener left on :4097"; FAIL=1; }
rm -rf /tmp/upgrade-prod.??????
if [[ $FAIL -eq 0 && $RC -eq 0 ]]; then echo "HARNESS PASS"; exit 0; else echo "HARNESS FAIL"; exit 1; fi