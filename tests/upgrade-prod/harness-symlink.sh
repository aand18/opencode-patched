#!/usr/bin/env bash
# PATH-symlink harness — step 8 must repoint the "latest" symlink to the
# verified binary, and --path-symlink must redirect it for testing.
# Section A: full destructive swap on a throwaway :4120 with a temp symlink.
# RED now: --path-symlink is an unknown flag (eaten as a positional -> abort).
# Section B/C: prod read-only sanity (check-only, dry-run) unaffected.
set -u
REPO=/home/dev/opencode-patched
BIN_NEW=/home/dev/.opencode/bin/opencode-v2.2.6-latest-202611082100
BIN_OLD=/home/dev/.opencode/bin/opencode-v2.2.0-latest-202610290031
MODEL="${GATE_MODEL:-tabbyapi/Qwen3.8-Flash-Next-exl3-3.18bpw_h6_ng8}"
DB=/tmp/upgrade-prod-test.db
CFG=/tmp/upgt-cfg.json
LG=/tmp/upgt-lg
LINK=/tmp/upgt-link
FAIL=0
TPID=$(ss -tlnpH | grep -oP ':4096\s.*pid=\K[0-9]+' | head -1)
PW=$(tr '\0' '\n' <"/proc/$TPID/environ" | sed -n 's/^OPENCODE_SERVER_PASSWORD=//p')
sqlite3 ~/.local/share/opencode/opencode.db ".backup $DB" || { echo "FAIL: backup"; exit 1; }
printf '%s\n' "$BIN_OLD" >"$LG"
python3 -c "import json;d={'binary':'$BIN_OLD','version':'2.2.0','flags':['serve'],'env':{},'port':4120,'cwd':'/tmp','note':'harness'};open('$CFG','w').write(json.dumps(d))"
ln -sfn "$BIN_OLD" "$LINK"

# A) full swap on the throwaway; owner repoints the symlink
setsid env OPENCODE_DB="$DB" OPENCODE_SERVER_PASSWORD="$PW" bash -c \
  "exec $BIN_OLD serve --hostname 127.0.0.1 --port 4120" </dev/null >/tmp/upgt-throw.log 2>&1 &
for i in $(seq 1 40); do ss -tlnpH | grep -q ':4120 ' && break; sleep 0.5; done
ss -tlnpH | grep -q ':4120 ' || { echo "FAIL: throwaway down"; exit 1; }
RC=0
OUT=$(cd "$REPO" && env -u OPENCODE_SESSION_ID ./scripts/upgrade-prod.sh "$BIN_NEW" --model "$MODEL" \
  --foreground --prompt-timeout 180 --prod-port 4120 --config-file "$CFG" --last-good "$LG" \
  --path-symlink "$LINK" 2>&1) || RC=$?
echo "A: swap rc=$RC"
[[ $RC -eq 0 ]] || { echo "FAIL: swap rc=$RC"; echo "$OUT" | tail -5; FAIL=1; }
[[ "$(readlink "$LINK")" == "$BIN_NEW" ]] || { echo "FAIL: symlink not repointed ($(readlink "$LINK"))"; FAIL=1; }
grep -q "symlink repointed" <<<"$OUT" || { echo "FAIL: no repoint log line"; FAIL=1; }
p=$(ss -tlnpH | grep -oP ':4120\s.*pid=\K[0-9]+' | head -1); [[ -n "$p" ]] && { kill -TERM "$p" 2>/dev/null; sleep 2; kill -KILL "$p" 2>/dev/null; }

# B) check-only sanity against live prod (read-only)
RC=0; (cd "$REPO" && ./scripts/upgrade-prod.sh "$BIN_NEW" --model "$MODEL" --check-only >/dev/null 2>&1) || RC=$?
echo "B: check-only rc=$RC"; [[ $RC -eq 0 ]] || { echo "FAIL: check-only broke"; FAIL=1; }

# C) dry-run sanity against live prod
RC=0; (cd "$REPO" && ./scripts/upgrade-prod.sh "$BIN_NEW" --model "$MODEL" --prompt-timeout 180 --dry-run >/dev/null 2>&1) || RC=$?
echo "C: dry-run rc=$RC"; [[ $RC -eq 0 ]] || { echo "FAIL: dry-run broke"; FAIL=1; }

# the REAL symlink must be untouched by all of the above
[[ "$(readlink ~/.opencode/bin/opencode)" == /home/dev/.opencode/bin/opencode-v2.3.2-latest-202611191829 ]] \
  || { echo "FAIL: real PATH symlink touched!"; FAIL=1; }

rm -f "$DB" "$DB-wal" "$DB-shm" /tmp/upgt-throw.log "$CFG" "$LG" "$LINK"
rm -rf /tmp/upgrade-prod.??????
[[ $FAIL -eq 0 ]] && { echo "HARNESS PASS"; exit 0; } || { echo "HARNESS FAIL"; exit 1; }