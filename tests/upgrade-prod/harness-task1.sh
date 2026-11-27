#!/usr/bin/env bash
# Task 1 harness — artifact refresh from live prod.
# RED on purpose: temp artifacts deliberately describe a DIFFERENT binary;
# after the run they must describe the live throwaway (:4120) and the log
# must show the refresh. Also asserts step 1b is skipped for :4120 and the
# dry-run completed without stopping the throwaway.
set -u
REPO=/home/dev/opencode-patched
BIN_LIVE=/home/dev/.opencode/bin/opencode-v2.2.6-latest-202611082100
BIN_OLD=/home/dev/.opencode/bin/opencode-v2.2.0-latest-202610290031
CFG=/tmp/upg-test-cfg.json
LG=/tmp/upg-test-lastgood
DB=/tmp/upgrade-prod-test.db
THROW=/tmp/upg-throwaway.log
DEVPORT_PID=$(ss -tlnpH 2>/dev/null | grep -oP ':4120\s.*pid=\K[0-9]+' | head -1)
if [[ -n "$DEVPORT_PID" ]]; then echo "FAIL: :4120 already in use (pid $DEVPORT_PID)"; exit 1; fi

# prod password (never echoed)
TPID=$(ss -tlnpH 2>/dev/null | grep -oP ':4096\s.*pid=\K[0-9]+' | head -1)
PW=$(tr '\0' '\n' <"/proc/$TPID/environ" | sed -n 's/^OPENCODE_SERVER_PASSWORD=//p')
# Gate model: resolve the calling session's live model (recipe as in
# upgrade-prod.sh step 1b / probe.py session-model; never a remembered one —
# the pinned opencode-go/crouton-alpha-free died with its provider in Nov).
MODEL="${GATE_MODEL:-}"
if [[ -z "$MODEL" && -n "${OPENCODE_SESSION_ID:-}" ]]; then
  NRC=$(mktemp /tmp/.h1nrc.XXXXXX); chmod 600 "$NRC"
  printf 'machine localhost login opencode password %s\n' "$PW" >"$NRC"
  MODEL=$(curl -s -n --netrc-file "$NRC" "http://localhost:4096/api/session/$OPENCODE_SESSION_ID" \
    | python3 -c 'import json,sys; m=(json.load(sys.stdin).get("data") or {}).get("model") or {}; print((m.get("providerID") or "")+"/"+(m.get("id") or m.get("modelID") or ""))' \
    | grep '/' || true)
  rm -f "$NRC"
fi
MODEL="${MODEL:-tabbyapi/Qwen3.8-Flash-Next-exl3-3.18bpw_h6_ng8}"
echo "gate model: $MODEL"
sqlite3 "$HOME/.local/share/opencode/opencode.db" ".backup $DB" || { echo "FAIL: backup"; exit 1; }

# stale artifacts claiming a binary that is NOT running
printf 'x' >/dev/null
python3 - "$CFG" <<'PY'
import json, os, sys
path = sys.argv[1]
data = {"binary": "/home/dev/.opencode/bin/STALE-NOT-RUNNING", "version": "0.0.0",
        "flags": ["serve"], "env": {}, "port": 4120, "cwd": "/tmp",
        "note": "harness stale marker"}
tmp = path + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
import io
with os.fdopen(fd, "w") as fh: json.dump(data, fh)
os.replace(tmp, path); os.chmod(path, 0o600)
PY
echo "$BIN_OLD" >"$LG"

# start throwaway
setsid env OPENCODE_DB="$DB" OPENCODE_SERVER_PASSWORD="$PW" BIN_LIVE="$BIN_LIVE" \
  bash -c 'exec "$BIN_LIVE" serve --hostname 127.0.0.1 --port 4120' </dev/null >"$THROW" 2>&1 &
THROW_PID=$!
for i in $(seq 1 40); do ss -tlnpH 2>/dev/null | grep -q ':4120 ' && break; sleep 0.5; done
ss -tlnpH | grep -q ':4120 ' || { echo "FAIL: throwaway did not bind :4120"; tail -5 "$THROW"; exit 1; }

# run dry-run against the throwaway
RC=0
OUT=$(cd "$REPO" && ./scripts/upgrade-prod.sh "$BIN_OLD" --model "$MODEL" \
  --dry-run --prompt-timeout 180 --prod-port 4120 --config-file "$CFG" --last-good "$LG" 2>&1) || RC=$?
echo "run rc=$RC"
FAIL=0
grep -q "Verifying caller session model" <<<"$OUT" && { echo "FAIL: step 1b ran for :4120"; FAIL=1; }
grep -q "refreshed from live prod" <<<"$OUT" || { echo "FAIL: no refresh log line"; FAIL=1; }
grep -q "WARN:" <<<"$OUT" || { echo "FAIL: no stale WARN"; FAIL=1; }
python3 -c "import json,sys; d=json.load(open('$CFG')); sys.exit(0 if d['binary']=='$BIN_LIVE' else 1)" \
  || { echo "FAIL: cfg not refreshed to live binary"; FAIL=1; }
grep -qF "$BIN_LIVE" "$LG" || { echo "FAIL: last-good not refreshed"; FAIL=1; }
ss -tlnpH | grep -q ':4120 ' || { echo "FAIL: throwaway was stopped"; FAIL=1; }

# cleanup
TPID=$(ss -tlnpH 2>/dev/null | grep -oP ':4120\s.*pid=\K[0-9]+' | head -1)
[[ -n "$TPID" ]] && kill -TERM "$TPID" 2>/dev/null
sleep 2; kill -KILL "$TPID" 2>/dev/null
rm -f "$DB" "$DB-wal" "$DB-shm"
if [[ $FAIL -eq 0 && $RC -eq 0 ]]; then echo "HARNESS PASS"; exit 0; else echo "HARNESS FAIL"; exit 1; fi