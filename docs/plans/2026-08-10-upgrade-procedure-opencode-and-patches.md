# Upgrade Procedure: Latest opencode + Latest opencode-patches

> **Date:** 2026-08-10. Procedure validated end-to-end on 2026-08-09 (v1.18.3 →
> v1.18.15). Follow this runbook for every upgrade; update it when the procedure
> changes.

**Goal:** Roll `opencode-src` forward to the newest upstream `anomalyco/opencode`
release tag, rebase/refresh the local patch stack, then align the stack with the
latest `johnnymo87/opencode-patched` (upstream fork) patches. Verify, build,
install, backup, document, commit.

**Layout:**

| Path | Repo | Role |
|---|---|---|
| `/home/dev/opencode-patched/` | `aand18/opencode-patched` (ours) | patches repo — the only repo that gets commits |
| `/home/dev/opencode-patched/opencode-src/` | `anomalyco/opencode` source clone | upstream source, patched in place; **never commit here** |

Remotes (patches repo): `origin` = aand18, `upstream` = johnnymo87, `anomalyco` =
original (broken — do not use).
Remotes (opencode-src): `origin` = anomalyco/opencode, `upstream` = johnnymo87/opencode
(mirror of the fork's source), `aand18`.

**CRITICAL:** All opencode-src git commands MUST run with
`workdir="/home/dev/opencode-patched/opencode-src"` or the wrong repo gets touched.
Avoid `git checkout .` / `git reset` in opencode-src — the working tree is dirty
with applied patches by design.

---

## Phase 0 — Preflight

1. Confirm no opencode instance is writing critical data mid-upgrade
   (the ~/.opencode/bin binary swap can proceed anytime; DB backup must use `.backup`).
2. `git fetch --all --tags` in opencode-src to pick up the newest release tag.
3. Check `gh release list` on anomalyco/opencode for the latest tag, and
   `git ls-remote --tags upstream refs/tags/v*` in the patches repo for the fork's
   latest patch additions.

## Phase 1 — Roll the source to the new tag

1. **Checkout the tag (detached):**
   ```
   git fetch origin tag v<VER>            # opencode-src, origin = anomalyco
   git checkout v<VER>                    # detached HEAD at tag
   # create a local tag for stable ancestry reference:
   git tag v<VER> <FETCH_HEAD-sha>
   ```
2. **`bun install` — REQUIRED before building.** Since v1.18.15 upstream vendors
   `@opencode-ai/client` as a tarball (`packages/app/vendor/opencode-ai-client-*.tgz`).
   A stale `node_modules` fails the app build with
   `Rollup failed to resolve import "@opencode-ai/client/promise"`. Verified
   2026-08-09; also on every fresh clone of a new tag.
3. **Apply the patch stack:**
   ```
   ./patches/apply.sh /home/dev/opencode-patched/opencode-src
   ```
   Must print "All patches applied successfully" (24/24 on v1.18.15). An early
   failure names the patch needing a rebase — see Phase 4 (rebasing), then go
   back to step 2-3.
4. **Build:**
   ```
   OPENCODE_VERSION=v<VER> OPENCODE_CHANNEL=prod \
     bun run --cwd /home/dev/opencode-patched/opencode-src/packages/opencode build
   ```
   - `OPENCODE_VERSION` MUST be an existing npm version (plugin dependency
     resolution; `@opencode-ai/plugin@0.0.0-prod-...` 404s otherwise).
   - `OPENCODE_CHANNEL=prod` — without it the channel defaults to the git branch
     name (non-prod), which forcibly enables the new UI layout and hides the old
     UI toggle.
    - Binary lands at `packages/opencode/dist/opencode-linux-x64/bin/opencode`.
    - **Fast path:** append `--single` to build only the current platform
      (`opencode-linux-x64`) instead of all 12 targets — ~29 s vs ~5 min
      (verified 2026-08-30, smoke included). Correct for local iteration;
      use the full build for release/publishing. `--skip-install` (optional)
      also skips the cross-platform `bun install --os="*"` steps — only when
      dependencies are unchanged.

## Phase 2 — Install + DB backup (verified procedure)

1. **Copy binary with versioned name:**
   ```
   cp opencode-src/packages/opencode/dist/opencode-linux-x64/bin/opencode \
      ~/.opencode/bin/opencode-v<VERSION>-patched-prod-<TIMESTAMP>
   ```
   `<TIMESTAMP>`: from `--version` output (e.g. `202608092343`). Example:
   `opencode-v1.18.15-patched-prod-202608092343`.
2. **DB backup — use `sqlite3 .backup`, NEVER plain `cp`:**
   ```
   sqlite3 ~/.local/share/opencode/opencode.db \
     ".backup $HOME/.local/share/opencode/opencode.db.bak.{TIMESTAMP}"
   ```
   - The live DB is WAL mode; plain `cp` misses the WAL tail (verified 2026-08-09:
     cp-backed `.bak` was 50 messages / ~12 min stale). `.backup` (online backup
     API) is consistent and safe while opencode runs (~7 s for a 4.3 GB DB).
   - sqlite3 does NOT expand `~` inside the `.backup` target — use `$HOME` or an
     absolute path.
   - See `~/.local/share/opencode/AGENTS.md` for full backup/restore notes.
3. **Smoke test:** `~/.opencode/bin/opencode-v<VERSION>-patched-prod-<TS> --version`
   then a short real session before switching default `opencode` alias/path.

## Phase 3 — Align patches with johnnymo87/opencode-patched

1. `git fetch upstream` in the **patches repo** (never in opencode-src).
2. Diff the fork's patch set against ours:
   ```
   git diff HEAD upstream/main --stat -- patches/
   git ls-tree --name-only upstream/main patches/
   ```
   Note new patch files, renamed/re-dropped ones, and the upstream
   `patches/apply.sh` header for its own dropped-patch ledger.
3. **Decision per patch** (record every decision in `apply.sh` header + README):
   - **adopt** — rebase into our stack (verify it applies + test hunks pass);
   - **skip** — heavy rebase friction / depends on absent upstream architecture
     (2026-08-09 session: `tui-door-attach`, `tui-reconcile-bound` skip — they
     target the fork's later serve/pool architecture not present in the older
     tag our stack hangs off);
   - **drop** — user preference (2026-08-09: `gemini-empty-parts`, `vim`,
     `opus5-adaptive-thinking` — pay models / vim irrelevant to user) or
     upstream-removed (dropped ledger in apply.sh).
   - Update the `apply.sh` DROPPED ledger with dates and reasons.
4. If the fork added/kept patches we already carry (e.g. `retry-cap`,
   `cache-thinking-skip`, `tool-fix`): diff our version against theirs
   (`git diff upstream/main -- patches/<name>.patch`) and fold in upstream
   improvements only if behavior verified; ours may already be newer.

## Phase 4 — Rebasing a failing patch

1. `git apply` the failing patch in opencode-src to see the rejection context;
   the error names the file+region. Do NOT edit the working tree — edit the
   **patch file** in the patches repo instead (or regenerate with
   `git diff` of a hand-fixed tree).
2. Common 2026-08-09 examples:
   - `retry-cap.patch` — upstream moved `RETRYABLE_MESSAGE_PATTERNS` above
     `cap()`; needed a 4-part manual rebase + regenerated test hunks, added
     `session.retry.policy` MAX_RETRIES halting test, renamed jitter test.
   - `revert-orphan-parents.patch` — upstream rewrote `cleanup()` to
     `msgs.slice(...)`; re-applied the orphan-reparent block after upstream's
     new code.
3. **Verify on a FRESH clone/tag checkout (mirrors CI):** apply 24/24 there,
   run the patch's test file from `packages/opencode`
   (e.g. `bun test test/session/retry.test.ts`, `test/session/message-v2.test.ts`).
4. Never keep a "conflicted" patch — every patch must `git apply --check` clean
   in the documented order or the release is broken.

## Phase 5 — Documentation

Update all of these in the **patches repo** (they are version pins):

1. `AGENTS.md` — build line version, vendored-tarball note, binary/backup naming.
2. `README.md` — "Currently tracking" version, patch table (add/remove rows),
   credits, dropped-patches digest.
3. `patches/apply.sh` header — TARGET UPSTREAM version, patch set, DROPPED ledger,
   dependency notes.
4. This runbook — only when the *procedure* changes (not per upgrade).

## Phase 6 — Commit

**Patches repo only.** Never commit in opencode-src (dirty tree is by design).

1. Stage intent-fully: `git status` shows spurious "modified" files from
   CRLF/autocrlf stat-cache noise (workflows, docs/plans, .gitattributes) —
   running `bun install` or WRITES to tracked files resets them. Only stage files
   with real diffs: patches, apply.sh, AGENTS.md, README.md.
2. Commit message style: `feat(v1.18.15): ...` / `docs: ...` / `chore(ci): ...`
   with per-file reasoning. (Reference commits: 5cebd98c7 roll-forward + fold-in,
   b4c27f263 docs refresh, 4983450f5 workflow cleanup.)
3. Push to `origin` (aand18) when the user approves.

## Phase 7 — Housekeeping

- Delete scratch worktrees/clones under `/tmp/opencode/` after the verify pass.
- Note the `.bak.{TIMESTAMP}` trust status in `~/.local/share/opencode/AGENTS.md`
  inventory if you want a durable record.
- If publishing a release: `gh workflow run build-release.yml --field version=X.Y.Z`
  (repo has build-release.yml + check-sunset.yml; sync-cached/sync-vim-pr were
  removed 2026-08-10 as stale).

---

## Evidence anchors (2026-08-09 upgrade, v1.18.3 → v1.18.15)

- Source: `opencode-src` detached HEAD `d7b115f623`, local tag `v1.18.15`.
- Fresh-clone verification: apply 24/24; build succeeded with `OPENCODE_VERSION=1.18.15
  OPENCODE_CHANNEL=prod`.
- Binary: `~/.opencode/bin/opencode-v1.18.15-patched-prod-202608092343`;
  DB backup `.bak.202608092356` (sqlite .backup, matches live).
- Commits in patches repo: `5cebd98c7` (roll-forward + 13 adopted patches),
  `b4c27f263` (docs), `4983450f5` (workflow cleanup).
- Scratch cleanup: 2026-08-10 removed `/tmp/opencode/{latest,wt-183,scratch-*,seq1815,
  upstream-patches,...}` ~30 GB.