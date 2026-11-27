#!/usr/bin/env bash
# Detach-marker harness — the 18:46 incident, part 1.
# A polluted UPGRADE_DETACHED=1 in the CALLER environment (live proof: the
# live prod server carries it because launch.py merged os.environ when the
# Nov-8 detached run launched it) must NOT disable detachment.
# RED now: env marker is trusted -> no detach, recovery-abort rc=1.
# GREEN after: marker moves to an argv flag; env cannot disable the detach.
set -u
REPO=/home/dev/opencode-patched
BIN=/home/dev/.opencode/bin/opencode-v2.3.2-latest-202611191829
RC=0
OUT=$(cd "$REPO" && env UPGRADE_DETACHED=1 UPGRADE_RUN_LOG=/tmp/upgd-poisoned.log \
  ./scripts/upgrade-prod.sh "$BIN" --model bogus/bogus --prod-port 4199 \
  --config-file /tmp/upgd-cfg.json --last-good /tmp/upgd-lg 2>&1) || RC=$?
echo "parent rc=$RC"
FAIL=0
grep -q "Detached upgrader started" <<<"$OUT" || { echo "FAIL: no detach under polluted env"; FAIL=1; }
[[ $RC -eq 0 ]] || { echo "FAIL: detached parent should exit 0, got $RC"; FAIL=1; }
[[ "$OUT" != *"/tmp/upgd-poisoned.log"* ]] || { echo "FAIL: inherited UPGRADE_RUN_LOG hijacked the log path"; FAIL=1; }
sleep 3  # let the child reach its (harmless) recovery abort; leave no listeners
ss -tlnpH | grep -q ':4199 ' && { echo "FAIL: child bound :4199?"; FAIL=1; }
rm -f /tmp/upgd-poisoned.log /tmp/upgd-cfg.json /tmp/upgd-lg
rm -rf /tmp/upgrade-prod.??????
[[ $FAIL -eq 0 ]] && { echo "HARNESS PASS"; exit 0; } || { echo "HARNESS FAIL"; exit 1; }