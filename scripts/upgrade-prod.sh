#!/usr/bin/env bash
set -euo pipefail
# upgrade-prod.sh — upgrade the running prod opencode binary, with verification.
#
# Usage:
#   scripts/upgrade-prod.sh <new-binary> --model <providerID/modelID> [--dry-run]
#                          [--foreground] [--timeout <sec>] [--prompt-timeout <sec>]
#                          [--prod-port <port>] [--config-file <path>] [--last-good <path>]
#
# Flow: discover prod (:4096) and capture its argv/env/cwd -> verify --model
# matches the calling session (OPENCODE_SESSION_ID) when set -> verify the new
# binary -> start a dev instance on a DB copy using prod's exact env -> live
# PONG round-trip on the caller's model (the model gate) -> stop prod, launch the
# new binary -> PONG round-trip on prod -> record last-known config + last-good
# binary. Any failure after prod is stopped rolls back to the previous binary
# and DB backup.
#
# Safety rules this script is built around:
# - Detaches itself (setsid) before it can touch prod, so the agent session
#   that runs it is not bricked when prod's process is stopped. --dry-run never
#   touches prod, so it stays in the foreground.
# - When OPENCODE_SESSION_ID is set (caller under opencode), --model must equal
#   that session's model; mismatch aborts before any DB copy (step 1b).
# - DB copies and restores use the sqlite online backup API only. A plain `cp`
#   misses the WAL tail (see AGENTS.md), so there is no `cp` fallback: a failed
#   backup aborts the run.
# - Captured argv and env travel as NUL-delimited data through launch.py; no
#   captured value is ever interpolated into a shell command or a python source
#   string.
# - Secrets (the captured env, the config file) are written 0600 and the server
#   password is never placed on a command line.

PROD_PORT=4096
DEV_PORT=4097
GLOBAL_TIMEOUT=600            # whole-run watchdog; fires a rollback, not a bare kill
PROMPT_TIMEOUT=60             # spec: end-to-end prompt round-trip budget
READY_TIMEOUT=90              # a fresh serve answers 503 until its plugins activate
CONFIG_FILE="$HOME/.opencode/last-prod-config.json"
LAST_GOOD="$HOME/.opencode/last-good-binary"
LOCK_FILE="/tmp/upgrade-prod.lock"
LOG_FILE="/tmp/upgrade-prod.log"

DRY_RUN=false
FOREGROUND=false
NEW_BINARY=""
MODEL_ID=""

ORIG_ARGS=("$@")

# ---------- arg parsing ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --foreground) FOREGROUND=true ;;
    --model) MODEL_ID="${2:-}"; shift ;;
    --timeout) GLOBAL_TIMEOUT="${2:-}"; shift ;;
    --prompt-timeout) PROMPT_TIMEOUT="${2:-}"; shift ;;
    --prod-port) PROD_PORT="${2:-}"; shift ;;
    --config-file) CONFIG_FILE="${2:-}"; shift ;;
    --last-good) LAST_GOOD="${2:-}"; shift ;;
    --help|-h)
      sed -n '3,28p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *) NEW_BINARY="$1" ;;
  esac
  shift
done

if [[ -z "$NEW_BINARY" ]]; then
  echo "Usage: $0 <new-binary> --model <providerID/modelID> [--dry-run]" >&2
  exit 1
fi
if [[ ! "$MODEL_ID" == */* ]]; then
  echo "ERROR: --model <providerID/modelID> is required (the model prod must keep serving)." >&2
  exit 1
fi
MODEL_PROVIDER="${MODEL_ID%%/*}"
MODEL_NAME="${MODEL_ID#*/}"
if [[ -z "$MODEL_PROVIDER" || -z "$MODEL_NAME" ]]; then
  echo "ERROR: --model must be providerID/modelID, got: $MODEL_ID" >&2
  exit 1
fi
if ! [[ "$PROD_PORT" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --prod-port must be numeric, got: $PROD_PORT" >&2
  exit 1
fi

# ---------- logging (defined before anything can use it) ----------
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# ---------- detach (spec 1) ----------
# prod is served on :4096, which is very likely the server hosting the session
# that launched this script. Re-exec in a new session so the upgrade finishes
# even after the caller's own process tree goes away.
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
if [[ "${UPGRADE_DETACHED:-}" != "1" ]] && ! $DRY_RUN && ! $FOREGROUND; then
  mkdir -p "$(dirname "$LOG_FILE")"
  setsid env UPGRADE_DETACHED=1 bash "$SCRIPT_PATH" "${ORIG_ARGS[@]}" \
    </dev/null >/dev/null 2>>"$LOG_FILE" &
  DETACHED_PID=$!
  echo "Detached upgrader started (pid=$DETACHED_PID). Follow progress: tail -f $LOG_FILE"
  exit 0
fi

# ---------- global timeout watchdog ----------
# The watchdog only signals this script; the TERM trap owns the rollback, so a
# timeout can never leave prod stopped.
MAIN_PID=$$
WATCHDOG_PID=""
# The watchdog must not hold the caller's stdout/stderr: a detached `sleep`
# child inheriting the pipe would keep a caller's pipeline open for the whole
# timeout window.
(
  sleep "$GLOBAL_TIMEOUT"
  echo "[$(date '+%H:%M:%S')] GLOBAL TIMEOUT after ${GLOBAL_TIMEOUT}s — signalling rollback"
  kill -TERM "$MAIN_PID" 2>/dev/null
) </dev/null >>"$LOG_FILE" 2>&1 &
WATCHDOG_PID=$!
disown 2>/dev/null || true

# ---------- state + cleanup ----------
PHASE="preflight"            # preflight | dev | prod-stopped | prod-launched | verified
ROLLBACK_DONE=false
CLEANED=false
DEV_PID=""
NEW_PID=""
PROD_PID=""
PROD_BIN=""
PROD_CWD=""
PROD_FLAGS_FILE=""
PROD_ENV_FILE=""
DB_BACKUP=""
DB_PATH=""
# Outside TMP_DIR: the relaunched prod keeps this open after cleanup runs.
PROD_LOG="/tmp/opencode-prod-relaunch-$$.log"
TMP_DIR="$(mktemp -d /tmp/upgrade-prod.XXXXXX)"
chmod 700 "$TMP_DIR"

stop_process() {
  # TERM the children while they are still parented, then the process itself.
  # pgrep -P is scoped to this pid only — never a system-wide pattern match.
  local pid=$1 bin base k i
  [[ -n "$pid" ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  local kids=()
  while read -r k; do kids+=("$k"); done < <(pgrep -P "$pid" 2>/dev/null || true)
  base=""
  if [[ -r "/proc/$pid/cmdline" ]]; then
    base="$(tr '\0' '\n' <"/proc/$pid/cmdline" | head -1)"
    base="${base##*/}"
  fi
  for k in "${kids[@]}"; do kill -TERM "$k" 2>/dev/null || true; done
  kill -TERM "$pid" 2>/dev/null || true
  for i in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  if kill -0 "$pid" 2>/dev/null; then
    log "  pid $pid ignored TERM — SIGKILL"
    for k in "${kids[@]}"; do kill -KILL "$k" 2>/dev/null || true; done
    kill -KILL "$pid" 2>/dev/null || true
    sleep 1
  fi
  # Children reparent to init once the parent dies; kill only the ones we
  # identified, and only while their cmdline still names the same binary.
  for k in "${kids[@]}"; do
    if kill -0 "$k" 2>/dev/null && [[ -r "/proc/$k/cmdline" ]] \
      && tr '\0' '\n' <"/proc/$k/cmdline" | grep -qF -- "$base"; then
      kill -KILL "$k" 2>/dev/null || true
    fi
  done
}

rollback() {
  $ROLLBACK_DONE && return 0
  ROLLBACK_DONE=true
  log "ROLLBACK: restoring the previous prod"
  stop_process "$NEW_PID"
  if [[ -n "$DB_BACKUP" && -f "$DB_BACKUP" && -n "$DB_PATH" ]]; then
    cp "$DB_BACKUP" "$DB_PATH"
    rm -f "$DB_PATH-wal" "$DB_PATH-shm"
    log "  DB restored from $DB_BACKUP"
  else
    log "  WARN: no DB backup available to restore"
  fi
  local old="$PROD_BIN"
  if [[ ! -x "$old" && -f "$LAST_GOOD" ]]; then
    old="$(head -1 "$LAST_GOOD" 2>/dev/null || true)"
  fi
  if [[ -n "$old" && -x "$old" ]]; then
    LAUNCH_LOG="$PROD_LOG"
    launch "$old" "$PROD_FLAGS_FILE" "$PROD_CWD"
    if [[ -n "$(wait_for_listener "$PROD_PORT" 20)" ]]; then
      log "  rollback complete: $old serving on :$PROD_PORT"
    else
      log "  ERROR: rollback launch did not bind :$PROD_PORT"
    fi
  else
    log "  ERROR: no previous binary available — prod is DOWN on :$PROD_PORT"
  fi
}

cleanup() {
  $CLEANED && return 0
  CLEANED=true
  if [[ -n "$WATCHDOG_PID" ]]; then
    pkill -KILL -P "$WATCHDOG_PID" 2>/dev/null || true
    kill -KILL "$WATCHDOG_PID" 2>/dev/null || true
  fi
  # The dev instance is ours; stop it and its children.
  if [[ "$PHASE" != "verified" ]]; then
    stop_process "$DEV_PID"
  fi
  rm -rf "$TMP_DIR"
  return 0
}

on_signal() {
  log "SIGNAL received in phase '$PHASE'"
  if [[ "$PHASE" == "prod-stopped" || "$PHASE" == "prod-launched" ]]; then
    rollback
  fi
  cleanup
  exit 1
}

trap on_signal INT TERM
trap 'cleanup' EXIT

# ---------- helpers ----------
find_listener() {
  local port=$1
  ss -tlnpH 2>/dev/null | grep -oP ":$port\s.*pid=\K[0-9]+" | head -1 || true
}

wait_for_listener() {
  local port=$1 limit=$2 i
  for i in $(seq 1 "$((limit * 2))"); do
    local pid
    pid=$(find_listener "$port")
    [[ -n "$pid" ]] && { echo "$pid"; return 0; }
    sleep 0.5
  done
  return 1
}

wait_port_free() {
  local port=$1 limit=$2 i
  for i in $(seq 1 "$((limit * 2))"); do
    [[ -z "$(find_listener "$port")" ]] && return 0
    sleep 0.5
  done
  return 1
}

parse_version() {
  grep -oP 'v?\K[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true
}

env_get() {
  # $1 key, $2 NUL-delimited env file
  local key=$1 file=$2
  [[ -f "$file" ]] || return 0
  tr '\0' '\n' <"$file" | grep -m1 -oP "^\Q${key}\E=\K.*" || true
}

# launch.py: exec a binary with a captured /proc/PID/environ + argv, no shell.
cat >"$TMP_DIR/launch.py" <<'PY'
#!/usr/bin/env python3
import os
import sys


def read_nul(path):
    with open(path, "rb") as fh:
        return [e for e in fh.read().split(b"\0") if e]


argv = sys.argv[1:]
env = dict(os.environ)
cwd = None
i = 0
while i < len(argv):
    arg = argv[i]
    if arg == "--env-file" and i + 1 < len(argv):
        for entry in read_nul(argv[i + 1]):
            k, sep, v = entry.partition(b"=")
            if sep:
                env[k.decode("utf-8", "surrogateescape")] = v.decode("utf-8", "surrogateescape")
        i += 2
    elif arg == "--set" and i + 1 < len(argv):
        k, sep, v = argv[i + 1].encode("utf-8", "surrogateescape").partition(b"=")
        if sep:
            env[k.decode("utf-8", "surrogateescape")] = v.decode("utf-8", "surrogateescape")
        i += 2
    elif arg == "--cwd" and i + 1 < len(argv):
        cwd = argv[i + 1]
        i += 2
    elif arg == "--":
        i += 1
        break
    else:
        break
if i >= len(argv):
    sys.stderr.write("launch.py: missing binary\n")
    raise SystemExit(2)
binary = argv[i]
if cwd:
    os.chdir(cwd)
os.execve(binary, [binary] + argv[i + 1:], env)
PY

# probe.py: health + real prompt round-trip. Reads the server password from the
# captured env file, so it never appears in argv or in ps output.
cat >"$TMP_DIR/probe.py" <<'PY'
#!/usr/bin/env python3
"""Liveness + real prompt round-trip against a running opencode serve.

Targets the current /api surface (v2.x): GET /api/info, GET /api/model,
POST /api/session, POST /api/session/{id}/prompt, GET /api/session/{id}/message.
A freshly started serve binds its port before its location plugins finish
activating and answers 503 until then, so every mode waits for readiness.
The server password is read from the captured env file, so it never appears in
argv or in ps output.
"""
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


def read_env(path):
    env = {}
    if path and os.path.exists(path):
        with open(path, "rb") as fh:
            for entry in fh.read().split(b"\0"):
                k, sep, v = entry.partition(b"=")
                if sep:
                    env[k.decode("utf-8", "surrogateescape")] = v.decode("utf-8", "surrogateescape")
    return env


class Api:
    def __init__(self, base, auth, timeout):
        self.base = base.rstrip("/")
        self.auth = auth
        self.timeout = timeout

    def call(self, method, path, payload=None, timeout=None):
        headers = {"Accept": "application/json"}
        if self.auth:
            headers["Authorization"] = self.auth
        data = None
        if payload is not None:
            data = json.dumps(payload).encode()
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(self.base + path, data=data, headers=headers, method=method)
        with urllib.request.urlopen(req, timeout=timeout or self.timeout) as resp:
            raw = resp.read().decode("utf-8", "replace")
        try:
            return json.loads(raw)
        except ValueError:
            return {}


def wait_ready(api, query, budget):
    """Poll /api/model until the location is activated; returns the model list."""
    deadline = time.time() + budget
    last = "no attempt"
    while time.time() < deadline:
        try:
            data = api.call("GET", "/api/model" + query, timeout=20).get("data") or []
            if data:
                return data
            last = "empty model list"
        except urllib.error.HTTPError as err:
            last = f"HTTP {err.code}"
        except (urllib.error.URLError, OSError) as err:
            last = str(err)
        time.sleep(2)
    raise RuntimeError(f"server not ready within {budget}s ({last})")


def main():
    mode, base, env_file, timeout = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
    env = read_env(env_file)
    auth = None
    # v2 reads OPENCODE_PASSWORD first and falls back to the legacy name
    # (packages/cli/src/env.ts), so try both.
    password = env.get("OPENCODE_PASSWORD", "") or env.get("OPENCODE_SERVER_PASSWORD", "")
    if password:
        raw = f'{env.get("OPENCODE_SERVER_USERNAME", "opencode")}:{password}'.encode()
        auth = "Basic " + base64.b64encode(raw).decode()
    api = Api(base, auth, timeout)

    if mode == "health":
        budget = float(sys.argv[5]) if len(sys.argv) > 5 else timeout
        try:
            models = wait_ready(api, "", budget)
            info = api.call("GET", "/api/info", timeout=15)
        except (urllib.error.HTTPError, urllib.error.URLError, OSError, RuntimeError) as err:
            print(f"health: {err}")
            return 1
        print(f"health: ok version={info.get('version', 'unknown')} models={len(models)}")
        return 0

    if mode == "session-model":
        session_id = sys.argv[5]
        cwd = sys.argv[6] if len(sys.argv) > 6 else ""
        query = "?" + urllib.parse.urlencode({"directory": cwd}) if cwd else ""
        try:
            data = api.call("GET", f"/api/session/{session_id}" + query, timeout=15)
        except (urllib.error.HTTPError, urllib.error.URLError, OSError, RuntimeError, KeyError) as err:
            print(f"session-model: {type(err).__name__}: {err}")
            return 1
        model = ((data.get("data") or {}).get("model") or {})
        provider_id = model.get("providerID")
        model_id = model.get("id") or model.get("modelID")
        if not provider_id or not model_id:
            print("session-model: session has no model")
            return 1
        print(f"{provider_id}/{model_id}")
        return 0

    provider, model, text, cwd = sys.argv[5], sys.argv[6], sys.argv[7], sys.argv[8]
    ready_budget = float(sys.argv[9]) if len(sys.argv) > 9 else 90.0
    query = "?" + urllib.parse.urlencode({"directory": cwd}) if cwd else ""
    session_id = None
    try:
        models = wait_ready(api, query, ready_budget)
        wanted = [
            m
            for m in models
            if m.get("providerID") == provider and m.get("modelID", m.get("id")) == model
        ]
        if not wanted:
            print(f"prompt: model {provider}/{model} is not available on this server ({len(models)} models listed)")
            return 1
        session = api.call("POST", "/api/session" + query, {"model": {"providerID": provider, "id": model}})
        session_id = session["data"]["id"]
        api.call("POST", f"/api/session/{session_id}/prompt" + query, {"text": text})
        # The prompt endpoint only admits the input. POST /api/experimental/session/
        # {id}/wait blocks until the agent loop is idle — the signal the CLI's own
        # non-interactive runner uses — so the reply is read once, not guessed from
        # partial streaming. No payload; 204 on success.
        try:
            api.call("POST", f"/api/experimental/session/{session_id}/wait" + query, None, timeout)
            read_budget = 30.0
        except urllib.error.HTTPError as err:
            if err.code not in (400, 404):
                raise
            read_budget = timeout  # endpoint not exposed: fall back to polling
        deadline = time.time() + read_budget
        while time.time() < deadline:
            messages = api.call("GET", f"/api/session/{session_id}/message" + query, timeout=20)
            for message in messages.get("data", []):
                if message.get("type") != "assistant":
                    continue
                if message.get("error"):
                    raise RuntimeError(json.dumps(message["error"])[:300])
                texts = " ".join(
                    c.get("text", "") for c in (message.get("content") or []) if c.get("type") == "text"
                )
                if not texts.strip():
                    continue
                got = message.get("model") or {}
                got_id = got.get("id", got.get("modelID"))
                detail = f"session={session_id} model={got.get('providerID')}/{got_id} reply={texts[:120]!r}"
                if got.get("providerID") != provider or got_id != model:
                    print(f"prompt: MODEL MISMATCH requested={provider}/{model} ({detail})")
                    return 1
                if "PONG" not in texts.upper():
                    print(f"prompt: no PONG in reply ({detail})")
                    return 1
                print(f"prompt: ok ({detail})")
                return 0
            time.sleep(2)
        print(f"prompt: no assistant reply within {timeout}s (session={session_id})")
        return 1
    except urllib.error.HTTPError as err:
        print(f"prompt: HTTP {err.code} {err.read().decode('utf-8', 'replace')[:200]}")
        return 1
    except (urllib.error.URLError, OSError, KeyError, ValueError, RuntimeError) as err:
        print(f"prompt: failed ({type(err).__name__}: {err})")
        return 1
    finally:
        if session_id:
            try:
                api.call("DELETE", f"/api/session/{session_id}" + query, timeout=15)
            except Exception:
                pass  # best-effort cleanup of the probe session


sys.exit(main())
PY

LAUNCH_BIN=(python3 "$TMP_DIR/launch.py")

launch() {
  # launch <binary> <flags-file> [cwd] — extra env overrides go in EXTRA_ENV
  # (NUL-delimited). Everything below stays argv-shaped: no captured value is
  # ever spliced into a shell string.
  local binary=$1 flags_file=$2 cwd=${3:-}
  local args=("${LAUNCH_BIN[@]}" --env-file "$PROD_ENV_FILE")
  if [[ -n "$cwd" ]]; then args+=(--cwd "$cwd"); fi
  if [[ -n "${EXTRA_ENV:-}" && -f "$EXTRA_ENV" ]]; then
    local pair
    while read -r -d '' pair; do args+=(--set "$pair"); done <"$EXTRA_ENV"
  fi
  args+=(-- "$binary")
  local flag
  while read -r -d '' flag; do args+=("$flag"); done <"$flags_file"
  # Detach stdio: an inherited stdout would hold the caller's pipe open for the
  # lifetime of the launched server.
  setsid "${args[@]}" </dev/null >"${LAUNCH_LOG:-$TMP_DIR/launch.log}" 2>&1 9>&- &
}

build_instance_flags() {
  # Rewrite the captured serve flags for the loopback dev instance.
  local port=$1 out=() skip=0 a
  mapfile -d '' base <"$PROD_FLAGS_FILE"
  for a in "${base[@]}"; do
    if (( skip )); then skip=0; continue; fi
    if [[ "$a" == "--port" || "$a" == "--hostname" ]]; then skip=1; continue; fi
    if [[ "$a" == --port=* || "$a" == --hostname=* || "$a" == "--mdns" ]]; then continue; fi
    out+=("$a")
  done
  if [[ ${#out[@]} -eq 0 ]]; then out=(serve); fi
  out+=(--hostname 127.0.0.1 --port "$port")
  INSTANCE_FLAGS_FILE="$TMP_DIR/instance-flags-$port"
  printf '%s\0' "${out[@]}" >"$INSTANCE_FLAGS_FILE"
}

# ---------- step 0: verify new binary ----------
log "Verifying new binary: $NEW_BINARY"
if [[ ! -x "$NEW_BINARY" ]]; then
  log "ERROR: binary not found or not executable: $NEW_BINARY"
  exit 1
fi
NEW_BINARY="$(readlink -f "$NEW_BINARY")"
VERSION_OUT=$("$NEW_BINARY" --version 2>&1) || { log "ERROR: --version failed"; exit 1; }
NEW_VERSION=$(echo "$VERSION_OUT" | parse_version)
if [[ -z "$NEW_VERSION" ]]; then
  log "ERROR: could not parse version from: $VERSION_OUT"
  exit 1
fi
log "New binary version: $NEW_VERSION"

# ---------- step 1: discover prod ----------
PROD_FLAGS_FILE="$TMP_DIR/prod-flags"
PROD_ENV_FILE="$TMP_DIR/prod-env"
: >"$PROD_FLAGS_FILE"
: >"$PROD_ENV_FILE"
chmod 600 "$PROD_ENV_FILE"

PROD_PID=$(find_listener "$PROD_PORT")
if [[ -n "$PROD_PID" ]]; then
  log "Found prod on :$PROD_PORT (pid=$PROD_PID)"
  tail -z -n +2 "/proc/$PROD_PID/cmdline" >"$PROD_FLAGS_FILE"
  cp "/proc/$PROD_PID/environ" "$PROD_ENV_FILE"
  PROD_BIN="$(tr '\0' '\n' <"/proc/$PROD_PID/cmdline" | head -1)"
  PROD_CWD="$(readlink "/proc/$PROD_PID/cwd" 2>/dev/null || true)"
  PROD_VERSION=$("$PROD_BIN" --version 2>/dev/null | parse_version)
  if [[ "$PROD_VERSION" == "$NEW_VERSION" ]]; then
    log "Already on $NEW_VERSION. Nothing to do."
    exit 0
  fi
  log "Prod version: ${PROD_VERSION:-unknown} -> $NEW_VERSION"
else
  log "No prod running on :$PROD_PORT"
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log "ERROR: no prod running and no last-known config ($CONFIG_FILE). Start prod manually first."
    exit 1
  fi
  log "Recovering from last-known config: $CONFIG_FILE"
  mapfile -d '' RECOVERED < <(python3 - "$CONFIG_FILE" "$PROD_FLAGS_FILE" "$PROD_ENV_FILE" <<'PY'
import json
import shlex
import sys

config_file, flags_file, env_file = sys.argv[1:4]
d = json.load(open(config_file))
flags = d.get("flags", [])
if isinstance(flags, str):
    flags = shlex.split(flags)
with open(flags_file, "wb") as fh:
    for a in flags:
        fh.write(a.encode("utf-8", "surrogateescape") + b"\0")
with open(env_file, "wb") as fh:
    for k, v in (d.get("env") or {}).items():
        fh.write(f"{k}={v}".encode("utf-8", "surrogateescape") + b"\0")
for key in ("binary", "cwd", "port"):
    sys.stdout.write(str(d.get(key) or "") + "\0")
PY
)
  PROD_BIN="${RECOVERED[0]:-}"
  PROD_CWD="${RECOVERED[1]:-}"
  log "Recovered binary: ${PROD_BIN:-none}  flags: $(tr '\0' ' ' <"$PROD_FLAGS_FILE")"
  if [[ ! -x "$PROD_BIN" ]]; then
    PROD_BIN=""
    log "WARN: recovered binary is not executable; rollback target will be \$LAST_GOOD"
  fi
fi

if [[ ! -s "$PROD_FLAGS_FILE" ]]; then
  log "WARN: no captured serve flags; defaulting to 'serve'"
  printf 'serve\0' >"$PROD_FLAGS_FILE"
fi

DB_PATH="$(env_get OPENCODE_DB "$PROD_ENV_FILE")"
[[ -n "$DB_PATH" ]] || DB_PATH="$HOME/.local/share/opencode/opencode.db"
if [[ ! -f "$DB_PATH" ]]; then
  log "ERROR: prod database not found: $DB_PATH"
  exit 1
fi
log "Prod DB: $DB_PATH"

# ---------- step 1b: caller-model enforcement ----------
# --model must name the calling session's model. When the caller runs under
# opencode (OPENCODE_SESSION_ID set), resolve that session's model from prod
# with the captured auth and abort early on mismatch, before any DB copy.
# Skipped for throwaway instances (--prod-port != 4096) and manual runs
# without a session id.
if [[ -n "${OPENCODE_SESSION_ID:-}" && -n "$PROD_PID" && "$PROD_PORT" == "4096" ]]; then
  log "Verifying caller session model ($OPENCODE_SESSION_ID)..."
  if ! SESSION_MODEL=$(python3 "$TMP_DIR/probe.py" session-model "http://127.0.0.1:$PROD_PORT" "$PROD_ENV_FILE" 20 "$OPENCODE_SESSION_ID" "$PROD_CWD" 2>&1); then
    log "ERROR: could not resolve caller session model from $OPENCODE_SESSION_ID: $SESSION_MODEL"
    exit 1
  fi
  if [[ "$MODEL_ID" != "$SESSION_MODEL" ]]; then
    log "ERROR: --model $MODEL_ID does not match calling session model $SESSION_MODEL. Pass $SESSION_MODEL (resolve from \$OPENCODE_SESSION_ID; never reuse a remembered model) or unset OPENCODE_SESSION_ID for manual runs."
    exit 1
  fi
  log "Caller model check passed: $SESSION_MODEL"
fi

if $FOREGROUND && ! $DRY_RUN && [[ -n "$PROD_PID" ]]; then
  # Stopping prod kills whatever it serves — including this script's own agent
  # session when the caller runs under that server. Detaching is the default for
  # exactly this reason; --foreground overrides it deliberately.
  anc=$MAIN_PID
  while [[ "$anc" =~ ^[0-9]+$ ]] && (( anc > 1 )); do
    if (( anc == PROD_PID )); then
      log "WARNING: pid $PROD_PID is an ancestor of this script — stopping prod will kill this session mid-run. Re-run without --foreground to detach."
      break
    fi
    anc=$(awk '{print $4}' "/proc/$anc/stat" 2>/dev/null || echo 0)
  done
fi

backup_db() {
  # Online backup only: a plain cp misses the WAL tail (AGENTS.md, 2026-08-09).
  local target=$1
  if ! sqlite3 "$DB_PATH" ".backup $target"; then
    log "ERROR: sqlite3 online backup failed for $target — aborting (no cp fallback)"
    exit 1
  fi
}

# ---------- step 2: dev instance ----------
if [[ -n "$(find_listener "$DEV_PORT")" ]]; then
  log "ERROR: port $DEV_PORT already in use (pid=$(find_listener "$DEV_PORT")). Aborting (will not kill)."
  exit 1
fi

DEV_DB="$TMP_DIR/dev.db"
backup_db "$DEV_DB"
log "Dev DB: $DEV_DB"

EXTRA_ENV="$TMP_DIR/dev-env"
printf 'OPENCODE_DB=%s\0' "$DEV_DB" >"$EXTRA_ENV"
build_instance_flags "$DEV_PORT"
log "Starting dev instance on :$DEV_PORT with prod's captured env"
LAUNCH_LOG="$TMP_DIR/dev.log"
launch "$NEW_BINARY" "$INSTANCE_FLAGS_FILE" "$PROD_CWD"
DEV_PID=$(wait_for_listener "$DEV_PORT" 20) || {
  log "ERROR: dev instance failed to start. Last lines of $LAUNCH_LOG:"
  tail -20 "$LAUNCH_LOG" | tee -a "$LOG_FILE" || true
  exit 1
}
log "Dev instance started on :$DEV_PORT (pid=$DEV_PID)"

# ---------- step 3: model gate (specs 6/9/11) ----------
# The dev instance runs the new binary with prod's captured env and the shared
# config dir, so a live prompt on the caller's model is the only check that
# proves "exactly the same model as prod" still works after the swap.
PHASE="dev"
log "Model gate: prompting $MODEL_ID on the dev instance (budget ${PROMPT_TIMEOUT}s)"
if ! GATE_OUT=$(python3 "$TMP_DIR/probe.py" prompt "http://127.0.0.1:$DEV_PORT" "$PROD_ENV_FILE" "$PROMPT_TIMEOUT" "$MODEL_PROVIDER" "$MODEL_NAME" "Reply with exactly: PONG" "$PROD_CWD" "$READY_TIMEOUT"); then
  log "ERROR: model gate FAILED for $MODEL_ID — $GATE_OUT"
  log "Aborting before touching prod."
  exit 1
fi
log "Model gate passed: $GATE_OUT"

# No separate smoke instance: the dev instance above already boots the new
# binary on a fresh copy of the prod DB with prod's captured env, and the model
# gate proves a real round-trip through it. A second full server would exercise
# a strict subset of that for another 4 GB DB copy and another resident process.

# ---------- dry-run exit ----------
if $DRY_RUN; then
  stop_process "$DEV_PID"
  DEV_PID=""
  log "DRY RUN: pre-flight checks passed (binary, dev boot, model gate). Prod untouched."
  exit 0
fi

# ---------- step 5: stop old prod ----------
if [[ -n "$PROD_PID" ]]; then
  log "Stopping old prod (pid=$PROD_PID)..."
  stop_process "$PROD_PID"
  PHASE="prod-stopped"
  if ! wait_port_free "$PROD_PORT" 15; then
    log "ERROR: port $PROD_PORT still in use after kill. Aborting."
    exit 1
  fi
  log "Old prod stopped, port $PROD_PORT free"
fi

# ---------- step 6: launch new prod ----------
DB_BACKUP="$DB_PATH.bak.$(date +%Y%m%d%H%M%S)"
backup_db "$DB_BACKUP"
log "DB backup: $DB_BACKUP"

EXTRA_ENV=""
log "Launching new prod: $NEW_BINARY"
LAUNCH_LOG="$PROD_LOG"
launch "$NEW_BINARY" "$PROD_FLAGS_FILE" "$PROD_CWD"
PHASE="prod-launched"
NEW_PID=$(wait_for_listener "$PROD_PORT" 30) || {
  log "ERROR: new prod did not bind :$PROD_PORT within 30s"
  tail -20 "$LAUNCH_LOG" | tee -a "$LOG_FILE" || true
  rollback
  exit 1
}
log "New prod listening on :$PROD_PORT (pid=$NEW_PID)"

# ---------- step 7: verify or rollback ----------
if ! HEALTH_OUT=$(python3 "$TMP_DIR/probe.py" health "http://127.0.0.1:$PROD_PORT" "$PROD_ENV_FILE" 20 "$READY_TIMEOUT"); then
  log "Health check failed: $HEALTH_OUT"
  rollback
  exit 1
fi
log "Health: $HEALTH_OUT"

log "End-to-end verification: prompting $MODEL_ID on new prod (budget ${PROMPT_TIMEOUT}s)"
if ! E2E_OUT=$(python3 "$TMP_DIR/probe.py" prompt "http://127.0.0.1:$PROD_PORT" "$PROD_ENV_FILE" "$PROMPT_TIMEOUT" "$MODEL_PROVIDER" "$MODEL_NAME" "Reply with exactly: PONG" "$PROD_CWD" "$READY_TIMEOUT"); then
  log "End-to-end verification FAILED: $E2E_OUT"
  rollback
  exit 1
fi
log "End-to-end verification passed: $E2E_OUT"

# ---------- step 8: success ----------
PHASE="verified"
NEW_VERSION_ACTUAL=$("$NEW_BINARY" --version 2>/dev/null | parse_version)
log "SUCCESS: upgraded to ${NEW_VERSION_ACTUAL:-$NEW_VERSION} (pid=$NEW_PID)"

mkdir -p "$(dirname "$CONFIG_FILE")"
python3 - "$CONFIG_FILE" "$NEW_BINARY" "$NEW_VERSION_ACTUAL" "$PROD_PORT" "$PROD_CWD" "$PROD_FLAGS_FILE" "$PROD_ENV_FILE" <<'PY'
import datetime
import json
import os
import sys

config_file, binary, version, port, cwd, flags_file, env_file = sys.argv[1:8]


def read_nul(path):
    with open(path, "rb") as fh:
        return [e for e in fh.read().split(b"\0") if e]


flags = [e.decode("utf-8", "surrogateescape") for e in read_nul(flags_file)]
env = {}
for entry in read_nul(env_file):
    k, sep, v = entry.partition(b"=")
    if sep:
        env[k.decode("utf-8", "surrogateescape")] = v.decode("utf-8", "surrogateescape")

data = {
    "binary": binary,
    "version": version,
    "flags": flags,
    "env": env,
    "port": int(port),
    "cwd": cwd,
    "timestamp": datetime.datetime.now().astimezone().isoformat(),
    "note": "written by scripts/upgrade-prod.sh after a verified upgrade; contains secrets",
}
tmp = config_file + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as fh:
    json.dump(data, fh, indent=2)
os.replace(tmp, config_file)
os.chmod(config_file, 0o600)
PY
log "Config written (0600) to $CONFIG_FILE"

echo "$NEW_BINARY" >"$LAST_GOOD"
chmod 600 "$LAST_GOOD"
log "Last-good binary updated: $LAST_GOOD -> $NEW_BINARY"

stop_process "$DEV_PID"
DEV_PID=""
log "Upgrade complete."
