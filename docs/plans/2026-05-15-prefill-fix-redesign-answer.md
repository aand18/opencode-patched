Recommendation

Patch workspace-routing.ts + instance-context.ts, not the session handlers and not SessionRunState.

The cleanest v1.15.0 shape is:

WorkspaceRoutingMiddleware should continue doing the session lookup it already does, but it should carry the found session’s stored directory forward in WorkspaceRouteContext; InstanceContextMiddleware should prefer that stored session directory over the request header/query directory when binding the request to an Instance.

That keeps the fix at the same architectural layer upstream just introduced: request routing decides the directory; instance context only binds to it.

The important refinement to your proposed patch: avoid doing a second Session.Service.get(sessionID) inside InstanceContextMiddleware. WorkspaceRoutingMiddleware already extracts /session/:sessionID and calls Session.Service.get(sessionID) before calling planRequest; today it passes only session?.workspaceID, which is the gap. 
GitHub

Why this is the right layer

WorkspaceRoutingMiddleware already owns:

URL parsing.

Session-ID extraction.

Workspace selection.

Local vs remote request planning.

Producing WorkspaceRouteContext.

The current local fallback explicitly uses defaultDirectory(request, url), which reads ?directory=, then x-opencode-directory, then process.cwd(). 
GitHub
+1

InstanceContextMiddleware then takes the chosen route directory, decodes it, and calls InstanceStore.provide({ directory }, ...). 
GitHub

And InstanceStore.load caches by resolved directory, so choosing the wrong directory really does create/select the wrong per-directory instance. 
GitHub

So the patch should change the route plan, not all route handlers.

Suggested patch shape
workspace-routing.ts

Extend the route context:

TypeScript
export class WorkspaceRouteContext extends Context.Service<
  WorkspaceRouteContext,
  {
    readonly directory: string
    readonly workspaceID?: WorkspaceID

    // Present when the URL identifies an existing session.
    // InstanceContextMiddleware should prefer this for local Instance binding.
    readonly sessionDirectory?: string
  }
>()("@opencode/ExperimentalHttpApiWorkspaceRouteContext") {}

Extend the local plan:

TypeScript
type RequestPlan = Data.TaggedEnum<{
  MissingWorkspace: { readonly workspaceID: WorkspaceID }
  Local: {
    readonly directory: string
    readonly workspaceID?: WorkspaceID
    readonly sessionDirectory?: string
  }
  Remote: {
    readonly request: HttpServerRequest.HttpServerRequest
    readonly workspace: Workspace.Info
    readonly target: RemoteTarget
    readonly url: URL
  }
}>

Change planRequest to accept the session object, not only its workspace ID:

TypeScript
function planRequest(
  request: HttpServerRequest.HttpServerRequest,
  session?: Pick<Session.Info, "directory" | "workspaceID">,
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

Change routeWorkspace to carry it:

TypeScript
Local: ({ directory, workspaceID, sessionDirectory }) =>
  effect.pipe(
    Effect.provideService(
      WorkspaceRouteContext,
      WorkspaceRouteContext.of({ directory, workspaceID, sessionDirectory }),
    ),
  )

Change the call site:

TypeScript
const plan = yield* planRequest(request, session)

That one-line call-site change is the essence of the fix. Today upstream has already fetched session; it just drops session.directory and keeps only session.workspaceID. 
GitHub

instance-context.ts

Prefer the session directory, and only URL-decode the request-supplied route directory:

TypeScript
function provideInstanceContext<E>(
  effect: Effect.Effect<HttpServerResponse.HttpServerResponse, E>,
  store: InstanceStore.Interface,
): Effect.Effect<HttpServerResponse.HttpServerResponse, E, WorkspaceRouteContext> {
  return Effect.gen(function* () {
    const route = yield* WorkspaceRouteContext

    const directory = route.sessionDirectory ?? decode(route.directory)

    return yield* store.provide(
      { directory },
      effect.pipe(Effect.provideService(WorkspaceRef, route.workspaceID)),
    )
  })
}

This avoids a subtle double-decoding problem. decode(route.directory) exists because query/header directories may be URL-encoded. A session row’s directory is already the canonical stored filesystem path, so do not run it through decodeURIComponent again.

Why not patch only InstanceContextMiddleware?

Your proposed InstanceContextMiddleware patch would work for the race, but it has three downsides:

It repeats the session lookup that WorkspaceRoutingMiddleware already performed.

It makes InstanceContextMiddleware depend on Session.Service and HttpServerRequest, even though its current job is just “bind the already-planned workspace route to an instance.” 
GitHub

It can ripple into the exported instanceRouterMiddleware, which may be used outside the HttpApi group stack.

The context-extension version avoids all of that. WorkspaceRoutingMiddleware already declares requires: Session.Service, and the route function already requires HttpServerRequest; no new middleware requirements are needed. 
GitHub

Is there a hidden reason upstream chose header-over-session?

I do not see evidence of a deliberate “rebind existing sessions per request” design in the v1.15.0 code. The source points more toward an implementation gap:

Session.Info explicitly contains directory and optional workspaceID. 
GitHub

Session creation persists directory from InstanceState.context and workspaceID from the current workspace reference. 
GitHub

Workspace routing fetches the session, but passes only session?.workspaceID into planRequest. 
GitHub

The non-workspace local fallback then uses request header/query directory. 
GitHub

So the safest interpretation is: upstream solved workspace routing, but the non-workspace session-directory invariant was not carried into the new architecture.

A good upstream PR framing would be:

For existing session-scoped local routes, bind the request to the session’s stored directory. x-opencode-directory should select a directory for session creation/listing/non-session routes, not rebind an existing session’s execution context.

Does Session.Service.get(sessionID) work cross-instance?

Yes, for this use case. In v1.15.0, Session.get does a database select by SessionTable.id and returns fromRow(row); it does not filter by current instance directory and does not require InstanceState.context. 
GitHub

That is different from Session.create and Session.list, which do use InstanceState.context / project context. 
GitHub
+1

So the lookup in WorkspaceRoutingMiddleware is the right place to recover the session’s canonical directory.

URL shapes to cover

The existing shared helper is broad enough for the v1.15.0 session group:

TypeScript
/^\/session\/([^/]+)(?:\/|$)/

It excludes /session/status, and it catches nested paths such as:

/session/:sessionID
/session/:sessionID/message
/session/:sessionID/message/:messageID
/session/:sessionID/message/:messageID/part/:partID
/session/:sessionID/prompt_async
/session/:sessionID/command
/session/:sessionID/shell
/session/:sessionID/revert

The session group’s SessionPaths are all under /session/:sessionID/... for session-scoped operations; list/create/status are the notable non-session-ID routes. 
GitHub
+1

Still, before finalizing the patch, run:

Bash
git grep -n "sessionID" packages/opencode/src/server/routes/instance/httpapi/groups

If another group has a session-scoped route not under /session/:sessionID, add that shape to the shared helper rather than special-casing the middleware.

Should you make SessionRunState.runners global too?

Not for this patch.

A global runner map keyed by sessionID would be stronger defense-in-depth, but it is a broader semantic change:

It changes session concurrency at a lower layer.

It bypasses the architecture upstream just introduced.

It may create awkward interactions with workspaces, remote routing, tests, or disposal.

It is harder to upstream.

Normalize the directory before InstanceStore.provide first. That fixes the cause of this race while preserving upstream’s per-instance state model. InstanceState is explicitly keyed by current directory via ScopedCache.get(self.cache, yield* directory), so making the request bind to the right directory is the canonical fix. 
GitHub

If you later want defense in depth, add a narrow test around the busy guard and then consider a separate patch.

Test I would add

Add a middleware-level test if possible. It is cheaper and less flaky than reproducing Anthropic corruption.

Test shape:

Fake or real session row:

TypeScript
session.id = S
session.directory = "/A"
session.workspaceID = undefined

Request:

POST /session/S/prompt_async
x-opencode-directory: /B

Fake InstanceStore.provide records the directory it receives.

Assert:

TypeScript
directory === "/A"

Then add the complementary non-session route test:

POST /session
x-opencode-directory: /B

Assert it still binds /B, because session creation should still be controlled by request directory.

If you have time for an integration regression, use two concurrent prompt_async calls for the same session with different x-opencode-directory values and assert the second one hits the existing busy behavior instead of starting a parallel runner.

Direct answers

Best approach: patch workspace-routing.ts to carry session.directory, and patch instance-context.ts to prefer it. That is cleaner than a new wrapper or a duplicate lookup in InstanceContextMiddleware.

Hidden upstream reason? I do not see one in source. The code already treats sessions as having stored directory; the new middleware simply drops that field while preserving only workspaceID.

Other URL shapes? For v1.15.0’s session group, /session/:sessionID/... appears to cover the session-scoped routes. Verify with git grep across all HttpApi groups.

Effect gotchas: avoid adding Session.Service / HttpServerRequest to InstanceContextMiddleware if you use the context-extension patch. If you do the duplicate-lookup version, expect type/layer ripple, especially through instanceRouterMiddleware.

Global runner guard? Not as the first fix. Directory normalization is smaller, more upstreamable, and consistent with the new middleware architecture.

This should be a small patch, not a v1.15.0 rabbit hole: two files, one context field, one planRequest signature change, one directory = route.sessionDirectory ?? decode(route.directory) line, plus a regression test.