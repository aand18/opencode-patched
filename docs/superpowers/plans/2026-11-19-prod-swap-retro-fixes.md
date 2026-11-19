# Prod-swap retro fixes + latest-release build & deploy — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden `scripts/upgrade-prod.sh` (live artifact refresh, per-run log + verdict sentinel, `--check-only` preflight), fix the rotted AGENTS.md pins and remotes, commit the autoupdate research doc, then build the newest upstream release via a subagent and deploy it to prod `:4096`.

**Architecture:** All script changes stay inside the single `scripts/upgrade-prod.sh` (bash + two embedded python heredocs). Tests are live runs against prod `:4096` (read-only modes only) and a throwaway instance on `:4120` for destructive paths, mirroring the established verification pattern. Docs are targeted edits to `AGENTS.md` plus committing `docs/research/`.

**Tech Stack:** bash, python3 stdlib (embedded `probe.py`/`launch.py`), bun 1.4.x build of opencode v2, git.

**Spec:** design approved in-session 2026-11-19 (retro items 1–7 from the "Reason v2.2.0 still live" audit of session `ses_e43458768ffeOakT2PYXYiLvuL`); user constraints below.

## Global Constraints

- Never stop, restart, or kill the prod `:4096` or service `:49374` processes outside a full verified `upgrade-prod.sh` run (production machine; the agent session rides these servers).
- Destructive paths are exercised only against a throwaway instance on `--prod-port 4120` with `--config-file`/`--last-good` pointed at temp files — never against prod.
- DB snapshot pruning stays manual; no pruning logic enters the script.
- `--model` must be the **live-caller** model resolved from `$OPENCODE_SESSION_ID` via `GET /api/session/{id}` at deploy time; the script's step 1b enforces this — never pass a remembered model.
- Server password and captured env never appear on command lines or in logs; artifact files stay 0600.
- Commits are atomic: one for the script, one for docs; unrelated untracked churn (`bench/`, `packages/`, stray `docs/plans/*`) stays out.
- The build subagent must not touch servers, DB, `~/.opencode/bin` entries other than the new one, or git remotes/branches other than checking out the newest tag.

## Review Focus

- Out-of-band prod restart between swaps → rollback artifacts must already describe the live build at the moment the next run starts (Task 1 refreshes them from `/proc` in step 1a; test: stale temp artifacts get overwritten before any DB copy).
- Two runs interleaving into one log (the Oct 29 tail of clock-only timestamps) → per-run log file + dated timestamps + `latest` symlink (Task 2).
- A polling agent can't tell success/failure/rollback from the log alone → exactly one `VERDICT:` sentinel line at every exit path (Task 2).
- `--check-only` accidentally becoming destructive → it must exit before step 2: no `dev.db`, no listener on `:4097`, prod pid unchanged (Task 3 test asserts all three).
- Artifact refresh running on the recovery branch (prod down, config is the only source) → refresh must be skipped when `PROD_PID` is empty, not rewrite the config from recovered state (Task 1).

---

### Task 1: Artifact refresh from live prod (step 1a) + shared writer

**Files:**
- Modify: `scripts/upgrade-prod.sh` (extract step 8's config-writing python into a reusable function; add step 1a after step 1's capture block, before step 1b)

**Interfaces:**
- Consumes: `PROD_BIN`, `PROD_VERSION`, `PROD_CWD`, `PROD_FLAGS_FILE`, `PROD_ENV_FILE`, `PROD_PID`, `PROD_PORT`, `CONFIG_FILE`, `LAST_GOOD` (step 1).
- Produces: `write_artifacts <binary> <version> <flags_file> <env_file> <port> <cwd>` (bash function, atomic 0600 write of both artifacts); step 8 calls it instead of its inline heredoc.

- [ ] **Step 1: Extract `write_artifacts` from step 8.** Move step 8's python heredoc into a function defined near `backup_db()`; body: write `CONFIG_FILE` atomically (tmp + `os.replace`, 0600, same JSON keys as today, `note` gains a `source=` suffix passed in) and `echo "$binary" >"$LAST_GOOD"; chmod 600`. Replace step 8's inline block and its two log lines with `write_artifacts "$NEW_BINARY" "$NEW_VERSION_ACTUAL" "$PROD_FLAGS_FILE" "$PROD_ENV_FILE" "$PROD_PORT" "$PROD_CWD" "verified-upgrade"` and keep the existing SUCCESS/Config-written/Last-good log lines equivalent.

- [ ] **Step 2: Add step 1a** after the step 1 `if/else` (the one ending `fi` at "recovered binary is not executable"), before step 1b:
  ```bash
  # ---------- step 1a: refresh artifacts from live prod ----------
  # Rollback targets must describe the build running NOW, not the last verified
  # swap (skill invariant 6): an out-of-band restart silently rots them.
  if [[ -n "$PROD_PID" ]]; then
    if [[ -f "$CONFIG_FILE" ]]; then
      CFG_BIN=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("binary",""))' "$CONFIG_FILE" 2>/dev/null || true)
      if [[ -n "$CFG_BIN" && "$CFG_BIN" != "$PROD_BIN" ]]; then
        log "WARN: $CONFIG_FILE describes ${CFG_BIN} but prod runs $PROD_BIN — refreshing from /proc/$PROD_PID"
      fi
    fi
    write_artifacts "$PROD_BIN" "${PROD_VERSION:-unknown}" "$PROD_FLAGS_FILE" "$PROD_ENV_FILE" "$PROD_PORT" "$PROD_CWD" "live-refresh-pid$PROD_PID"
    log "Rollback artifacts refreshed from live prod (pid=$PROD_PID, version=${PROD_VERSION:-unknown})"
  fi
  ```

- [ ] **Step 3: Syntax check.** Run: `bash -n scripts/upgrade-prod.sh` → exit 0.

- [ ] **Step 4: Throwaway test for the refresh.** Start a throwaway on `:4120`: online-backup copy `/tmp/upgrade-prod-test.db` (`sqlite3 $HOME/.local/share/opencode/opencode.db ".backup /tmp/upgrade-prod-test.db"`), then `setsid env OPENCODE_DB=/tmp/upgrade-prod-test.db OPENCODE_SERVER_PASSWORD=<pw> ~/.opencode/bin/opencode-v2.2.6-latest-202611082100 serve --hostname 127.0.0.1 --port 4120 >/tmp/upg-throwaway.log 2>&1 &`, wait for listener. Run `./scripts/upgrade-prod.sh ~/.opencode/bin/opencode-v2.2.0-latest-202610290031 --model opencode-go/crouton-alpha-free --dry-run --prod-port 4120 --config-file /tmp/upg-test-cfg.json --last-good /tmp/upg-test-lastgood`. Verify: log has **no** "Verifying caller session model" line (step 1b correctly skipped for `:4120`), and after the step-1 phase `/tmp/upg-test-cfg.json` + `/tmp/upg-test-lastgood` describe the live v2.2.6 throwaway. Stop the throwaway (TERM its pid), keep temp files for Step 5.

- [ ] **Step 5: Stale-artifact test on throwaway.** Restart the throwaway on `:4120` with the **v2.2.0** binary (same temp DB/env); hand-write `/tmp/upg-test-cfg.json` claiming `binary` = the v2.1.4 path (copy the JSON shape, any valid file); run the same `--dry-run --prod-port 4120` command; verify the log contains `WARN:` + `refreshed from live prod` and the config now names the v2.2.0 path. Then stop the throwaway and `rm -f /tmp/upg-test-* /tmp/upgrade-prod-test.db* /tmp/upg-throwaway.log`.

- [ ] **Step 6: Commit.**
  ```bash
  git add scripts/upgrade-prod.sh
  git commit -m "fix(scripts): refresh rollback artifacts from live prod before the swap"
  ```

### Task 2: Per-run log, dated timestamps, verdict sentinel

**Files:**
- Modify: `scripts/upgrade-prod.sh` (LOG_FILE definition ~line 41, detach block ~97-103, `log()` ~90, watchdog append ~118, every `exit 0/1` path, rollback function)

**Interfaces:**
- Consumes: nothing from Task 1 beyond `write_artifacts` (rollback already uses captured state).
- Produces: `RUN_LOG="/tmp/upgrade-prod-<YYYYmmdd-HHMMSS>.log"`; `/tmp/upgrade-prod.log` is always a symlink to the newest run; `log()` prefix `[%m-%d %H:%M:%S]`; sentinel line `VERDICT: <ok|failed|rolled-back> new=<version|-> pid=<pid|-> phase=<phase>` printed via `log` as the final line before exit.

- [ ] **Step 1: Run log + symlink.** At LOG_FILE definition: keep `LOG_LINK="/tmp/upgrade-prod.log"` but set `LOG_FILE` to the run name only when `UPGRADE_DETACHED=1` or `DRY_RUN`/`CHECK_ONLY`/`FOREGROUND`; in the detach branch, compute the run name once in the parent, export `UPGRADE_RUN_LOG=<name>` for the child, pass the child's own stderr to `2>>"$UPGRADE_RUN_LOG"`, `ln -sfn` it to `$LOG_LINK`, and print the tail-follow hint with the run name. Child: if `UPGRADE_RUN_LOG` set, use it; else (manual foreground) compute its own.

- [ ] **Step 2: Dated timestamps.** `log()` → `date '+%m-%d %H:%M:%S'`.

- [ ] **Step 3: Sentinel function + wiring.** Define `finish() { log "VERDICT: $1 new=${NEW_VERSION:-${NEW_VERSION_ACTUAL:-}} pid=${NEW_PID:-${PROD_PID:-}} phase=${PHASE}"; }` after `PHASE` is declared. Wire: success path calls `finish ok` before "Upgrade complete."; rollback path (inside `rollback()` after restoring) sets `ROLLED_BACK=true`; every `exit 1` goes through a wrapper or explicit `finish failed`/`finish rolled-back` (trap `on_signal` and the global-timeout path included). Keep it literal — one line, no cleverness.

- [ ] **Step 4: Syntax + live read-only check.** `bash -n` → clean. Run a `--dry-run` against prod `:4096` with the resolved caller model: verify new file `/tmp/upgrade-prod-<ts>.log` exists, `readlink /tmp/upgrade-prod.log` points at it, dated prefixes present, final line starts `VERDICT:` (failed or ok per outcome), prod pid unchanged, `:4097` free.

- [ ] **Step 5: Commit.**
  ```bash
  git add scripts/upgrade-prod.sh
  git commit -m "feat(scripts): per-run log with verdict sentinel"
  ```

### Task 3: `--check-only` preflight (no DB copy, no dev instance)

**Files:**
- Modify: `scripts/upgrade-prod.sh` (arg parse, header usage block, `--help` sed range, new exit block after step 1b)
- Modify: embedded `probe.py` (add `model-present` mode: `/api/model` list membership check for `providerID/id`, print `model-present: ok|missing (...)`, exit accordingly; reuse `wait_ready`)

**Interfaces:**
- Consumes: step 1 + 1a + 1b outputs; `PROD_ENV_FILE`, `PROD_CWD`.
- Produces: `--check-only` flag; exit code 0 = safe to attempt a real swap's gate, 1 = don't.

- [ ] **Step 1: Add `CHECK_ONLY=false`, parse `--check-only`, update usage header + the `--help` sed line range** (header grows — re-derive from `grep -n` so `--help` still prints exactly the comment block).

- [ ] **Step 2: Add `model-present` mode to probe.py** (argv: mode base env timeout provider model [+directory +ready-budget]; readiness via `wait_ready`, membership check like the prompt mode's `wanted` filter).

- [ ] **Step 3: Insert the check block after step 1b:** health probe against `http://127.0.0.1:$PROD_PORT` (existing health mode), `model-present` for `MODEL_PROVIDER/MODEL_NAME` with `PROD_CWD`, then `finish ok` + `exit 0` with a log line `CHECK ONLY: binary ok, prod healthy, caller model check passed, $MODEL_ID present. No DB copy, no dev instance.` It must run **before** the dev-port check and `backup_db "$DEV_DB"`. Skip the health probe if `PROD_PID` is empty (no live prod to probe); model-present then logs `skipped (no live prod)`.

- [ ] **Step 4: Live test — the original motivating check.** Run `--check-only` against prod `:4096` with a WRONG `--model`: expect step 1b abort (`does not match calling session model`), `VERDICT: failed`, no `/tmp/upgrade-prod.*` dirs created (check `ls -d /tmp/upgrade-prod.??????` before/after), elapsed < 5 s. Run with the CORRECT model: expect `VERDICT: ok`, health line with live version, `model-present: ok`, no temp dir, `:4097` still free, prod pid unchanged.

- [ ] **Step 5: Commit.**
  ```bash
  git add scripts/upgrade-prod.sh
  git commit -m "feat(scripts): add --check-only non-destructive preflight"
  ```

### Task 4: Docs — unpin versions, fix remotes, skew pointer, commit research

**Files:**
- Modify: `AGENTS.md` lines 5, 9-16, 92, 99 area (remotes, build recipe, version pins, shallow gotcha, swap section ~61-65)
- Create (tracked): `docs/research/autoupdate-mechanism.md`, `docs/research/opencode-v2-user-tracking-fingerprinting.md` (already exist untracked; user approved committing both)

**Interfaces:**
- Consumes: nothing.
- Produces: AGENTS.md with zero live-version numbers for the v2 path.

- [ ] **Step 1: AGENTS.md edits.**
  - Line 5: split remotes per repo — patches repo (`origin=aand18/opencode-patched`, `upstream=johnnymo87/opencode-patched`); `opencode-src/` (`origin=anomalyco/opencode` — **the release-tag source**, `upstream=johnnymo87/opencode`, `aand18=aand18/opencode`).
  - Build recipe line 9: `OPENCODE_VERSION=<NEW_VERSION>` + "both vars required; the number is not pinned — live prod binary: `readlink /proc/$(ss -tlnpH | awk '/:4096 /{split($0,a,"pid="); split(a[2],b,","); print b[1]}')/exe`; tree: `git -C opencode-src describe --tags`".
  - Lines 11/92/99: keep the bun-1.4.x fact and the pristine-tree rule, drop the pinned `2.1.4`/dates tied to a live version (v1 sections keep their historical numbers — they're marked obsolete).
  - Gotchas: add `git rev-parse --is-shallow-repository` before computing version deltas across tags (shallow clone cost six calls on 2026-11-08).
  - Swap section: add bullet — `upgrade-prod.sh moves :4096 only; the :49374 serve --service daemon keeps the binary it started with and hosts the agent sessions attached to it; it re-registers (SIGTERM→respawn, kills attached clients) only when a newer client hits Service.stop+ensure — a human-side restart in a quiet window. Details: docs/research/autoupdate-mechanism.md.`

- [ ] **Step 2: `git add AGENTS.md docs/research/ && git commit -m "docs: unpin live versions, correct per-repo remotes, document the :49374 skew"`.**

### Task 5: Build latest release (subagent, background)

**Files:** none in the patches repo; work in `opencode-src/` + one new file in `~/.opencode/bin/`.

**Interfaces:**
- Consumes: `git fetch origin --tags` from `origin=anomalyco/opencode`.
- Produces (report back): absolute path of the staged binary + `--version` output + tag SHA. Acceptance criterion baked into the brief: the file exists, is executable, `--version` prints `opencode v<X.Y.Z>` equal to the newest tag, report is ≤10 lines with those three facts.

- [ ] **Step 1: Dispatch `subagent` (agent: general, background=false) with brief:** determine newest tag (`git ls-remote --tags origin | grep -E 'refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1`); if equal to `git -C opencode-src describe --tags --exact-match`, say so and stop; else `git fetch origin tag <tag>`, `git checkout -f <tag>` (+ `git clean -fd` only if untracked leftovers from patches appear), `bun install`, `OPENCODE_VERSION=<X.Y.Z> OPENCODE_CHANNEL=latest bun run --cwd packages/cli build --single`, stage `packages/cli/dist/cli-linux-x64/bin/opencode` → `~/.opencode/bin/opencode-v<X.Y.Z>-latest-$(date +%Y%m%d%H%M)`, `chmod +x`, verify `--version`. Constraints from Global list; bun is 1.4.4 on PATH.

- [ ] **Step 2: Verify the artifact yourself** (fresh eyes): `ls -lh`, `--version`, tag matches `origin`.

### Task 6: Deploy to prod

**Files:** none (runtime only).

- [ ] **Step 1: Resolve the CALLER model live** (not remembered): `GET /api/session/$OPENCODE_SESSION_ID?directory=$PWD` on `:4096` with captured password → `model.providerID/model.id`.
- [ ] **Step 2: `--check-only`** with that model → expect `VERDICT: ok`.
- [ ] **Step 3: `--dry-run`** with that model → expect gate PONG, `VERDICT:`, prod untouched, step 1a refresh logs clean (no WARN — artifacts are current).
- [ ] **Step 4: Real swap** (detached default): follow `tail` on the run log named in the detach message until the `VERDICT:` line (single wait, not a poll loop); then independently verify `GET /api/info` version/pid via the captured env and `readlink /proc/<pid>/exe`.
- [ ] **Step 5: Post-deploy check:** `ss -tlnp` (prod pid moved, `:4097` free), artifacts updated (`source=verified-upgrade`), DB snapshot present, session still alive. Note the `:49374` skew is now one version wider — remind user it awaits a human-side restart.