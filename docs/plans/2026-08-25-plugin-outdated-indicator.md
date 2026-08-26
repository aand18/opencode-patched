# Plugin outdated indicator + live version switching — Implementation Plan (patch #29)

**Spec:** `docs/plans/2026-08-25-plugin-outdated-indicator-design.md` (commit c7ee7b4db)
**Target:** opencode-src @ v1.18.21 (tag v1.18.21), web app only (v1 protocol).
**Convention:** implement in the dirty `opencode-src` working tree (NO commits there); cut
`patches/plugin-outdated-indicator.patch`; register in `apply.sh` + `README.md`.

## Context

The status popover Plugins tab lists enabled plugin specs as raw strings. Users cannot tell
which version is installed or whether a newer release exists. This patch adds, per plugin row:

1. **Installed version + commit** (from `node_modules/<name>/package.json` + `git rev-parse HEAD`).
2. **Outdated indicator:** red dot when a newer release exists (green otherwise).
3. **Clickable URL** (git → repo URL; npm → package page).
4. **Chevron dropdown** listing the 3 most recent versions; selecting one runs
   `git fetch + checkout <tag>` (git) or `npm i <name>@<version>` (npm) and refreshes the row.

No truncation, no TUI, v1 HTTP endpoints only, no core `npm.ts`/`config` changes.

### Key prior research (verified in code)

- `packages/opencode/src/server/routes/instance/httpapi/server.ts:141-171` — `instanceApiRoutes`
  does `Layer.provide([configHandlers, experimentalHandlers, ..., tuiHandlers, workspaceHandlers])`.
  We add `pluginHandlers` here.
- `server.ts:212-233` — `LayerNode.group([Npm.node, Config.node, ...])`. We add `PluginInfo.node`.
- Platform services (`ChildProcessSpawner`, `Global`, `httpClient`) are provided by
  `AppNodeBuilderV1.build(app)` — do NOT declare spawner in node deps (Git.node pattern: only
  `[AppProcess.node]`).
- `Config.node` deps: `[FSUtil.node, Auth.node, Account.node, Env.node, Npm.node, httpClient]`.
  `Config.Service`: `get`, `invalidate`. `Npm.sanitize(pkg)` is identity on Linux;
  `Npm.directory(pkg) = global.cache/packages/<sanitize(pkg)>`.
- `Git.node` = `makeGitNode({ service, layer, deps: [AppProcess.node] })` in
  `packages/core/src/git.ts`; layer does `yield* ChildProcessSpawner` (platform-injected).
- `packages/core/src/global.ts`: `Global.make(input)` exported; `Global.node`;
  `Interface = { state, config, cache, data, bin, log, repo }`.
- **ChildProcessSpawner (effect/unstable/process):**
  `spawner.string(ChildProcess.make("git", args, { extendEnv: true, stdin: "ignore" }))`
  returns `Effect<string, PlatformError>` — no spawn+Stream.mkString needed.
- **HttpClient (from config.ts pattern):**
  `HttpClient.filterStatusOk(http).execute(HttpClientRequest.get(url).pipe(HttpClientRequest.acceptJson))`
  → `response.text` is `Effect<string>`. Import `HttpClient` from `"effect/unstable/http"`.
- `packages/opencode/src/plugin/shared.ts`: `isPathPluginSpec(spec)` matches `file://`,
  `"."`, or `path.isAbsolute` — does **NOT** catch `~/`. `parsePluginSpecifier` for `git+ssh` etc.
- **Legacy SDK:** app talks to v1 servers through `OpencodeClient` from `@opencode-ai/sdk`
  (packages/sdk/js). `serverSDK().createClient({ directory, throwOnError: true })`.
  Regenerate with `./packages/sdk/js/script/build.ts` (runs `bun dev generate` in
  packages/opencode → openapi → @hey-api → `src/v2/gen/` + post-patch + tsc).
  NEVER hand-edit `src/v2/gen`.
- **App UI:** `packages/app/src/components/status-popover-body.tsx` — plugins tab renders
  lines ~498-505; `fail()` + `showToast` pattern at ~263-268; `props.shown()` accessor;
  `sync().directory`; imports `IconButton` from `@opencode-ai/ui/icon-button`,
  `DropdownMenu` from `@opencode-ai/ui/dropdown-menu`, `Spinner` from `@opencode-ai/ui/spinner`.
- **i18n:** flat keys, `packages/app/src/i18n/en.ts`; new keys added only to en.ts.
- **Effect idiom:** `yield* new UpdateError(...)` — yielding a failure Effect gives `never`;
  branch ends. No `return yield*`, no `Effect.fail`.
- **Patch format:** plain `git diff` (unified diff, git headers). New files need `git add -N`
  first. `apply.sh` uses `git apply --check` then `git apply`.

## Architecture (summary)

```
app (status-popover-body.tsx)
  │  GET /plugin           → PluginInfo.list()
  │  POST /plugin/update   → PluginInfo.update({spec, version})
  ▼
handlers/plugin.ts (thin Effect handlers; markInstanceForDisposal on failure)
  ▼
PluginInfo Service  (packages/opencode/src/plugin/info.ts)
  ├─ Config.Service   (get → plugin entries + invalidate)
  ├─ Global.Service   (cache dir for npm packages)
  ├─ ChildProcessSpawner (git ls-remote / rev-parse; npm install)
  ├─ HttpClient       (npm registry fetch)
  └─ Scope.Scope      (fork background refreshes)

groups/plugin.ts — PluginApi: GET /plugin (PluginList), POST /plugin/update (UpdateRequest)
api.ts — .addHttpApi(PluginApi)
server.ts — pluginHandlers in Layer.provide + PluginInfo.node in LayerNode.group
```

- **"Latest" semantics:** git → highest semver tag (prereleases excluded; fall back to raw
  newest tag if no stable); npm → `dist-tags.latest`. Prereleases never count as "latest"
  unless the only versions are prereleases.
- **`versions` / `all`** = up to 3 most recent release versions, **raw tag strings** for git
  (e.g. `v6.3.0`) because updateSpec must write `#v6.3.0`; npm = normalized version strings.
- **`latest`** = semver-normalized (e.g. `6.3.0`) for display + comparison.
- **SWR:** in-memory `Map<spec, {at: number, result: Item[]}>`. Fresh (TTL 60s) → blocking
  fetch. Stale → serve cached immediately + `Effect.forkIn(refresh, scope)`. No inflight map.
- **makeService(deps)** takes plain object deps (`config`, `global`, `spawner`, `http`,
  `scope`) so tests construct the service with fakes — no Effect layer plumbing in tests.

### Files

| File | Change |
|---|---|
| `packages/opencode/src/plugin/info.ts` | NEW — pure helpers + Service + layer + node |
| `packages/opencode/test/plugin/info.test.ts` | NEW — unit tests (no network) |
| `packages/opencode/src/server/routes/instance/httpapi/groups/plugin.ts` | NEW — PluginApi |
| `packages/opencode/src/server/routes/instance/httpapi/handlers/plugin.ts` | NEW — pluginHandlers |
| `packages/opencode/src/server/routes/instance/httpapi/api.ts` | +import, +.addHttpApi(PluginApi) |
| `packages/opencode/src/server/routes/instance/httpapi/server.ts` | +import pluginHandlers; +pluginHandlers in provide; +PluginInfo.node in group |
| `packages/sdk/js/src/v2/gen/**` | regenerated (never hand-edit) |
| `packages/app/src/i18n/en.ts` | +4 keys |
| `packages/app/src/components/status-popover-body.tsx` | imports + fetch/update logic + plugins tab render |
| `patches/plugin-outdated-indicator.patch` | NEW (patches repo) |
| `patches/apply.sh` | +1 PATCH_NAMES entry |
| `README.md` | +table row 29 |

## Task 1 — Pure helpers + types in `packages/opencode/src/plugin/info.ts`

No Effect in this section (keep it import-light and unit-testable without Effect runtime):

```ts
import { Npm } from "@opencode-ai/core/npm"
import { Global } from "@opencode-ai/core/global"
import { Config } from "../config/config"
import { isPathPluginSpec } from "./shared"
import * as semver from "@opencode-ai/core/semver"   // reuse core semver utils if present
```

> NOTE: before writing, check whether `@opencode-ai/core` already exports a semver helper
> (used by retry-cap / version logic). If not, implement minimal local `parseSemver` /
> `compareSemver` (major.minor.patch + prerelease ordering). Do NOT add a new dependency.

Types (exact — the API contract; app + handlers depend on these):

```ts
export type Kind = "git" | "npm" | "path"

export interface PluginInfo {
  spec: string
  name: string                      // parsed: git repo basename | npm name | path basename
  kind: Kind
  url: string | null                // git: remote URL; npm: package page; path: null
  installed: string | null          // version from node_modules/<name>/package.json
  commit: string | null             // git only: short HEAD in the package dir
  latest: string | null             // normalized latest (git: top stable tag; npm: dist-tag)
  outdated: boolean | null          // null when version/latest unknown; true only when outdated
  versions: string[]                // newest 3 raw (git tag / npm version) strings, desc
  updating: boolean                 // always false from server; app sets it locally during update
}
```

Pure helpers (exported for tests):

```ts
// spec -> { kind, name, url }
export function classify(spec: string): { kind: Kind; name: string; url: string | null }

// { kind, url, name, version } -> new spec string
export function updateSpec(kind: Kind, url: string | null, name: string, version: string): string

// git ls-remote --tags output -> { latest, versions, all }
export function parseTags(output: string): { latest: string | null; versions: string[]; all: string[] }

// npm registry JSON -> { latest, versions }
export function parseNpm(doc: any): { latest: string | null; versions: string[] }

// installed vs latest -> outdated (null when either missing)
export function isOutdated(installed: string | null, latest: string | null): boolean | null
```

Rules:

- `classify`:
  - `isPathPluginSpec(spec)` OR `spec.startsWith("~/")` → `{ kind: "path", name: basename, url: null }`
    (`~/` is NOT caught by `isPathPluginSpec` — explicit check required).
  - `git+ssh://…`, `git+https://…`, `https://…/*.git`, `ssh://git@…`, `github:user/repo`
    → `{ kind: "git", name: repoBasename(url), url }` (strip `.git`).
  - else → `{ kind: "npm", name: spec.split("@")[0] (or whole if no @), url: https://www.npmjs.com/package/<name> }`
    Handle `name@version` and scoped `@scope/name@version`.
- `updateSpec`:
  - git + `#tag` present in url → `url.replace(/#v?[\w.\-]+$/, "#" + (version.startsWith("v") ? version : "v" + version))`
    — write the **raw** version (already raw for git; for npm versions are numeric so `v`-prefixed
    only if the original tag was v-prefixed: keep it simple — store whether tags are v-prefixed
    in parseTags and pass through; implementation: `updateSpec` takes `version` in the same
    raw form it will be compared to, i.e. git versions from `versions[]` are raw tags, npm are numeric).
  - git without `#tag` → `${url}#${version}`.
  - npm → `${name}@${version}` (preserve scope).
- `parseTags`:
  - Lines: `<sha>\trefs/tags/<tag>`. Keep only tags whose name is semver-parseable
    (strip leading `v` for parsing, keep raw for output). Drop `^{}$` (annotated peel lines).
  - Sort by semver desc. `all` = all matching tags raw. `versions` = top 3 raw.
  - `latest` = top STABLE (no prerelease) tag, **normalized** (strip `v`). If no stable,
    top prerelease normalized. None → `null`.
- `parseNpm`:
  - `latest = doc["dist-tags"]?.latest ?? null` (already normalized).
  - `versions` = keys of `doc.versions` sorted semver desc, filtered to stable first;
    take 3; if <3 stable, top up with prereleases (stable desc, then prerelease desc).
- `isOutdated`: `installed == null || latest == null` → `null`; `semverGt(latest, installed)` → true else false.
  (Prerelease installed vs stable latest: stable > prerelease of same tuple.)

## Task 2 — Effect Service in `info.ts` (makeService + layer + node)

```ts
export class UpdateError extends Error {
  cause?: unknown
}

export interface Interface {
  readonly list: () => Effect.Effect<PluginInfo[], unknown>
  readonly update: (input: { spec: string; version: string }) => Effect.Effect<PluginInfo, UpdateError>
}

export const Service = ...   // Effect.Service("PluginInfo") pattern matching sibling services

type Deps = {
  config: Config.Interface
  global: Global.Interface
  spawner: ChildProcessSpawner["Service"]
  http: HttpClient.HttpClient
  scope: Scope.Scope
}

export function makeService(deps: Deps): Interface {
  // SWR cache (closure state)
  const cache = new Map<string, { at: number; result: PluginInfo[] }>()
  const TTL = 60_000

  const readInstalled = (name: string): Effect.Effect<{ version: string | null; commit: string | null }, never> => {
    // candidate dirs, in order:
    //   1) path plugins: the spec path itself
    //   2) npm-style: deps.global.cache/packages/<Npm.sanitize(spec)>/node_modules/<name>
    //   3) npm fallback: <same>/node_modules (root)
    // read package.json -> version; then spawner.string(git -C <dir> rev-parse --short HEAD)
    //   (ignore failure -> commit: null)
  }

  const fetchRemote = (spec: string, cls: ReturnType<typeof classify>):
    Effect.Effect<{ latest: string | null; versions: string[] }, unknown> => {
    if (cls.kind === "path") return Effect.succeed({ latest: null, versions: [] })
    if (cls.kind === "git")
      return deps.spawner
        .string(ChildProcess.make("git", ["ls-remote", "--tags", cls.url!], { extendEnv: true, stdin: "ignore" }))
        .pipe(Effect.map(parseTags), Effect.map(p => ({ latest: p.latest, versions: p.versions })))
    // npm
    return HttpClient.filterStatusOk(deps.http)
      .execute(HttpClientRequest.get(`https://registry.npmjs.org/${cls.name}`).pipe(HttpClientRequest.acceptJson))
      .pipe(Effect.map(resp => resp.text))
      .pipe(Effect.map(t => JSON.parse(t)))
      .pipe(Effect.map(parseNpm), Effect.map(p => ({ latest: p.latest, versions: p.versions })))
  }

  const one = (spec: string): Effect.Effect<PluginInfo, unknown> => {
    const cls = classify(spec)
    return Effect.all(
      [
        readInstalled(cls.name),        // { version, commit }
        fetchRemote(spec, cls),         // { latest, versions }
      ],
      { concurrency: "unlimited" },
    ).pipe(Effect.map(([inst, remote]) => ({
      spec, name: cls.name, kind: cls.kind, url: cls.url,
      installed: inst.version, commit: inst.commit,
      latest: remote.latest, versions: remote.versions,
      outdated: isOutdated(inst.version, remote.latest),
      updating: false,
    })))
  }

  return {
    list: () => {
      const cfg = deps.config.get().pipe(Effect.flatMap(() => Promise.resolve(null)))  // see note below
      // NOTE: Config.get() — verify exact API (sync getter vs Effect) in config.ts before writing.
      const specs = /* plugin specs from config (top-level + per-agent?), de-duped, in order */
      const fresh = () => Effect.all(specs.map(one), { concurrency: 8 }).pipe(Effect.map(result => { cache.set("all", { at: Date.now(), result }); return result }))
      const hit = cache.get("all")
      if (hit && Date.now() - hit.at < TTL) return Effect.succeed(hit.result)
      return fresh().pipe(
        Effect.catchAll(err => {  // stale-while-revalidate on failure too
          if (hit) return Effect.succeed(hit.result)
          return Effect.fail(err)
        }),
      )
    },
    update: ({ spec, version }) => {
      const cls = classify(spec)
      if (cls.kind === "path") return Effect.fail(new UpdateError("path plugins cannot be updated"))
      const newSpec = updateSpec(cls.kind, cls.url, cls.name, version)
      const run = cls.kind === "git"
        ? deps.spawner.string(
            ChildProcess.make("git", ["-C", installDir(cls), "fetch", "origin", version], { extendEnv: true, stdin: "ignore" }),
          ).pipe(
            Effect.andThen(deps.spawner.string(ChildProcess.make("git", ["-C", installDir(cls), "checkout", version], { extendEnv: true, stdin: "ignore" }))),
          )
        : deps.spawner.string(
            ChildProcess.make("npm", ["install", `--prefix`, <installRoot>, `${cls.name}@${version}`], { extendEnv: true, stdin: "ignore" }),
          )
      return run.pipe(
        Effect.andThen(Effect.suspend(() => { cache.delete("all"); return deps.config.invalidate() })),
        Effect.andThen(one(spec)),
        Effect.mapError(() => new UpdateError("update failed")),
      )
    },
  }
}
```

> **Verify before coding:** exact `Config.Interface` surface (is `get()` sync? is `invalidate()`
> an Effect?), how plugin specs are enumerated from config (see `config/plugin.ts` / lifecycle —
> reuse the SAME enumeration lifecycle uses so the list matches what actually loads), and how
> lifecycle installs packages (to mirror `installDir`). `readInstalled` dir resolution MUST match
> where lifecycle/npm.ts actually puts packages.
>
> **`list()` staleness on update:** update() deletes the cache entry, so the next list() refetches.

Layer + node (mirror `groups/config.ts` / `Git.node`):

```ts
export const layer = Layer.effect(Service, makeService({
  config: yield* Config.Service,
  global: yield* Global.Service,
  spawner: yield* ChildProcessSpawner,
  http: yield* HttpClient.HttpClient,
  scope: yield* Scope.Scope,
}).pipe(Effect.provideService(...)))   // or plain Layer.effect with the deps yielded inside

export const node = LayerNode.make({ service: Service, layer, deps: [Config.node, Global.node, httpClient] })
```

(`httpClient` imported from `@opencode-ai/core/effect/app-node-platform` — same as config.ts.)

## Task 3 — Tests `packages/opencode/test/plugin/info.test.ts`

Style: match existing tests in `packages/opencode/test/` (check runner: likely `bun test` or
Effect `runSync` helpers — look at a sibling test file first and copy its idioms).

**Pure helpers (no runtime):**
- `classify`: npm `foo@1.2.3`, scoped `@x/foo@1.0.0`, bare `foo`; git `https://github.com/a/b.git`,
  `git+ssh://git@github.com/a/b.git#v1.2.3`, `ssh://git@github.com/a/b.git`; path `./local`,
  `/abs/path`, `~/home/dir`, `file:///x/y`.
- `updateSpec`: git with `#tag` (replace), git without (append), npm, scoped npm.
- `parseTags`: mixed annotated `^{}` lines, v-prefixed, no-v, prereleases (`v1.0.0-rc.1`),
  non-semver tags (ignored), ordering, top-3 `versions`, `latest` stable preference + fallback.
- `parseNpm`: dist-tags.latest, versions ordering, prerelease top-up.
- `isOutdated`: (null, x)→null, (x, null)→null, (1.0.0, 1.0.1)→true, equal→false, prerelease cases.

**makeService with fakes:**
```ts
const fakeSpawner = (out: Record<string, string>) =>
  ({ string: (cp: any) => { const args = cp.command ?? cp._command; return Effect.succeed(out[args.join(" ")] ?? "") } }) as unknown as ChildProcessSpawner["Service"]
const fakeHttp = (json: unknown) =>
  (() => Effect.succeed({ headers: { "content-type": "application/json" }, text: Effect.succeed(JSON.stringify(json)) })) as unknown as HttpClient.HttpClient
const fakeConfig = (specs: string[]) => ({ get: () => /* whatever Config.Interface needs */, invalidate: () => Effect.sync(() => {}) }) as unknown as Config.Interface
```
- `list()`: path plugin (no network) returns kind path, latest null; git spec with fake
  `ls-remote` output → latest/outdated/versions correct; npm spec with fake registry JSON.
- SWR: second `list()` within TTL hits cache (fake spawner call count unchanged).
- `update()`: git → fake spawner receives fetch+checkout in order; config.invalidate called;
  returned item reflects new installed (readInstalled fake dir or second spawner output).
  npm → spawner receives `npm install name@ver`.
- Stale path (TTL expired): not waited for — document as code-review-verified (60s TTL too long
  to test); the branch is 4 lines and mirrors the catchAll shape.

## Task 4 — HTTP wiring (groups/plugin.ts, handlers/plugin.ts, api.ts, server.ts)

### `groups/plugin.ts` (NEW) — mirror `groups/config.ts` shape

```ts
import { HttpApi, HttpApiBuilder, HttpApiError, HttpApiGroup, HttpApiMiddleware, HttpApiVersionedSchema, openapi } from "@opencode-ai/server"
import { PluginInfo, UpdateError } from "../../../plugin/info"

export const PluginList = HttpApiVersionedSchema.Struct({ plugins: HttpApiVersionedSchema.Array(PluginInfo.Schema) })
export const PluginUpdateRequest = HttpApiVersionedSchema.Struct({ spec: HttpApiVersionedSchema.String, version: HttpApiVersionedSchema.String })
export const ApiPluginUpdateError = HttpApiError.init({
  type: "PluginUpdateError",
  ...
})  // copy the exact error-declaration idiom from an existing groups file (e.g. config.ts)

export const PluginApi = HttpApiGroup.init("plugin")
  .addHttpApi(
    HttpApiBuilder.group("plugin",
      HttpApiBuilder.get("/plugin", ...).annotateEffect(...).annotateOpenAPI({ operationId: "plugin.list", ... }),
      HttpApiBuilder.post("/plugin/update", ...).annotateEffect(...).annotateOpenAPI({ operationId: "plugin.update", ... }),
    ),
  )
```

> Mirror the EXACT annotate/annotateEffect/annotateOpenAPI structure of an existing simple
> group (config.ts GET /config is the closest analog). Response for GET is the wrapped
> `{ plugins: [...] }` object (per design doc), not a bare array.

### `handlers/plugin.ts` (NEW) — mirror `handlers/config.ts`

```ts
export const pluginHandlers = HttpApiBuilder.group("plugin", PluginApi, (handlers) =>
  Effect.gen(function* () {
    const plugin = yield* PluginInfo.Service
    return {
      list: () => Effect.succeed(new HttpApiBuilder.HttpResponse({ body: { plugins: yield* plugin.list() } })),
      update: (ctx) =>
        Effect.gen(function* () {
          try {
            const item = yield* plugin.update({ spec: ctx.payload.spec, version: ctx.payload.version })
            return new HttpApiBuilder.HttpResponse({ body: item })
          } catch (e) {
            if (e instanceof UpdateError) { markInstanceForDisposal(); return new HttpApiBuilder.HttpResponse({ error: ... }) }
            throw e
          }
        }),
    }
  }),
)
```

> Copy the exact handler-response/error idioms (including `markInstanceForDisposal` usage and
> how typed errors are returned) from `handlers/config.ts` — do not invent.

### `api.ts` — 2 lines

```ts
import { PluginApi } from "./groups/plugin"
// in the .addHttpApi(...) chain:
.addHttpApi(PluginApi)
```

### `server.ts` — 3 hunks

1. `import { pluginHandlers } from "./handlers/plugin"` (with the other handler imports).
2. `Layer.provide([configHandlers, experimentalHandlers, ..., tuiHandlers, workspaceHandlers, pluginHandlers])`.
3. In `LayerNode.group([...])` (~line 224): add `PluginInfo.node` (import from `../../../plugin/info`).

## Task 5 — Regenerate legacy SDK (`packages/sdk/js`)

Run: `./packages/sdk/js/script/build.ts` (workdir `opencode-src`, env as usual).
This runs `bun dev generate` in `packages/opencode` (dumps OpenAPI incl. new
`plugin.list` / `plugin.update` operations), then @hey-api/openapi-ts into `src/v2/gen/`,
post-patches, and typechecks. Result: new `src/v2/gen/sdk.gen.ts` methods
`client.plugin.list()` → `res.data?.plugins`, `client.plugin.update({ body: { spec, version } })`.

Verify: `bun run typecheck` in packages/sdk/js passes; grep `plugin` in `src/v2/gen/sdk.gen.ts`.

> The generated client is v1-protocol (OpencodeClient), which is what the app uses — the
> @opencode-ai/client v2 tarball is a separate thing and untouched.

## Task 6 — App UI (`status-popover-body.tsx` + `i18n/en.ts`)

### i18n (`en.ts`, after the status.popover.* block, ~line 772)

```ts
"status.popover.plugin.open": "Open",
"status.popover.plugin.selectVersion": "Switch version",
"status.popover.plugin.latest": "latest",
"status.popover.plugin.updateFailed": "Update failed",
```

### `status-popover-body.tsx`

**Imports:** `DropdownMenu` from `@opencode-ai/ui/dropdown-menu`, `Spinner` from
`@opencode-ai/ui/spinner`, `IconButton` from `@opencode-ai/ui/icon-button`.

**State + fetch** (near the other store declarations; gated like the existing fetch patterns):

```ts
const pluginInfo = useStore(() => createSignal<Map<string, PluginInfo>>(new Map()))
const updating = useStore(() => createSignal<Set<string>>(new Set()))

createEffect(on([props.shown, protocol], ([shown]) => {
  if (!shown || protocol.value !== "v1") return
  serverSDK().client.then(client =>
    client.plugin.list().then(res => pluginInfo.set(new Map((res.data?.plugins ?? []).map(p => [p.spec, p]))))
      .catch(() => {/* silent: rows fall back to plain spec */})),
  )
}))
```

**update function** (next to `fail()`):

```ts
const updatePlugin = async (spec: string, version: string) => {
  updating.set(prev => new Set(prev).add(spec))
  try {
    const res = await serverSDK().client.then(c => c.plugin.update({ body: { spec, version } }))
    const item = res.data
    if (item) pluginInfo.update(m => { m.set(spec, item); return new Map(m) })
  } catch {
    showToast({ variant: "error", title: t("status.popover.plugin.updateFailed"), description: spec })
  } finally {
    updating.set(prev => { const n = new Set(prev); n.delete(spec); return n })
  }
}
```

> Match the EXACT client-access idiom used in the same file (how other tabs get the client +
> handle errors) — `serverSDK().client` above is the expected shape; confirm against the file.

**Plugins tab render** (replace the ~lines 498-505 block that maps specs to plain rows):

```tsx
{specs.map(spec => {
  const info = pluginInfo.spec(spec)
  const busy = updating.spec().has(spec)
  return (
    <div key={spec} class="flex items-center gap-2 px-3 py-1.5 break-words">
      <span class={`size-2 shrink-0 rounded-full ${info?.outdated ? "bg-icon-critical-base" : "bg-icon-success-base"}`} />
      <span class="min-w-0 flex-1 text-sm break-words">{spec}</span>
      {info?.installed && (
        <span class="shrink-0 text-xs text-text-weak break-words">
          {info.installed}{info.commit ? ` @ ${info.commit}` : ""}
        </span>
      )}
      {info?.url && (
        <a href={info.url} target="_blank" rel="noreferrer" class="shrink-0 text-xs text-link hover:underline">
          {t("status.popover.plugin.open")}
        </a>
      )}
      {!!info?.versions?.length && (
        <DropdownMenu>
          <DropdownMenu.Trigger as={IconButton} icon="chevron-down" variant="ghost" disabled={busy} />
          <DropdownMenu.Content>
            {info.versions.map(v => (
              <DropdownMenu.Item key={v} onClick={() => updatePlugin(spec, v)} disabled={busy}>
                {v}{info.latest === normalize(v) ? `  ${t("status.popover.plugin.latest")}` : ""}
              </DropdownMenu.Item>
            ))}
          </DropdownMenu.Content>
        </DropdownMenu>
      )}
      {busy && <Spinner class="size-3 shrink-0" />}
    </div>
  )
})}
```

> Verify exact class tokens (`bg-icon-critical-base`, `bg-icon-success-base`, `text-text-weak`,
> `text-link`) exist in the app's design tokens — check the tokens file or an existing usage.
> DropdownMenu.Trigger props: confirm `as`, `icon`, `variant` against an existing usage in app.
> `normalize(v)` = strip leading `v` for comparison with `latest` (which is normalized).

## Task 7 — Build, verify, cut patch

1. `cd opencode-src && OPENCODE_VERSION=1.18.21 OPENCODE_CHANNEL=prod bun run --cwd packages/opencode build`
   (SDK build already ran in Task 5; app is built into the opencode bundle by this command.)
2. Run tests: `bun test test/plugin/info.test.ts` (workdir packages/opencode — confirm exact
   test command from package.json scripts).
3. Typecheck: `bun run typecheck` in packages/opencode (and packages/app if separate).
4. Smoke: install binary to scratch `XDG_*` dirs, start `opencode serve` on a free port,
   `curl /plugin` (expect `{plugins: []}` or current plugins), exercise POST /plugin/update
   against a scratch git plugin if feasible (optional; unit tests cover the logic).
5. **Cut the patch** (in `opencode-src`):
   ```
   git add -N packages/opencode/src/plugin/info.ts packages/opencode/test/plugin/info.test.ts \
     packages/opencode/src/server/routes/instance/httpapi/groups/plugin.ts \
     packages/opencode/src/server/routes/instance/httpapi/handlers/plugin.ts
   git diff -- packages/opencode packages/sdk/js packages/app > /home/dev/opencode-patched/patches/plugin-outdated-indicator.patch
   ```
   (Check the diff includes ONLY the intended files; sdk/js gen files + app files + info.ts etc.)
6. **Fresh-clone verification:** clean checkout of opencode @ v1.18.21 into /tmp →
   `cp patches plugin-outdated-indicator.patch` → `./apply.sh` → all 29 apply cleanly, build passes.
7. Patches repo: add `plugin-outdated-indicator` to `PATCH_NAMES` in `apply.sh` (position: after
   the entry that widens the popover — #28; check whether order matters: #29 touches
   status-popover-body.tsx which #28 also touches, so #29 MUST come AFTER #28 in apply order).
   Add README table row 29. Commit patches repo (NOT opencode-src).

## Risks / open items (resolve during Task 2/6 coding, note in patch header)

- Exact `Config.Interface` get/invalidate surface + plugin-spec enumeration source (must match lifecycle).
- Exact install dir layout for git vs npm plugins (mirror lifecycle install path).
- Design-token class names for dot colors / weak text / link (verify, don't guess).
- DropdownMenu.Trigger `as={IconButton}` prop shape (verify against existing usage).
- SDK build script network access (registry.npmjs.org) — production machine, should be fine.
- Prerelease `latest` fallback: spec says stable-preferred; keep behavior consistent between
  parseTags/parseNpm and isOutdated.
