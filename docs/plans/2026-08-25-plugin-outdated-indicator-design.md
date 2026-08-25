# Plugin outdated indicator + version switching — design

Date: 2026-08-25
Status: approved (approach A)
Target: opencode v1.18.21, becomes patch #29 `plugin-outdated-indicator.patch`

## Problem

The status popover Plugins tab renders raw specifiers with a static dot
(`status-popover-body.tsx:498-504`). There is no visibility into which version of a
plugin is installed, whether a newer version exists, or any way to switch versions
from the UI. Concretely: superpowers installed 6.1.1 while upstream is at v6.3.0.

The server exposes no plugin version information over HTTP today: `GET /config`
carries only raw spec strings, and `Npm.add` short-circuits when the plugin is
already installed in the cache (`packages/core/src/npm.ts:125-127`), so a version
bump via config edit alone would never fetch the new version.

## Goals

1. Show the installed version per plugin in the Plugins tab.
2. Mark outdated plugins with a red dot.
3. Make the plugin URL clickable (repo / npm page).
4. Chevron affordance on the version → dropdown to switch versions, applied live
   (no opencode process restart).

## Non-goals

- TUI (the Plugins tab is web-app-only, v1 protocol).
- Auto-update (indicator + manual switch only).
- Plugin install/uninstall from the UI.
- Branch-HEAD tracking for git plugins: "latest" means **newest git tag**
  (user decision; matches the "obra is 6.3" mental model).

## Verified environment facts (v1.18.21, 2026-08-25)

- Install layout: `~/.cache/opencode/packages/<sanitized-spec>/node_modules/<name>/package.json`.
  Example: `~/.cache/opencode/packages/superpowers@git+https:/github.com/obra/superpowers.git/node_modules/superpowers/package.json` → `"version": "6.1.1"`.
- npm registry `superpowers` is 0.0.2 (placeholder) — for git specs the git **tag**
  is the version source; `git ls-remote --tags https://github.com/obra/superpowers.git`
  → newest `v6.3.0`.
- `~/.local/state/opencode/plugin-meta.json` exists but is only written by the TUI
  runtime — not usable for the web server.
- Plugin specs today (global config): `superpowers@git+https://github.com/obra/superpowers.git`,
  `opencode-lmstudio@git+https://github.com/aand18/opencode-lmstudio.git`,
  `~/.config/opencode/plugins/lmstudio-context-sync.ts` (local path).
- `semver` ^7.6.3 is a direct dependency of both `packages/opencode` and `packages/core`.
- Config provenance: each surviving spec has a derived `plugin_origins` entry
  `{spec, source, scope: "global"|"local"}` (`packages/core/src/v1/config/config.ts:111-115`),
  stripped before write; the server knows scope, the API does not expose it.
- Live reload mechanism already exists: config update → `markInstanceForDisposal` →
  next request rebuilds the instance (re-reads config, re-runs PluginLoader). Sessions
  live in the DB and survive. No process restart needed.

## Server design

### New module `packages/opencode/src/plugin/info.ts`

For each spec in the merged instance config:

| Field | git spec | npm spec | path spec |
|---|---|---|---|
| `kind` | `"git"` | `"npm"` | `"path"` |
| `name` | from installed `package.json`, fallback parsed name | parsed name | null |
| `url` | repo homepage (strip `git+`, trailing `.git`) | `https://www.npmjs.com/package/<name>` | null |
| `installed` | version from cache-dir `package.json` | same | null |
| `latest` | highest semver tag via `git ls-remote --tags <url>` (strip leading `v` from tag) | registry JSON `dist-tags.latest` | null |
| `outdated` | `semver.gt(latest, installed)`; null if either unknown | same | null |
| `versions` | top 10 tags, semver-desc | top 10 registry versions, desc | null |

Spec classification reuses the existing `npm-package-arg` parsing in
`packages/opencode/src/plugin/shared.ts` (`parsePluginSpecifier`, `isPathPluginSpec`).

**Network policy** — stale-while-revalidate in-memory cache keyed by spec, TTL ~15 min:

- fresh cache → return immediately
- stale cache → return stale value, refresh in background
- no cache (first request) → fetch, bounded by a short timeout; on failure return
  with `latest: null, outdated: null` (and no versions)
- failed refresh → keep last-known value

No checks at server startup; everything is lazy on first `GET /plugin`. `git
ls-remote` runs via the `git` binary (already a hard dependency of the npm install
path); registry fetch via `fetch()` to `https://registry.npmjs.org/<name>`.

### Routes (instance httpapi group, next to `/config`)

**`GET /plugin`** → `{ plugins: PluginInfo[] }` in config order.

**`POST /plugin/update`** body `{ spec, version }`:

1. Validate: spec exists in merged config; kind is `git` or `npm` (path → 400);
   version is in the known list (git tag / npm version; git accepts the tag as-is,
   e.g. `v6.3.0`).
2. Resolve origin from `plugin_origins` (global vs project).
3. Rewrite **only that entry** in the origin file, preserving tuple options
   (`[spec, options]`): git → append `#<tag>` committish
   (`superpowers@git+https://github.com/obra/superpowers.git#v6.3.0`); npm →
   `name@<version>`. Global scope uses the JSONC-preserving global update path;
   project scope the instance config path.
4. Remove `~/.cache/opencode/packages/<sanitized-old-spec>` (bypasses the
   `Npm.add` short-circuit) — only the dir matching the changed spec.
5. `markInstanceForDisposal` → next request re-resolves + re-imports the new
   version; `global.disposed`/`config.updated` events flow to the app.

Concurrent updates: idempotent, last write wins. Errors (bad version, origin file
unreadable, cache dir removal failure) → non-2xx with a message; the cache dir is
only removed after the config rewrite succeeds (rewrite-then-remove order is safe:
a failed removal leaves the new spec + the old cached copy → the short-circuit
reinstalls the old version on next load, config stays the source of truth and the
user simply retries).

### SDK

Run `bun run generate` from `packages/client`; never hand-edit `src/generated*`.

## App design

`packages/app/src/components/status-popover-body.tsx`, Plugins tab only
(unchanged v1-protocol gating):

- On popover mount: fetch `sdk.plugin.list()` into a local `createStore`.
  Refetch after a completed update. Fetch failure → fall back to today's
  raw-specifier rows.
- Row layout (600px panel from patch #28 is unchanged):

  `[dot] [name/URL — flex-1 min-w-0, wraps] [version chip + chevron — shrink-0]`

- **No truncation (user decision): the full spec must always be visible.** The
  name span uses `overflow-wrap: anywhere` (Tailwind `break-words`-style)
  instead of `truncate`: one line when the spec fits, wraps at URL slashes
  otherwise. Row height is adaptive; the panel width is not a constraint on
  name visibility anymore (wrapping is the safety net, so even the
  `max-w-[calc(100vw-40px)]` clamp on narrow viewports degrades to wrapping,
  never clipping).
- **Dot**: existing `bg-icon-success-base` dot stays exactly as-is by default;
  switches to `bg-icon-critical-base` (red) when `outdated === true`. No other
  dot states (user decision).
- **Name**: the spec string as today, wrapped in `<a target="_blank"
  rel="noopener" href={url}>` for git/npm specs; local paths render as plain
  text, no link.
- **Version chip + chevron**: installed version + chevron-down icon. Click opens
  the existing `@opencode-ai/ui/dropdown-menu` (radio-item pattern, cf.
  `session-header.tsx:385`): top 10 versions descending, current preselected,
  newest marked "Latest".
  - Select → pending state (chevron → spinner, menu closes) →
    `POST /plugin/update` → refetch on success → error toast on failure, row
    returns to normal.
- Path plugins and specs with unknown version: no version chip, no chevron.

**i18n**: all new copy ("Latest", "Updating…", error messages, aria labels)
through new `status.popover.*` keys in the app locale files; no hardcoded
strings.

## Patch shape

Patch #29, order-independent (touches no files used by other patches):

1. `packages/opencode/src/plugin/info.ts` (new)
2. `packages/opencode/src/server/routes/instance/httpapi/…` (group + handler)
3. `packages/client/src/generated*` (regenerated)
4. `packages/app/src/components/status-popover-body.tsx`
5. app i18n locale files (new keys; English source copy)

Register in `patches/apply.sh` header + `PATCH_NAMES` + README table (independence
+ file mapping). Fresh-clone apply must be 29/29.

## Maintainability (roll-forward friendliness)

Conflict risk per file, lowest first:

1. `packages/opencode/src/plugin/info.ts` (new file) — no conflicts unless
   upstream creates the same path.
2. Server group/handler registration — small isolated hunks in files that churn
   moderately.
3. `status-popover-body.tsx` — churns upstream (UI code); keep the diff confined
   to the Plugins tab block (row rendering + memo + fetch), no incidental
   reformatting, so `git apply --3way` rebase stays cheap.
4. i18n locale files — append-only key blocks.
5. `packages/client/src/generated*` (regenerated SDK) — **highest risk**: large
   generated files that churn on every upstream protocol change.

Mitigations:

- **All new server logic lives in the one new file**; route registration is the
  smallest possible hunk. Do not touch `npm.ts`, config core, or lifecycle code.
- **Never hand-merge generated SDK files** on rebase: re-land the server route
  hunks, then re-run `bun run generate` from `packages/client` and re-cut those
  hunks. Document this in the `apply.sh` header (the re-derivation recipe, per
  the patch-#28 convention of recording the *why* and the *how to re-derive*).
- Keep generated hunks small: two new endpoints add per-method sections; if an
  upstream release reorders surrounding generated code, re-generation (not
  manual conflict resolution) is the fix.
- The feature is a **self-contained upstream PR candidate** (server module +
  routes + app row). If anomalyco merges it, patch #29 is dropped on the next
  alignment pass — the spec here doubles as the PR description.
- `apply.sh` header note: patch shares `status-popover-body.tsx` with #28 —
  #28 changes only width classes (line ~301 body container), #29 changes only
  the Plugins tab block + the `plugins` memo a few lines above. Hunks are
  adjacent, not colliding: `git apply --3way` rebase is trivial, but if both
  ever need re-cutting, rebase #28 first (it is listed earlier in apply.sh).

## Verification plan

1. `bun typecheck` from `packages/opencode` (and `packages/app`).
2. Server: scratch instance with scratch config + global dir (env overrides):
   - `GET /plugin` shows superpowers installed 6.1.1, latest 6.3.0, outdated true
   - `POST /plugin/update` → config file entry rewritten with `#v6.3.0`, cache
     dir removed, next `GET /plugin` after disposal shows installed 6.3.0,
     outdated false
   - offline case (unreachable URL) → `outdated: null`, no crash
3. UI: live-verify on the running instance (`:4096`) via devtools/agent-browser
   **before** cutting the patch (house workflow): row layout at 600px, dot color,
   clickable URL, dropdown open/select/pending states.
4. Cut patch, register, fresh-clone verify, build + install per
   `docs/plans/2026-08-10-upgrade-procedure-opencode-and-patches.md`.

## Edge cases

- Git repo with no tags → `latest: null`, no dot, dropdown hidden.
- Prerelease tags (e.g. `v6.4.0-rc.1`) → excluded from `versions` list and
  `latest` unless no stable tag exists.
- Git spec already pinned with `#committish` → `installed` still readable;
  "latest" comparison unchanged; update rewrites the committish.
- Cache dir naming: the dir is keyed by the sanitized spec; implement must check
  whether the `#committish` survives sanitization (pinned vs unpinned spec may map
  to the **same** dir). Removal always targets the old spec's dir and happens
  before the instance reloads, so both cases work; verify empirically in step 2.
- npm spec `@latest`/`@tag` (no version) → `installed` from cache; `latest` from
  the same tag; switching pins an explicit version.
- Instance with no plugins → `GET /plugin` returns empty list.
- Same plugin in both global and project config → dedup winner (existing
  `plugin_origins` behavior) is the one updated.
