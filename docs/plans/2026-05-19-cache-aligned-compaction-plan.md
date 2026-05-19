# Cache-Aligned Compaction Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add PR #25100 as a local patch so compaction reuses the normal agent-loop cache prefix.

**Architecture:** Add `cache-aligned-compaction.patch` after `prompt-loop-cache.patch` in the existing patch stack. Refresh only the two known v1.15.0 anchor rejects and keep #27377 out of scope.

**Tech Stack:** Bash `apply.sh`, Git patch files, upstream OpenCode v1.15.0, SQLite DB measurement for follow-up.

---

### Task 1: Capture and stage the PR #25100 patch

**Files:**
- Create: `patches/cache-aligned-compaction.patch`

**Step 1: Fetch the upstream PR diff**

Run: `gh pr diff 25100 --repo anomalyco/opencode > /tmp/pr-25100.patch`

Expected: patch file exists and references `session/compaction.ts` and `session/prompt.ts`.

**Step 2: Save into this repo**

Copy `/tmp/pr-25100.patch` to `patches/cache-aligned-compaction.patch`.

**Step 3: Record the PR head SHA in docs/README text**

Use current head `972380a75249b01a424010e8bc0453e15a3a14c2` unless `gh pr view` reports a newer head.

---

### Task 2: Refresh known rejects against v1.15.0 + caching + #25367

**Files:**
- Modify: `patches/cache-aligned-compaction.patch`

**Step 1: Create a scratch upstream checkout**

Run: `git clone --depth 1 --branch v1.15.0 https://github.com/anomalyco/opencode.git /tmp/opencode-compaction-verify/opencode-v1.15.0`

Expected: checkout at `2662a4f`.

**Step 2: Apply existing stack up to #25367**

Apply `caching.patch` from opencode-cached and `patches/prompt-loop-cache.patch`.

Expected: both apply cleanly.

**Step 3: Apply #25100 for diagnostics**

Run `git apply --reject --whitespace=nowarn patches/cache-aligned-compaction.patch` from the scratch checkout.

Expected: two rejects matching `/tmp/task1-probe-report.md`.

**Step 4: Refresh `session/compaction.ts` import-block hunk**

Update the patch context so the `import { type Tool as AITool } from "ai"` insertion anchors against v1.15.0's current import block instead of the removed `fn` import.

**Step 5: Refresh `session/prompt.ts` compaction hunk**

Update the patch context to include #25367's `needsFullReload = true` before `continue`.

**Step 6: Verify patch applies after #25367**

Reset scratch checkout, reapply `caching.patch`, `prompt-loop-cache.patch`, then run `git apply --check patches/cache-aligned-compaction.patch`.

Expected: check passes.

---

### Task 3: Wire patch into the stack and docs

**Files:**
- Modify: `patches/apply.sh`
- Modify: `README.md`

**Step 1: Add `CACHE_ALIGNED_COMPACTION_PATCH` variable and guard**

Add variable near `PROMPT_LOOP_CACHE_PATCH` and a missing-file guard.

**Step 2: Apply patch after `prompt-loop-cache.patch`**

Insert a failure-diagnostic block mirroring the existing patch blocks, with source PR `https://github.com/anomalyco/opencode/pull/25100`.

**Step 3: Renumber later patch comments**

Ensure comments reflect the new order.

**Step 4: Update README**

Add a patch section explaining cache-aligned compaction, update build order, patch ownership, patch independence, maintenance notes, and credits.

---

### Task 4: Verify complete patch stack

**Files:**
- No source changes unless verification exposes rejects.

**Step 1: Run full stack against fresh v1.15.0**

Run: `VERIFY_DIR=$(mktemp -d /tmp/opencode-patched-verify-compaction.XXXXXX) && git clone --depth 1 --branch v1.15.0 https://github.com/anomalyco/opencode.git "$VERIFY_DIR/opencode-v1.15.0" && /home/dev/projects/opencode-patched/patches/apply.sh "$VERIFY_DIR/opencode-v1.15.0"`

Expected: all patches apply successfully, including `cache-aligned-compaction.patch`.

**Step 2: Review git diff**

Run: `git diff -- README.md patches/apply.sh patches/cache-aligned-compaction.patch`

Expected: only #25100-related changes plus existing #25367 changes in working tree.

**Step 3: Request code review**

Use `code-reviewer` read-only against the working-tree diff.

Expected: no critical or important findings.

---

### Task 5: Report results

**Files:**
- No changes.

**Step 1: Summarize verification evidence**

Report the full-stack apply result and any code-review findings.

**Step 2: State what remains out of scope**

Mention no #27377, no GPT-5.5 price accounting fix, no release/workstation bump unless requested.
