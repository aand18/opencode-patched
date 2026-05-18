# Add Cache-Fix Patches Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to
> implement this plan task-by-task. Companion design doc:
> `2026-05-18-add-cache-fix-patches-design.md`. Beads epic: `workstation-b4p`.

**Goal:** Add three unmerged upstream prompt-cache cost-reduction PRs
(#25367, #25100, #27377/#27378) to our `opencode-patched` build
pipeline, ship a `v1.15.0-patched` release, bump the workstation home-manager
pin, and run a comparable workload to measure the cost delta. Also ship a
usage-logging plugin in workstation to settle the 2× compaction-cost
mystery.

**Architecture:** Each PR becomes a patch file in
`opencode-patched/patches/`. The existing `apply.sh` script gets updated to
apply them in dependency order (`#25367 → #25100 → #27377`) BEFORE the
unrelated patches (`vim`, `tool-fix`, etc.). A separate
`workstation/assets/opencode/plugins/cache-usage-logger.ts` ships
independently via the workstation home-manager flake.

**Tech Stack:** opencode-patched (bash + git apply), workstation (Nix +
home-manager), opencode plugin runtime (TypeScript), GitHub Actions
(release workflow), beads (issue tracking), oc-cost (cost analysis).

---

## Task 1: Probe each PR diff against pristine v1.15.0

**Why first:** before writing any patch file, verify each PR applies cleanly
or document the rejects. This drives all downstream effort estimates.

**Files (probe-only, no commits):**

- Probe: `/tmp/opencode-cache-probe/opencode-v1.15.0/` (scratch checkout)

**Step 1.1: Fetch pristine v1.15.0**

```bash
mkdir -p /tmp/opencode-cache-probe
cd /tmp/opencode-cache-probe
git clone --depth 1 --branch v1.15.0 https://github.com/anomalyco/opencode.git opencode-v1.15.0
cd opencode-v1.15.0
git log -1 --oneline
```

Expected: a commit hash on `HEAD` for v1.15.0 release tag.

**Step 1.2: Apply caching.patch first (we always do this)**

```bash
cd /tmp/opencode-cache-probe/opencode-v1.15.0
curl -sfL https://raw.githubusercontent.com/johnnymo87/opencode-cached/main/patches/caching.patch > /tmp/caching-base.patch
git apply --check /tmp/caching-base.patch && echo OK
git apply /tmp/caching-base.patch
git diff --stat
```

Expected: caching.patch applies cleanly (we've already shipped this for
v1.15.0).

**Step 1.3: Fetch + probe PR #25367 diff**

```bash
gh pr diff 25367 --repo anomalyco/opencode > /tmp/pr-25367.patch
wc -l /tmp/pr-25367.patch  # expect ~50 lines
cd /tmp/opencode-cache-probe/opencode-v1.15.0
git apply --check /tmp/pr-25367.patch 2>&1 | tee /tmp/pr-25367-check.txt
```

Expected outcomes (record which applies):
- **A:** clean apply → proceed to Step 1.4 directly.
- **B:** 1-2 hunk rejects → record in design doc retro under "Open
  questions", needs anchor refresh.
- **C:** target file not found → escalate; redesign.

**Step 1.4: Apply #25367 to scratch, fetch + probe PR #25100**

```bash
cd /tmp/opencode-cache-probe/opencode-v1.15.0
git apply /tmp/pr-25367.patch  # or refresh anchors if Step 1.3 was B
gh pr diff 25100 --repo anomalyco/opencode > /tmp/pr-25100.patch
wc -l /tmp/pr-25100.patch
git apply --check /tmp/pr-25100.patch 2>&1 | tee /tmp/pr-25100-check.txt
```

Same A/B/C decision tree. Record outcome.

**Step 1.5: Apply #25100, fetch + probe PR #27377**

```bash
cd /tmp/opencode-cache-probe/opencode-v1.15.0
git apply /tmp/pr-25100.patch  # or refresh
gh pr diff 27377 --repo anomalyco/opencode > /tmp/pr-27377.patch
wc -l /tmp/pr-27377.patch
git apply --check /tmp/pr-27377.patch 2>&1 | tee /tmp/pr-27377-check.txt
```

Same A/B/C. **If C on any step, stop and update the design doc.**

**Step 1.6: Record findings in design doc**

Update `opencode-patched/docs/plans/2026-05-18-add-cache-fix-patches-design.md`'s
"Plan B if a patch doesn't apply cleanly" section with the actual outcomes.

**Step 1.7: Commit findings**

```bash
cd ~/projects/opencode-patched
git add docs/plans/2026-05-18-add-cache-fix-patches-design.md
git commit -m "docs: probe v1.15.0 + caching apply check for #25367, #25100, #27377"
```

---

## Task 2: Add `prompt-loop-cache.patch` (PR #25367)

**Bead:** `workstation-tbn`

**Files:**

- Create: `opencode-patched/patches/prompt-loop-cache.patch`
- Modify: `opencode-patched/patches/apply.sh` (add as new patch step)
- Modify: `opencode-patched/README.md` (document the new patch)

**Step 2.1: Save patch from probe**

```bash
cp /tmp/pr-25367.patch ~/projects/opencode-patched/patches/prompt-loop-cache.patch
```

If `vite.js` change is not needed for v1.15.0 (verify by looking at the
file in v1.15.0), strip that hunk:

```bash
# Edit prompt-loop-cache.patch and remove the packages/app/vite.js hunk if
# v1.15.0's vite.js already has @opencode-ai/core alias or doesn't need it.
```

**Step 2.2: Add header comment to patch file**

Prepend:

```
# Patch: prompt-loop byte identity (anomalyco/opencode#25367)
# Source: https://github.com/anomalyco/opencode/pull/25367
# Captured at PR head: <RECORD COMMIT SHA>
# Why: caches the conversation array across prompt-loop iterations so
# tool-call continuations preserve byte-identity. Eliminates the
# flat-cache_read + growing-input cost-leak pattern observed in
# ses_1c70728a7ffeLlgL1FsKXdTQLu. See
# docs/plans/2026-05-18-add-cache-fix-patches-design.md.
```

To get the SHA:

```bash
gh pr view 25367 --repo anomalyco/opencode --json headRefOid -q .headRefOid
```

**Step 2.3: Add to apply.sh between caching.patch and vim.patch**

Edit `opencode-patched/patches/apply.sh`. Insert this block after the
`Caching patch applied` echo (around line 95) and before the `--- Patch 2:
Vim` divider:

```bash
# --- Patch 2: Prompt-loop byte identity (PR #25367) ---

echo "Applying prompt-loop-cache.patch..."
if ! git apply --check "$PROMPT_LOOP_CACHE_PATCH" 2>/dev/null; then
  echo ""
  echo "❌ PROMPT LOOP CACHE PATCH FAILED TO APPLY"
  echo ""
  echo "Attempting to apply for diagnostics..."
  git apply "$PROMPT_LOOP_CACHE_PATCH" 2>&1 || true
  echo ""
  echo "Failed files:"
  find . -name "*.rej" -type f 2>/dev/null || echo "  None found"
  echo ""
  echo "The prompt-loop-cache patch may need updating for this upstream version."
  echo "Source PR: https://github.com/anomalyco/opencode/pull/25367"
  exit 1
fi

git apply "$PROMPT_LOOP_CACHE_PATCH"
echo "✓ Prompt-loop-cache patch applied"
```

Also add `PROMPT_LOOP_CACHE_PATCH="$SCRIPT_DIR/prompt-loop-cache.patch"` to
the variable definitions at the top, and add an `if [ ! -f
"$PROMPT_LOOP_CACHE_PATCH" ]` guard alongside the existing ones.

Renumber subsequent patch comments (Patch 2 → 3, etc.) for clarity.

**Step 2.4: Verify full apply.sh stack against v1.15.0**

```bash
rm -rf /tmp/opencode-cache-probe/opencode-v1.15.0
cd /tmp/opencode-cache-probe
git clone --depth 1 --branch v1.15.0 https://github.com/anomalyco/opencode.git opencode-v1.15.0
~/projects/opencode-patched/patches/apply.sh /tmp/opencode-cache-probe/opencode-v1.15.0
```

Expected: every patch in the stack applies cleanly. New summary should list
`prompt-loop-cache.patch` among the applied patches.

**Step 2.5: Update README**

In `opencode-patched/README.md`, add a new section under "Patches Included":

```markdown
### 6. Prompt-Loop Byte Identity ([PR #25367](https://github.com/anomalyco/opencode/pull/25367))

Stored locally as `patches/prompt-loop-cache.patch`. Caches the
conversation array across prompt-loop iterations so tool-call continuations
preserve byte-identity, eliminating the "flat cache_read + growing
uncached input" cost pattern that bills the entire tool-output tail at
full input price every turn.

Without this patch, sessions with heavy tool use can spend $10+ on the
same context paying full input price across many turns. With this patch,
warm-cache reuse persists across tool continuations.
```

Renumber subsequent patch headings.

**Step 2.6: Commit**

```bash
cd ~/projects/opencode-patched
git add patches/prompt-loop-cache.patch patches/apply.sh README.md
git commit -m "feat(prompt-loop-cache): patch in anomalyco/opencode#25367

Caches conversation array across prompt-loop iterations to preserve
byte-identity on tool-call continuations. Eliminates the flat-cache_read +
growing-input cost pattern observed in ses_1c70728a7ffeLlgL1FsKXdTQLu.

Captured at PR head <SHA>. See docs/plans/2026-05-18-add-cache-fix-patches-design.md."
```

**Step 2.7: Close bead**

```bash
cd ~/projects/workstation
bd update workstation-tbn --status in_progress
# (already in_progress)
bd close workstation-tbn --reason "patch committed; ready for release cut"
bd sync
```

---

## Task 3: Add `cache-aligned-compaction.patch` (PR #25100)

**Bead:** `workstation-z5b`

**Files:**

- Create: `opencode-patched/patches/cache-aligned-compaction.patch`
- Modify: `opencode-patched/patches/apply.sh`
- Modify: `opencode-patched/README.md`

**Step 3.1: Save patch from probe**

```bash
cp /tmp/pr-25100.patch ~/projects/opencode-patched/patches/cache-aligned-compaction.patch
```

**Step 3.2: Add header comment to patch file**

```
# Patch: cache-aligned compaction (anomalyco/opencode#25100)
# Source: https://github.com/anomalyco/opencode/pull/25100
# Captured at PR head: <SHA>
# Why: compaction currently builds its own LLM request with empty system
# prompt + no tools + filtered history, missing the prefix cache entirely.
# This patch aligns compaction's request shape to the normal agent-loop
# prefix so historical messages hit the provider cache. Author claims
# ~90% compaction-cost reduction; we measured 29% of session cost going
# to compaction in ses_1c70728a7ffeLlgL1FsKXdTQLu.
```

**Step 3.3: Add to apply.sh after prompt-loop-cache**

Same pattern as Task 2.3 — variable, guard, apply block.

**Step 3.4: Verify full apply.sh stack against fresh v1.15.0**

Same as Task 2.4. Both new patches should apply.

**Step 3.5: Update README**

Add section 7:

```markdown
### 7. Cache-Aligned Compaction ([PR #25100](https://github.com/anomalyco/opencode/pull/25100))

Stored locally as `patches/cache-aligned-compaction.patch`. Aligns the
compaction LLM request shape to the normal agent-loop prefix so historical
messages hit the provider's prompt cache. Without this patch, compaction
builds an entirely different request (empty system prompt, no tools,
filtered history) that misses the cache, paying full input price for the
re-summarized history.

Author claims ~90% compaction-cost reduction. We measured 29% of session
cost going to compaction in a baseline Opus 4.7 session before this
patch.
```

**Step 3.6: Commit + close bead**

```bash
cd ~/projects/opencode-patched
git add patches/cache-aligned-compaction.patch patches/apply.sh README.md
git commit -m "feat(cache-aligned-compaction): patch in anomalyco/opencode#25100

Aligns compaction's LLM request shape to the normal agent-loop prefix
so historical messages hit the prompt cache. Targets the \$15 compaction
burst (29% of session cost) observed in ses_1c70728a7ffeLlgL1FsKXdTQLu.

Captured at PR head <SHA>."

cd ~/projects/workstation
bd close workstation-z5b --reason "patch committed; ready for release cut"
bd sync
```

---

## Task 4: Add `system-prompt-split.patch` (PR #27377)

**Bead:** `workstation-0qg`

**Files:**

- Create: `opencode-patched/patches/system-prompt-split.patch`
- Modify: `opencode-patched/patches/apply.sh`
- Modify: `opencode-patched/README.md`

**Step 4.1: Save patch + add header**

```bash
cp /tmp/pr-27377.patch ~/projects/opencode-patched/patches/system-prompt-split.patch
```

Header:

```
# Patch: system prompt split + cache stabilization (anomalyco/opencode#27377)
# Source: https://github.com/anomalyco/opencode/pull/27377
# Captured at PR head: <SHA>
# Why: splits Instruction.system() into { global, project } scopes; LLM
# layer sends stable (global) + dynamic (project) blocks so the stable
# prefix can be cached across sessions. Gated behind
# OPENCODE_EXPERIMENTAL_SYSTEM_PROMPT_SPLIT (and CACHE_STABILIZATION for
# the date-freeze + instruction-cache layer). Flags OFF by default —
# safe to ship.
```

**Step 4.2: Add to apply.sh after cache-aligned-compaction**

Same pattern. Variable, guard, apply block, renumber subsequent comments.

**Step 4.3: Verify full apply.sh stack**

Same as before.

**Step 4.4: Update README**

Add section 8:

```markdown
### 8. System Prompt Split + Cache Stabilization ([PR #27377](https://github.com/anomalyco/opencode/pull/27377))

Stored locally as `patches/system-prompt-split.patch`. Splits the system
prompt into stable (global instructions + global skills + provider
prompt) and dynamic (env + project skills + project instructions) blocks,
gated behind `OPENCODE_EXPERIMENTAL_SYSTEM_PROMPT_SPLIT`. The
`OPENCODE_EXPERIMENTAL_CACHE_STABILIZATION` flag additionally freezes the
date and caches instruction file reads for the process lifetime.

Without these flags the patch is a no-op (behavior identical to upstream).
With them, cross-session prompt caching is dramatically improved — the
author's measurements show 0% → 97.6% hit rate on first prompt in a new
repo.

**Daemon-restart footgun:** with `CACHE_STABILIZATION` on, editing
AGENTS.md or skill markdown mid-process won't take effect until restart.
Recommended only for long-lived daemons like opencode-serve.
```

**Step 4.5: Commit + close bead**

```bash
cd ~/projects/opencode-patched
git add patches/system-prompt-split.patch patches/apply.sh README.md
git commit -m "feat(system-prompt-split): patch in anomalyco/opencode#27377

Splits system prompt into stable/dynamic blocks (gated behind
OPENCODE_EXPERIMENTAL_SYSTEM_PROMPT_SPLIT). Helps cross-session cache
reuse for swarm topology with large global+project AGENTS.md and many
skills. Flags OFF by default.

Captured at PR head <SHA>."

cd ~/projects/workstation
bd close workstation-0qg --reason "patch committed; ready for release cut"
bd sync
```

---

## Task 5: Build `cache-usage-logger.ts` plugin (workstation)

**Bead:** `workstation-7kn` (independent of the patch work — can run in
parallel)

**Files:**

- Create: `workstation/assets/opencode/plugins/cache-usage-logger.ts`
- Modify: `workstation/users/dev/opencode-config.nix` (register plugin)

**Step 5.1: Read the existing plugin shape**

```bash
cat ~/projects/workstation/assets/opencode/plugins/shell-env.ts
cat ~/projects/workstation/assets/opencode/plugins/compaction-context.ts
```

Understand the opencode plugin API (hooks available, signature, the
`Plugin` export shape).

**Step 5.2: Identify the right hook**

Plugin needs a post-response hook that gives access to `response.usage`.
Look in `~/.config/opencode/plugins/` and opencode source for the hook
name. Likely candidates: `chat.message`, `response`, or similar. Use
`gh search code --repo anomalyco/opencode 'plugin' 'hook'` if unsure.

**Step 5.3: Write the plugin**

Skeleton:

```typescript
// cache-usage-logger.ts
//
// Logs raw provider cache_creation token fields per LLM response to a
// JSONL file at ~/.local/share/opencode/cache-usage.jsonl. Lets us
// distinguish 5m vs 1h cache writes on the wire vs. opencode's stored
// cost estimate.
//
// Why: a 28-min Opus 4.7 session cost $53 on Vertex; backed-out
// compaction-write rate was ~$12.5/MTok (2× Anthropic's published 5m
// rate, 1.25× the 1h rate). We don't know if the 2× is wire-real or
// estimator bug. This plugin settles it.

import type { Plugin } from "@opencode-ai/plugin"
import { appendFile, mkdir } from "node:fs/promises"
import { dirname } from "node:path"
import { homedir } from "node:os"

const LOG_PATH = `${homedir()}/.local/share/opencode/cache-usage.jsonl`

export const CacheUsageLoggerPlugin: Plugin = {
  // hook name TBD from Step 5.2
  async someResponseHook({ response, request, sessionID, model }) {
    const usage = response?.usage
    if (!usage) return
    const record = {
      ts: new Date().toISOString(),
      sessionID,
      providerID: model?.providerID,
      modelID: model?.id,
      input: usage.input_tokens,
      output: usage.output_tokens,
      cache_read: usage.cache_read_input_tokens,
      cache_create_total: usage.cache_creation_input_tokens,
      cache_create_5m: usage.cache_creation?.ephemeral_5m_input_tokens,
      cache_create_1h: usage.cache_creation?.ephemeral_1h_input_tokens,
    }
    await mkdir(dirname(LOG_PATH), { recursive: true })
    await appendFile(LOG_PATH, JSON.stringify(record) + "\n")
  },
}
export default CacheUsageLoggerPlugin
```

The exact hook signature must be verified against the opencode plugin API.
If the hook gives raw provider response, perfect. If it gives only opencode's
normalized `tokens` shape, the plugin loses access to the
`ephemeral_5m/1h` split — in that case the plugin must intercept at a
lower layer or we need to patch opencode core to expose those fields.

**Step 5.4: Register the plugin in opencode-config.nix**

Add after the existing plugin registrations (~line 117):

```nix
xdg.configFile."opencode/plugins/cache-usage-logger.ts".source = "${assetsPath}/opencode/plugins/cache-usage-logger.ts";
```

**Step 5.5: Apply home-manager + smoke-test**

```bash
nix run home-manager -- switch --flake ~/projects/workstation#cloudbox  # or #dev
# Start a fresh opencode session, send "hello", check:
tail -3 ~/.local/share/opencode/cache-usage.jsonl
```

Expected: at least one JSONL record with all fields populated (some may
be `undefined` if the provider didn't return them — that's the diagnostic
we want).

**Step 5.6: Commit + close bead**

```bash
cd ~/projects/workstation
git add assets/opencode/plugins/cache-usage-logger.ts users/dev/opencode-config.nix
git commit -m "feat(opencode-plugin): cache-usage-logger

Logs response.usage.cache_creation.ephemeral_{5m,1h}_input_tokens per
LLM response to ~/.local/share/opencode/cache-usage.jsonl. Settles
whether the 2× compaction-write rate observed in
ses_1c70728a7ffeLlgL1FsKXdTQLu is wire-real or an opencode estimator
bug.

Refs workstation-7kn, beads-b4p."
bd close workstation-7kn --reason "plugin shipped; will collect 24h of data"
bd sync
```

---

## Task 6: Cut `v1.15.0-patched-pl` release

**Bead:** `workstation-adw` (blocked by `workstation-tbn`; can ship before
Tasks 3-4 land if desired, but cleaner to ship all together)

**Files:** none in this repo — uses GitHub Actions on opencode-patched.

**Step 6.1: Push opencode-patched commits to GitHub**

```bash
cd ~/projects/opencode-patched
git push origin main
```

This triggers `build-release.yml` if it's wired to `push` on `main`. If
not, trigger manually:

```bash
gh workflow run build-release.yml --repo johnnymo87/opencode-patched
```

Watch the run:

```bash
gh run watch --repo johnnymo87/opencode-patched
```

**Step 6.2: Verify release artifacts**

```bash
gh release view --repo johnnymo87/opencode-patched | head -30
```

Expected: a new release tag like `v1.15.0-patched-pl` (or whatever the
build pipeline names it after the new patch is added) with four platform
archives.

**Step 6.3: Close bead**

```bash
cd ~/projects/workstation
bd close workstation-adw --reason "release cut; tag <TAG>"
bd sync
```

---

## Task 7: Bump opencode-patched in workstation + apply on cloudbox

**Bead:** `workstation-qys`

**Files:**

- Modify: `workstation/users/dev/home.base.nix` (version + 4 hashes)

**Step 7.1: Compute new hashes**

For each platform asset, fetch + hash:

```bash
NEW_VERSION="<the released tag, e.g. 1.15.0-pl1>"
for platform in linux-arm64 linux-x64 darwin-arm64 darwin-x64; do
  url="https://github.com/johnnymo87/opencode-patched/releases/download/v${NEW_VERSION}-patched/opencode-${platform}.${platform%-*x64}.tar.gz"
  # ... use nix-prefetch-url or the existing update-opencode-patched.yml workflow logic
done
```

**Easier:** trigger the existing `update-opencode-patched.yml` GitHub
Action in workstation:

```bash
gh workflow run update-opencode-patched.yml --repo johnnymo87/workstation
gh run watch --repo johnnymo87/workstation
```

This auto-detects the latest release, computes hashes, opens a PR.

**Step 7.2: Review + auto-merge PR**

```bash
gh pr list --repo johnnymo87/workstation --search "update-opencode-patched"
gh pr view <NUM> --repo johnnymo87/workstation
# Verify the diff only changes version + 4 hashes
gh pr merge <NUM> --repo johnnymo87/workstation --rebase
```

**Step 7.3: Pull + apply on cloudbox**

```bash
cd ~/projects/workstation
git pull --rebase
nix run home-manager -- switch --flake .#cloudbox
opencode --version  # should report v1.15.0 (the upstream version, our patches are transparent)
```

**Step 7.4: Smoke test**

```bash
# In a fresh opencode session:
echo "hi" | opencode run
# Or use TUI manually and run one tool-call cycle.
```

Verify no crash, no startup errors. Check `~/.local/share/opencode/cache-usage.jsonl`
gains entries.

**Step 7.5: Close bead**

```bash
bd close workstation-qys --reason "bumped to <TAG>; applied on cloudbox; smoke passed"
bd sync
```

---

## Task 8: Re-measure on a similar workload

**Bead:** `workstation-y8m`

**Files:**

- Modify: `opencode-patched/docs/plans/2026-05-18-add-cache-fix-patches-design.md`
  (fill in the Retro section)

**Step 8.1: Run a comparable workload**

A ~30-minute Opus 4.7 session with:
- Heavy tool use (bash, read, grep, ~50+ tool calls)
- At least one manual compaction
- Same provider (`google-vertex-anthropic` if possible)
- Same model variant

Note the session id from `opencode list` or the DB.

**Step 8.2: Run oc-cost**

```bash
oc-cost --days 1 --json | jq '.daily[]'
```

**Step 8.3: Query the new session directly**

Using the same SQL from this design doc's "Cost forensics" section,
substituting the new session id. Compute:

- Total cost.
- Per-message cost-by-pattern (uncached input, cache write 5m vs 1h,
  cache read, output).
- Pattern detection: does `cache_read` stay flat while `input` grows
  across turns? (the diagnostic)
- Compaction message cost.

**Step 8.4: Check the cache-usage-logger output**

```bash
tail -100 ~/.local/share/opencode/cache-usage.jsonl | jq -s '
  {
    n: length,
    total_5m: map(.cache_create_5m // 0) | add,
    total_1h: map(.cache_create_1h // 0) | add,
    total_read: map(.cache_read // 0) | add
  }
'
```

This answers the wire-vs-estimator question.

**Step 8.5: Fill in retro section**

Update the design doc's Retro section with actual numbers,
pattern-disappearance results, and any surprises.

**Step 8.6: Commit + close bead**

```bash
cd ~/projects/opencode-patched
git add docs/plans/2026-05-18-add-cache-fix-patches-design.md
git commit -m "docs(retro): cache-fix patches landed; new baseline <COST>/<MIN>min"

cd ~/projects/workstation
bd close workstation-y8m --reason "measured: <BEFORE> → <AFTER>"
bd sync
```

---

## Task 9 (optional, deferred): Drift-detection workflows

**Bead:** `workstation-j7t` (P3 — defer until we've shipped + measured)

**Files:**

- Create: `opencode-patched/.github/workflows/sync-prompt-loop-cache-pr.yml`
- Create: `opencode-patched/.github/workflows/sync-cache-aligned-compaction-pr.yml`
- Create: `opencode-patched/.github/workflows/sync-system-prompt-split-pr.yml`

Mirror the existing `sync-tool-fix-pr.yml` and `sync-vim-pr.yml`. Each one
polls `gh pr diff <num>`, compares hash to the committed patch file, files
a GitHub issue if drift is detected.

**Step 9.1:** Copy `sync-tool-fix-pr.yml`, find/replace PR number + patch
filename, repeat for each new PR.

**Step 9.2:** Commit:

```bash
cd ~/projects/opencode-patched
git add .github/workflows/sync-{prompt-loop-cache,cache-aligned-compaction,system-prompt-split}-pr.yml
git commit -m "ci: add drift-detection workflows for #25367, #25100, #27377"
git push
```

**Step 9.3:** Close bead.

---

## Acceptance criteria

The work is done when:

1. All three patches commit cleanly to `opencode-patched/patches/`.
2. `apply.sh` applies the full stack against pristine v1.15.0 with no
   rejects.
3. A new `v1.15.0-patched-*` release is published on GitHub.
4. Workstation `home.base.nix` is bumped, PR merged, cloudbox applied.
5. The `cache-usage-logger.ts` plugin emits JSONL records on the next
   opencode session.
6. A re-measurement session is run and the retro section of the design
   doc is filled in with actual deltas.
7. All beads under `workstation-b4p` are closed.

**Stretch:** drift-detection workflows added (Task 9).

## Don't proceed past Task 1 if...

- PR #25367 fails to apply with full-file deletion (escalate to redesign).
- The probe reveals all three PRs collide irreconcilably with one another
  on `session/prompt.ts` (escalate to picking which one to ship first).
- v1.15.0 has already incorporated any of these PRs (then we can drop
  that patch from the plan).
