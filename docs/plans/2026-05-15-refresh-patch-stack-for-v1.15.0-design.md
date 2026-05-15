# Design: Refresh Patch Stack for v1.15.0

> **For Claude:** This is the **design** doc. The companion execution plan is
> `2026-05-15-refresh-patch-stack-for-v1.15.0.md` (write that next, in a worktree).
> Beads epic for cross-session tracking: `workstation-1ue`.
>
> Sub-beads (in dependency order):
> - `workstation-bix` — Refresh caching.patch (4 rejects)
> - `workstation-24i` — Cut v1.15.0-cached release
> - `workstation-3b6` — Refresh vim.patch (3 rejects)
> - `workstation-9g8` — Refresh tool-fix.patch (2 rejects)
> - `workstation-5qk` — Refresh mcp-reconnect.patch (1 reject)
> - `workstation-68a` — **Redesign prefill-fix.patch (HIGH RISK)**
> - `workstation-e7w` — Verify full apply.sh stack
> - `workstation-str` — Cut v1.15.0-patched release
> - `workstation-bgg` — Bump workstation home.base.nix
> - `workstation-9sp` — Rebuild cloudbox + devbox

## Goal

Refresh the full patch stack onto upstream `anomalyco/opencode@v1.15.0`:

- `opencode-cached`: `caching.patch`
- `opencode-patched`: `vim.patch`, `tool-fix.patch`, `mcp-reconnect.patch`,
  `eager-input-streaming.patch`, `prefill-fix.patch`

Cut `v1.15.0-cached` and `v1.15.0-patched` releases. Bump `workstation` from
`1.14.28` to `1.15.0`. Apply on cloudbox + devbox.

## Why This Is a Real Refresh, Not a Mechanical Rebump

Jumping from `v1.14.28` → `v1.15.0` is **1058 upstream commits**, **552 files
changed**, **~67k+ insertions / 37k+ deletions**. Several of those commits
land directly in code that our patches anchor on:

| Upstream PR | Affects |
|---|---|
| #27415 Effect-native core event system | `mcp-reconnect.patch` (event/bus surface) |
| #27506 simplify tui plugin runtime flags | `vim.patch` (TUI input) |
| #27269 #27275 #27291 typed message lookup wrappers | `tool-fix.patch` (message-v2 surface), `prefill-fix.patch` (session ops) |
| #27347 move models.dev into core | `caching.patch` (config schema imports) |
| Routes restructure → `httpapi/handlers/` | **`prefill-fix.patch` (whole file moved + framework rewritten)** |

The last one is the showstopper: `packages/opencode/src/server/routes/instance/session.ts`
**no longer exists**. It has been split into Effect-native HTTP API handlers
under `packages/opencode/src/server/routes/instance/httpapi/handlers/`. The
old file used Hono routes wrapping `jsonRequest()` callbacks; the new ones
use `HttpApiBuilder.group()` with Effect generators. The 489-line
prefill-fix patch wrapped 24 routes via `withSessionInstance(sessionID, async () => ...)`.
That `async () =>` shape doesn't exist anywhere in the new code — the pattern
must be redesigned.

## Per-Patch Verdict (against pristine v1.15.0)

Tested with `git apply --check` against fresh `anomalyco/opencode@v1.15.0`
(probed at design time on cloudbox `/tmp/opencode-refresh/opencode-v1.15.0`):

| Patch | Status | Diagnostic |
|---|---|---|
| `caching.patch` | ❌ 4 rejects | `agent.ts` h#1, `provider.ts` h#1+h#2, `transform.ts` h#1, `prompt.ts` h#1. Likely the same import-refactor pattern as v1.14.25 (PositiveInt/NonNegativeInt moved to util/schema). Probably small. |
| `vim.patch` | ❌ 3 rejects | `app.tsx`, `prompt/index.tsx`, `tui-schema.ts`. Likely the runtime-flags refactor (#27506) shifted anchors. Mechanical context refresh, no semantic redesign expected. |
| `tool-fix.patch` | ❌ 2 rejects | `message-v2.ts` h@704, `message-v2.test.ts` h@947. The session message refactors (#27269, #27275, #27291) churned this surface. May need anchor refresh and/or test updates. |
| `mcp-reconnect.patch` | ❌ 1 reject | `mcp/index.ts` h@129. The Effect-native event system (#27415) rewired bus surface. Need to verify the `watch()` reconnect handler still has somewhere to land. Risk: medium. |
| `eager-input-streaming.patch` | ✅ clean | Survives. |
| `prefill-fix.patch` | ❌ **target file deleted** | `server/routes/instance/session.ts` no longer exists. Routes moved to `server/routes/instance/httpapi/handlers/session.ts` and rewritten in Effect-native style. **Patch needs full redesign.** |

## High-Level Plan

Five tracks, mostly sequential because of inter-patch dependencies:

```
Track 1: caching.patch refresh ──┐
                                 ├──→ opencode-cached release (v1.15.0-cached)
                                 │
Track 2: vim ────────────┐       │
Track 3: tool-fix ───────┼───────┴──→ Track 6: full apply.sh stack test ──→ opencode-patched release (v1.15.0-patched)
Track 4: mcp-reconnect ──┘       │
                                 │
Track 5: prefill-fix REDESIGN ───┘ (gates Track 6)
                                              │
                                              └──→ Track 7: workstation pin bump ──→ Track 8: rebuild + verify
```

`prefill-fix` is the long pole. Tracks 2–4 can proceed in parallel with Track 5
once Track 1 is done (since the patched stack apply order needs caching first).

## Track 5 (prefill-fix) Design Sketch

The original race is still present in v1.15.0: concurrent `prompt_async`
requests with different `x-opencode-directory` headers can resolve to
different `Instance` contexts, all see an empty `runners` map, all bypass the
busy guard. The old fix wrapped each `/:sessionID/...` route in a helper that:

1. Looked up the session's stored `directory` via `Session.Service.get()`.
2. Called `Instance.provide({ directory, init: ..., fn })` to bind subsequent
   work to the session's canonical Instance.

In v1.15.0 the routes are Effect-typed handlers like:

```ts
handlers.handle("get", ({ path: { sessionID } }) =>
  Effect.gen(function* () {
    const session = yield* Session.Service
    return yield* session.get(sessionID)
  })
)
```

The natural redesign uses the Effect dependency graph. Instead of an
`async () => {}` wrapper, define an Effect that:

1. Reads the session row.
2. Provides a per-session `Instance` layer/scope to the wrapped Effect.

Pseudocode:

```ts
const withSessionInstance = <E, A>(
  sessionID: SessionID,
  body: Effect.Effect<A, E, Instance>
) =>
  Effect.gen(function* () {
    const session = yield* Session.Service
    const info = yield* session.get(sessionID)
    return yield* body.pipe(
      Effect.provideService(Instance, /* construct from info.directory */)
    )
  })
```

Need to verify:

- Whether `Instance` is exposed as a `Tag` we can `provideService` on, or
  if it's still a scope-style API requiring a different pattern.
- Whether `InstanceBootstrap` / `AppRuntime` from the old patch still exist
  or have been refactored.
- Whether the routes already have implicit per-request Instance scoping that
  obviates the patch (check `httpapi/server.ts` middleware — search for
  `directory` header handling).

If upstream introduced any per-session middleware that fixes the race, the
patch can be **dropped**. This must be the first thing checked in Track 5.

## Risks

- **Medium**: `mcp-reconnect.patch` may need substantial rework if the bus
  reconnect API was rewritten. The old patch already had to re-thread
  `bridge` through async context; another iteration may be needed.
- **High**: `prefill-fix.patch` redesign. Could take a full session by itself.
  May discover upstream now handles this correctly, in which case the patch
  can be retired (best case) or the old workaround no longer makes sense
  (worst case — need a fresh design).
- **Low**: build/CI failures specific to Bun version, codesigning, etc. The
  build-release.yml already handles the Bun 1.3.12 codesign trap (see
  `darwin-signing.md` skill); should still apply.

## Compaction-Resilience

The execution plan (separate doc) will follow the v1.14.25 plan template:
named tasks A–I, each with explicit step-by-step commands and expected
outputs. Beads epic + sub-issues track cross-session state.

If resuming after compaction:

1. Read this design doc + the execution plan + the beads epic.
2. `bd show <epic-id>` to see which sub-issues are open / closed / in_progress.
3. Verify ground truth before assuming any task is done:
   ```bash
   gh release view v1.15.0-cached --repo johnnymo87/opencode-cached --json tagName 2>/dev/null
   gh release view v1.15.0-patched --repo johnnymo87/opencode-patched --json tagName 2>/dev/null
   grep 'version = ' ~/projects/workstation/users/dev/home.base.nix | head -1
   ```
4. Resume at the first incomplete bead.

## State at Design Time (2026-05-15)

- `~/projects/opencode` upstream HEAD: `1c7c03332` (post-v1.15.0).
- `~/projects/opencode-cached`: clean, on `main`, HEAD `312013e` (v1.14.28-cached).
- `~/projects/opencode-patched`: clean, on `main`, HEAD `c4f4027` (v1.14.28-patched).
- `workstation/users/dev/home.base.nix:121`: `version = "1.14.28"`.
- Latest releases:
  - `johnnymo87/opencode-cached`: `v1.14.28-cached`
  - `johnnymo87/opencode-patched`: `v1.14.28-patched`
- No automated workflow has yet attempted v1.15.0 (or if it did, it hasn't been
  noticed as a failed CI run — verify before starting work).
