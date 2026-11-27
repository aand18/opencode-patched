#!/usr/bin/env bash
# Check command for scripts/upgrade-prod.sh.
#
# Every harness here runs against throwaway state only: instances on
# --prod-port 4120, temp config/last-good/log/db files under /tmp. None of
# them can touch prod :4096 or the service port. Run from the repo root.
#
# The harnesses reference the staged binaries they were written against
# (~/.opencode/bin/opencode-v2.2.0-latest-202610290031,
#  ...v2.2.6-latest-202611082100, ...v2.3.2-latest-202611191829); if one of
# those is ever pruned, restore or re-point before running.
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "== step 0: shell syntax (bash -n) =="
for f in scripts/*.sh tests/upgrade-prod/harness-*.sh tests/upgrade-prod/run.sh; do
  bash -n "$f"
done
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --severity=error scripts/upgrade-prod.sh tests/upgrade-prod/harness-*.sh
else
  echo "note: shellcheck not installed - bash -n only"
fi

# Gate model: live caller-session model, as in upgrade-prod.sh step 1b. The
# harnesses that hit real prod must pass the session's own model or step 1b
# aborts; harnesses keep a fallback pin for standalone runs.
# Note: the gate PONGs through the same tabbyAPI server that serves the agent
# running the suite — budget the co-resident load (harnesses pass
# --prompt-timeout 180, the 60s default starves behind a long generation).
GATE_MODEL="${GATE_MODEL:-}"
if [[ -z "$GATE_MODEL" && -n "${OPENCODE_SESSION_ID:-}" ]]; then
  TPID=$(ss -tlnpH 2>/dev/null | grep -oP ':4096\s.*pid=\K[0-9]+' | head -1)
  if [[ -n "$TPID" ]]; then
    PW=$(tr '\0' '\n' <"/proc/$TPID/environ" | sed -n 's/^OPENCODE_SERVER_PASSWORD=//p')
    NRC=$(mktemp /tmp/.runshnrc.XXXXXX); chmod 600 "$NRC"
    printf 'machine localhost login opencode password %s\n' "$PW" >"$NRC"
    GATE_MODEL=$(curl -s -n --netrc-file "$NRC" "http://localhost:4096/api/session/$OPENCODE_SESSION_ID" \
      | python3 -c 'import json,sys; m=(json.load(sys.stdin).get("data") or {}).get("model") or {}; print((m.get("providerID") or "")+"/"+(m.get("id") or m.get("modelID") or ""))' \
      | grep '/' || true)
    rm -f "$NRC"
  fi
fi
export GATE_MODEL
echo "gate model: ${GATE_MODEL:-<fallback pin per harness>}"

for h in harness-task1.sh harness-task2.sh harness-task3.sh \
         harness-detach.sh harness-selfguard.sh harness-symlink.sh; do
  echo "== $h =="
  "tests/upgrade-prod/$h"
done

# harness-fix12.sh section B performs a full destructive swap on the
# throwaway :4120 instance (slowest, copies a DB). Gate it to keep the
# default run quick; run it before shipping any change to the swap path.
# Load caveat: section B boots two servers and gates twice; the script's
# internal 90s readiness budget (READY_TIMEOUT) for a fresh dev instance can
# be starved by co-resident load (4.4 GB DB copies earlier in the suite, or
# heavy generations on the tabby server the gate PONGs through). If only
# section B fails with "server not ready within 90.0s", re-run it alone in a
# quieter window before reading anything into it.
if [[ "${ALLOW_DESTRUCTIVE:-0}" == "1" ]]; then
  echo "== harness-fix12.sh (full throwaway swap) =="
  tests/upgrade-prod/harness-fix12.sh
else
  echo "skipped harness-fix12.sh - set ALLOW_DESTRUCTIVE=1 to run the full :4120 swap"
fi

echo "ALL GREEN"