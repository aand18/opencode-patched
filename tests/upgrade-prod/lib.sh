#!/usr/bin/env bash
# lib.sh — shared bootstrap for the upgrade-prod.sh test cases. SOURCED, never run.
#
# One canonical copy of everything the old per-ticket harnesses each carried their
# own variant of (review 2026-11-27 §3): prod password extraction, gate-model
# resolution, throwaway start/stop on :4120, the 0600 artifact fixture writer,
# the sqlite .backup wrapper, residue cleanup, and the PATH-symlink guard.
#
# Hard rules this file enforces (each maps to an incident, review §1/§6):
#  - No harness ever passes the default --path-symlink: every invocation goes
#    through run_upgrade, which pins --path-symlink to a per-case link (or "" to
#    disable). harness-fix12.sh section B forgot it and downgraded
#    ~/.opencode/bin/opencode to v2.2.6 (L1). real_path_symlink_unchanged
#    asserts the real link is identical before and after the run.
#  - No full-size DB copy unless a case explicitly asks: backup_real_db is the
#    ONLY function that copies the prod DB, and every copy — ours or the
#    script's — is tallied (copies_total / copies_fullsize). Mechanics, guard and
#    preflight cases boot fresh empty DBs, so the default run writes kilobytes of
#    throwaway schema and zero full-size copies; run.sh asserts both.
#  - No real secret in a harness artifact: throwaways boot with a random harness
#    password, so the cfg the script refreshes (it stores captured env, note:
#    "contains secrets") carries a throwaway secret, never the prod password
#    (L3). The prod password is read only to resolve the gate model, through a
#    0600 netrc temp file — never on a command line.
#  - Cleanup removes what the suite created, and only that: per-run logs and
#    script tmp dirs are reaped by set-diff against the baseline taken before
#    the first run. task2 deleted the operator's /tmp/upgrade-prod.log and its
#    `rm -f /tmp/upgrade-prod-*.log` glob could destroy a concurrent real
#    upgrade's audit log; harness-task2 also stranded the operator log link.
#  - No remembered model pins (AGENTS.md: "never reuse a remembered model"):
#    gate_model returns only a live-resolved value. The five copies of the old
#    hardcoded provider/model fallback pin are gone.

[[ -n "${_UPG_LIB_LOADED:-}" ]] && return 0
_UPG_LIB_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$LIB_DIR/../.." && pwd)"   # run.sh's recipe, not a hardcoded path (§6.11)

LIVE_DB="$HOME/.local/share/opencode/opencode.db"
REAL_PATH_SYMLINK="$HOME/.opencode/bin/opencode"   # the script's default step-8 target
LOG_LINK="/tmp/upgrade-prod.log"                   # the operator's follow-me link
LEGACY_DB="/tmp/upgrade-prod-test.db"              # the name review §4.8 asserts is gone
# The suite's scratch root: teardown is one directory, and the prefix sits in the
# /tmp/upg* family that assert_no_strays sweeps.
SUITE_ROOT="${SUITE_ROOT:-/tmp/upg-harness}"
STATE="$SUITE_ROOT/state"
H_RUN="$SUITE_ROOT/run"                            # per-invocation binary shims

# case_root NAME — one dir per case for throwaway DBs, cfg, last-good, the temp
# swap symlink, boot logs and the seed backup; registered for teardown, so the
# "$DB".bak.* files (the 4.88 GB orphans that stranded in /tmp, review L2) can
# never survive a run.
case_root() {
  H_CASE="${H_CASE_ROOT:-$SUITE_ROOT/cases}/$1"
  export H_CASE
  rm -rf "$H_CASE"; mkdir -p "$H_CASE"
  printf '%s\n' "$H_CASE" >>"$STATE/cases"
  printf '%s\n' "$H_CASE"
}

# Staged binaries the cases rehearse with. If one is ever pruned from
# ~/.opencode/bin, restore it or override the variable before running.
BIN_OLD="${BIN_OLD:-$HOME/.opencode/bin/opencode-v2.2.0-latest-202610290031}"    # throwaway "prod"
BIN_MID="${BIN_MID:-$HOME/.opencode/bin/opencode-v2.2.6-latest-202611082100}"    # swap target
BIN_V232="${BIN_V232:-$HOME/.opencode/bin/opencode-v2.3.2-latest-202611191829}"  # what real prod runs
require_bins() {
  local b
  for b in "$BIN_OLD" "$BIN_MID" "$BIN_V232"; do
    [[ -x "$b" ]] || { echo "FAIL: staged binary missing or not executable: $b (restore it or set BIN_OLD/BIN_MID/BIN_V232)" >&2; return 1; }
  done
}

_case_name=${CASE_NAME:-$(basename "${0%.sh}")}

# ---------- accounting -------------------------------------------------------
# fail() replaces the old per-harness FAIL ladders: run.sh reads $STATE/failures
# and only prints ALL GREEN when it is empty.
fail() { echo "FAIL[$_case_name]: $*"; printf '%s\n' "$*" >>"$STATE/failures"; }
pass() { echo "  ok: $*"; }

# ---------- prod discovery / password (single copy; was x4) ------------------
listener_pid() { ss -tlnpH 2>/dev/null | grep -oP ":$1\s.*pid=\K[0-9]+" | head -1 || true; }
prod_pid() { listener_pid 4096; }

# prod_password: echoes the live server's password. Call it only into a 0600
# file or a bash variable — never into a spawned process's argv.
prod_password() {
  local p; p=$(prod_pid)
  [[ -n "$p" ]] || { echo "FAIL: prod :4096 is not listening — the suite needs the live server (the gate model and the read-only preflight resolve from it)" >&2; return 1; }
  tr '\0' '\n' <"/proc/$p/environ" | sed -n 's/^OPENCODE_SERVER_PASSWORD=//p' | head -1
}

# api_get PORT PASSWORD PATH — basic-auth GET. Auth goes through a 0600 netrc
# temp file, so the password never appears on a command line or in ps.
api_get() {
  local port=$1 pw=$2 path=$3 nrc rc=0
  nrc=$(mktemp "$STATE/nrc.XXXXXX"); chmod 600 "$nrc"
  printf 'machine localhost login opencode password %s\n' "$pw" >"$nrc"
  curl -s -n --netrc-file "$nrc" "http://localhost:$port$path" || rc=$?
  rm -f "$nrc"
  return $rc
}

# ---------- gate model (single copy; zero fallback pins) ---------------------
# Resolution order: exported GATE_MODEL > $OPENCODE_SESSION_ID's model on live
# prod (the AGENTS.md recipe) > the newest live prod session whose model is
# still offered by /api/model — a live resolve, which is what lets a
# standalone/cron run (no session id) work without a remembered model.
# Also exports HARNESS_SESSION_ID: the wrong-model case needs a session id that
# really exists on prod, or step 1b is skipped and the abort cannot fire (the
# old task3 test only passed when OPENCODE_SESSION_ID happened to be set).
resolve_gate_model() {
  [[ -n "${GATE_MODEL_RESOLVED:-}" ]] && return 0
  mkdir -p "$STATE"
  local pw src
  HARNESS_SESSION_ID="${OPENCODE_SESSION_ID:-}"
  if [[ -z "${GATE_MODEL:-}" ]]; then
    [[ -n "$HARNESS_SESSION_ID" ]] || HARNESS_SESSION_ID=$(prod_session_newest || true)
    [[ -n "$HARNESS_SESSION_ID" ]] || { echo "FAIL: cannot resolve a gate model — export GATE_MODEL=<providerID/modelID>, run under an opencode session, or start prod :4096" >&2; return 1; }
    pw=$(prod_password) || return 1
    [[ -n "$pw" ]] || { echo "FAIL: the prod :4096 process does not carry OPENCODE_SERVER_PASSWORD" >&2; return 1; }
    GATE_MODEL=$(session_model_authed "$pw" "$HARNESS_SESSION_ID")
    src="session $HARNESS_SESSION_ID"
    [[ -n "${OPENCODE_SESSION_ID:-}" ]] || src="newest live prod session $HARNESS_SESSION_ID (no OPENCODE_SESSION_ID in this environment)"
    echo "gate model: ${GATE_MODEL:-<unresolved>} ($src)" >&2
  fi
  if [[ "${GATE_MODEL:-}" != */* || -z "${GATE_MODEL%%/*}" || -z "${GATE_MODEL##*/}" ]]; then
    echo "FAIL: gate model unresolved ('${GATE_MODEL:-}'). The suite is session-bound: run it from an opencode session or export a live GATE_MODEL. No fallback pin is kept on purpose (AGENTS.md: never reuse a remembered model)." >&2
    return 1
  fi
  export GATE_MODEL GATE_MODEL_RESOLVED=1 HARNESS_SESSION_ID
}

# session_model_authed PW SID — prints providerID/modelID, or "/-" when the
# session is gone or has no model.
session_model_authed() {
  api_get 4096 "$1" "/api/session/$2" | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
m = (d.get("data") or {}).get("model") or {}
prov = m.get("providerID") or ""
mid = m.get("id") or m.get("modelID") or ""
print((prov + "/" + mid) if prov and mid else "/-")'
}

# prod_session_newest — newest prod session whose model is still offered.
# Reads both endpoints with netrc auth; the password reaches no argv.
prod_session_newest() {
  local pw dir tmp out
  pw=$(prod_password) || return 1
  tmp=$(mktemp -d "$STATE/sess.XXXXXX"); chmod 700 "$tmp"
  dir=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$REPO")
  api_get 4096 "$pw" "/api/model?directory=$dir" >"$tmp/models.json"
  api_get 4096 "$pw" "/api/session?directory=$dir" >"$tmp/sessions.json"
  out=$(python3 - "$tmp/models.json" "$tmp/sessions.json" <<'PY'
import json
def load(p):
    try:
        with open(p) as fh:
            return json.load(fh).get("data") or []
    except Exception:
        return []
offered = {(m.get("providerID"), m.get("modelID", m.get("id"))) for m in load(__import__("sys").argv[1])}
best, best_t = "", -1
for s in load(__import__("sys").argv[2]):
    m = s.get("model") or {}
    key = (m.get("providerID"), m.get("modelID", m.get("id")))
    t = (s.get("time") or {}).get("updated") or (s.get("time") or {}).get("created") or 0
    if key in offered and str(s.get("id") or "").startswith("ses") and t > best_t:
        best, best_t = s["id"], t
print(best)
PY
)
  rm -rf "$tmp"
  printf '%s\n' "$out"
}

# ---------- port preflight ---------------------------------------------------
# The script hardcodes DEV_PORT=4097 (§6.8): a real swap in flight owns it and
# two suite runs cannot overlap. Refuse before the first case, not mid-run.
require_port_free() {
  local port=$1 pid
  pid=$(listener_pid "$port")
  [[ -z "$pid" ]] || { echo "FAIL: port :$port is owned by pid $pid ($(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | head -c 120)) — a real swap or another suite run owns it; refusing to run" >&2; return 1; }
}

# ---------- artifact fixtures ------------------------------------------------
# write_cfg FILE BINARY VERSION PORT — atomic 0600 writer (was three variants),
# same shape as the script's own config file.
write_cfg() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import json, os, sys
path, binary, version, port = sys.argv[1:5]
data = {"binary": binary, "version": version, "flags": ["serve"], "env": {},
        "port": int(port), "cwd": "/tmp", "note": "harness fixture"}
tmp = path + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as fh:
    json.dump(data, fh)
os.replace(tmp, path); os.chmod(path, 0o600)
PY
}

# ---------- DB ---------------------------------------------------------------
# backup_real_db TARGET — the only full-size copy in the suite, and the only
# place the prod DB is read into a file. Online backup API only (a cp misses the
# WAL tail). Tallied so run.sh can report the run's byte cost.
backup_real_db() {
  local target=$1
  sqlite3 "$LIVE_DB" ".backup $target" || { fail "sqlite3 online backup of the prod DB failed"; return 1; }
  tally_copy "$target"
}

# tally_copy PATH — record one .backup's bytes under the current TALLY_LABEL.
tally_copy() {
  local sz; sz=$(stat -c%s "$1" 2>/dev/null || echo 0)
  printf '%s\t%s\t%s\n' "$sz" "${TALLY_LABEL:-harness}" "$1" >>"$STATE/copies.tsv"
}

# tally_copies OUT SRC_DB — every "Dev DB:" / "DB backup:" line in a run's output
# is one copy the script performed of SRC_DB; the source size is what got written.
# The dev copy itself is deleted with the script's tmp dir, so the source is the
# evidence.
tally_copies() {
  local out=$1 db=$2 path sz
  [[ -n "$db" ]] || return 0
  sz=$(stat -c%s "$db" 2>/dev/null || echo 0)
  while read -r path; do
    [[ -n "$path" ]] || continue
    printf '%s\t%s\t%s\n' "$sz" "${TALLY_LABEL:-script}" "$path" >>"$STATE/copies.tsv"
  done < <(grep -oP '^\[[^]]*\] (Dev DB|DB backup): \K\S+' <<<"$out" || true)
}

# copies_total — "<bytes> <count>" of every tallied copy.
copies_total() {
  [[ -s "$STATE/copies.tsv" ]] || { echo "0 0"; return 0; }
  awk -F'\t' '{b+=$1; n++} END {printf "%d %d\n", b+0, n+0}' "$STATE/copies.tsv"
}

# copies_fullsize — how many tallied copies were FULL-SIZE (>=1 GB): the number
# the wear budget is about. A mechanics case copying a 4 KB throwaway db is a
# copy operation, not a full-size copy.
copies_fullsize() {
  [[ -s "$STATE/copies.tsv" ]] || { echo 0; return 0; }
  awk -F'\t' '$1 >= 1073741824 {n++} END {print n+0}' "$STATE/copies.tsv"
}

# wal_tail_synthetic — on a throwaway DB, prove that the online backup API
# carries an UNCHECKPOINTED WAL frame while a plain cp of the same file does
# not. This is the assertion behind AGENTS.md's 2026-08-09 finding and behind
# every .backup the script performs; it costs kilobytes and is deterministic.
# Non-vacuity is built in: the writer connection is held open over a fifo so no
# checkpoint-on-close can run, and the marker is grep-proved absent from the
# main file and present in the -wal before either copy is taken.
wal_tail_synthetic() {
  local dir=$1 nonce=$2
  local w="$dir/waltail.db" cp="$dir/waltail-cp.db" bak="$dir/waltail-backup.db"
  local fifo="$dir/waltail.fifo" wpid got in_main in_wal in_cp
  rm -f "$w" "$w-wal" "$w-shm" "$cp" "$bak" "$fifo"
  mkfifo "$fifo"
  sqlite3 "$w" "PRAGMA journal_mode=WAL; CREATE TABLE t(x text);" </dev/null >/dev/null 2>&1
  sqlite3 "$w" <"$fifo" >/dev/null 2>&1 &
  wpid=$!
  exec 9>"$fifo"                       # keep the writer open: no checkpoint-on-close
  printf "INSERT INTO t(x) VALUES('WALTAIL-%s');\n" "$nonce" >&9
  sleep 1
  in_main=$(grep -ac "WALTAIL-$nonce" "$w" 2>/dev/null || true); in_main=${in_main:-0}
  in_wal=$(grep -ac "WALTAIL-$nonce" "$w-wal" 2>/dev/null || true); in_wal=${in_wal:-0}
  sqlite3 "$w" ".backup $bak" || { exec 9>&-; fail "wal-tail: .backup of the throwaway WAL db failed"; return 1; }
  cp "$w" "$cp"
  printf '.quit\n' >&9; exec 9>&-; wait "$wpid" 2>/dev/null || true
  got=$(sqlite3 "$bak" "select x from t;" 2>/dev/null || true)
  in_cp=$(sqlite3 "$cp" "select count(*) from t where x='WALTAIL-$nonce';" 2>/dev/null || echo err)
  [[ "$in_main" == "0" ]] || { fail "wal-tail: marker already in the main db file ($in_main hits) — the check would be vacuous"; return 1; }
  (( in_wal >= 1 )) || { fail "wal-tail: marker not in $w-wal — nothing was un-checkpointed, the check is vacuous"; return 1; }
  [[ "$got" == "WALTAIL-$nonce" ]] || { fail "wal-tail: the .backup copy lost the un-checkpointed row (got '${got:-none}')"; return 1; }
  [[ "$in_cp" == "0" ]] || { fail "wal-tail: the cp'd file contains the row ($in_cp) — cp-vs-backup contrast is vacuous"; return 1; }
  pass "wal-tail: an un-checkpointed WAL row lands in the .backup copy and is absent from a cp of the same file"
}

# ---------- throwaway server -------------------------------------------------
# Harness password for throwaways: random, so artifacts refreshed by the script
# never capture the real prod password.
harness_pw() {
  if [[ ! -s "$STATE/hpw" ]]; then
    ( umask 077; head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$STATE/hpw" )
  fi
  cat "$STATE/hpw"
}

# start_throwaway BIN PORT DB [shim] — boots `BIN serve` on PORT with
# OPENCODE_DB=DB (a fresh path auto-creates its own schema: ~4 KB, no copy) and
# the harness password. shim=1 puts a PATH shim named "opencode" first so
# argv[0] is a bare name (the argv[0]-clobber case).
start_throwaway() {
  local bin=$1 port=$2 db=$3 shim=${4:-0} log pre
  pre=$(listener_pid "$port")
  [[ -z "$pre" ]] || { fail ":$port already in use (pid $pre) before start_throwaway"; return 1; }
  [[ -z "$(listener_pid 4097)" ]] || { fail ":4097 (the script's dev port) is busy before start_throwaway"; return 1; }
  log="$H_CASE/throwaway-$port.log"
  if [[ "$shim" == "1" ]]; then
    mkdir -p "$H_CASE/shim"
    ln -sfn "$bin" "$H_CASE/shim/opencode"
    setsid env OPENCODE_DB="$db" OPENCODE_SERVER_PASSWORD="$(harness_pw)" \
      PATH="$H_CASE/shim:$PATH" \
      bash -c 'exec opencode serve --hostname 127.0.0.1 --port "'"$port"'"' \
      </dev/null >"$log" 2>&1 &
  else
    setsid env OPENCODE_DB="$db" OPENCODE_SERVER_PASSWORD="$(harness_pw)" \
      bash -c 'exec "'"$bin"'" serve --hostname 127.0.0.1 --port "'"$port"'"' \
      </dev/null >"$log" 2>&1 &
  fi
  local i
  for i in $(seq 1 60); do [[ -n "$(listener_pid "$port")" ]] && break; sleep 0.5; done
  [[ -n "$(listener_pid "$port")" ]] || { fail "throwaway ($bin) did not bind :$port within 30s (log $log)"; tail -5 "$log" 2>/dev/null; return 1; }
  echo "$port" >>"$STATE/ports"
}

stop_throwaway() {
  local port=$1 i p
  p=$(listener_pid "$port")
  [[ -n "$p" ]] || return 0
  kill -TERM "$p" 2>/dev/null || true
  for i in $(seq 1 8); do kill -0 "$p" 2>/dev/null || break; sleep 0.5; done
  kill -KILL "$p" 2>/dev/null || true
  sleep 1
  [[ -z "$(listener_pid "$port")" ]] || fail ":$port still listening after stop_throwaway"
}

# exe_of PORT — canonical binary path of the listener on PORT.
exe_of() { local p; p=$(listener_pid "$1"); [[ -n "$p" ]] && readlink "/proc/$p/exe" || true; }

# ---------- running the script under test ------------------------------------
# harness_bin_link BIN — a per-invocation unique path for the new binary. The
# script logs this pre-canonicalization path in its first log line, which is
# what lets cleanup prove that a given /tmp/upgrade-prod-*.log belongs to us.
harness_bin_link() {
  local real tag link
  real=$(readlink -f "$1")
  mkdir -p "$H_RUN/bin"
  tag="$(basename "$real").$$.$RANDOM"
  link="$H_RUN/bin/$tag"
  ln -sfn "$real" "$link"
  printf '%s\n' "$link"
}

# swap_arg — decides the step-8 target and stores it in SWAP_ARG; every
# invocation must state its intent (an unset choice is a harness bug, not a
# default: leaving it to the script's default is exactly what moved the real
# ~/.opencode/bin/opencode in the fix12 incident).
swap_arg() {
  if [[ -n "${SWAP_SYMLINK:-}" ]]; then
    SWAP_ARG="$SWAP_SYMLINK"
  elif [[ -n "${NO_SWAP_SYMLINK:-}" ]]; then
    SWAP_ARG=""
  else
    fail "internal: an invocation that can reach step 8 must set SWAP_SYMLINK or NO_SWAP_SYMLINK"
    return 1
  fi
}

# run_upgrade BIN [script flags...] — the ONLY way a case invokes
# scripts/upgrade-prod.sh. Pins the step-8 target on every call (SWAP_SYMLINK
# repoints a temp link; NO_SWAP_SYMLINK=1 disables step 8), tallies the DB
# copies the run performed, and exports LAST_OUT / LAST_RC.
# Extra env for the child goes in RUN_UPGRADE_ENV (NAME=VALUE list).
run_upgrade() {
  local bin=$1; shift
  local link out rc=0
  link=$(harness_bin_link "$bin")
  swap_arg || return 1
  mkdir -p "$H_CASE"
  out=$(cd "$REPO" && env ${RUN_UPGRADE_ENV[@]+"${RUN_UPGRADE_ENV[@]}"} \
    "$REPO/scripts/upgrade-prod.sh" "$link" "$@" --path-symlink "$SWAP_ARG" 2>&1) || rc=$?
  tally_copies "$out" "${TALLY_DB:-}"
  LAST_OUT="$out"; export LAST_OUT
  LAST_RC=$rc; export LAST_RC
  printf '%s\n' "$out"
  return $rc
}

# run_upgrade_bg / wait_upgrade_bg — the same pinned invocation in the
# background, for the one case that must act *during* a run (the rollback case
# signals the script after prod is stopped). Output lands in $BG_LOG.
run_upgrade_bg() {
  local bin=$1; shift
  local link
  link=$(harness_bin_link "$bin")
  swap_arg || return 1
  mkdir -p "$H_CASE"
  BG_LOG="$H_CASE/swap.out"; export BG_LOG
  : >"$BG_LOG"
  ( cd "$REPO" && exec env ${RUN_UPGRADE_ENV[@]+"${RUN_UPGRADE_ENV[@]}"} \
      "$REPO/scripts/upgrade-prod.sh" "$link" "$@" --path-symlink "$SWAP_ARG" \
  ) >"$BG_LOG" 2>&1 &
  BG_PID=$!; export BG_PID
}

wait_upgrade_bg() {
  local rc=0
  wait "$BG_PID" || rc=$?
  LAST_OUT=$(cat "$BG_LOG" 2>/dev/null || true); export LAST_OUT
  LAST_RC=$rc; export LAST_RC
  tally_copies "$LAST_OUT" "${TALLY_DB:-}"
  return $rc
}

# last_run_log — the newest per-run log owned by this suite (ownership proven by
# the binary-shim marker inside the file, never by a glob).
last_run_log() {
  logs_new
  local f newest="" nm=0 m
  while read -r f; do
    [[ -n "$f" && -f "$f" ]] || continue
    m=$(stat -c%Y "$f")
    if (( m > nm )) || { (( m == nm )) && [[ "$f" > "$newest" ]]; }; then nm=$m; newest=$f; fi
  done <"$STATE/logs"
  printf '%s\n' "$newest"
}

# ---------- cleanup ----------------------------------------------------------
# Baselines are taken ONCE by run.sh so they exclude anything the cases create;
# they are what makes "clean only what you created" checkable.
suite_baselines() {
  mkdir -p "$STATE" "$H_RUN/bin" "$SUITE_ROOT/cases"
  [[ -e "$STATE/initialized" ]] && return 0
  : >"$STATE/copies.tsv"; : >"$STATE/logs"; : >"$STATE/failures"; : >"$STATE/ports"; : >"$STATE/cases"; : >"$STATE/dbs"
  ls -1 /tmp/upgrade-prod-*.log 2>/dev/null | sort >"$STATE/logs.before" || true
  ls -1 /tmp/opencode-prod-relaunch-*.log 2>/dev/null | sort >"$STATE/relaunch.before" || true
  # >1 GB files already in /tmp, so the default run's "no full-size copy" check
  # compares against the world as it found it (the prod DB backups live elsewhere).
  find /tmp -maxdepth 1 -type f -size +1G 2>/dev/null | sort >"$STATE/bigfiles.before" || true
  if [[ -L "$LOG_LINK" ]]; then readlink "$LOG_LINK" >"$STATE/loglink.before"; else : >"$STATE/loglink.before"; fi
  readlink "$REAL_PATH_SYMLINK" >"$STATE/symlink.before" 2>/dev/null || : >"$STATE/symlink.before"
  date +%s >"$STATE/start"
  touch "$STATE/initialized"
}

# logs_new — per-run logs created since the baseline that name our binary shim
# dir. The content marker is the ownership proof that lets cleanup delete them
# without touching a concurrent real upgrade's audit log (§6.7).
logs_new() {
  [[ -e "$STATE/initialized" ]] || return 0     # already torn down: nothing to track
  mkdir -p "$STATE"; touch "$STATE/logs"
  local f
  for f in /tmp/upgrade-prod-*.log; do
    [[ -f "$f" ]] || continue
    grep -qF "Verifying new binary: $H_RUN/" "$f" 2>/dev/null && printf '%s\n' "$f" >>"$STATE/logs"
  done
  sort -u "$STATE/logs" -o "$STATE/logs"
}

reap_new_script_logs() {
  [[ -e "$STATE/initialized" ]] || return 0    # torn down already: never sweep blind
  logs_new
  local f
  [[ -s "$STATE/logs" ]] && while read -r f; do [[ -n "$f" && -f "$f" ]] && rm -f "$f"; done <"$STATE/logs"
  for f in /tmp/opencode-prod-relaunch-*.log; do
    [[ -f "$f" ]] || continue
    grep -qxF "$f" "$STATE/relaunch.before" 2>/dev/null && continue
    rm -f "$f"
  done
}

# restore_operator_log — /tmp/upgrade-prod.log is the operator's follow-me link.
# A full swap moves it (that is the script's own behavior, asserted in
# swap-e2e); the suite puts it back exactly as it found it. Never `rm -f` it.
restore_operator_log() {
  [[ -e "$STATE/loglink.before" ]] || return 0   # torn down already: leave the link alone
  local want
  want=$(cat "$STATE/loglink.before")
  if [[ -n "$want" ]]; then
    ln -sfn "$want" "$LOG_LINK"
  elif [[ -L "$LOG_LINK" ]] && grep -qxF "$(readlink "$LOG_LINK")" "$STATE/logs" 2>/dev/null; then
    rm -f "$LOG_LINK"          # none existed at baseline and it points at our log
  fi
}

# reap_suite_tmpdirs — the script mktemp -d's /tmp/upgrade-prod.XXXXXX and its
# own EXIT trap removes it; this sweeps only dirs created after suite start.
# The old blind `rm -rf /tmp/upgrade-prod.??????` could clobber a concurrent
# real run's dir; require_port_free 4097 in run.sh bounds that risk, and the
# mtime gate keeps it honest.
reap_suite_tmpdirs() {
  local s d
  [[ -f "$STATE/start" ]] || return 0   # torn down already: never sweep blind
  s=$(cat "$STATE/start")
  for d in /tmp/upgrade-prod.??????; do
    [[ -e "$d" ]] || continue
    (( $(stat -c%Y "$d" 2>/dev/null || echo 0) >= s )) && rm -rf "$d"
  done
}

# assert_no_strays — the suite proves its own cleanliness (review §3). The
# patterns are the harness families: the L2 4.88 GB "$DB".bak.* orphans, the
# password-bearing cfg and last-good (the old upg-test-*, upgd-*, upgs-*,
# upgt-* prefixes), and every log this suite provably created. Pre-existing
# operator files — today's /tmp/upgrade-prod-*.log run logs and the follow-me
# link — are deliberately left alone: that is the invariant, not residue.
assert_no_strays() {
  local leftovers f
  reap_new_script_logs
  leftovers=$(ls -1d "$LEGACY_DB"* /tmp/upg-* /tmp/upgd-* /tmp/upgs-* /tmp/upgt-* 2>/dev/null \
    | grep -vx "$SUITE_ROOT" || true)
  while read -r f; do [[ -n "$f" && -e "$f" ]] && leftovers+="$f"$'\n'; done <"$STATE/logs"
  if [[ -d "$SUITE_ROOT/cases" ]]; then
    f=$(find "$SUITE_ROOT/cases" -mindepth 1 -maxdepth 1 2>/dev/null | head -3)
    [[ -z "$f" ]] || leftovers+="un-removed case dirs: $f"$'\n'
  fi
  [[ -z "$leftovers" ]] || { fail "stray harness files after cleanup: $(tr '\n' ' ' <<<"$leftovers")"; return 1; }
  pass "no stranded /tmp/upgrade-prod-test.db* (incl. .bak.*), no harness cfg/last-good, no suite logs"
}

# real_path_symlink_unchanged — the L1 guard. Every swap case ends with it and
# run.sh asserts it again for the whole run.
real_path_symlink_unchanged() {
  local want now
  want=$(cat "$STATE/symlink.before" 2>/dev/null || true)
  now=$(readlink "$REAL_PATH_SYMLINK" 2>/dev/null || true)
  if [[ "$now" != "$want" ]]; then
    fail "real PATH symlink moved: '$want' -> '$now' (step 8 must only ever move \$SWAP_SYMLINK)"
    return 1
  fi
  pass "real PATH symlink unchanged: $now"
}

# register_db PATH — register a database (and its -wal/-shm/".bak.*" siblings)
# for teardown. The seed backup the script writes next to the throwaway DB is
# the file that stranded as a 4.88 GB orphan on 2026-11-27 (review L2), so the
# sweep is explicit and pattern-based, not "the case dir is gone, fine".
register_db() { printf '%s\n' "$1" >>"$STATE/dbs"; }
sweep_dbs() {
  [[ -s "$STATE/dbs" ]] || return 0
  local f
  while read -r f; do
    [[ -n "$f" ]] || continue
    rm -f "$f" "$f-wal" "$f-shm"
    rm -f "$f".bak.*
  done <"$STATE/dbs"
}

# case_teardown — every case traps EXIT with this.
case_teardown() {
  local rc=$? dp pt
  [[ -n "${H_CASE:-}" ]] || return $rc
  # stop every throwaway port this suite registered, plus :4199 (the detach
  # child's target — it never binds, checking is free), then the script's dev
  # instance if its own cleanup left it up.
  stop_throwaway 4199 2>/dev/null || true
  if [[ -s "$STATE/ports" ]]; then
    while read -r pt; do [[ -n "$pt" ]] && stop_throwaway "$pt" 2>/dev/null || true; done <"$STATE/ports"
  fi
  dp=$(listener_pid 4097)                       # the script's dev instance, if left
  [[ -z "$dp" ]] || kill -KILL "$dp" 2>/dev/null || true
  sweep_dbs
  restore_operator_log
  reap_new_script_logs
  reap_suite_tmpdirs
  [[ -d "$H_CASE" ]] && rm -rf "$H_CASE"
  return $rc
}

# suite_teardown — run.sh's final cleanup: every case dir plus the suite root.
# Ends in `return 0` deliberately: this runs from the EXIT trap, and a failing
# last command there would replace the script's own exit status (a green run
# would report rc=1).
suite_teardown() {
  sweep_dbs
  restore_operator_log
  reap_new_script_logs
  reap_suite_tmpdirs
  [[ -d "$SUITE_ROOT" ]] && rm -rf "$SUITE_ROOT"
  return 0
}