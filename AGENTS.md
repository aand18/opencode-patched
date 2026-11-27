## opencode-patched fork (aand18/opencode-patched)

**Repo:** `/home/dev/opencode-patched/` (patches repo)
**Source:** `/home/dev/opencode-patched/opencode-src/` (separate git clone)
**Remotes (patches repo):** origin=aand18/opencode-patched, upstream=johnnymo87/opencode-patched.
**Remotes (opencode-src/):** origin=anomalyco/opencode — the release-tag source (`git ls-remote --tags origin | sed 's|.*refs/tags/||' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1`), upstream=johnnymo87/opencode, aand18=aand18/opencode.

**CRITICAL:** Default bash workdir is `/home/dev/opencode-patched` (patches repo). All opencode-src git commands MUST use `workdir="/home/dev/opencode-patched/opencode-src"` to avoid accidentally resetting the wrong repo.

**Build (v2 — what prod runs, vanilla):** `OPENCODE_VERSION=<X.Y.Z> OPENCODE_CHANNEL=latest bun run --cwd packages/cli build --single` — both vars are required; the version number is never pinned here, look it up: target tag from origin (above), live prod binary via `readlink /proc/$(ss -tlnpH | grep -oP ':4096\s.*pid=\K[0-9]+' | head -1)/exe`, tree via `git -C opencode-src describe --tags`.
- v2 restructure: the package is `packages/cli` (`@opencode/cli`), not `packages/opencode`; output is `packages/cli/dist/cli-linux-x64/bin/opencode` (the target name uses `cli` where v1 used `opencode`). Layout/flags verified 2026-10-05; `--single`, `--target=<t>`, `--skip-install`, `--skip-web-ui` present (`packages/cli/script/build.ts`).
- v2 needs bun `^packageManager` (root `package.json`; 1.4.4 since v2.1.4) — an older host bun hard-fails `packages/script`, and build.ts spawns `bun install` itself. Host bun is 1.4.4 (since Nov 2026); if it ever falls behind, `npm i --prefix /tmp/bun144 bun@<ver>` and PATH-prepend for the install + build only.
- Channels are `latest`/`beta`/`dev` (not `prod`). `latest` maps to the plain `opencode.db`, writes `service.json`, and defaults the service port to 0xc0de (49374) — a second instance must set `OPENCODE_DB`. Plain `serve` runs `--service=false` (no registration).
- Server password env is `OPENCODE_PASSWORD`; `OPENCODE_SERVER_PASSWORD` is the fallback (`packages/cli/src/env.ts`).
- Unpatched v2 builds are named `opencode-v{VERSION}-{CHANNEL}-{TIMESTAMP}` — no `patched` infix.

**After build:**
1. Copy binary to `~/.opencode/bin/` with versioned name: `cp opencode-src/packages/opencode/dist/opencode-linux-x64/bin/opencode ~/.opencode/bin/opencode-v{VERSION}-patched-{CHANNEL}-{TIMESTAMP}` (e.g., `opencode-v1.18.3-patched-prod-202607251625`). `{CHANNEL}` matches `OPENCODE_CHANNEL` env var (e.g., `prod`). Get timestamp from `--version` output.
2. Backup database with sqlite online backup API (plain `cp` MISSES the WAL tail — verified 2026-08-09: cp-backed .bak was 50 messages/12 min stale while live db is in WAL mode): `sqlite3 ~/.local/share/opencode/opencode.db ".backup $HOME/.local/share/opencode/opencode.db.bak.{TIMESTAMP}"` (note: sqlite3 does NOT expand `~` in the .backup target; use `$HOME` or absolute path)
   Each upgrade leaves a full snapshot next to the DB (~4.4 GB as of 2026-10-25). Trimming them is a manual step, not script logic: keep the newest 3, confirm the live `opencode.db`/`-wal` are not in the candidate list, check `fuser` for open handles, then remove. 30 stale snapshots pruned 2026-10-25 (119 GB).

**Dev (v2 source, no build):** `bun run dev` from the repo root runs `bun run --cwd packages/cli src/index.ts`; `bun run dev:vite` for the web app, `bun run dev:web` for `packages/app`. The `dev:live` scripts wire `OPENCODE_PASSWORD` and `--server` from the running service.

**UI toggle:** New layout is controlled by `newLayoutDesigns` in browser localStorage key `settings.v3` under `general`. Toggle in Settings → General → "New layout". Sunset date: Sept 14, 2026 (old UI forced off after).

**Patches (v1):** `patches/apply.sh` header is the source of truth for patch set, apply order, dependency constraints, and dropped patches. `README.md` has the same info summarized.
**v1 patch stack (obsolete; archived 2026-11-27):** build/dev/roll-forward/align/patch-order/UI-toggle details moved to `docs/archive/v1-patch-stack.md`.

**Workflows:**

Full step-by-step runbook (fetch tag → apply → rebase → build → install → backup
→ align fork → docs → commit): `docs/plans/2026-08-10-upgrade-procedure-opencode-and-patches.md`.

Swapping the **running prod binary** (:4096) without a manual restart: `scripts/upgrade-prod.sh <new-binary> --model <providerID/modelID>`.
- Verifies before prod is touched: a dev instance on a DB copy, running with prod's captured env, must answer a real PONG round-trip on `--model`. Then health + PONG on the relaunched prod; any failure after prod stops restores the DB backup and relaunches the previous binary.
- `--check-only` runs the cheap preflight (binary version, artifact refresh, caller-model check, prod health, model-present) and stops before the DB copy / dev instance — use it first; the full `--dry-run` costs a 4.4 GB DB copy.
- The swap moves `:4096` only. The `:49374` `serve --service` daemon keeps the binary it started with and hosts **only** the sessions attached to it — on this box nothing is attached; prod sessions ride :4096, so kill it freely; respawns take the PATH symlink (e2e-tested 2026-11-19: a client-style `opencode serve --service` respawn via PATH bound :49374 on the v2.3.2 binary, registered it, and answered `/api/info`). Which server your own session rides is read from ancestry: `readlink /proc/$PPID/exe` walked up to a listener pid from `ss -tlnpH` — the process on this box, where the doc names only the mechanism. It re-registers (SIGTERM→respawn, terminating attached clients) only when a newer-version client triggers `Service.stop`+`ensure` — a human-side restart in a quiet window. Details: `docs/research/autoupdate-mechanism.md`. Closing the version skew promptly matters: migrations from the new build are shared through the same `opencode.db`.
- On verified success step 8 repoints `~/.opencode/bin/opencode` → the new binary (`--path-symlink <path>` overrides; empty disables). `~/.local/bin/opencode` → that symlink is the PATH entry client respawns resolve; timestamped binaries are never removed by the script.
- At boot, prod is started by the **systemd user unit** `opencode-prod.service` (linger enabled; WSL `systemd=true`): `ExecStart=%h/.opencode/bin/opencode serve --hostname 0.0.0.0 --port 4096`, secrets from `~/.config/opencode/prod.env` (0600), `Restart=no` — during a swap the script SIGTERMs the server, and systemd must not respawn an unverified build; the unit takes over again at the next boot. Verified by isolated clone on :4121 (exe=resolved symlink, api version match) 2026-11-23. For any manual start, go through the `~/.opencode/bin/opencode` symlink — a versioned filename in shell history left prod on v2.2.6 from Nov 21 until the Nov 23 swap.
- `--model` names the model that must keep working — pass the one the calling session uses. Resolve it from `$OPENCODE_SESSION_ID` via `GET /api/session/{id}` (`model.providerID`/`model.id`) before invoking; the script verifies `--model` against it and aborts on mismatch — never reuse a remembered model.
- Detaches itself (setsid) before it can stop :4096, because that server hosts the session running it. Run `--dry-run` first (foreground, prod untouched). Progress: the detach message names the per-run log; `/tmp/upgrade-prod.log` is a symlink to the newest one; the last line of every run is a `VERDICT:` sentinel.
- Exercise the destructive path against a throwaway instance instead of prod: `--prod-port 4120 --config-file … --last-good …`.

**Gotchas:**
- opencode-src is kept at a pristine tag checkout (`git -C opencode-src describe --tags` says which). Build patched variants in a worktree (`git worktree add ../<name> <tag>`) and keep this tree at a tag, so a patch experiment never costs the tree
- Patches repo shows spurious "modified" files from CRLF/autocrlf stat-cache noise — running `bun install` or writes to tracked files resets them; skip unrelated noise when staging

**The live HTTP surface is v2's `/api/…`, not the v1 `/session` routes** (the v1 tree cost a wrong turn on 2026-10-24):
- Live surface is `/api/…`: `POST /api/session` (create, `{model:{providerID,id}}`), `POST /api/session/{id}/prompt` (`{text}` — admits only), `GET /api/session/{id}/message`, `POST /api/experimental/session/{id}/wait` (blocks until the agent loop is idle — the completion signal), `GET /api/model?directory=`, `GET /api/info` (version/pid — the useful liveness probe). Legacy `POST /session` returns 405.
- `Model.Ref` is `{id, providerID}`, not `modelID`; assistant messages carry `model` plus `content[]`.
- A fresh `serve` binds its port before location plugins activate and answers 503 `Location plugins did not finish activating` for ~10–45 s — poll for readiness. `/global/health` and `/health` return the SPA HTML catch-all, not JSON.
- `opencode-src` is kept a pristine tag checkout (0 modified expected; the v1 patch stack is obsolete and its working-tree state was discarded). Other tags read with `git show <tag>:<path>` — all v2 tags are fetched locally. Before computing any cross-tag delta, check `git -C opencode-src rev-parse --is-shallow-repository`: a shallow clone makes `merge-base` fail and tag logs count 1 (cost six calls on 2026-11-08); fix with `git fetch --unshallow origin`.
- After moving the tree to a new tag, `bun install` with the `packageManager` bun version is needed before a v2 build (`node_modules`/`dist` lag behind the checkout).
