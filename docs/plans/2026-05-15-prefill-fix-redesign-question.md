# How should we redesign our `prefill-fix` patch for opencode v1.15.0's new HttpApi middleware architecture?

## Keywords

opencode, anomalyco/opencode, opencode-patched, HttpApiMiddleware, InstanceContextMiddleware, WorkspaceRoutingMiddleware, InstanceStore, Effect-TS, Anthropic prefill 400, multi-cwd race, opencode-serve, prompt_async

## The situation

We maintain a fork of `anomalyco/opencode` called `opencode-patched`, which applies a small stack of behavioral patches on top of upstream tagged releases. One of those patches (`prefill-fix.patch`) closes a real concurrency race in our specific deployment topology:

- We run a single shared `opencode-serve` daemon that is hit by **multiple concurrent clients** (a "swarm" of TUI/CLI sessions, each in its own working directory). Every request carries an `x-opencode-directory` header naming the client's cwd.
- The daemon uses that header to select an `Instance` (one per directory). Per-Instance state — including the `SessionRunState.runners` map that gates the "is this session already busy?" check — is keyed by `Instance.directory`.
- If a swarm client A (cwd `/A`) has a session `S` busy with one `prompt_async`, and another swarm client B (cwd `/B`) sends a second `prompt_async` against the **same** session `S` (legitimate cross-client coordination — e.g., a coordinator session being driven by workers that happen to be in different cwds), then in the unpatched build:
  - B's request resolves to `Instance(/B)`.
  - `Instance(/B).runners` is empty (it's never seen `S` before).
  - The busy guard short-circuits as "not busy".
  - Both A's and B's prompt loops run in parallel against the same persisted message log → produces interleaved assistant content → Anthropic Claude 4.x rejects the next replay with `400 "does not support assistant message prefill"` errors.
  - The session is then poisoned for replay until the corrupted assistant turn is manually edited or the session is forked.

This is reproducible — we hit it consistently in our swarm coordinator/worker pattern when v1.14.x first started sending Claude 4.x traffic without prefill support, and our patch has been load-bearing for our daily use ever since.

The original v1.14.x fix (committed as `prefill-fix.patch` in `johnnymo87/opencode-patched`) wrapped 24 session routes in `packages/opencode/src/server/routes/instance/session.ts` with this helper:

```ts
async function withSessionInstance<R>(sessionID: string, fn: () => Promise<R>): Promise<R> {
  const directory = await AppRuntime.runPromise(
    Effect.gen(function* () {
      const session = yield* Session.Service
      const info = yield* session.get(sessionID as SessionID)
      return info.directory
    })
  )
  return Instance.provide({
    directory,
    init: () => AppRuntime.runPromise(InstanceBootstrap),
    fn
  })
}
```

The pattern: for every `/:sessionID/...` route, look up the **session's stored directory** (from the database row) and bind the rest of the route's work to that Instance, ignoring whatever directory the request header asked for. This makes `Instance(S.directory).runners` the single source of truth for the busy guard, regardless of the requesting client's cwd.

Now we are refreshing the patch stack from `v1.14.28` → `v1.15.0`, and **the entire targeted file has been deleted upstream**. Routes have been rewritten in Effect-native `HttpApiBuilder.group()` style and split into `packages/opencode/src/server/routes/instance/httpapi/handlers/*.ts`. Crucially, v1.15.0 introduces a brand-new pair of middleware that *almost* does what our patch was doing.

## Environment

- Upstream: `github.com/anomalyco/opencode` tagged `v1.15.0` (released 2026-05-15).
- Our fork: `github.com/johnnymo87/opencode-patched` (applies caching → vim → tool-fix → mcp-reconnect → eager-input-streaming → prefill-fix in order).
- Effect-TS version is whatever ships with `effect` and `effect/unstable/httpapi` in opencode v1.15.0's `package.json`. The unstable HttpApi is "effect-smol" — see comment at workspace-routing.ts:21.
- Bun 1.3.x runtime.
- Anthropic Claude Opus 4.7 / Opus 4.6 / Sonnet 4.6 do **not** support assistant-message prefill (verified). This is the root reason `messages.* tool_use ids without tool_result blocks` style 400s are unrecoverable without restructuring the persisted message log.
- We do **not** enroll our sessions in the new Workspace abstraction — sessions are created with `workspaceID = undefined` (the InstanceState.workspaceID is undefined in our serve setup).

## What v1.15.0 already provides

There are two new middlewares in `packages/opencode/src/server/routes/instance/httpapi/middleware/`. Both are applied to every HTTP API group (verified for `groups/session.ts:447-450`):

```ts
.middleware(InstanceContextMiddleware)
.middleware(WorkspaceRoutingMiddleware)
.middleware(Authorization)
```

### `workspace-routing.ts` (the upstream layer that resolves the directory)

```ts
function defaultDirectory(request: HttpServerRequest.HttpServerRequest, url: URL): string {
  return url.searchParams.get("directory") || request.headers["x-opencode-directory"] || process.cwd()
}

function planRequest(
  request: HttpServerRequest.HttpServerRequest,
  sessionWorkspaceID?: WorkspaceID,
): Effect.Effect<RequestPlan, never, Workspace.Service> {
  return Effect.gen(function* () {
    const url = requestURL(request)
    const envWorkspaceID = configuredWorkspaceID()
    const workspaceID = selectedWorkspaceID(url, sessionWorkspaceID)
    const workspace = yield* resolveWorkspace(workspaceID, envWorkspaceID)

    if (workspaceID && workspace === undefined && !envWorkspaceID) {
      return RequestPlan.MissingWorkspace({ workspaceID })
    }

    if (workspace !== undefined && !envWorkspaceID && !shouldStayOnControlPlane(request, url)) {
      return yield* planWorkspaceRequest(request, url, workspace)
    }

    return RequestPlan.Local({ directory: defaultDirectory(request, url), workspaceID: envWorkspaceID ?? workspaceID })
  })
}

function routeHttpApiWorkspace<E>(
  client: HttpClient.HttpClient,
  effect: Effect.Effect<HttpServerResponse.HttpServerResponse, E, WorkspaceRouteContext>,
): Effect.Effect<...> {
  return Effect.gen(function* () {
    const request = yield* HttpServerRequest.HttpServerRequest
    const sessionID = getWorkspaceRouteSessionID(requestURL(request))
    const session = sessionID
      ? yield* Session.Service.use((svc) => svc.get(sessionID)).pipe(
          Effect.catchIf(NotFoundError.isInstance, () => Effect.succeed(undefined)),
          Effect.catchDefect(() => Effect.succeed(undefined)),
        )
      : undefined
    const plan = yield* planRequest(request, session?.workspaceID)
    return yield* routeWorkspace(client, effect, plan)
  })
}
```

`getWorkspaceRouteSessionID` extracts the sessionID from the URL path (`/session/<sessionID>/...`).

The middleware also exposes a `WorkspaceRouteContext` containing `{ directory: string, workspaceID?: WorkspaceID }`.

### `instance-context.ts` (the upstream layer that binds the request to an Instance)

```ts
function provideInstanceContext<E>(
  effect: Effect.Effect<HttpServerResponse.HttpServerResponse, E>,
  store: InstanceStore.Interface,
): Effect.Effect<HttpServerResponse.HttpServerResponse, E, WorkspaceRouteContext> {
  return Effect.gen(function* () {
    const route = yield* WorkspaceRouteContext
    return yield* store.provide(
      { directory: decode(route.directory) },
      effect.pipe(Effect.provideService(WorkspaceRef, route.workspaceID)),
    )
  })
}
```

`InstanceStore.provide({ directory }, effect)` calls `load({ directory })` which gets-or-creates the per-directory Instance and provides it as `InstanceRef` to the effect. Per-Instance state (e.g., the runners map) is then keyed off this directory.

### Session row structure

Every session row has a `directory` column (string) and an optional `workspaceID`. From `session.ts`:

```ts
{
  id: row.id,
  workspaceID: row.workspace_id ?? undefined,
  directory: row.directory,
  ...
}
```

Sessions get their `workspaceID` from `InstanceState.workspaceID` at create time (which is undefined in our serve setup). `InstanceState.directory` is `(InstanceRef ?? Instance.current).directory`.

## The remaining race

The v1.15.0 architecture solves the race **only for sessions that are enrolled in a workspace**. The flow there is:

1. URL has `/session/<sessionID>/...`.
2. `WorkspaceRoutingMiddleware` extracts the sessionID, looks up `session.workspaceID`.
3. If `session.workspaceID` is set, that workspace's `target.directory` becomes the request's directory regardless of the header.
4. `InstanceContextMiddleware` then binds the request to `Instance(workspace.target.directory)`.

For sessions **without** a workspaceID (our case):

1. Same URL extraction, but `session.workspaceID` is undefined.
2. `selectedWorkspaceID` returns undefined.
3. `resolveWorkspace` returns `Effect.void`.
4. `planRequest` falls through to `RequestPlan.Local({ directory: defaultDirectory(request, url) })` — i.e., the **header value** is used.
5. `InstanceContextMiddleware` binds the request to `Instance(headerDirectory)`.
6. If two clients send concurrent requests to the same session with different headers → bound to different Instances → busy-guard race fires → poisoned session.

## What we are considering

A surgical addition to `InstanceContextMiddleware` (or a new wrapper middleware sitting between WorkspaceRouting and InstanceContext) that does this:

```ts
function provideInstanceContext<E>(
  effect: Effect.Effect<HttpServerResponse.HttpServerResponse, E>,
  store: InstanceStore.Interface,
): Effect.Effect<HttpServerResponse.HttpServerResponse, E, WorkspaceRouteContext | Session.Service | HttpServerRequest.HttpServerRequest> {
  return Effect.gen(function* () {
    const route = yield* WorkspaceRouteContext
    const request = yield* HttpServerRequest.HttpServerRequest
    const sessionID = getWorkspaceRouteSessionID(new URL(request.url, "http://localhost"))
    const sessionDirectory = sessionID
      ? yield* Session.Service.use((svc) => svc.get(sessionID).pipe(
          Effect.map((s) => s.directory),
          Effect.catchIf(NotFoundError.isInstance, () => Effect.succeed(undefined)),
          Effect.catchDefect(() => Effect.succeed(undefined)),
        ))
      : undefined
    const directory = sessionDirectory ?? decode(route.directory)
    return yield* store.provide(
      { directory },
      effect.pipe(Effect.provideService(WorkspaceRef, route.workspaceID)),
    )
  })
}
```

This way:

- For workspace-enrolled sessions: `route.directory` is already the workspace's target directory (set by WorkspaceRoutingMiddleware), and `session.directory` should equal that. They agree → no behavior change.
- For non-workspace sessions: `session.directory` (from DB) overrides whatever the header asked for. Race closed.
- For non-session-scoped routes (no sessionID in URL): falls through to `route.directory` as before.

Other patch members in the same stack that already work in v1.15.0 use HttpApiMiddleware with similar request-derived context (`WorkspaceRouteContext`, `InstanceRef`, `WorkspaceRef`). Adding `Session.Service` and `HttpServerRequest.HttpServerRequest` as middleware requirements seems to fit the pattern.

## What we know vs. what we're uncertain about

**Verified facts (read primary source on cloudbox):**

- The race exists in v1.15.0 for sessions without workspaceID (read planRequest line 165 of `workspace-routing.ts`; non-workspace path reaches `defaultDirectory(request, url)` which is the header).
- Every session group (`groups/session.ts`) applies both middlewares. Session DB rows have a `directory` column.
- `InstanceStore.provide` keys per-directory Instances; per-Instance state via `InstanceState.make` is keyed by `Instance.directory` (verified in v1.14.x at `instance-state.ts` and unchanged in semantics).
- The new `WorkspaceRouteContext` is **provides:** of `WorkspaceRoutingMiddleware`. `InstanceContextMiddleware` declares `requires: WorkspaceRouteContext` — so it sees what WorkspaceRouting set.
- Anthropic 400 prefill failures with these models are unrecoverable without surgery on the persisted log.

**Uncertain — would love a researcher's eye:**

1. **Is the proposed middleware surgery the correct shape**, or is there a more idiomatic Effect-native way (e.g., a new Layer-level concern) we're missing? We want minimal divergence from upstream's architecture so future v1.16.0+ refreshes are cheap.
2. **Are there other races we're missing** in the new architecture? E.g., the workspace-routing path uses `Session.Service.use((svc) => svc.get(sessionID)).pipe(Effect.catchIf(NotFoundError.isInstance, ...))`. If the session lookup happens against a directory's `Session.Service` that hasn't loaded that session yet (cross-Instance lookup), what does `svc.get(sessionID)` actually return? Does `Session.Service` operate per-Instance or globally?
3. **Should we instead push for upstream adoption** of a tiny fix to `workspace-routing.ts` itself (preferring `session.directory` to `defaultDirectory()` when sessionWorkspaceID is undefined and a session is found)? Is there a reason upstream made this design choice intentionally — e.g., do they want clients to be free to rebind a session to a different directory per request, perhaps for /experimental routes?
4. **Are there any non-`/session/<sessionID>/...` routes** that operate on a session and would benefit from the same per-session directory binding (so we'd want the wrapper to handle multiple URL shapes)? E.g., is there a `/messages/<messageID>/...` or `/parts/<partID>/...` route shape?
5. **Will adding `Session.Service` + `HttpServerRequest.HttpServerRequest` as middleware requirements** cause layer-build problems? Both are present everywhere because the application already wires them, but we'd like a sanity check on whether HttpApiMiddleware composition will accept this.
6. **Is `decode(route.directory)` doing url-decoding for a reason** — should our `session.directory` value also pass through `decode()`, or is the decode purely for header-supplied values?

**Constraints:**

- Must work for sessions WITHOUT a workspaceID (our daily use).
- Must not break sessions WITH a workspaceID (other users may rely on this).
- Must apply on top of v1.15.0+caching+vim+tool-fix+mcp-reconnect+eager-input-streaming. Test surface is `bun test` in `packages/opencode/`.
- Patch should be small and live-mergeable into a single `prefill-fix.patch` file in our patch stack.
- Should not require enrolling our sessions in workspaces (we don't use the workspace abstraction).

## Specific questions

1. Is the proposed middleware surgery the best approach? Or would a different layer (e.g., wrapping `routeHttpApiWorkspace` itself; modifying the Layer for `InstanceContextMiddleware`) be cleaner?
2. Is there a hidden reason the upstream chose header-over-session for the directory in the non-workspace path, that would make our override semantically dangerous?
3. Are there other URL shapes in v1.15.0's session routes that we should also handle?
4. Any Effect-TS gotchas we should know about when adding `Session.Service` / `HttpServerRequest.HttpServerRequest` to a middleware's required services?
5. Would it be more correct to ALSO surgically protect the busy-guard inside `SessionRunState` itself (e.g., make the runners map global rather than per-Instance) as a defense in depth? Or is the per-request directory normalization the canonical fix?

## Files we can share more of if needed

- `/tmp/opencode-refresh/opencode-v1.15.0/packages/opencode/src/server/routes/instance/httpapi/middleware/workspace-routing.ts` (full file)
- `/tmp/opencode-refresh/opencode-v1.15.0/packages/opencode/src/server/routes/instance/httpapi/middleware/instance-context.ts` (full file)
- `/tmp/opencode-refresh/opencode-v1.15.0/packages/opencode/src/server/routes/instance/httpapi/groups/session.ts`
- `/tmp/opencode-refresh/opencode-v1.15.0/packages/opencode/src/server/routes/instance/httpapi/AGENTS.md` (route patterns guide)
- `/tmp/opencode-refresh/opencode-v1.15.0/packages/opencode/src/project/instance-store.ts`
- `/tmp/opencode-refresh/opencode-v1.15.0/packages/opencode/src/effect/instance-state.ts`
- `~/projects/opencode-patched/patches/prefill-fix.patch` (the v1.14.28 form of our existing patch)

The original ChatGPT briefing for the v1.14.x patch is at `~/projects/workstation/docs/plans/research/2026-04-21-opencode-multi-instance-prefill-question.md` if researcher wants to see how we framed the original problem.
