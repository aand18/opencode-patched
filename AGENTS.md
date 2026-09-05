## opencode-patched fork (aand18/opencode-patched)

**Repo:** `/home/dev/opencode-patched/` (patches repo)
**Source:** `/home/dev/opencode-patched/opencode-src/` (separate git clone)
**Remotes:** origin=aand18, upstream=johnnymo87, anomalyco=original (broken)

**CRITICAL:** Default bash workdir is `/home/dev/opencode-patched` (patches repo). All opencode-src git commands MUST use `workdir="/home/dev/opencode-patched/opencode-src"` to avoid accidentally resetting the wrong repo.

**Build:** `OPENCODE_VERSION=1.18.21 OPENCODE_CHANNEL=prod bun run --cwd packages/opencode build`
- **Fast path (local iteration): append `--single`** — builds only the current platform (`opencode-linux-x64`) instead of all 12 targets. Verified 2026-08-30: ~29 s vs ~5 min for the full build, smoke test included. Use for patch iteration; the full multi-target build is only needed for release/publishing. Optional extra: `--skip-install` additionally skips the cross-platform `bun install --os="*"` steps — only safe when dependencies have not changed since the last `bun install`.
- `OPENCODE_VERSION` MUST be set to a version that exists on npm (e.g., `1.18.21`), otherwise plugin dependency resolution will fail: `@opencode-ai/plugin@0.0.0-prod-...` 404s on npm.
- After switching to a new release tag, run `bun install` first — v1.18.15+ vendors `@opencode-ai/client` as a tarball (`packages/app/vendor/`), and without it the app build fails on `@opencode-ai/client/promise` resolution.
- Without `OPENCODE_CHANNEL=prod`, channel defaults to git branch name (non-prod), which defaults the new UI layout to `true` and hides the old UI toggle.
- Binary output: `packages/opencode/dist/opencode-linux-x64/bin/opencode`
- Binaries stored at: `~/.opencode/bin/`

**After build:**
1. Copy binary to `~/.opencode/bin/` with versioned name: `cp opencode-src/packages/opencode/dist/opencode-linux-x64/bin/opencode ~/.opencode/bin/opencode-v{VERSION}-patched-{CHANNEL}-{TIMESTAMP}` (e.g., `opencode-v1.18.3-patched-prod-202607251625`). `{CHANNEL}` matches `OPENCODE_CHANNEL` env var (e.g., `prod`). Get timestamp from `--version` output.
2. Backup database with sqlite online backup API (plain `cp` MISSES the WAL tail — verified 2026-08-09: cp-backed .bak was 50 messages/12 min stale while live db is in WAL mode): `sqlite3 ~/.local/share/opencode/opencode.db ".backup $HOME/.local/share/opencode/opencode.db.bak.{TIMESTAMP}"` (note: sqlite3 does NOT expand `~` in the .backup target; use `$HOME` or absolute path)

**Dev (no build):** run the patched source directly — no binary build needed for testing changes/patches. `./dev-serve.sh` (repo root) mirrors the built binary: same env (`OPENCODE_SERVER_PASSWORD`, `OPENCODE_DB`) + `serve --hostname 0.0.0.0 --port 4096 --mdns`. Edit a file → `Ctrl-C` → rerun.
- Command is `bun --conditions=browser --define 'OPENCODE_VERSION="1.18.21"' --define 'OPENCODE_CHANNEL="prod"' <src>/packages/opencode/src/index.ts serve …`. Run the file **directly** (`bun [flags] file.ts`), not `bun run file.ts` — `--define` is not a `bun run` subcommand flag (it prints usage and exits).
- The `--define` flags mirror the prod binary (source otherwise falls back to `version="local"`, `channel="local"`); keep `channel=prod` or the new-UI layout default flips.
- **Web UI:** source mode proxies it from `https://app.opencode.ai` — the embedded `opencode-web-ui.gen.ts` only resolves under `Bun.build` (a no-`./` import specifier). Fine for backend/patch testing (UI still hits your patched API); run `bun run dev:web` (Vite) separately for the patched UI. The backend's own port therefore never shows local session-ui/app changes — always verify UI patches in the Vite dev UI.
- `OPENCODE_MODELS_DEV` is unset at source, so the first model-list load fetches `models.opencode.ai` (5-min cache under `Global.Path.cache`).
- Overrides: `DEV_SERVE_HOST`, `DEV_SERVE_PORT`, `DEV_SERVE_MDNS` (0/1), `OPENCODE_SERVER_PASSWORD`, `OPENCODE_DB`, `DEV_SERVE_NO_AUTH` (0/1). Extra args forward to `opencode serve`.
- Testing without a password: `DEV_SERVE_NO_AUTH=1` unsets `OPENCODE_SERVER_PASSWORD` (server auth is skipped when it is unset/empty), so dev servers can be added in the dev UI with no credentials. Testing-only — prod always keeps its password.
- Dev database: never point a dev backend at the prod DB file (SQLite lock contention with the prod server). Copy it to tmp first via the online backup API — plain `cp` misses the WAL tail: `sqlite3 $HOME/.local/share/opencode/opencode.db ".backup /tmp/opencode-dev.db"`, then `OPENCODE_DB=/tmp/opencode-dev.db`. Re-copy when the copy goes stale (prod keeps changing).
- Cleanup when done: stop the dev backend + Vite dev UI, then `rm -f /tmp/opencode-dev.db*` (also removes `-wal`/`-shm` sidecars). Optionally remove the test server entries in the dev UI server picker.
- Dev UI against prod backend: works from desktop only — the CORS allowlist covers any `http://localhost:<port>` origin, so the Vite dev UI can add `http://localhost:4096` (+ password) with no restarts. From a LAN IP it is blocked (prod can't take `--cors` without a restart — don't). Sensible only for read-only checks of display-only changes when versions match (verified 2026-09-04: prod binary and source both at v1.18.21); the dev UI can otherwise issue real mutations (prompts, revert, fork, delete) against prod sessions, so interactive testing stays on the dev backend.
- LAN testing: backend CORS allowlist defaults to localhost / 127.0.0.1 / tauri / `opencode.ai` only — a dev UI opened from another device (phone via LAN IP) shows "could not connect" until the exact UI origin is passed, e.g. `DEV_SERVE_PORT=4097 ./dev-serve.sh --cors http://192.168.88.11:4098` (verified 2026-09-04).
- Adding the server in the dev UI: server picker → "Servers" → Add server → address `http://<host>:<port>` (name optional, username optional defaulting to `opencode`, password = `OPENCODE_SERVER_PASSWORD`), then set it as default server.
- Auto-populate (dev UI only, `packages/app/src/entry.tsx`): `VITE_OPENCODE_SERVER_HOST` / `VITE_OPENCODE_SERVER_PORT` at vite startup set the initial server (default `localhost:4096`) — e.g. `VITE_OPENCODE_SERVER_HOST=192.168.88.11 VITE_OPENCODE_SERVER_PORT=4097 bun dev -- --port 4098`. Credentials via `?auth_token=<base64("user:password")>` (seeded as Basic auth, stripped from the URL after read). Caveat: a previously stored `defaultServerUrl` in that browser's localStorage wins — clear it or re-pick the server.
- **Mobile Web UI testing — dev backend `:4097` + dev UI `:4098` (verified 2026-09-04, prod `:4096` untouched throughout):**
  1. Fresh prod copy (stop dev backend first if it holds the file): `sqlite3 $HOME/.local/share/opencode/opencode.db ".backup /tmp/opencode-dev-4097.db"`
  2. Dev backend (no password, LAN CORS for the phone UI): `DEV_SERVE_PORT=4097 DEV_SERVE_MDNS=0 DEV_SERVE_NO_AUTH=1 OPENCODE_DB=/tmp/opencode-dev-4097.db ./dev-serve.sh --cors http://192.168.88.11:4098` (drop `--cors` for desktop-only testing)
  3. Dev UI (pre-pointed at the dev backend so the phone needs no manual server add): `VITE_OPENCODE_SERVER_HOST=192.168.88.11 VITE_OPENCODE_SERVER_PORT=4097 bun dev -- --port 4098` from `opencode-src/packages/app`
  4. On the phone open `http://192.168.88.11:4098` (desktop: `http://localhost:4098`); the `:4097` dev backend is already the default server and needs no credentials; validate against sessions containing the relevant tool calls
  5. Iterate: UI edits hot-reload via Vite (phone needs only a refresh); backend edits need dev-backend restart; re-copy the DB when it goes stale
  6. Cleanup per above when done

**UI toggle:** New layout is controlled by `newLayoutDesigns` in browser localStorage key `settings.v3` under `general`. Toggle in Settings → General → "New layout". Sunset date: Sept 14, 2026 (old UI forced off after).

**Patches:** `patches/apply.sh` header is the source of truth for patch set, apply order, dependency constraints, and dropped patches. `README.md` has the same info summarized.

**Workflows:**

Full step-by-step runbook (fetch tag → apply → rebase → build → install → backup
→ align fork → docs → commit): `docs/plans/2026-08-10-upgrade-procedure-opencode-and-patches.md`.

Roll forward to a new upstream release:
1. Fetch new tag into opencode-src (detached HEAD at tag; create local tag from FETCH_HEAD)
2. Run `bun install` (v1.18.15+ vendors `@opencode-ai/client` tarball)
3. `./patches/apply.sh opencode-src` — fix/rebase any failing patch, verify fresh-clone apply (34/34 at v1.18.21)
4. Build, install binary (versioned name + `.bak.{TIMESTAMP}` DB backup)
5. Update version pins: `AGENTS.md`, `README.md`, `apply.sh` header
6. Commit in patches repo only (never commit in opencode-src)

Align with johnnymo87/opencode-patched upstream/main:
1. `git fetch upstream` (johnnymo87) in patches repo; diff `upstream/main` patches vs ours
2. Per patch: adopt (rebased into our stack) / skip (only if verified heavy friction at current tag) / drop (user preference)
   - **USER-REQUESTED EXCLUSIONS (diverge from parent intentionally, documented here):** `gemini-empty-parts.patch` (PR #28669), `vim.patch` (PR #12679), `opus5-adaptive-thinking.patch` (cherry-pick #38757) — upstream still carries them; we drop per user preference.
   - All other parent patches are adopted (as of 2026-08-23: `db-isolation-guard`, `message-serve-provenance`, `tui-door-attach`, `tui-reconcile-bound` all adopted; `retry-cap` dropped as upstreamed `c78986831c` with stricter `MAX=5`).
   - Local-only patches kept as safety (parent does not carry, still useful at v1.18.21): `vcs-untracked-normal` (VCS crash), `revert-orphan-parents` (#38864).
3. Update `apply.sh` header + README table; verify clean-clone apply + build before committing

New UI patches (web app): verify cosmetics live BEFORE cutting the patch — swap
classes in the running app via chrome-devtools `evaluate_script` and measure the
result (e.g. element `scrollWidth` vs `offsetWidth`), which is much cheaper than a
build/install cycle. Tailwind arbitrary-value classes (`w-[360px]`) beat non-important
inline `style` in live DOM tests — use `!important` to override them. Record the
measured sizing basis (real strings + max width) in the `apply.sh` header comment so
rebase/re-derivation has a why, not a guess.

**Gotchas:**
- opencode-src working tree is dirty with patch changes (by design); never `git checkout .` / `git reset` it
- Patches repo shows spurious "modified" files from CRLF/autocrlf stat-cache noise — running `bun install` or writes to tracked files resets them; skip unrelated noise when staging

**Patch dependency order (in apply.sh):** #9 after #4, #22 after #6, #19 after #16, #17 after #7, #21 last, #24 after #3 (see header for all). Legacy 24-patch stack was #11 after #10 etc.

**VCS large repo fix (v1.18.3+):** `vcs-untracked-normal.patch` switches `git status --untracked-files=all` to `--untracked-files=normal` and filters directory entries. Prevents CPU saturation and VCS crash on repos with many untracked files (upstream #33928, #21699, #3176).

**UI toggle bug (v1.18.x):** The "New layout" toggle in Settings → General is hidden by default because `layoutTransitionEligible` defaults to `false` and nothing ever sets it to `true`. To show the toggle and switch to old layout, run in browser console:
```javascript
const s = JSON.parse(localStorage.getItem("settings.v3") || "{}");
s.general = s.general || {};
s.general.layoutTransitionEligible = true;
s.general.newLayoutDesigns = false;
localStorage.setItem("settings.v3", JSON.stringify(s));
location.reload();
```
