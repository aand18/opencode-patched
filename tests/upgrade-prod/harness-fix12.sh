#!/usr/bin/env bash
# Fix-harness — reviewer findings 1 (argv[0] clobber) + 2 (symlink ownership),
# plus the full destructive path on a throwaway: real swap, VERDICT ok, the
# run that OWNS the swap moves the latest link.
set -u
REPO=/home/dev/opencode-patched
BIN_NEW=/home/dev/.opencode/bin/opencode-v2.2.6-latest-202611082100
BIN_OLD=/home/dev/.opencode/bin/opencode-v2.2.0-latest-202610290031
MODEL="${GATE_MODEL:-tabbyapi/Qwen3.8-Flash-Next-exl3-3.18bpw_h6_ng8}"
DB=/tmp/upgrade-prod-test.db
CFG=/tmp/upg-test-cfg.json
LG=/tmp/upg-test-lastgood
MARK=/tmp/upgrade-prod-marker.log
FAIL=0
TPID=$(ss -tlnpH | grep -oP ':4096\s.*pid=\K[0-9]+' | head -1)
PW=$(tr '\0' '\n' <"/proc/$TPID/environ" | sed -n 's/^OPENCODE_SERVER_PASSWORD=//p')
sqlite3 ~/.local/share/opencode/opencode.db ".backup $DB" || { echo "FAIL: backup"; exit 1; }
printf '%s\n' "$BIN_NEW" >"$LG"
python3 -c "import json;d={'binary':'$BIN_NEW','version':'2.2.6','flags':['serve'],'env':{},'port':4120,'cwd':'/tmp','note':'good'};open('$CFG','w').write(json.dumps(d))"
echo marker > "$MARK"; ln -sfn "$MARK" /tmp/upgrade-prod.log

start_throw () { # $1=binary
  mkdir -p /tmp/upg-bin && ln -sf "$1" /tmp/upg-bin/opencode
  setsid env OPENCODE_DB="$DB" OPENCODE_SERVER_PASSWORD="$PW" PATH="/tmp/upg-bin:$PATH" \
    bash -c 'exec opencode serve --hostname 127.0.0.1 --port 4120' </dev/null >/tmp/upg-throwaway.log 2>&1 &
  for i in $(seq 1 40); do ss -tlnpH | grep -q ':4120 ' && break; sleep 0.5; done
  ss -tlnpH | grep -q ':4120 ' || { echo "FAIL: throwaway ($1) down"; FAIL=1; }
}
stop_throw () { local p; p=$(ss -tlnpH | grep -oP ':4120\s.*pid=\K[0-9]+' | head -1); [[ -n "$p" ]] && { kill -TERM "$p" 2>/dev/null; sleep 2; kill -KILL "$p" 2>/dev/null; }; }

# --- A) argv[0]-clobber: check-only against bare-name throwaway
start_throw "$BIN_NEW"
WPID=$(ss -tlnpH | grep -oP ':4120\s.*pid=\K[0-9]+' | head -1)
echo "throwaway argv0=$(tr '\0' '\n' < "/proc/$WPID/cmdline" | head -1)"
RC=0; OUT=$(cd "$REPO" && ./scripts/upgrade-prod.sh "$BIN_NEW" --model "$MODEL" --check-only --dry-run --prod-port 4120 --config-file "$CFG" --last-good "$LG" 2>&1) || RC=$?
grep -q "REFRESH SKIPPED" <<<"$OUT" && { echo "FAIL: skipped instead of canonicalizing via exe"; FAIL=1; }
CB=$(python3 -c "import json;print(json.load(open('$CFG'))['binary'])")
[[ "$CB" == "$BIN_NEW" ]] || { echo "FAIL: cfg binary clobbered to '$CB'"; FAIL=1; }
[[ "$(cat "$LG")" == "$BIN_NEW" ]] || { echo "FAIL: last-good clobbered to '$(cat "$LG")'"; FAIL=1; }
[[ "$(readlink /tmp/upgrade-prod.log)" == "$MARK" ]] || { echo "FAIL: symlink hijacked by read-only run"; FAIL=1; }
stop_throw

# --- B) owner-moves-link + full destructive swap on the throwaway
start_throw "$BIN_OLD"
RC=0; OUT=$(cd "$REPO" && env -u OPENCODE_SESSION_ID ./scripts/upgrade-prod.sh "$BIN_NEW" --model "$MODEL" --foreground --prompt-timeout 180 --prod-port 4120 --config-file "$CFG" --last-good "$LG" 2>&1) || RC=$?
echo "swap rc=$RC"
[[ $RC -eq 0 ]] || { echo "FAIL: swap rc=$RC"; echo "$OUT" | tail -6; FAIL=1; }
grep -q "VERDICT: ok" <<<"$OUT" || { echo "FAIL: no ok verdict"; FAIL=1; }
[[ "$(readlink /tmp/upgrade-prod.log)" =~ /tmp/upgrade-prod-[0-9]{8}-[0-9]{6}\.log$ ]] || { echo "FAIL: owner did not move latest link"; FAIL=1; }
tail -n 1 "$(readlink /tmp/upgrade-prod.log)" | grep -q "VERDICT:" || { echo "FAIL: VERDICT not last line of run log"; FAIL=1; }
NEWPID=$(ss -tlnpH | grep -oP ':4120\s.*pid=\K[0-9]+' | head -1)
[[ "$(readlink /proc/$NEWPID/exe)" == "$BIN_NEW" ]] || { echo "FAIL: throwaway not on new binary"; FAIL=1; }
[[ "$(cat "$LG")" == "$BIN_NEW" ]] || { echo "FAIL: last-good not updated by swap"; FAIL=1; }
stop_throw
rm -f "$DB" "$DB-wal" "$DB-shm" /tmp/upg-throwaway.log "$MARK"
rm -rf /tmp/upg-bin /tmp/upgrade-prod.??????
[[ $FAIL -eq 0 ]] && { echo "HARNESS PASS"; exit 0; } || { echo "HARNESS FAIL"; exit 1; }