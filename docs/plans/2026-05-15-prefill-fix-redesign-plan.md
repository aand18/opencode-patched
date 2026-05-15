# Plan: Redesign `prefill-fix.patch` for opencode v1.15.0

**Status**: ready to execute (one ~30-LOC patch across 2 files + 1 test).

**Context (READ THESE FIRST):**
- `2026-05-15-refresh-patch-stack-for-v1.15.0-design.md` — epic design doc; Track 5 is this work
- `2026-05-15-prefill-fix-redesign-question.md` — full briefing (rich code + reasoning)
- `2026-05-15-prefill-fix-redesign-answer.md` — ChatGPT's recommendation (deep, concrete)
- Beads epic: `workstation-1ue`. This task: `workstation-68a`.
- Working tree: `/tmp/opencode-refresh/opencode-v1.15.0` (already has caching applied during this session for adjacent work; before starting this redesign, **reset to clean v1.15.0**).

## TL;DR

The original v1.14.x prefill-fix patch (489 lines) wrapped 24 session routes via a `withSessionInstance(sessionID, async () => {...})` helper that looked up the session's stored directory and rebound the route's Instance to it.

In v1.15.0 the routes were rewritten in Effect-native HttpApi style and the entire targeted file (`server/routes/instance/session.ts`) is gone. A new `WorkspaceRoutingMiddleware` + `InstanceContextMiddleware` pair almost solves the race — but only for sessions enrolled in a workspace. Our sessions are not enrolled in workspaces (we don't use the workspace abstraction), so the race remains.

ChatGPT's deep-research recommendation: thread the already-fetched session's `directory` through the existing `WorkspaceRouteContext`, then prefer `sessionDirectory` over the request-supplied directory in `InstanceContextMiddleware`. Tiny diff, idiomatic, no new middleware dependencies, no duplicate session lookup.

## The race (one-line restatement)

Concurrent `prompt_async` requests for the same session, sent by clients with different `x-opencode-directory` headers, currently bind to different `Instance(directory)` runners → busy guard short-circuits → parallel runners → corrupted assistant log → Anthropic 400 prefill rejection on next replay → poisoned session.

## Implementation

Working tree: `/tmp/opencode-refresh/opencode-v1.15.0`. Reset clean before starting:

```bash
cd /tmp/opencode-refresh/opencode-v1.15.0
git checkout .
git clean -fd
git status -sb   # should show clean / "## HEAD (no branch)"
```

Then apply caching first (it's a hard prereq for the patch stack), so anchors match:

```bash
git apply ~/projects/opencode-cached/patches/caching.patch
```

### Patch 1 — `packages/opencode/src/server/routes/instance/httpapi/middleware/workspace-routing.ts`

Five edits, all small:

1. **Extend `WorkspaceRouteContext` data:**
   ```ts
   export class WorkspaceRouteContext extends Context.Service<
     WorkspaceRouteContext,
     {
       readonly directory: string
       readonly workspaceID?: WorkspaceID
       // Present when the URL identifies an existing session.
       // InstanceContextMiddleware should prefer this for local Instance binding,
       // because the session row has a canonical directory that the request header
       // may not match (e.g. a client in /B sending prompt_async to a session
       // stored under /A). Without this, concurrent cross-cwd requests bind to
       // different Instances and bypass the per-session busy guard.
       readonly sessionDirectory?: string
     }
   >()("@opencode/ExperimentalHttpApiWorkspaceRouteContext") {}
   ```

2. **Extend `RequestPlan.Local`:**
   ```ts
   Local: {
     readonly directory: string
     readonly workspaceID?: WorkspaceID
     readonly sessionDirectory?: string
   }
   ```

3. **Change `planRequest`'s second parameter** from `sessionWorkspaceID?: WorkspaceID` to a session pick:
   ```ts
   function planRequest(
     request: HttpServerRequest.HttpServerRequest,
     session?: { directory?: string; workspaceID?: WorkspaceID },
   ): Effect.Effect<RequestPlan, never, Workspace.Service> {
     return Effect.gen(function* () {
       const url = requestURL(request)
       const envWorkspaceID = configuredWorkspaceID()
       const workspaceID = selectedWorkspaceID(url, session?.workspaceID)
       const workspace = yield* resolveWorkspace(workspaceID, envWorkspaceID)

       if (workspaceID && workspace === undefined && !envWorkspaceID) {
         return RequestPlan.MissingWorkspace({ workspaceID })
       }

       if (workspace !== undefined && !envWorkspaceID && !shouldStayOnControlPlane(request, url)) {
         return yield* planWorkspaceRequest(request, url, workspace)
       }

       return RequestPlan.Local({
         directory: defaultDirectory(request, url),
         workspaceID: envWorkspaceID ?? workspaceID,
         sessionDirectory: session?.directory,
       })
     })
   }
   ```

4. **Update `routeWorkspace`'s Local case** to thread `sessionDirectory`:
   ```ts
   Local: ({ directory, workspaceID, sessionDirectory }) =>
     effect.pipe(
       Effect.provideService(
         WorkspaceRouteContext,
         WorkspaceRouteContext.of({ directory, workspaceID, sessionDirectory }),
       ),
     ),
   ```

5. **Update the call site in `routeHttpApiWorkspace`** to pass the full session:
   ```ts
   const plan = yield* planRequest(request, session)
   ```

   (Currently passes `session?.workspaceID`; just pass `session` instead.)

**Do NOT modify `workspaceRouterMiddleware` (line 219+, the non-HttpApi router variant).** It calls `planRequest(request)` with no session, which now means `sessionDirectory: undefined` and falls through to header-based directory — same behavior as before.

### Patch 2 — `packages/opencode/src/server/routes/instance/httpapi/middleware/instance-context.ts`

One edit. Change the directory resolution in `provideInstanceContext`:

```ts
function provideInstanceContext<E>(
  effect: Effect.Effect<HttpServerResponse.HttpServerResponse, E>,
  store: InstanceStore.Interface,
): Effect.Effect<HttpServerResponse.HttpServerResponse, E, WorkspaceRouteContext> {
  return Effect.gen(function* () {
    const route = yield* WorkspaceRouteContext
    // Prefer the session's stored directory (canonical filesystem path, not URL-encoded)
    // over the request-supplied route directory. Closes the multi-cwd race where
    // concurrent prompt_async requests for the same session from different
    // x-opencode-directory headers would bind to different Instances and bypass
    // the per-session busy guard. See workstation/docs/plans/2026-04-21-opencode-prefill-fix-design.md
    // and opencode-patched/docs/plans/2026-05-15-prefill-fix-redesign-{question,answer}.md
    // for the full root cause and the v1.15.0 redesign rationale.
    const directory = route.sessionDirectory ?? decode(route.directory)
    return yield* store.provide(
      { directory },
      effect.pipe(Effect.provideService(WorkspaceRef, route.workspaceID)),
    )
  })
}
```

Note: do **not** wrap `route.sessionDirectory` in `decode()` — session row directories are already canonical filesystem paths, while request-supplied (header/query) directories may be URL-encoded. Double-decoding would be a real bug.

### Test — `packages/opencode/test/server/middleware/instance-context.test.ts` (NEW)

Two test cases. Use a fake `InstanceStore` whose `provide` records the directory it was asked to bind to.

```ts
import { describe, test, expect } from "bun:test"
import { Effect, Layer } from "effect"
import { HttpServerRequest, HttpServerResponse } from "effect/unstable/http"
import { InstanceStore } from "@/project/instance-store"
import { Session } from "@/session/session"
import {
  workspaceRoutingLayer,
  WorkspaceRoutingMiddleware,
} from "@/server/routes/instance/httpapi/middleware/workspace-routing"
import {
  instanceContextLayer,
  InstanceContextMiddleware,
} from "@/server/routes/instance/httpapi/middleware/instance-context"
// ... (need to figure out test harness — see "Test infrastructure" below)

describe("instance-context middleware", () => {
  test("session-scoped routes bind to session.directory, ignoring x-opencode-directory header", async () => {
    // Fake session row: id S, directory=/A, no workspace
    // Request: POST /session/S/prompt_async, x-opencode-directory: /B
    // Expect: InstanceStore.provide called with { directory: "/A" }
  })

  test("non-session routes bind to header directory", async () => {
    // Request: POST /session, x-opencode-directory: /B  (session creation/list — no sessionID in URL)
    // Expect: InstanceStore.provide called with { directory: "/B" }
  })
})
```

**Test infrastructure note**: skim `packages/opencode/test/server/` (if it exists) for existing patterns. If there's no test infrastructure for HttpApi middleware specifically, the simplest harness is:

- Build a Layer that swaps `InstanceStore.Service` for a fake interface that captures arguments to `provide()`.
- Build a Layer that swaps `Session.Service` for a fake that returns a stub session row for known IDs.
- Run `provideInstanceContext(noopEffect, fakeStore)` directly with a constructed `HttpServerRequest` and assert the captured directory.

If middleware-level testing turns out to require too much fake-Layer scaffolding for a speed-run, fall back to: do the patch + targeted test case for `workspace-routing`'s `planRequest` function (which is exported as a function we can call directly with a constructed request and an inline session pick). At minimum, prove the data-flow logic:

```ts
test("planRequest threads session.directory into Local plan", async () => {
  // Construct a fake HttpServerRequest, call planRequest(request, { directory: "/A" })
  // Assert RequestPlan.Local.sessionDirectory === "/A"
})
```

The middleware integration is then trivially correct by code inspection.

## Verification

1. `bunx tsc --noEmit -p packages/opencode` → exit 0.
2. `bun test test/server/` (or whatever the closest test directory is) → 0 fail. New test passes.
3. `bun test test/session/` → unchanged from baseline (no regressions).
4. **Sanity check session group middleware order**: `groups/session.ts:447-450` should still apply `InstanceContextMiddleware` after `WorkspaceRoutingMiddleware` (verify; the order matters because InstanceContext requires WorkspaceRouteContext).
5. Regenerate `prefill-fix.patch`:
   ```bash
   cd /tmp/opencode-refresh/opencode-v1.15.0
   git diff -- \
     packages/opencode/src/server/routes/instance/httpapi/middleware/workspace-routing.ts \
     packages/opencode/src/server/routes/instance/httpapi/middleware/instance-context.ts \
     packages/opencode/test/server/middleware/instance-context.test.ts \
     > /tmp/prefill-fix-v1.15.0.patch
   ```
6. Verify against fresh tree:
   ```bash
   cd /tmp && rm -rf prefill-verify && git clone --depth 1 --branch v1.15.0 --quiet https://github.com/anomalyco/opencode.git prefill-verify
   cd /tmp/prefill-verify
   git apply ~/projects/opencode-cached/patches/caching.patch
   git apply --check /tmp/prefill-fix-v1.15.0.patch
   ```
7. Copy to opencode-patched, commit, push, close `workstation-68a`.

## Why the redesign is dramatically smaller than the old patch

| | v1.14.x patch | v1.15.0 redesign |
|---|---|---|
| LOC | 489 | ~30 |
| Files | 1 (session.ts) | 2 middleware + 1 test |
| Pattern | Wrap each route handler in helper | Thread data through existing context |
| Risk surface | 24 route handlers | 1 directory-resolution branch |
| Upstreamability | Low (architectural mismatch) | High (extends existing data flow naturally) |

The reason: v1.14.x had no per-route middleware doing instance binding, so we had to wrap every handler. v1.15.0 already has the middleware abstraction; we just teach it about session-stored directories.

## Compaction-resilience

If this session compacts mid-implementation, the next session should:

1. `cat ~/projects/opencode-patched/docs/plans/2026-05-15-prefill-fix-redesign-plan.md` (this doc).
2. `bd show workstation-68a` for current status / notes.
3. `cd /tmp/opencode-refresh/opencode-v1.15.0 && git status -sb` to see what's already edited.
4. Resume from whichever step is incomplete.

## Open question (low-priority, file as separate bead if it bites)

Should we file a small upstream PR proposing this exact change for `anomalyco/opencode`? Framing per ChatGPT's suggestion:

> "For existing session-scoped local routes, bind the request to the session's stored directory. `x-opencode-directory` should select a directory for session creation/listing/non-session routes, not rebind an existing session's execution context."

This would let us drop the patch entirely on the next bump where it merges. Defer until after our patch ships and we have time for upstream work.
