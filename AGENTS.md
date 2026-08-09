## opencode-patched fork (aand18/opencode-patched)

**Repo:** `/home/dev/opencode-patched/` (patches repo)
**Source:** `/home/dev/opencode-patched/opencode-src/` (separate git clone)
**Remotes:** origin=aand18, upstream=johnnymo87, anomalyco=original (broken)

**CRITICAL:** Default bash workdir is `/home/dev/opencode-patched` (patches repo). All opencode-src git commands MUST use `workdir="/home/dev/opencode-patched/opencode-src"` to avoid accidentally resetting the wrong repo.

**Build:** `OPENCODE_VERSION=1.18.15 OPENCODE_CHANNEL=prod bun run --cwd packages/opencode build`
- `OPENCODE_VERSION` MUST be set to a version that exists on npm (e.g., `1.18.15`), otherwise plugin dependency resolution will fail: `@opencode-ai/plugin@0.0.0-prod-...` 404s on npm.
- After switching to a new release tag, run `bun install` first — v1.18.15+ vendors `@opencode-ai/client` as a tarball (`packages/app/vendor/`), and without it the app build fails on `@opencode-ai/client/promise` resolution.
- Without `OPENCODE_CHANNEL=prod`, channel defaults to git branch name (non-prod), which defaults the new UI layout to `true` and hides the old UI toggle.
- Binary output: `packages/opencode/dist/opencode-linux-x64/bin/opencode`
- Binaries stored at: `~/.opencode/bin/`

**After build:**
1. Copy binary to `~/.opencode/bin/` with versioned name: `cp opencode-src/packages/opencode/dist/opencode-linux-x64/bin/opencode ~/.opencode/bin/opencode-v{VERSION}-patched-{CHANNEL}-{TIMESTAMP}` (e.g., `opencode-v1.18.3-patched-prod-202607251625`). `{CHANNEL}` matches `OPENCODE_CHANNEL` env var (e.g., `prod`). Get timestamp from `--version` output.
2. Backup database with sqlite online backup API (plain `cp` MISSES the WAL tail — verified 2026-08-09: cp-backed .bak was 50 messages/12 min stale while live db is in WAL mode): `sqlite3 ~/.local/share/opencode/opencode.db ".backup $HOME/.local/share/opencode/opencode.db.bak.{TIMESTAMP}"` (note: sqlite3 does NOT expand `~` in the .backup target; use `$HOME` or absolute path)

**UI toggle:** New layout is controlled by `newLayoutDesigns` in browser localStorage key `settings.v3` under `general`. Toggle in Settings → General → "New layout". Sunset date: Sept 14, 2026 (old UI forced off after).

**Patches:** `patches/apply.sh` header is the source of truth for patch set, apply order, dependency constraints, and dropped patches. `README.md` has the same info summarized.

**Workflows:**

Roll forward to a new upstream release:
1. Fetch new tag into opencode-src (detached HEAD at tag; create local tag from FETCH_HEAD)
2. Run `bun install` (v1.18.15+ vendors `@opencode-ai/client` tarball)
3. `./patches/apply.sh opencode-src` — fix/rebase any failing patch, verify fresh-clone apply 24/24
4. Build, install binary (versioned name + `.bak.{TIMESTAMP}` DB backup)
5. Update version pins: `AGENTS.md`, `README.md`, `apply.sh` header
6. Commit in patches repo only (never commit in opencode-src)

Align with johnnymo87/opencode-patched upstream/main:
1. `git fetch upstream` (johnnymo87) in patches repo; diff `upstream/main` patches vs ours
2. Per patch: adopt (rebased into our stack) / skip (heavy rebase friction, e.g. tui-door-attach, tui-reconcile-bound) / drop (user preference — gemini-empty-parts, vim, opus5-adaptive-thinking)
3. Update `apply.sh` header + README table; verify clean-clone apply + build before committing

**Gotchas:**
- opencode-src working tree is dirty with patch changes (by design); never `git checkout .` / `git reset` it
- Patches repo shows spurious "modified" files from CRLF/autocrlf stat-cache noise — running `bun install` or writes to tracked files resets them; skip unrelated noise when staging

**Patch dependency order (in apply.sh):** #11 after #10, #14 after #13, #19 after #18.

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
