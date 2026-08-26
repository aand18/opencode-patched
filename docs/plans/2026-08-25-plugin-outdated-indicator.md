# Plugin outdated indicator + live version switching — Implementation Plan (patch #29)

**Spec:** `docs/plans/2026-08-25-plugin-outdated-indicator-design.md` (commit c7ee7b4db)
**Target:** opencode-src @ v1.18.21 (detached tag), web app only (v1 protocol).
**Convention:** implement in the dirty `opencode-src` working tree (NO commits there); cut
`patches/plugin-outdated-indicator.patch`; register in `apply.sh` + `README.md`.

## Verified code facts (2026-08-25, re-checked while planning)

### Server (packages/opencode, packages/core)
- `Config.Interface` (src/config/config.ts:124-133): `get(): Effect<Info>` (an **Effect**, not
  sync), `invalidate(): Effect<void>`, `update(info)`, `updateGlobal(info)`. `Info` =
  ConfigV1.Info + `plugin_origins?: ConfigPlugin.Origin[]` (Origin = `{spec, source, scope}`).
  `plugin` is the merged, deduped, path-resolved spec list (path specs become `file://` URLs).
  **Do NOT** use `update`/`updateGlobal` for our rewrite: they deep-merge the whole merged Info
  into the target file (destructive for other files' plugins). Instead: surgical single-entry
  edit of the origin file (JSONC-preserving, via `jsonc-parser` `modify`/`applyEdits`, same deps
  config.ts already uses).
- `ConfigPlugin` (src/config/plugin.ts): `pluginSpecifier(spec)` unwraps `[spec, options]`
  tuples. Reuse for matching entries.
- Install layout (core/npm.ts): `directory(spec) = global.cache/packages/<Npm.sanitize(spec)>`
  (sanitize = identity on Linux; on win32 it replaces `<>:"|?*` with `_`). Package dir =
  `<directory>/node_modules/<name>` (name via npa), fallback `<directory>` itself.
  `Npm.add(spec)` short-circuits when `<directory>/node_modules/<name>` exists — so a version
  switch works by **changing the spec string** (new cache dir) + removing the old dir.
- Plugin enumeration: merged `info.plugin` from `Config.get()` — exactly what the app's
  Plugins tab shows today (`sync().data.config.plugin`).
- `semver` ^7.6.3 is an existing direct dep of packages/opencode (used in plugin/shared.ts).
  No new dependency. `npm-package-arg` (npa) also existing (used in shared.ts).
- Group idiom (groups/config.ts): `HttpApi.make("name").add(HttpApiGroup.make("name").add(
  HttpApiEndpoint.get("op", path, { query: WorkspaceRoutingQuery, success: described(Schema, "x") })
  .annotateMerge(OpenApi.annotations({ identifier: "name.op", summary, description })), ...))
  .middleware(InstanceContextMiddleware).middleware(WorkspaceRoutingMiddleware)
  .middleware(Authorization)`. `described` from `./metadata`.
- Error idiom (errors.ts): `Schema.TaggedErrorClass("XError", { message: Schema.String },
  { httpApiStatus: 400 })`. Reuse existing **`InvalidRequestError`** (400) — no new class.
- Handler idiom (handlers/config.ts): `HttpApiBuilder.group(InstanceHttpApi, "name",
  (handlers) => Effect.gen(function* () { const svc = yield* Svc; return
  handlers.handle("op", Effect.fn("NameHttpApi.op")(function* (ctx) {...})) }))`.
  Instance disposal: `yield* markInstanceForDisposal(yield* InstanceState.context)`.
- api.ts: `InstanceHttpApi = HttpApi.make("opencode-instance").addHttpApi(...)` chain.
- server.ts: `pluginHandlers` into the `Layer.provide([...])` handler list;
  `PluginInfo.node` into the `LayerNode.group([...])`.
- Node idiom: `LayerNode.make({ service, layer, deps: [...] })`; platform values (httpClient,
  filesystem) are listed in deps (see Config.node / Npm.node); ChildProcessSpawner + Scope
  come from the platform/runtime (Git.node pattern).
- Module shape (packages/opencode AGENTS.md): flat exports + `export * as PluginInfo from
  "./info"`; `Effect.fn("Domain.method")`; `yield* new MyError(...)` for early failure;
  prefer `FileSystem.FileSystem`, `ChildProcessSpawner`, `HttpClient` services;
  no `else`, no import aliases, no star imports, avoid destructuring.
- `ChildProcessSpawner`: `spawner.string(ChildProcess.make("git", args,
  { extendEnv: true, stdin: "ignore" }))` → `Effect<string, PlatformError>`.
  Import from `effect/unstable/process`.
- HttpClient: `HttpClient.filterStatusOk(http).execute(HttpClientRequest.get(url).pipe(
  HttpClientRequest.acceptJson))` → `response.text` is `Effect<string>` (config.ts:193-202).
  Import from `effect/unstable/http`.
- Effect v4 beta: no `Effect.fork` — use `Effect.forkIn(scope)`.

### App (packages/app) — legacy v1 client
- App consumes v1 servers through the **legacy** `OpencodeClient` (`@opencode-ai/sdk/v2/client`,
  source packages/sdk/js, generated `src/v2/gen/`). `createSdkForServer` (utils/server.ts:21)
  wraps `createOpencodeClient`. `useSync()` → `sync().client` = legacy client bound to the
  directory (throwOnError); `sync().protocol` = "v1"|"v2" memo. Response shape:
  `promise resolves { data, error, response }` → read `.data` (server-sync.tsx:245 pattern).
- Regenerate: `./packages/sdk/js/script/build.ts` from repo root (runs `bun dev generate` in
  packages/opencode → OpenAPI dump → @hey-api → `src/v2/gen/` + post-patch + tsc).
  NEVER hand-edit `src/v2/gen`. (Design doc's "packages/client bun run generate" refers to the
  v2 client — not what the app uses for v1; sdk/js is the one that matters here.)
- Plugins tab is already v1-gated: `<Show when={protocol() === "v1"}>` wraps
  `Tabs.Content value="plugins"` (status-popover-body.tsx:490-510).
- Row today (lines 498-503): `<div class="flex items-center gap-2 w-full px-2 py-1">
  <div class="size-1.5 rounded-full shrink-0 bg-icon-success-base" />
  <span class="text-14-regular text-text-base truncate">{plugin}</span></div>`.
- DropdownMenu (Kobalte-based, @opencode-ai/ui/dropdown-menu):
  `<DropdownMenu gutter={4} placement="bottom-end"><DropdownMenu.Trigger as={IconButton}
  icon="chevron-down" variant="ghost" size="small" /><DropdownMenu.Portal>
  <DropdownMenu.Content><DropdownMenu.RadioGroup value={cur}><For each={versions}>
  <DropdownMenu.RadioItem value={v} closeOnSelect onSelect={...}>
  <DropdownMenu.ItemLabel>{v}</DropdownMenu.ItemLabel>
  <DropdownMenu.ItemIndicator>check icon</DropdownMenu.ItemIndicator></DropdownMenu.RadioItem>
  </For></DropdownMenu.RadioGroup></DropdownMenu.Content></DropdownMenu.Portal></DropdownMenu>`.
  Existing examples: file-tabs.tsx:42, prompt-project-selector.tsx:510.
- Spinner: `import { Spinner } from "@opencode-ai/ui/spinner"`; `<Spinner class="size-4" />`.
- Toast: `showToast({ variant: "error", title, description })` (component already has
  `fail(err)` helper using `language.t("common.requestFailed")`).
- App AGENTS: `createStore` over multiple `createSignal`; ALL visible copy via i18n keys
  (`language.t`); i18n keys flat in packages/app/src/i18n/en.ts (status.popover.* block ends
  line 772); new keys in en.ts only (fallback covers other locales).
- Generated type import: `import type { PluginInfo } from "@opencode-ai/sdk/v2/types"`
  (exports map: `"./v2/types": "./src/v2/gen/types.gen.ts"`).

## Wire contract (frozen)

`GET /plugin` → `{ plugins: PluginInfo[] }` (config order).
`POST /plugin/update` body `{ spec: string, version: string }` → updated `PluginInfo`;
errors → 400 `InvalidRequestError { message }`.

```ts
type PluginInfo = {
  spec: string
  kind: "git" | "npm" | "path"
  name: string
  url?: string            // git: repo homepage (strip git+, .git); npm: npmjs page; path: absent
  installed?: string      // version from cache-dir package.json (or path plugin's)
  commit?: string         // git only: short HEAD of the installed copy
  latest?: string         // git: newest stable tag normalized; npm: dist-tags.latest
  outdated?: boolean      // true only when installed < latest; absent when unknown
  versions: string[]      // top 10 raw versions (git: raw tags; npm: version strings), desc
}
```

Semantics:
- **latest** = newest STABLE semver (prereleases excluded unless only prereleases exist);
  normalized (strip leading `v`). git: from `git ls-remote --tags`; npm: `dist-tags.latest`.
- **versions** = top 10 desc, stable-first (git: raw tag strings — `updateSpec` must write
  them back verbatim; npm: numeric version strings).
- **outdated** = `semver.gt(latest, installed)`; absent when either is missing/unparseable.
- **name** = installed package.json `name` when readable, else parsed (npa) name.
- SWR: in-memory Map keyed by spec, TTL **15 min**. Fresh → return. Stale → return stale +
  background refresh (forkIn scope). Miss → blocking fetch with **10 s** per-spec timeout;
  per-spec remote failure → that spec returns with `latest`/`outdated` absent + empty
  versions, installed still read from disk. List never fails as a whole.

## Files

| File | Change |
|---|---|
| `packages/opencode/src/plugin/info.ts` | NEW — pure helpers + Service + layer + node |
| `packages/opencode/test/plugin/info.test.ts` | NEW — unit tests (no network) |
| `packages/opencode/src/server/routes/instance/httpapi/groups/plugin.ts` | NEW — PluginApi |
| `packages/opencode/src/server/routes/instance/httpapi/handlers/plugin.ts` | NEW — pluginHandlers |
| `packages/opencode/src/server/routes/instance/httpapi/api.ts` | +import, +.addHttpApi(PluginApi) |
| `packages/opencode/src/server/routes/instance/httpapi/server.ts` | +import, +handler, +node |
| `packages/sdk/js/src/v2/gen/**` | regenerated via build script |
| `packages/app/src/i18n/en.ts` | +4 keys |
| `packages/app/src/components/status-popover-body.tsx` | fetch/update logic + row render |
| `patches/plugin-outdated-indicator.patch` | NEW (patches repo) |
| `patches/apply.sh` | +PATCH_NAMES entry (after status-popover-widen) |
| `README.md` | +table row 29 |

## Task 1 — `packages/opencode/src/plugin/info.ts`

Imports: `path`, `fileURLToPath`, `npa` (npm-package-arg), `semver`, `effect` (Effect,
Schema, Context, Layer, Scope), `effect/unstable/process` (ChildProcess, ChildProcessSpawner),
`effect/unstable/http` (HttpClient, HttpClientRequest), `@opencode-ai/core/npm` (Npm),
`@opencode-ai/core/global` (Global), `@opencode-ai/core/effect/app-node` (LayerNode),
`@opencode-ai/core/effect/app-node-platform` (httpClient, filesystem), `FileSystem` from
effect, `Config` from `@/config/config`, `ConfigPlugin` from `@/config/plugin`,
`isPathPluginSpec` from `./shared`, `jsonc-parser` (modify, applyEdits — check exact import
path used by config/config.ts and match).

### Pure helpers (sync, exported, unit-tested)

```ts
export type PluginKind = "git" | "npm" | "path"
export type PluginClass = { kind: PluginKind; name: string; url: string | null; committish: string | null }
export type PluginRemote = { latest: string | null; versions: string[] }

classify(spec): PluginClass
  - isPathPluginSpec(spec) || spec.startsWith("~/") → path (name = basename of resolved path)
  - npa(spec) (wrap in try/catch; fallback npm with name = spec):
      inner = hit.type === "alias" && hit.subSpec ? hit.subSpec : hit
      inner.type === "git" → git:
        url = inner.git.raw with leading "git+" stripped, "#fragment" stripped
        committish = fragment (or null)
        name = hit.name ?? inner.name ?? basename(url)
        url = strip trailing ".git" (homepage)
      else → npm: name = hit.name ?? spec (scoped handled by npa);
        url = `https://www.npmjs.com/package/${name}`
updateSpec(spec, version): string
  - git: (spec up to last "#") + "#" + version   (version is a RAW tag from versions[])
  - npm: `${name}@${version}`
  - path: spec (caller rejects path updates)
parseTags(lsRemoteOutput): PluginRemote | null   (null when no semver tags)
  - lines `<sha>\trefs/tags/<tag>`; drop `^{}` peel lines; unique tags
  - keep tags with semver.parse(tag) != null
  - sort desc (stable first, then prerelease — comparator: rcompare within stables, then prereleases)
  - versions = top 10 raw; latest = semver.clean(topStable ?? topAny)
parseNpmRegistry(doc): PluginRemote | null
  - latest = doc["dist-tags"]?.latest ?? null
  - versions = Object.keys(doc.versions) with semver.parse ok, same sort, top 10
isOutdated(installed, latest): boolean | null
  - null if either null/unparseable; else semver.gt(latest, installed)
```

### Effect service

```ts
export class PluginUpdateError extends Error {}   // plain domain error (no schema)
export interface Interface {
  readonly list: () => Effect.Effect<PluginInfoItem[]>
  readonly update: (input: { spec: string; version: string }) => Effect.Effect<PluginInfoItem, PluginUpdateError>
}
export class Service extends Context.Service<Service, Interface>()("@opencode/PluginInfo") {}
export const use = serviceUse(Service)   // if the helper exists (check siblings); optional

type Deps = { config; global; fs: FileSystem.FileSystem; spawner; http; scope }
export function makeService(deps: Deps): Interface {
  const cache = new Map<string, { at: number; result: PluginInfoItem }>()
  const TTL = 15 * 60 * 1000

  readInstalled(spec, cls) → { name?, installed?, commit? }
    - candidates:
        path: fileURLToPath(spec) if file:// else spec; try <dir>/package.json, <dir>/../package.json? NO —
          exactly: <path>/package.json if dir, else dirname(<path>)/package.json (spec may be a file)
        git/npm: base = path.join(deps.global.cache, "packages", Npm.sanitize(spec))
          try base/node_modules/<name>/package.json, then base/package.json
      (fs.exists/with fs.readJson via Effect, catch → fields absent)
    - commit (git only): spawner.string(git -C <pkgdir> rev-parse --short HEAD), catch → absent
  fetchRemote(spec, cls) → PluginRemote | { latest: null, versions: [] }
    - path → { latest: null, versions: [] }
    - git → spawner.string(git ls-remote --tags <cls.url>) → parseTags; catch → null-remote
    - npm → filterStatusOk(http).execute(GET https://registry.npmjs.org/<name> acceptJson)
            → response.text → JSON.parse → parseNpmRegistry; catch → null-remote
    - whole thing wrapped: Effect.timeout({ duration: 10_000, failWith: ... }) then catch → null-remote
  one(spec) → Effect.all([readInstalled, fetchRemote], { concurrency: "unlimited" })
    → PluginInfoItem (SWR: miss → store; stale → return + forkIn refresh in deps.scope)

  list: () => config.get() → specs = (info.plugin ?? []).map(ConfigPlugin.pluginSpecifier)
        → Effect.all(specs.map(one), { concurrency: 8 })   (per-spec remote failures already
        contained inside one(); readInstalled never fails)
  update: ({ spec, version }) =>
        info = config.get()
        origin = (info.plugin_origins ?? []).find(o => ConfigPlugin.pluginSpecifier(o.spec) === spec)
          → else yield* new PluginUpdateError(`plugin ${spec} not found in config`)
        cls = classify(spec); if path → yield* new PluginUpdateError("path plugins cannot be updated")
        remote = yield* fetchRemote(spec, cls)   (unwrapped; failure here → PluginUpdateError
          "could not determine available versions")
        if (!remote?.versions.includes(version)) yield* new PluginUpdateError(
          `version ${version} not available for ${spec}`)
        newSpec = updateSpec(spec, version)
        if (newSpec === spec) return (yield* one(spec))
        rewritePluginEntry(origin.source, spec, newSpec)   (below; failure → PluginUpdateError)
        remove old cache dir: fs.remove(path.join(global.cache, "packages", Npm.sanitize(spec)),
          { recursive: true })  (ENOENT ok; other errors → PluginUpdateError)
        cache.clear()
        return (yield* one(newSpec))
}

rewritePluginEntry(file, oldSpec, newSpec): Effect<void, PluginUpdateError>
  - read file string (fs)
  - jsonc-parser: parseTree → find property "plugin" (array) → for each index i, entry =
    parse(text) array value (use JSON.parse fallback? use jsonc-parser `getNodeValue`);
    if ConfigPlugin.pluginSpecifier(entry) === oldSpec →
      modify(text, ["plugin", i, entryIsArray ? 0 : undefined]... careful with jsonc-parser
      modify paths for arrays) → replace string or tuple[0]; applyEdits
  - write back with fs.writeFileString
  - simpler robust variant: locate the `"plugin"` array with parseTree, then use
    `modify(document, ["plugin", i], newValue, { formattingOptions: { insertSpaces: true, tabSize: 2 } })`
    where newValue = entryIsArray ? [newSpec, ...rest] : newSpec — replaces the whole entry
    node (still single-entry surgical, tuple options preserved).
```

Layer + node:

```ts
export const layer = Layer.effect(Service, Effect.gen(function* () {
  const config = yield* Config.Service
  const global = yield* Global.Service
  const fs = yield* FileSystem.FileSystem
  const spawner = yield* ChildProcessSpawner
  const http = yield* HttpClient.HttpClient
  const scope = yield* Scope.Scope
  return makeService({ config, global, fs, spawner, http, scope })
}))
export const node = LayerNode.make({ service: Service, layer, deps: [Config.node, Global.node, httpClient, filesystem] })
export * as PluginInfo from "./info"
```

## Task 2 — `packages/opencode/test/plugin/info.test.ts`

Runner/style: match siblings in test/plugin/ (check meta.test.ts first — bun test vs effect
test). No network, no real git.

- `classify`: `foo@1.2.3`, `@scope/foo@1.0.0`, bare `foo`, `./local/plugin.ts`, `/abs/path`,
  `~/home/x.ts`, `file:///x/y`, `https://github.com/a/b.git`,
  `superpowers@git+https://github.com/obra/superpowers.git`,
  `git+ssh://git@github.com/a/b.git#v1.2.3` (committish extracted), `ssh://git@github.com/a/b.git`.
- `updateSpec`: git append `#tag`, git replace existing `#old`, npm `name@ver`, scoped npm.
- `parseTags`: annotated `^{}` duplicates, v-prefixed + bare tags, prerelease ordering
  (`1.0.0-rc.1` < `1.0.0`), non-semver tags ignored, top-10 cap, latest = stable preferred,
  latest falls back to prerelease when no stable, empty output → null.
- `parseNpmRegistry`: dist-tags.latest, versions cap 10, stable-first ordering, missing
  versions → null.
- `isOutdated`: (null, x) → null, (x, null) → null, equal → false, gt → true, lt → false,
  unparseable installed → null.
- `makeService` with fakes (this is why deps are injectable):
  - fake spawner: `{ string: () => Effect.succeed(fakeLsRemote) }` cast to
    `ChildProcessSpawner["Service"]`; per-call script if needed.
  - fake http: `() => Effect.succeed({ headers: {}, text: Effect.succeed(registryJson) })`
    cast to `HttpClient.HttpClient`.
  - fake config: `{ get: () => Effect.succeed({ plugin: [...], plugin_origins: [...] }) }`
    cast to `Config.Interface`; `invalidate: () => Effect.void`.
  - fake global: `Global.make({ ... })` if easy, else plain object `{ cache: tmpdir }`.
  - tmpdir fixture for package.json (Bun.file / fs in test setup, or `fs.mkdtemp`).
  - `list()`: path spec (no network) → kind path, versions []; git spec with fake
    ls-remote → latest/outdated/versions; npm spec with fake registry JSON; second `list()`
    within TTL → cache hit (spawner not re-called — count calls).
  - `update()`: unknown spec → PluginUpdateError; version not in list → PluginUpdateError;
    git happy path → origin file rewritten (assert file content contains `#v6.3.0`, tuple
    options preserved), old cache dir removed, config.get reflects new spec (fake), returned
    item.spec === newSpec; path spec → PluginUpdateError.

## Task 3 — HTTP wiring

### `groups/plugin.ts` (mirror groups/config.ts exactly)

```ts
import { Schema } from "effect"
import { HttpApi, HttpApiEndpoint, HttpApiError, HttpApiGroup, OpenApi } from "effect/unstable/httpapi"
import { InvalidRequestError } from "../errors"
import { Authorization } from "../middleware/authorization"
import { InstanceContextMiddleware } from "../middleware/instance-context"
import { WorkspaceRoutingMiddleware, WorkspaceRoutingQuery } from "../middleware/workspace-routing"
import { described } from "./metadata"

const root = "/plugin"
const PluginInfo = Schema.Struct({ spec: Schema.String, kind: Schema.Union(Schema.Literal("git"), Schema.Literal("npm"), Schema.Literal("path")), name: Schema.String, url: Schema.optional(Schema.String), installed: Schema.optional(Schema.String), commit: Schema.optional(Schema.String), latest: Schema.optional(Schema.String), outdated: Schema.optional(Schema.Boolean), versions: Schema.Array(Schema.String) }).annotate({ identifier: "PluginInfo" })
export const PluginApi = HttpApi.make("plugin")
  .add(
    HttpApiGroup.make("plugin")
      .add(
        HttpApiEndpoint.get("list", root, { query: WorkspaceRoutingQuery, success: described(Schema.Struct({ plugins: Schema.Array(PluginInfo) }), "List plugins") })
          .annotateMerge(OpenApi.annotations({ identifier: "plugin.list", summary: "List plugins", description: "..." })),
        HttpApiEndpoint.post("update", `${root}/update`, { query: WorkspaceRoutingQuery, payload: Schema.Struct({ spec: Schema.String, version: Schema.String }), success: described(PluginInfo, "Updated plugin"), error: [HttpApiError.BadRequest, InvalidRequestError] })
          .annotateMerge(OpenApi.annotations({ identifier: "plugin.update", summary: "Update plugin version", description: "..." })),
      )
      .annotateMerge(OpenApi.annotations({ title: "plugin", description: "Plugin version info and switching." }))
      .middleware(InstanceContextMiddleware)
      .middleware(WorkspaceRoutingMiddleware)
      .middleware(Authorization),
  )
  .annotateMerge(OpenApi.annotations({ title: "opencode experimental HttpApi", version: "0.0.1", description: "Experimental HttpApi surface for selected instance routes." }))
```
(Adjust annotate/title wording to what other groups use — copy verbatim from config.ts.)

### `handlers/plugin.ts` (mirror handlers/config.ts)

```ts
import { PluginInfo } from "@/plugin/info"
import * as InstanceState from "@/effect/instance-state"
import { Effect } from "effect"
import { HttpApiBuilder } from "effect/unstable/httpapi"
import { InstanceHttpApi } from "../api"
import { InvalidRequestError } from "../errors"
import { markInstanceForDisposal } from "../lifecycle"

export const pluginHandlers = HttpApiBuilder.group(InstanceHttpApi, "plugin", (handlers) =>
  Effect.gen(function* () {
    const plugin = yield* PluginInfo.Service
    const list = Effect.fn("PluginHttpApi.list")(function* () {
      return { plugins: yield* plugin.list() }
    })
    const update = Effect.fn("PluginHttpApi.update")(function* (ctx) {
      const result = yield* plugin.update(ctx.payload).pipe(Effect.either)
      if (result._tag === "Left") {
        return yield* new InvalidRequestError({ message: result.left.message })
      }
      yield* markInstanceForDisposal(yield* InstanceState.context)
      return result.right
    })
    return handlers.handle("list", list).handle("update", update)
  }),
)
```

### `api.ts` — `import { PluginApi } from "./groups/plugin"` + `.addHttpApi(PluginApi)` in the
InstanceHttpApi chain (alphabetical position: after PtyApi/QuestionApi... follow existing order —
insert at the spot that keeps the chain tidy, e.g. after `PermissionApi`).

### `server.ts` — 3 hunks: import pluginHandlers (with handler imports); add `pluginHandlers`
to the `Layer.provide([...])` array; add `PluginInfo.node` (import from `../../../plugin/info`)
to the `LayerNode.group([...])` array.

## Task 4 — Regenerate legacy SDK

`cd packages/sdk/js && bun run ./script/build.ts` (or `./packages/sdk/js/script/build.ts`
from repo root — check script's expected cwd first; it shells out to `bun dev generate` in
packages/opencode, then @hey-api gen + post-patch + tsc).
Verify: `packages/sdk/js/src/v2/gen/sdk.gen.ts` gains a `Plugin` resource class with
`list()` (GET /plugin) and `update(parameters)` (POST /plugin/update); `types.gen.ts`
gains `PluginInfo`; typecheck passes in packages/sdk/js.

## Task 5 — App UI

### `i18n/en.ts` (append after line 772, in the status.popover block):

```ts
"status.popover.plugin.updateFailed": "Update failed",
"status.popover.plugin.selectVersion": "Select version",
"status.popover.plugin.latest": "Latest",
"status.popover.plugin.open": "Open",
```
(Air labels: selectVersion for the trigger; latest for the newest marker; updateFailed for
the toast title; open for the link aria-label. Adjust naming if a sibling key fits better —
e.g. reuse existing "common.*" where exact.)

### `status-popover-body.tsx`

Imports: `DropdownMenu` from `@opencode-ai/ui/dropdown-menu`, `IconButton` from
`@opencode-ai/ui/icon-button`, `Spinner` from `@opencode-ai/ui/spinner`,
`type PluginInfo as PluginInfoItem` from `@opencode-ai/sdk/v2/types` (verify exact export
name in types.gen.ts after regen; alias if it collides — but AGENTS bans import aliases...
the ban is for internal imports; for type collision use the exported name as-is and rename
our local usage if needed — check the generated name first).

State (single store, app AGENTS):

```ts
const [pluginState, setPluginState] = createStore<{
  info: Record<string, PluginInfoItem>
  pending: Record<string, boolean>
}>({ info: {}, pending: {} })
```

Fetch (v1-gated, on popover show):

```ts
createEffect(
  on(
    () => props.shown(),
    (shown) => {
      if (!shown) return
      if (sync().protocol !== "v1") return
      let dead = false
      void sync().client
        .plugin.list()
        .then((res) => {
          if (dead) return
          setPluginState("info", Object.fromEntries((res.data?.plugins ?? []).map((p) => [p.spec, p])))
        })
        .catch(() => {})   // silent: rows fall back to plain spec
      onCleanup(() => { dead = true })
    },
  ),
)
```

Update:

```ts
const updatePlugin = (spec: string, version: string) => {
  setPluginState("pending", spec, true)
  void sync().client
    .plugin.update({ spec, version })
    .then(() => {
      const res = /* refetch */
      return sync().client.plugin.list().then((r) => {
        setPluginState("info", Object.fromEntries((r.data?.plugins ?? []).map((p) => [p.spec, p])))
      })
    })
    .catch((err) => {
      showToast({ variant: "error", title: language.t("status.popover.plugin.updateFailed"), description: err instanceof Error ? err.message : String(err) })
    })
    .finally(() => setPluginState("pending", spec, false))
}
```

Row render (replace the `For each={plugins()}` block, lines 498-503):

```tsx
<For each={plugins()}>
  {(plugin) => {
    const info = () => pluginState.info[plugin]
    const pending = () => pluginState.pending[plugin]
    const outdated = () => info()?.outdated === true
    const url = () => info()?.url
    const installed = () => info()?.installed
    return (
      <div class="flex items-start gap-2 w-full px-2 py-1">
        <div class={`size-1.5 rounded-full shrink-0 mt-[7px] ${outdated() ? "bg-icon-critical-base" : "bg-icon-success-base"}`} />
        <span class="text-14-regular text-text-base min-w-0 flex-1 break-words">
          {url() ? (
            <a href={url()!} target="_blank" rel="noopener noreferrer" class="hover:underline" aria-label={language.t("status.popover.plugin.open")}>
              {plugin}
            </a>
          ) : (
            plugin
          )}
        </span>
        <Show when={installed() && !!info()?.versions?.length} fallback={<Show when={installed()}><span class="text-12-regular text-text-weak shrink-0">{installed()}</span></Show>}>
          <div class="flex items-center gap-1 shrink-0" onMouseDown={(e) => e.stopPropagation()} onClick={(e) => e.stopPropagation()}>
            <span class="text-12-regular text-text-weak">{installed()}</span>
            <DropdownMenu gutter={4} placement="bottom-end">
              <DropdownMenu.Trigger as={IconButton} icon="chevron-down" variant="ghost" size="small" class="size-6 rounded-md" aria-label={language.t("status.popover.plugin.selectVersion")}>
              </DropdownMenu.Trigger>
              <DropdownMenu.Portal>
                <DropdownMenu.Content>
                  <DropdownMenu.RadioGroup value={installed()!}>
                    <For each={info()!.versions}>
                      {(version) => (
                        <DropdownMenu.RadioItem value={version} closeOnSelect disabled={pending()} onSelect={() => updatePlugin(plugin, version)}>
                          <DropdownMenu.ItemLabel class="min-w-0 truncate">{version}</DropdownMenu.ItemLabel>
                          {version === info()!.latest && <span class="text-11-regular text-text-weak">{language.t("status.popover.plugin.latest")}</span>}
                          <DropdownMenu.ItemIndicator class="size-3.5 text-icon-success-base" />
                        </DropdownMenu.RadioItem>
                      )}
                    </For>
                  </DropdownMenu.RadioGroup>
                </DropdownMenu.Content>
              </DropdownMenu.Portal>
            </DropdownMenu>
            <Show when={pending()}><Spinner class="size-3" /></Show>
          </div>
        </Show>
      </div>
    )
  }}
</For>
```

> Verify before writing: `text-12-regular`/`text-11-regular` token existence (match existing
> usage in the file — it uses `text-14-regular`, `text-12-regular` for tab labels);
> `DropdownMenu.ItemIndicator` default render vs the check-icon pattern from
> prompt-project-selector (copy whatever renders the selection checkmark); IconButton inside
> Trigger needs `aria-label` (copied from file-tabs pattern); RadioItem `value` must be a
> string (versions are raw tags — current installed may be v-prefixed raw tag while RadioItem
> value matches versions[] raw; installed from package.json is normalized → preselect may not
> match; acceptable: use `value={installed()!}` and let Kobalte just not preselect when
> normalized ≠ raw tag — verify live, adjust by matching via `semver`-clean comparison if
> needed, e.g. pass a normalized map. Keep simple: preselect by raw string equality, accept
> no-preselect for v-prefixed git plugins, verify live.)

## Task 6 — Build, verify, cut patch

1. Typecheck: `bun typecheck` from packages/opencode and packages/app (and packages/sdk/js
   via its build script).
2. Tests: from packages/opencode: `bun test test/plugin/info.test.ts` (verify exact test
   command in package.json; NEVER from repo root).
3. Build: `OPENCODE_VERSION=1.18.21 OPENCODE_CHANNEL=prod bun run --cwd packages/opencode build`.
4. Smoke (scratch XDG dirs, free port ~4097): `GET /plugin` (empty or current plugins, no
   crash), `POST /plugin/update` with a bad version → 400 JSON error. Full git-update smoke
   optional (unit tests cover logic; live UI check is step 5).
5. **Live UI verify BEFORE cutting** (house workflow, design doc): running patched instance,
   devtools/agent-browser — row layout at 600px, dot color, clickable URL, dropdown
   open/select/pending, error toast on bad update.
6. Cut patch (in opencode-src):
   `git add -N` the 4 new files, then
   `git diff -- packages/opencode packages/sdk/js packages/app > /home/dev/opencode-patched/patches/plugin-outdated-indicator.patch`
   (verify diff contains only intended paths).
7. Patches repo: `apply.sh` PATCH_NAMES += `plugin-outdated-indicator` AFTER
   `status-popover-widen` (both touch status-popover-body.tsx; #28's hunk must apply first);
   README.md table row 29. Commit patches repo only.
8. Fresh-clone verify: clean opencode @ v1.18.21 in /tmp → copy patches → `./apply.sh` →
   29/29 apply, build passes.

## Open items (resolve while coding, note outcomes in the patch header comment)

- Exact jsonc-parser import path/style used by config/config.ts (`modify`, `applyEdits`).
- Whether `serviceUse` helper exists for PluginInfo (`use` export) — optional, skip if not.
- Generated type name for PluginInfo in types.gen.ts (probably `PluginInfo` or
  `Plugininfo`... check; if it collides with anything in the app, the SDK export wins and
  the app imports it as-is).
- RadioItem preselect semantics with v-prefixed git tags (verify live).
- `DropdownMenu.ItemIndicator` content (default check icon? copy prompt-project-selector).
- Scope of `plugin_origins` presence: if a spec somehow lacks an origin entry, update()
  fails with "not found in config" (acceptable; list() still shows it).
