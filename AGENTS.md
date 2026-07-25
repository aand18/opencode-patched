## opencode-patched fork (aand18/opencode-patched)

**Repo:** `/home/dev/opencode-patched/` (patches repo)
**Source:** `/home/dev/opencode-patched/opencode-src/` (separate git clone)
**Remotes:** origin=aand18, upstream=johnnymo87, anomalyco=original (broken)

**CRITICAL:** Default bash workdir is `/home/dev/opencode-patched` (patches repo). All opencode-src git commands MUST use `workdir="/home/dev/opencode-patched/opencode-src"` to avoid accidentally resetting the wrong repo.

**Build:** `OPENCODE_CHANNEL=prod bun run --cwd packages/opencode build`
- Without `OPENCODE_CHANNEL=prod`, channel defaults to git branch name (non-prod), which defaults the new UI layout to `true` and hides the old UI toggle.
- Binary output: `packages/opencode/dist/opencode-linux-x64/bin/opencode`
- Binaries stored at: `~/.opencode/bin/`

**UI toggle:** New layout is controlled by `newLayoutDesigns` in browser localStorage key `settings.v3` under `general`. Toggle in Settings → General → "New layout". Sunset date: Sept 14, 2026 (old UI forced off after).

**Patches:** See `patches/apply.sh` header for current patch set and dropped patches.

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
