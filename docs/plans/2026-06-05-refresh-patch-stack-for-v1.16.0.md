# Refresh Patch Stack for v1.16.0 Implementation Plan

> **For Claude:** Use superpowers:executing-plans. This plan executes in this
> session (or a fresh one) directly on `main` in `~/projects/opencode-patched`.
> The work is NOT mechanical this time — v1.16.0 carries a large internal
> refactor. Read the whole "Background" section before touching any patch.

**Goal:** Refresh the 9-patch stack onto upstream `anomalyco/opencode@v1.16.0`,
cut a `v1.16.0-patched` release, bump `workstation` to consume it, and rebuild.

**Architecture:** Work directly on `main` in `~/projects/opencode-patched`.
Re-derive each conflicting hunk against a fresh checkout, regenerate the patch
with `git diff`, and validate with the real CI path (`apply.sh` + `bun install`
+ `bun run script/build.ts`) plus targeted `bun test`. The local patches — NOT
the upstream PRs — are the source of truth (see PR status below).

**Tech Stack:** Upstream opencode (TypeScript, Bun, Effect, SolidJS TUI), git,
bash, gh CLI, Nix.

---

## Background: This Is Not a Routine Bump

v1.15.13 → v1.16.0 includes a **sweeping "v1/v2 namespace" migration** plus
structural refactors. Every patch's target file is affected. The renames seen
across the patched files:

| Old (v1.15.13) | New (v1.16.0) | Kind |
|---|---|---|
| `MessageV2.WithParts` / `.Part` / `.Assistant` / `.User` / `.ToolPart` / `.TextPart` / `.FilePart` / `.CompactionPart` / `.Format` / `.ContextOverflowError` / `.StructuredOutputError` (types) | `SessionV1.<same>` | type only |
| `MessageV2.filterCompactedEffect` / `.toModelMessagesEffect` / `.toModelMessages` / `.latest` (functions) | **unchanged** (still on `MessageV2`) | runtime |
| `Bus` service / `bus.publish(...)` | `EventV2Bridge.Service` / `events.publish(...)` | runtime |
| `BusEvent.define("x", Schema.Struct({...}))` | `EventV2.define({ type: "x", schema: {...} })` | runtime |
| `AppFileSystem` (`@opencode-ai/core/filesystem`) | `FSUtil` (`@opencode-ai/core/fs-util`) | import + runtime |
| `Config.Info` | `ConfigV1.Info` (`@opencode-ai/core/v1/config/config`) | type |
| `ConfigMCP.Info` (`../config/mcp`) | `ConfigMCPV1.Info` (`@opencode-ai/core/v1/config/mcp`) | type + import |
| `ProviderID` / `ModelID` (`@/provider/schema`) | `ProviderV2.ID` / `ModelV2.ID` (`@opencode-ai/core/provider` / `/model`) | type |
| `import * as Log from "@opencode-ai/core/util/log"` | `import { Log } from "@opencode-ai/core/util/log"` | import |

### Why `git apply --check` is misleading here

The release build (`packages/opencode/script/build.ts`) is `Bun.build({ minify:
true, ... })` — a **bundler that transpiles and strips types; it does NOT run
`tsc`**. Consequences:

- **Type-level breakage does NOT fail CI.** A patch that adds
  `const x: MessageV2.WithParts[]` (now an invalid type) will still build. It is
  *latent* breakage — typecheck/test only.
- **Missing import paths DO fail CI.** If a patch adds `import { Foo } from
  "@/moved/path"` and that path no longer resolves, the bundler errors.
- Therefore `apply.sh` succeeding is **necessary but not sufficient**. Validation
  MUST include `bun run script/build.ts` AND targeted `bun test` AND a manual
  grep of the applied tree for renamed symbols in added lines.

### Upstream PR status (checked 2026-06-05)

| Patch | Tracking PR/issue | Status | Implication |
|---|---|---|---|
| prompt-loop-cache | PR #25367 | **CLOSED, unmerged** (2026-06-02) | Won't land upstream. Local patch is source of truth. `gh pr diff 25367` still works but is stale. |
| cache-aligned-compaction | PR #25100 | **CLOSED, unmerged** (2026-05-30) | Same — local patch is source of truth. |
| vim | PR #12679 | OPEN, **stale** (last code commit 2026-04-29) | Owner did NOT rebase onto v1.16.0. Local `vim.patch` is *ahead* of the PR. Re-derive ourselves. |
| eager-input-streaming | issues #23257/#23541/#23767 | **PARTIALLY UPSTREAMED in v1.16.0** | See sunset decision below. |
| MCP reconnect | issue #15247 | CLOSED (likely stale, not fixed) | Upstream `mcp/index.ts` still has no reconnect logic. Keep patch. |
| instance-state-partition | issue #29772 / PR #29773 | **OPEN, root cause NOT fixed in v1.16.0** | `server.ts:129` still uses `Layer.makeMemoMapUnsafe()`. Merged TUI fixes (#30574/#30578, the v1.16.0 "routed question responses to the right session directory") only patch one TUI symptom, not the server-side dual-`InstanceStore`. Keep patch — see Task 6. |

---

## Background: Per-Patch Verdict (against clean v1.16.0)

Tested with `git apply --check` / `--reject` against fresh
`anomalyco/opencode@v1.16.0`:

| Patch | apply --check | Rejected hunks | Effort | Notes |
|---|---|---|---|---|
| `prompt-loop-cache` | ❌ | 1/6 (`prompt.ts`) | **moderate** | upstream wrapped `filterCompactedEffect` in `.pipe(Effect.provideService(Database.Service, database))`; reload/merge logic must wrap the new form; type annotation must become `SessionV1.WithParts[]` |
| `cache-aligned-compaction` | ❌ | 7/18 (`compaction.ts` 4, `prompt.ts` 1, `tools.ts` 2) | **heavy** | `compaction.ts` refactored (namespace migration, `bus`→`events`, agent naming); biggest re-derivation |
| `gemini-empty-parts` | ✅ | 0 | verify-only | applies clean; no renamed symbols in added lines; still validate via its test |
| `vim` | ❌ | 2 (`prompt/index.tsx`) | **moderate-heavy** | all 8 vim files + schema + test apply clean; `prompt/index.tsx` heavily restructured upstream (workspace/move extracted to `usePromptWorkspace`/`usePromptMove` hooks; `input.visualCursor.offset`→`input.cursorOffset`) |
| `tool-fix` | ✅ | 0 | verify+fix-test | runtime hunk applies; **test hunk references removed `MessageV2.WithParts`/`Part` types** → update to `SessionV1.*` |
| `mcp-reconnect` | ❌ | 1/4 (`mcp/index.ts`) | **trivial** | upstream inserted a `ConfigV1` import → context shifted 1 line; only the import hunk rejects |
| `eager-input-streaming` | ✅ | 0 | **SUNSET decision** | upstream now sets `toolStreaming=false` for `@ai-sdk/google-vertex/anthropic` + non-claude `@ai-sdk/anthropic`. Patch is redundant for the user's case. See decision. |
| `instance-state-partition` | ❌ | 2/18 (`app-runtime.ts` 1, `provider.test.ts` 1) | **moderate** | `app-runtime.ts` AppLayer rebuilt (Pty/File/FileWatcher/SyncEvent/DataMigration removed; `Database` added; `Project.defaultLayer` now top-level); the InstanceLayer wrap must be re-derived |
| `cache-thinking-skip` | ✅ | 0 | verify-only | `applyCaching` still present at `transform.ts:323`; applies clean |

---

## DECISION POINT: eager-input-streaming sunset

Upstream `options()` in v1.16.0 (`provider/transform.ts:1009`) now contains:

```ts
if (
  input.model.api.npm === "@ai-sdk/google-vertex/anthropic" ||
  (!input.model.api.id.includes("claude") && input.model.api.npm === "@ai-sdk/anthropic")
) {
  result["toolStreaming"] = false
}
```

Our `eager-input-streaming.patch` adds (broader):

```ts
if (
  input.model.api.npm === "@ai-sdk/anthropic" ||
  input.model.api.npm === "@ai-sdk/google-vertex/anthropic"
) {
  result["toolStreaming"] = false
}
```

**The user runs `google-vertex-anthropic/claude-opus-4-8` (npm
`@ai-sdk/google-vertex/anthropic`) → upstream's first clause already covers it.**
The only behavior our patch adds beyond upstream is disabling toolStreaming for
**claude-id models on the direct `@ai-sdk/anthropic` package** (which upstream
deliberately keeps ON, since the official Anthropic API accepts
`eager_input_streaming`).

**Recommendation: DROP `eager-input-streaming.patch`.** The user's case is fully
covered by upstream; the extra coverage only matters for a strict-validation
*gateway* sitting behind the direct `@ai-sdk/anthropic` package with claude model
IDs, which is not the user's setup. Dropping removes a patch and reduces future
maintenance. If kept, the patch double-sets `toolStreaming=false` for vertex
(harmless but redundant) and must be narrowed to avoid drift.

→ **This plan assumes DROP.** If the executor/user decides to KEEP, see Task 7B.

---

## Compaction-Resilience Checklist

If resuming after compaction:

1. Read this whole doc.
2. Check whether the release exists:
   ```bash
   gh release view v1.16.0-patched --repo johnnymo87/opencode-patched --json tagName 2>/dev/null
   ```
3. Check workstation pin:
   ```bash
   grep -n 'upstreamVersion =' ~/projects/workstation/users/dev/home.base.nix
   ```
   If `1.16.0`, only the rebuild (Task 11) may remain.
4. Check which patches are already refreshed:
   ```bash
   cd /tmp/opencode && rm -rf ocv1160 && git clone --depth 1 --branch v1.16.0 \
     https://github.com/anomalyco/opencode.git ocv1160 && cd ocv1160
   ~/projects/opencode-patched/patches/apply.sh . 2>&1 | tail -20
   ```
5. Resume at the first unchecked task.

**State at plan-write time (2026-06-05):**
- Upstream `v1.16.0` published 2026-06-05 03:08 UTC.
- Latest patched release: `v1.15.13-patched.2`. No `v1.16.0-patched` yet.
- The scheduled `sync-upstream` (09:00 UTC) WILL trigger a build that **fails**
  at `prompt-loop-cache` (first patch) and opens a build-failure issue. Either
  let that happen and fix forward, or do this plan first.
- workstation pins `upstreamVersion = "1.15.13"`, `patchedRevision = "2"`
  (`users/dev/home.base.nix:284-285`).

---

## Task List

- [ ] **1.** Set up a clean v1.16.0 work checkout
- [ ] **2.** (DECISION) Confirm eager-input-streaming DROP vs KEEP
- [ ] **3.** Refresh `mcp-reconnect.patch` (trivial — import context)
- [ ] **4.** Refresh `prompt-loop-cache.patch` (Database pipe + SessionV1 type)
- [ ] **5.** Refresh `cache-aligned-compaction.patch` (compaction.ts + prompt.ts + tools.ts)
- [ ] **6.** Refresh `instance-state-partition.patch` (AppLayer wrap + test imports)
- [ ] **7.** Refresh `vim.patch` (prompt/index.tsx integration)
- [ ] **8.** Fix `tool-fix.patch` test types (`MessageV2.*` → `SessionV1.*`)
- [ ] **9.** Update `apply.sh` (drop eager if decided) + full-stack validation
- [ ] **10.** Commit + push + dispatch build-release for 1.16.0
- [ ] **11.** Bump `workstation` (version + 4 hashes) + rebuild

---

### Task 1: Clean work checkout

**Step 1.1:** Clone a pristine v1.16.0 (mirrors CI):

```bash
cd /tmp/opencode && rm -rf ocv1160 && git clone --depth 1 --branch v1.16.0 \
  https://github.com/anomalyco/opencode.git ocv1160
```

**Step 1.2:** Helper to reset between attempts:

```bash
cd /tmp/opencode/ocv1160 && git checkout -- . && git clean -fdq
```

> Re-derivation pattern for every task: `git apply --reject <patch>` → hand-merge
> the `.rej` into the file → `rm *.rej *.orig` → regenerate with `git diff`
> (use `git add -N <new-files>` so created files appear in the diff) → copy over
> the patch in `~/projects/opencode-patched/patches/`.

---

### Task 2: eager-input-streaming decision

Re-read the DECISION POINT above. Default = **DROP**. Record the choice; it
drives Task 9's `apply.sh` edit. If KEEP, do Task 7B before Task 9.

---

### Task 3: Refresh mcp-reconnect.patch (trivial)

**Conflict:** upstream inserted `import { ConfigV1 } from
"@opencode-ai/core/v1/config/config"` right after the `from "ai"` import, so the
patch's hunk #1 context (which expected `import { serviceUse }...` next) shifted.
Hunks #2–4 (the reconnect wrapper) apply cleanly and reference no renamed symbols.

**Step 3.1:**
```bash
cd /tmp/opencode/ocv1160 && git checkout -- . && git clean -fdq
git apply --reject ~/projects/opencode-patched/patches/mcp-reconnect.patch 2>&1 | tail
cat packages/opencode/src/mcp/index.ts.rej
```

**Step 3.2:** The rejected hunk only adds `type ToolExecutionOptions` to the
`from "ai"` import. Hand-add it to the (now ConfigV1-adjacent) import line, then
remove `.rej`/`.orig`.

**Step 3.3:** Regenerate + verify:
```bash
git diff packages/opencode/src/mcp/index.ts > /tmp/mcp.diff   # sanity check it's small
# Regenerate the full single-file patch:
git diff packages/opencode/src/mcp/index.ts > ~/projects/opencode-patched/patches/mcp-reconnect.patch
git checkout -- . && git clean -fdq
git apply --check ~/projects/opencode-patched/patches/mcp-reconnect.patch && echo "CHECK OK"
```

> NOTE: the reconnect wrapper added by this patch calls into upstream MCP code.
> After the full-stack build (Task 9), confirm there are no references to the old
> `bus` variable inside the added code (there shouldn't be — it uses the SDK
> client/transport directly).

---

### Task 4: Refresh prompt-loop-cache.patch

**Conflict (hunk #1 of `prompt.ts`):** upstream changed
```ts
let msgs = yield* MessageV2.filterCompactedEffect(sessionID)
```
to
```ts
let msgs = yield* MessageV2.filterCompactedEffect(sessionID).pipe(
  Effect.provideService(Database.Service, database),
)
```
The patch replaces this single statement with declare-once + reload/merge logic.
Hunks #2–6 (the `needsFullReload = true` reset points after compaction/subtask/
overflow, and the `app/vite.js` build-id change) apply cleanly.

**Step 4.1:** Apply with reject, inspect:
```bash
cd /tmp/opencode/ocv1160 && git checkout -- . && git clean -fdq
git apply --reject ~/projects/opencode-patched/patches/prompt-loop-cache.patch 2>&1 | tail
cat packages/opencode/src/session/prompt.ts.rej
sed -n '1255,1270p' packages/opencode/src/session/prompt.ts
```

**Step 4.2:** Hand-merge the reload/merge block, adapting to v1.16.0:
- Declare `let msgs: SessionV1.WithParts[] | undefined` (NOT `MessageV2.WithParts`
  — that type is gone; `SessionV1` is already imported in `prompt.ts`).
- Keep `let needsFullReload = true`.
- BOTH the full-reload branch AND the incremental branch must call
  `MessageV2.filterCompactedEffect(sessionID).pipe(Effect.provideService(Database.Service, database))`
  (`database` is already in scope in `runLoop`; `Database` already imported).
  Target shape:
  ```ts
  let msgs: SessionV1.WithParts[] | undefined
  let needsFullReload = true
  while (true) {
    ...
    if (needsFullReload || !msgs) {
      msgs = yield* MessageV2.filterCompactedEffect(sessionID).pipe(
        Effect.provideService(Database.Service, database),
      )
      needsFullReload = false
    } else {
      const fresh = yield* MessageV2.filterCompactedEffect(sessionID).pipe(
        Effect.provideService(Database.Service, database),
      )
      const knownIDs = new Set(msgs.map((m) => m.info.id))
      for (const m of fresh) if (!knownIDs.has(m.info.id)) msgs.push(m)
    }
    ...
  ```

**Step 4.3:** Confirm hunks #2–6 still landed (the `needsFullReload = true`
resets and `app/vite.js`). If any reset-point context drifted, refresh it too.

**Step 4.4:** Regenerate (includes `app/vite.js` + `prompt.ts`):
```bash
git diff packages/app/vite.js packages/opencode/src/session/prompt.ts \
  > ~/projects/opencode-patched/patches/prompt-loop-cache.patch
git checkout -- . && git clean -fdq
git apply --check ~/projects/opencode-patched/patches/prompt-loop-cache.patch && echo "CHECK OK"
```

> Behavioral guide: PR #25367 (CLOSED but diff still fetchable via
> `gh pr diff 25367 --repo anomalyco/opencode`). Preserve: byte-identity of the
> conversation array across tool-loop iterations, full reload after
> compaction/subtask/overflow.

---

### Task 5: Refresh cache-aligned-compaction.patch (heaviest)

**This patch must apply AFTER prompt-loop-cache** (both touch `prompt.ts`).
Conflicts: `compaction.ts` (4 hunks), `prompt.ts` (1 hunk), `tools.ts` (2 hunks).
All driven by the namespace migration in those files.

**Step 5.1:** Stage prompt-loop-cache first, then apply this with reject:
```bash
cd /tmp/opencode/ocv1160 && git checkout -- . && git clean -fdq
git apply ~/projects/opencode-patched/patches/prompt-loop-cache.patch
git apply --reject ~/projects/opencode-patched/patches/cache-aligned-compaction.patch 2>&1 | tail
for f in $(find . -name '*.rej'); do echo "=== $f ==="; cat "$f"; done
```

**Step 5.2:** Re-derive each reject. Key adaptations in `compaction.ts`:
- All `MessageV2.<Type>` → `SessionV1.<Type>` (WithParts, Assistant, User, Part,
  ToolPart, TextPart, CompactionPart, ContextOverflowError).
- `bus.publish(Event.Compacted, ...)` → `events.publish(Event.Compacted, ...)`
  (upstream removed the `bus` binding; `events = yield* EventV2Bridge.Service`).
- `Event.Compacted` is now defined via `EventV2.define({ type, schema })`.
- The patch's `resolved`/`ResolvedContext` machinery + `AITool` import + the
  branched `processor.process({...})` call must be re-anchored against the
  refactored `processCompaction`. Watch the agent-name binding (upstream uses a
  local that may have been renamed) and the new `toModelMessagesEffect(msgs,
  model, resolved ? undefined : {...})` form.
- `model: { providerID: ProviderID; modelID: ModelID }` → `{ providerID:
  ProviderV2.ID; modelID: ModelV2.ID }` in the `Interface`/`create` signatures.

In `tools.ts`: `MessageV2.WithParts`/`FilePart` → `SessionV1.*`; `ModelID.make`
→ `ModelV2.ID.make` if the patch's added lines touch those.

In `prompt.ts`: re-anchor the single hunk on top of the Task 4 result.

**Step 5.3:** Regenerate (3 files) + verify in sequence:
```bash
git diff packages/opencode/src/session/compaction.ts \
         packages/opencode/src/session/prompt.ts \
         packages/opencode/src/session/tools.ts > /tmp/cac.patch
# IMPORTANT: prompt.ts now contains BOTH patches' changes. Regenerate
# cache-aligned-compaction as the diff AFTER prompt-loop-cache is applied, so the
# two patches stay independent and ordered. Easiest: generate against a tree that
# already has prompt-loop-cache, capturing only compaction.ts + tools.ts + the
# incremental prompt.ts hunk. Verify by the clean-sequence check below.
cp /tmp/cac.patch ~/projects/opencode-patched/patches/cache-aligned-compaction.patch
git checkout -- . && git clean -fdq
git apply ~/projects/opencode-patched/patches/prompt-loop-cache.patch
git apply --check ~/projects/opencode-patched/patches/cache-aligned-compaction.patch && echo "CHECK OK (post prompt-loop)"
```

> CAUTION on prompt.ts double-ownership: regenerating with a blanket
> `git diff prompt.ts` after BOTH patches are applied would fold prompt-loop-cache's
> changes into cache-aligned-compaction. To keep them separate, generate
> cache-aligned-compaction's prompt.ts hunk from the delta *introduced on top of*
> the prompt-loop-cache tree (i.e. apply prompt-loop-cache, commit locally, then
> apply the compaction edits, then `git diff` the working tree against that local
> commit). Document the exact sequence you used in the commit message.

> Behavioral guide: PR #25100 (CLOSED; `gh pr diff 25100 --repo anomalyco/opencode`).

---

### Task 6: Refresh instance-state-partition.patch

> **NOT A SUNSET — root cause confirmed still present in v1.16.0 (checked
> 2026-06-05).** This patch fixes issue
> [#29772](https://github.com/anomalyco/opencode/issues/29772) (authored by us;
> upstream PR [#29773](https://github.com/anomalyco/opencode/pull/29773), still
> OPEN/unmerged): `InstanceStore.Service` materializes twice per directory because
> the TCP listener builds with a fresh `Layer.makeMemoMapUnsafe()` while the
> in-process webHandler uses the shared `memoMap`, splitting `Question.Service`'s
> pending-request map so replies hit the wrong tree (`reply for unknown request`).
>
> The decisive root-cause line is **unchanged in v1.16.0** —
> `server.ts:129` still reads
> `Layer.buildWithMemoMap(listenerLayer(opts, port), Layer.makeMemoMapUnsafe(), scope)`.
> That is exactly the line our `server.ts` hunk rewrites to the shared `memoMap`,
> and it's why that hunk applied cleanly in the dry-run (upstream never touched it).
>
> **Do not be misled by merged upstream "fixes."** Sibling issue #30523
> ("Question hangs when continuing from a different directory") was closed by PRs
> **#30574 / #30578** (`fix(tui): route question replies/responses by session
> directory`), which shipped in v1.16.0 as the release note *"Routed question
> responses to the right session directory."* Those are **TUI-layer routing**
> fixes for one directory-specific symptom — they do NOT unify the dual
> `InstanceStore.Service` on the server, so they don't help non-TUI surfaces
> (Telegram, plugins, SDK webHandler). The broader bug class remains OPEN upstream
> (#30066, #4632; #29850 was closed NOT_PLANNED). Our server-side fix covers all
> surfaces and is orthogonal to the TUI fix. **Keep the patch.**

**Conflicts:** `app-runtime.ts` (1 hunk), `provider.test.ts` (1 hunk). The other
7 hunks (`instance-layer.ts`, `httpapi/server.ts`, `server.ts`, `worktree/index.ts`,
3 tests) applied cleanly under `--reject` — including the load-bearing
`server.ts` memoMap one-liner.

**Step 6.1:**
```bash
cd /tmp/opencode/ocv1160 && git checkout -- . && git clean -fdq
git apply --reject ~/projects/opencode-patched/patches/instance-state-partition.patch 2>&1 | tail
cat packages/opencode/src/effect/app-runtime.ts.rej
git show HEAD:packages/opencode/src/effect/app-runtime.ts | tail -25   # see new AppLayer tail
```

**Step 6.2:** Re-derive the `app-runtime.ts` hunk. v1.16.0's AppLayer:
- already lists `Project.defaultLayer` at top level (line ~97),
- removed `Pty`/`PtyTicket`/`File`/`FileWatcher`/`SyncEvent`/`DataMigration`,
- added `Database.defaultLayer`,
- ends with `.pipe(Layer.provideMerge(InstanceLayer.layer),
  Layer.provideMerge(Observability.layer))`.

The patch wraps `InstanceLayer.layer` with `Layer.provide(InstanceBootstrap.defaultLayer)`
+ `Layer.provide(Project.defaultLayer)`. **Re-evaluate whether the `Project`
provide is still needed** given `Project.defaultLayer` is now top-level — the
partition fix's intent is to give the InstanceLayer its own `InstanceBootstrap`
so per-directory `InstanceStore` state isn't shared. Re-anchor onto the new
`.pipe(...)` tail; keep the `InstanceBootstrap` provide; only keep the `Project`
provide if the InstanceLayer subtree actually requires it (test by building).
Confirm `InstanceBootstrap` import path (`@/project/bootstrap`) still resolves
(it exists in v1.16.0).

**Step 6.3:** Re-derive the `provider.test.ts` import hunk (add `InstanceBootstrap`
+ `Project` imports; context shifted).

**Step 6.4:** Regenerate the multi-file patch:
```bash
git diff packages/opencode/src/effect/app-runtime.ts \
  packages/opencode/src/project/instance-layer.ts \
  packages/opencode/src/server/routes/instance/httpapi/server.ts \
  packages/opencode/src/server/server.ts \
  packages/opencode/src/worktree/index.ts \
  packages/opencode/test/project/instance-bootstrap.test.ts \
  packages/opencode/test/provider/provider.test.ts \
  packages/opencode/test/server/httpapi-instance-context.test.ts \
  packages/opencode/test/server/httpapi-promptasync-context.test.ts \
  > ~/projects/opencode-patched/patches/instance-state-partition.patch
git checkout -- . && git clean -fdq
git apply --check ~/projects/opencode-patched/patches/instance-state-partition.patch && echo "CHECK OK"
```

> Reference: `pigeon/docs/plans/2026-05-26-instancestate-partition-fix-design.md`.

---

### Task 7: Refresh vim.patch (prompt/index.tsx integration)

**Conflict:** only `prompt/index.tsx` (2 hunks). All 8 `vim/*.ts` files,
`tui-schema.ts`, `app.tsx`, and the test apply cleanly. But `prompt/index.tsx`
was heavily restructured upstream:
- `dialog-workspace-create` imports + the entire `selectWorkspace`/`createWorkspace`/
  `warpSession` block were **extracted** into `usePromptWorkspace`/`usePromptMove`
  hooks (`./workspace`, `./move`).
- `input.visualCursor.offset` → `input.cursorOffset`.
- new `promptOffsetWidth` import, `expandTrackedPastedText`, etc.

The vim patch's index.tsx hunks add: vim imports (`useVimEnabled`,
`createVimState`, `createVimHandler`, `vimScroll`, `useVimIndicator`), a
`const vimEnabled = useVimEnabled()` signal, and the key-handling integration.

**Step 7.1:**
```bash
cd /tmp/opencode/ocv1160 && git checkout -- . && git clean -fdq
git apply --reject ~/projects/opencode-patched/patches/vim.patch 2>&1 | tail
cat packages/opencode/src/cli/cmd/tui/component/prompt/index.tsx.rej
```

**Step 7.2:** Hand-integrate into the restructured component:
- Add the 5 vim imports near the other `../vim`-adjacent imports (the anchor
  `dialog-workspace-create` block the patch keyed on is gone — place imports
  after `useTuiConfig` / `usePromptWorkspace` imports instead).
- Add `const vimEnabled = useVimEnabled()` among the signal declarations
  (the old `workspaceSelection` neighbors were removed; put it near the other
  `createSignal`/`createMemo` calls at the top of `Prompt()`).
- Re-locate any key-handler / onKeyDown integration hunks the patch had — find
  the current key-handling site in v1.16.0 and weave the vim handler in there.
- Replace any `input.visualCursor.offset` the patch relied on with
  `input.cursorOffset` if applicable.

> Get the full set of index.tsx hunks the patch carries before editing:
> ```bash
> git show :./ 2>/dev/null  # n/a
> awk '/prompt\/index.tsx/{p=1} p&&/^@@/{print} /^diff --git/{if(seen)exit; if(/prompt\/index.tsx/)seen=1}' \
>   ~/projects/opencode-patched/patches/vim.patch
> ```
> Simpler: open `~/projects/opencode-patched/patches/vim.patch` and read the
> `prompt/index.tsx` section directly.

**Step 7.3:** Regenerate vim.patch from the clean base (it does not depend on
other patches). Include the created files via `git add -N`:
```bash
cd /tmp/opencode/ocv1160 && git checkout -- . && git clean -fdq
git apply --reject ~/projects/opencode-patched/patches/vim.patch
# ...hand-fix prompt/index.tsx, rm its .rej/.orig...
git add -N \
  packages/opencode/src/cli/cmd/tui/component/vim/index.ts \
  packages/opencode/src/cli/cmd/tui/component/vim/vim-handler.ts \
  packages/opencode/src/cli/cmd/tui/component/vim/vim-indicator.ts \
  packages/opencode/src/cli/cmd/tui/component/vim/vim-motion-jump.ts \
  packages/opencode/src/cli/cmd/tui/component/vim/vim-motions.ts \
  packages/opencode/src/cli/cmd/tui/component/vim/vim-scroll.ts \
  packages/opencode/src/cli/cmd/tui/component/vim/vim-state.ts \
  packages/opencode/test/cli/tui/vim-motions.test.ts
git diff > ~/projects/opencode-patched/patches/vim.patch
git checkout -- . && git clean -fdq
git apply --check ~/projects/opencode-patched/patches/vim.patch && echo "CHECK OK"
```

> Behavioral guide: PR #12679 (stale, last code 2026-04-29). The local patch is
> the more current base. The drift issue #8 is just a review prompt, not a blocker.

#### Task 7B (ONLY if KEEPING eager-input-streaming)

Narrow the patch to avoid duplicating upstream's vertex clause. Either (a) leave
it as-is (it double-sets `toolStreaming=false` for vertex — harmless), or (b)
change the condition to only the gap upstream leaves:
`input.model.api.npm === "@ai-sdk/anthropic" && input.model.api.id.includes("claude")`.
Then re-anchor + regenerate against v1.16.0's larger `options()`.

---

### Task 8: Fix tool-fix.patch test types

The runtime hunk (`message-v2.ts`) applies clean. The **test hunk**
(`test/session/message-v2.test.ts`) adds code typed as `MessageV2.WithParts[]`
and `as MessageV2.Part[]` — both removed from `MessageV2` in v1.16.0 (the test
won't typecheck; build still passes but `bun test` may surface it).

**Step 8.1:** In the patch's test hunk, change `MessageV2.WithParts` →
`SessionV1.WithParts` and `MessageV2.Part` → `SessionV1.Part`. Ensure the test
file imports `SessionV1` (check upstream test imports;
`@opencode-ai/core/v1/session`). `MessageV2.toModelMessages` (function) stays.

**Step 8.2:** Verify and regenerate:
```bash
cd /tmp/opencode/ocv1160 && git checkout -- . && git clean -fdq
git apply ~/projects/opencode-patched/patches/tool-fix.patch   # after hand-edit, should apply
git diff packages/opencode/src/session/message-v2.ts \
         packages/opencode/test/session/message-v2.test.ts \
  > ~/projects/opencode-patched/patches/tool-fix.patch
```

---

### Task 9: Update apply.sh + full-stack validation

**Step 9.1:** If DROPPING eager-input-streaming (Task 2 default):
- Remove `patches/eager-input-streaming.patch`.
- In `patches/apply.sh`: delete the `EAGER_INPUT_STREAMING_PATCH` var, its
  existence check, and its "Patch 7" apply block; renumber comments.
- Update `README.md` (section 7 + ownership table + "How It Works" + DROPPED
  history) and the header comment in `apply.sh`.
- Note the sunset in a new `docs/plans/` or README line: "eager-input-streaming
  DROPPED 2026-06-05 — v1.16.0 upstreamed the `@ai-sdk/google-vertex/anthropic`
  + non-claude `@ai-sdk/anthropic` toolStreaming=false in `options()`."

**Step 9.2:** Run the real CI path end-to-end:
```bash
cd /tmp/opencode && rm -rf ocstack && git clone --depth 1 --branch v1.16.0 \
  https://github.com/anomalyco/opencode.git ocstack && cd ocstack
~/projects/opencode-patched/patches/apply.sh .     # must print "All patches applied successfully"
bun install
bun run script/build.ts --all 2>&1 | tail -30      # must succeed (catches missing imports)
```

**Step 9.3:** Targeted tests (catch type/behavior breakage the bundler skips):
```bash
cd /tmp/opencode/ocstack/packages/opencode
bun test test/session/message-v2.test.ts \
         test/provider/transform.test.ts \
         test/provider/provider.test.ts \
         test/cli/tui/vim-motions.test.ts \
         test/project/instance-bootstrap.test.ts 2>&1 | tail -30
bun test test/provider/transform.test.ts -t "gemini empty parts" 2>&1 | tail
```

**Step 9.4:** Grep the applied tree for stranded renamed symbols in our additions
(belt-and-suspenders, since the build doesn't typecheck):
```bash
cd /tmp/opencode/ocstack
git diff | grep -nE '^\+' | grep -E '\bbus\.|Bus\.Service|AppFileSystem|ConfigMCP\.|Config\.Info\b|\bProviderID\b|\bModelID\b|MessageV2\.(WithParts|Part|Assistant|User|TextPart|FilePart|ToolPart|CompactionPart|Format|ContextOverflowError|StructuredOutputError)\b|visualCursor' \
  || echo "clean: no stranded renamed symbols in added lines"
```

**Step 9.5:** Smoke test the built binary:
```bash
./dist/opencode-linux-x64/bin/opencode --version   # path per build.ts output
```

---

### Task 10: Commit + push + build

**Step 10.1:** Review and commit (one commit, or per-patch — match repo style):
```bash
cd ~/projects/opencode-patched
git status && git diff --stat
git add patches/ README.md docs/plans/2026-06-05-refresh-patch-stack-for-v1.16.0.md
git commit -m "chore: rebase patch stack onto v1.16.0

v1.16.0 carries the v1/v2 namespace migration (MessageV2 types -> SessionV1,
Bus -> EventV2Bridge/EventV2, AppFileSystem -> FSUtil, Config.Info -> ConfigV1,
ConfigMCP -> ConfigMCPV1, ProviderID/ModelID -> ProviderV2.ID/ModelV2.ID) plus
prompt/index.tsx + AppLayer restructures.

- prompt-loop-cache: wrap reload/merge around the new
  filterCompactedEffect(...).pipe(provideService(Database)) form; SessionV1 type.
- cache-aligned-compaction: re-derive compaction.ts/prompt.ts/tools.ts for the
  namespace migration + events.publish.
- vim: re-integrate into restructured prompt/index.tsx (workspace/move hooks).
- instance-state-partition: re-anchor InstanceLayer wrap onto rebuilt AppLayer.
- mcp-reconnect: refresh import context.
- tool-fix: test types MessageV2.* -> SessionV1.*.
- eager-input-streaming: DROPPED — v1.16.0 options() upstreams toolStreaming=false
  for @ai-sdk/google-vertex/anthropic + non-claude @ai-sdk/anthropic."
git push
```

**Step 10.2:** Dispatch build + watch:
```bash
gh workflow run build-release.yml --repo johnnymo87/opencode-patched --field version=1.16.0
sleep 3
RUN_ID=$(gh run list --repo johnnymo87/opencode-patched --workflow=build-release.yml \
  --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RUN_ID" --repo johnnymo87/opencode-patched --exit-status
gh release view v1.16.0-patched --repo johnnymo87/opencode-patched --json tagName
```

**Step 10.3:** Close/triage stale issues: build-failure issues for old versions
(#12/#13/#14), the sunset issue #11 (note eager dropped; mcp/opus verdicts), and
note vim drift #8 was addressed by this rebase.

---

### Task 11: Bump workstation + rebuild

**Step 11.1:** Compute SRI hashes for all 4 assets:
```bash
cd /tmp && mkdir -p ocp-1.16.0 && cd ocp-1.16.0
for a in opencode-linux-arm64.tar.gz opencode-darwin-arm64.zip \
         opencode-linux-x64.tar.gz opencode-darwin-x64.zip; do
  curl -sL "https://github.com/johnnymo87/opencode-patched/releases/download/v1.16.0-patched/$a" -o "$a" &
done; wait
for f in *.tar.gz *.zip; do echo "$f -> sha256-$(nix hash file --base64 --type sha256 "$f")"; done
```

**Step 11.2:** Edit `~/projects/workstation/users/dev/home.base.nix`:
- `upstreamVersion = "1.15.13"` → `"1.16.0"`
- `patchedRevision = "2"` → `""`  (reset on upstream bump, per the comment at :281-285)
- Replace all 4 hashes in `opencode-platforms` (:255/260/265/270).
- Refresh the explanatory comment block (:233-243) for v1.16.0 + the eager drop.

**Step 11.3:** Commit + rebuild on this host:
```bash
cd ~/projects/workstation && git diff users/dev/home.base.nix
git add users/dev/home.base.nix && git commit -m "chore(deps): update opencode-patched to 1.16.0

Reset patchedRevision; refresh 4 hashes. Drops eager-input-streaming.patch
(upstreamed in v1.16.0)."
git push
echo $OPENCODE_HOSTNAME   # confirm target (devbox vs cloudbox)
nix run home-manager -- switch --flake ".#$OPENCODE_HOSTNAME" 2>&1 | tail -10
opencode --version        # expect 1.16.0
rm -rf /tmp/ocp-1.16.0
```

**Step 11.4:** Cleanup: `rm -rf /tmp/opencode/ocstack /tmp/opencode/ocv1160`.

---

## Hand-off Notes

- The running OpenCode session is on the OLD binary after rebuild — restart to
  pick up 1.16.0.
- macOS / other machines auto-update via `workstation/update-opencode-patched`
  once `v1.16.0-patched` is latest (opens a PR).
- v1.16.0 also adds upstream "skill discovery and file-based agent loading" —
  unrelated to patches but worth a look for the skills setup.
- If KEEPING eager-input-streaming, this plan's apply.sh/README/workstation edits
  for the drop are skipped; do Task 7B instead.
- Next routine bump: if all (remaining) patches apply clean, only Task 11 is
  needed. The v1/v2 migration may continue across future releases — expect more
  `MessageV2`→`SessionV1`-style churn.
