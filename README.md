# opencode-patched

Fork of [OpenCode](https://github.com/anomalyco/opencode) that layers a local patch stack
onto upstream release tags. The stack is aligned with the
[johnnymo87/opencode-patched](https://github.com/johnnymo87/opencode-patched) fork:
patches adopted from there are rebased onto each new release here, plus
locally-authored patches.

Currently tracking **v1.18.21** (rebased 2026-08-23; 32 patches, aligned to `johnnymo87/opencode-patched` `853da6382`).

## Patch stack

Patches live in `patches/` and are applied in order by `patches/apply.sh`.
The header of that script is the source of truth for the patch set, apply
order, dependency constraints, and the dropped-patch ledger. The table below
is a summary.

| # | Patch | Origin | What it does |
|---|-------|--------|--------------|
| 1 | `tool-fix.patch` | upstream PR #16751 | synthetic step-start boundaries (tool_use/result mismatch) |
| 2 | `cache-thinking-skip.patch` | upstream PR #17883 | cache breakpoints scan past trailing thinking/reasoning blocks |
| 3 | `sqlite-foreign-key-wrap.patch` | local | catch nested/wrapped FK constraints on modern error wrappers |
| 4 | `event-session-scope.patch` | local | optional `?session_ids=` filter on `GET /event` (pool-of-K serves) |
| 5 | `createnext-readback.patch` | local | `Session.createNext` reads durable row back after `Created` |
| 6 | `serve-lease.patch` | local | serve-side session-lease participation (routing-lease CAS, heartbeat, fenced run loop; `OPENCODE_ROUTING_DB`-gated) |
| 7 | `attach-route-resolve.patch` | local | pool-aware `opencode attach` + per-attempt SSE teardown (leak fix) |
| 8 | `bootstrap-disposed-filter.patch` | local | filter + debounce TUI disposed storm |
| 9 | `event-cold-start-directory.patch` | local | fix cold-start live-delivery race (apply after #4) |
| 10 | `project-copy-debounce.patch` | local | single-flight dedup + concurrency cap on `ProjectCopy.refresh` |
| 11 | `step-end-diff-bound.patch` | local | bound step-end summary diff to prevent CPU pin freeze |
| 12 | `globalbus-maxlisteners.patch` | local | uncap GlobalBus listener ceiling |
| 13 | `event-log-gate.patch` | local | gate durable event log behind `OPENCODE_EXPERIMENTAL_WORKSPACES` |
| 14 | `compaction-bounded-load.patch` | local | bound prompt-loop message load to compaction window |
| 15 | `available-cache.patch` | local | herd-collapse cache for CatalogV2 provider/model availability |
| 16 | `session-door-routes.patch` | local | `?session_ids=` on `event.subscribe` schema + session-scoped permission/question routes |
| 17 | `tui-door-attach.patch` | parent `johnnymo87` | Phase 8 front-door TUI: session-scoped `/event?session_ids=` + door-owned REST (apply after #7) |
| 18 | `tui-door-tests.patch` | local | client contract test for session-scoped door SDK |
| 19 | `session-mcp-routes.patch` | local | session-scoped MCP status/connect/disconnect routes (apply after #16) |
| 20 | `tui-mcp-dialog.patch` | local | MCP status/connect/disconnect dialog UI |
| 21 | `tui-reconcile-bound.patch` | parent `johnnymo87` | bound TUI pending-reconcile, proceed degraded after N=3 (apply last) |
| 22 | `registry-port-fence.patch` | local | PID fence on serve pool slots (apply after #6) |
| 23 | `plugin-loader-observability.patch` | local | structured plugin load-failure logging |
| 24 | `message-serve-provenance.patch` | parent `johnnymo87` | stamp serve provenance on assistant rows for sweeper (apply after #3) |
| 25 | `db-isolation-guard.patch` | parent `johnnymo87` | refuse DB open when `XDG_DATA_HOME` isolation requested but `OPENCODE_DB` outside it |
| 26 | `vcs-untracked-normal.patch` | local | respect `.gitignore`, prevent VCS crash on large repos (parent does not carry; kept as local safety) |
| 27 | `revert-orphan-parents.patch` | local | reparent orphaned messages after `/undo` revert cleanup (upstream #38864; parent does not carry; kept) |
| 28 | `status-popover-widen.patch` | local | widen status popover 360px → 600px so plugin/MCP identifiers aren't truncated to their URL/path prefix |
| 29 | `plugin-outdated-indicator.patch` | local | plugin version/outdated indicator: `GET /plugin` route + `isOutdated` (semver vs latest stable) + status-popover plugin tab (targeted v2 SDK additions, not full regen) |
| 30 | `sse-heartbeat-4s.patch` | local | lower SSE heartbeat tick 10s → 4s (prevents WSL2 NAT idle-kill of idle SSE streams) (apply after #5) |
| 31 | `ui-asset-compression-cache.patch` | local | embedded UI assets: gzip-eligible body (2,741,090 B → 814,864 B gz) + cache-control (hashed `assets/*` immutable, stable names no-cache) |
| 32 | `popover-nested-overlay.patch` | local | popover dismiss: focus/pointer inside a portaled overlay opened from within the popover (e.g. plugin version menu) no longer closes the popover |
| 33 | `generic-tool-expand.patch` | local | expandable generic (unknown/MCP/custom) tool calls: bordered card, input + JSON-object output as key/value rows (no JSON blob), other output as Markdown, separator instead of labels, per-section copy |

Dependency constraints: #9 after #4, #22 after #6, #19 after #16, #17 after #7, #21 last, #24 after #3, #30 after #5.

### Patch implementers

Model that implemented each patch (#1–32 predate attribution — unknown):

| Patch | Implemented by |
|-------|---------------|
| 33 `generic-tool-expand.patch` | Muse Spark 1.3 (Xhigh) |
| 1–32 | unknown |

## Patch details

Detailed writeups for the patches shared with the upstream fork
(johnnymo87/opencode-patched).

### Adopted from parent `johnnymo87` (2026-08-23 alignment to `853da6382`)

- **`tui-door-attach.patch` + `tui-reconcile-bound.patch`** — Phase 8 front-door TUI + bound reconcile (workstation-mlve / fdb1). Door owns `GET /event?session_ids=` and `session/` REST routing, TUI drops pigeon `/route` self-resolve; reconcile after `N=3` proceeds degraded with slow-cadence retry. Verified at `v1.18.21`: both apply clean on top of full stack, 6 + 9 files, no conflict with `attach-route-resolve`/`tui-mcp-dialog`. Heavy but order-independent except #21 last.

- **`message-serve-provenance.patch`** — stamps `{serveId,invocationId,port,pid}` into assistant rows via `projector.ts:75` (gated on `OPENCODE_SERVE_ID` + `/proc/self/cgroup` containing `opencode-serve@<port>.service`), so sweeper can finalize orphans promptly instead of ~24h. Disjoint from `sqlite-foreign-key-wrap` (different hunks), applies clean at `v1.18.21`, adds 4 files/340 lines + 16 tests. Useful for phantom-busy sweeper.

- **`db-isolation-guard.patch`** — `packages/core/src/database/database.ts:42` + new `isolation.ts` (incident 2026-08-14). `OPENCODE_DB` absolute wins over `XDG_DATA_HOME`, so throwaway `XDG_DATA_HOME` copy recipe left DB on prod; guard refuses when `XDG_DATA_HOME` set and `OPENCODE_DB` outside it (escape `OPENCODE_DB_ALLOW_FOREIGN_XDG=1`). Armed only when `XDG_DATA_HOME` set (prod pool has it unset), so no break. Applies clean at `v1.18.21`, order-independent, 1 + 184 lines, 14 tests.

- **`retry-cap.patch` dropped** — upstream `c78986831c` in `v1.18.17` now caps at `RETRY_MAX_RETRIES=5` with `RETRY_JITTER_FACTOR=0.25` (`packages/opencode/src/session/retry.ts:31`); parent tombstone 4 says do not re-litigate `5-vs-8`. Verified at `v1.18.21`: cap present, so local `5->8` bump removed to align.

### Cache thinking-skip (`cache-thinking-skip.patch`)

Upstream `applyCaching` marks the conversation cache breakpoint on
`msg.content[msg.content.length - 1]` — blindly the last content block. When the last
block is a `reasoning`/`redacted-reasoning` (thinking) block, Anthropic rejects the
request with HTTP 400 because `cache_control` isn't allowed on thinking blocks (bites
whenever adaptive reasoning is on). The patch makes the breakpoint scan backwards to
the last *cacheable* content block, skipping trailing reasoning and tool-approval
pseudo-blocks. ~15 lines in `applyCaching`, `packages/opencode/src/provider/transform.ts`.
Tracked upstream as [Issue #17883](https://github.com/anomalyco/opencode/issues/17883).

### Tool use/result fix (`tool-fix.patch`)

Fixes the widespread `tool_use ids were found without tool_result blocks` error
([#16749](https://github.com/anomalyco/opencode/issues/16749), upstream
[PR #16751](https://github.com/anomalyco/opencode/pull/16751)) that corrupts sessions
when stream errors cause lost step boundaries. Injects synthetic step-start boundaries
at message reconstruction time in `packages/opencode/src/session/message-v2.ts`.

### Local: status popover widen (`status-popover-widen.patch`)

Status popover plugin/MCP/LSP list truncated raw specifiers from the right — keeping
the redundant URL/path prefix and cutting the informative name at the end. Widens the
popover 360px → 600px (7 real specifiers measured 372–474px at `text-14-regular`, so
~120px headroom; ≥530px is the floor). Rejected alternatives: `break-words` (URLs have
no spaces → overflow), `break-all` (forces 2 lines per entry, list 2× taller), and
name-extraction (changes displayed content, loses the path). The width is duplicated in
six places (old-layout + V2 popover classes + 2 Suspense fallbacks + 2 body
containers) and must stay in sync; placement `bottom-end` + `shift -168` stays anchored
with the wider panel. All six sites carry `max-w-[calc(100vw-40px)]` — the 4 inner ones
(2 Suspense fallbacks + 2 body containers) were previously uncapped, and on a 390px
viewport the 600px inner overflowed 242px (right edge 632 → 382 after the cap), cutting
the plugin list + version chevrons off the right edge.

## Patch independence

Files touched per patch (from patch headers; overlaps apply cleanly in `apply.sh` order
because they modify disjoint regions):

| Patch | Files |
|-------|-------|
| tool-fix | `session/message-v2.ts`, `test/session/message-v2.test.ts` |
| cache-thinking-skip | `provider/transform.ts` |
| sqlite-foreign-key-wrap | `core/src/session/projector.ts` |
| event-session-scope | `httpapi/handlers/event.ts` + test |
| event-cold-start-directory | `httpapi/handlers/event.ts` (same file as event-session-scope) |
| createnext-readback | `session/session.ts` + test |
| serve-lease | `core/src/flag`, `cli/cmd/serve.ts`, `session/prompt.ts`, serve-process tests |
| attach-route-resolve | `cli/cmd/attach.ts`, `tui/app.tsx`, `tui/context/sdk.tsx` |
| bootstrap-disposed-filter | `tui/context/sync.tsx` |
| project-copy-debounce | `core/src/project/copy.ts` + test |
| step-end-diff-bound | `snapshot/index.ts` |
| globalbus-maxlisteners | `bus/global.ts` |
| event-log-gate | `core/src/event.ts` |
| compaction-bounded-load | `session/message-v2.ts` + test (same file as tool-fix, disjoint region) |
| available-cache | `core/src/catalog.ts` + test |
| session-door-routes | `httpapi/groups/{event,session}.ts`, sdk gen files |
| tui-door-attach | `cli/cmd/attach.ts`, `tui/context/sdk.tsx`, `tui/context/sync.tsx`, `tui/util/sse.ts` + `permission`/`question` routes |
| tui-door-tests | new client contract test |
| session-mcp-routes | same files as session-door-routes (disjoint regions) |
| tui-mcp-dialog | `dialog-mcp.tsx`, `context/{sync,local}.tsx`, `util/session.ts` |
| tui-reconcile-bound | `tui/util/reconcile.ts` (new), `tui/util/sse.ts`, `tui/context/{sdk,sync}.tsx` + tests |
| registry-port-fence | extends serve-lease files (`core/src/serve/routing-lease.ts`, `serve.ts`, flag) |
| plugin-loader-observability | `plugin/index.ts` |
| message-serve-provenance | `core/src/session/projector.ts` (disjoint from sqlite-foreign-key-wrap), `schema/src/v1/session.ts` + tests |
| db-isolation-guard | `core/src/database/database.ts`, new `core/src/database/isolation.ts` + test |
| vcs-untracked-normal | `git/index.ts` |
| revert-orphan-parents | `session/revert.ts` |
| status-popover-widen | `app/src/components/status-popover.tsx`, `app/src/components/status-popover-body.tsx` |
| sse-heartbeat-4s | `httpapi/handlers/{global,event}.ts` (event.ts: same file as event-session-scope / event-cold-start-directory, disjoint region) |
| popover-nested-overlay | `ui/src/components/popover.tsx` |
| generic-tool-expand | `session-ui/src/components/basic-tool.{tsx,css}`, new `generic-tool-input.ts` + test |

## Dropped patches

Full ledger with reasons lives in the `patches/apply.sh` header. Highlights:

- `retry-cap.patch` — dropped 2026-08-23 to align with parent (upstreamed `c78986831c` in `v1.18.17`, `MAX=5` stricter than local `8`; parent tombstone 4)
- `prompt-loop-cache.patch` (#25367) + `cache-aligned-compaction.patch` (#25100) — dropped by upstream, pending a measured cache-economics pass
- `mcp-reconnect.patch` — incompatible with OAuth-aware MCP in v1.17+; upstream removed it too
- `eager-input-streaming.patch`, `prefill-fix.patch` — merged upstream
- `caching.patch` — dropped by upstream (opencode-cached PR #5422)
- `gemini-empty-parts.patch`, `vim.patch`, `opus5-adaptive-thinking.patch` — **USER-REQUESTED EXCLUSIONS** (upstream still carries; we drop per user preference, documented in `AGENTS.md:42`)
- `tui-follow-owner.patch`, `integration-list-batch.patch`, `instance-state-partition.patch` — upstream removed them

## Installation

### From a release

Releases are published by the `build-release.yml` workflow
(`gh workflow run build-release.yml --field version=X.Y.Z`) as `vX.Y.Z-patched`:

```bash
curl -sL https://github.com/<owner>/opencode-patched/releases/latest/download/opencode-linux-x64.tar.gz | tar xz
sudo mv bin/opencode /usr/local/bin/
opencode --version
```

### Build locally

```bash
# source clone (separate from this repo) checked out at the target tag
git clone https://github.com/anomalyco/opencode.git opencode-src
git -C opencode-src checkout v1.18.21

# apply the patch stack
./patches/apply.sh opencode-src            # must print "All patches applied successfully"

# build (bun install is REQUIRED for v1.18.15+ — vendored @opencode-ai/client tarball)
bun install --cwd opencode-src
OPENCODE_VERSION=1.18.21 OPENCODE_CHANNEL=prod \
  bun run --cwd opencode-src/packages/opencode build

# binary lands at opencode-src/packages/opencode/dist/opencode-linux-x64/bin/opencode
```

### Run from source (no build)

To test changes/patches without a full binary build, run the patched source
directly. `dev-serve.sh` (repo root) wraps the exact command with the right flags
and env:

```bash
./dev-serve.sh   # = bun --conditions=browser --define 'OPENCODE_VERSION="1.18.21"' --define 'OPENCODE_CHANNEL="prod"' opencode-src/packages/opencode/src/index.ts serve --hostname 0.0.0.0 --port 4096 --mdns
```

Edit a file → `Ctrl-C` → rerun; no build step. The Web UI is proxied from
`app.opencode.ai` in source mode (the embedded `opencode-web-ui.gen.ts` only
resolves at build time); run `bun run dev:web` (Vite) separately if you need the
patched UI. See `AGENTS.md` for the full flag list and the
`DEV_SERVE_HOST` / `DEV_SERVE_PORT` / `DEV_SERVE_MDNS` / `OPENCODE_DB` overrides.

## Maintenance

### Roll forward to a new upstream release

1. Fetch the new tag into `opencode-src`; verify with `git apply --check` on a clean checkout.
2. Run `bun install` before the first build (newer builds vendor `@opencode-ai/client`).
3. `./patches/apply.sh` — any failure means the corresponding patch needs a rebase.
    Rebase, then verify a fresh clone applies 33/33 and builds.
4. Install the binary with a versioned name and back up `~/.local/share/opencode/opencode.db`.
5. Update the version pins in `AGENTS.md`, this README, and the `apply.sh` header.
6. Commit and push.

### Align with johnnymo87/opencode-patched

The upstream fork carries patches ahead of upstream opencode. Periodically:

1. `git fetch upstream` (johnnymo87) and diff `upstream/main`'s `patches/` against ours.
2. Decide per patch: **adopt** (rebased here), **skip** (only if heavy friction and verified at current tag), or **drop** (user preference; documented in `AGENTS.md:42` + `apply.sh` header). As of `2026-08-23` we align fully to parent except user exclusions (`gemini-empty-parts`, `vim`, `opus5`).
3. Update the `apply.sh` header (patch set + dropped ledger) and the table above.
4. Verify: clean-clone apply + build before committing.

### When a patch breaks (build failure)

`apply.sh` fails on the first patch that doesn't apply; that's the one needing a rebase.
Behavioral guides per patch:

- **retry-cap**: **DROPPED** as of `2026-08-23` (upstreamed `c78986831c`); if upstream changes cap, no action needed. Previously: re-derive `MAX_RETRIES` cap + jitter against `packages/opencode/src/session/retry.ts`, verify with `bun test test/session/retry.test.ts`.
- **cache-thinking-skip**: re-derive the backward-scan hunk against the new
  `applyCaching` in `provider/transform.ts` (replace the blind last-block breakpoint
  pick with a scan past `reasoning`/`redacted-reasoning`/`tool-approval-*` blocks).
  Drop if upstream fixes [Issue #17883](https://github.com/anomalyco/opencode/issues/17883).
- **tool-fix**: prefer **drop over refresh** — if the upstream release includes the fix
  (verify by running PR #16751's regression test against a plain upstream checkout),
  remove the patch entirely. Otherwise regenerate:
  `gh pr diff 16751 --repo anomalyco/opencode > patches/tool-fix.patch`.
- **tool-fix drift** (`sync-tool-fix-pr.yml`, every 8h): hash mismatch vs the upstream
  PR diff is a *review signal, not breakage* — the committed patch still builds; treat
  the drift issue as a prompt to review and adopt.

### Sunset criteria

Monthly `check-sunset.yml` monitors upstream PRs/issues:

- **Any PR merged (or tracked issue closed)**: drop the corresponding patch from
  `apply.sh`, update this README + AGENTS.md pins.
- **All merged**: switch to the upstream release and archive this repo.

## Credits

- **OpenCode**: [anomalyco/opencode](https://github.com/anomalyco/opencode)
- **Upstream fork**: [johnnymo87/opencode-patched](https://github.com/johnnymo87/opencode-patched)
- **Tool fix**: PR [#16751](https://github.com/anomalyco/opencode/pull/16751) by [@altendky](https://github.com/altendky)
- **Cache thinking skip**: PR [#17883](https://github.com/anomalyco/opencode/pull/17883)
- **Orphan-parent revert cleanup**: upstream issue [#38864](https://github.com/anomalyco/opencode/issues/38864)

## License

MIT (same as upstream OpenCode)