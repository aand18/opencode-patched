# opencode-patched

Fork of [OpenCode](https://github.com/anomalyco/opencode) that layers a local patch stack
onto upstream release tags. The stack is aligned with the
[johnnymo87/opencode-patched](https://github.com/johnnymo87/opencode-patched) fork:
patches adopted from there are rebased onto each new release here, plus
locally-authored patches.

Currently tracking **v1.18.15** (rebased 2026-08-09; 24 patches).

## Patch stack

Patches live in `patches/` and are applied in order by `patches/apply.sh`.
The header of that script is the source of truth for the patch set, apply
order, dependency constraints, and the dropped-patch ledger. The table below
is a summary.

| # | Patch | Origin | What it does |
|---|-------|--------|--------------|
| 1 | `retry-cap.patch` | local | MAX_RETRIES=8 + backoff jitter (Vertex/Gemini runaway cure) |
| 2 | `tool-fix.patch` | upstream PR #16751 | synthetic step-start boundaries (tool_use/result mismatch) |
| 3 | `cache-thinking-skip.patch` | upstream PR #17883 | cache breakpoints scan past trailing thinking/reasoning blocks |
| 4 | `step-end-diff-bound.patch` | local | bound step-end summary diff to prevent CPU pin freeze |
| 5 | `project-copy-debounce.patch` | local | single-flight dedup + concurrency cap on `ProjectCopy.refresh` |
| 6 | `bootstrap-disposed-filter.patch` | local | filter + debounce TUI disposed storm |
| 7 | `available-cache.patch` | local | herd-collapse cache for CatalogV2 provider/model availability |
| 8 | `compaction-bounded-load.patch` | local | bound prompt-loop message load to compaction window |
| 9 | `sqlite-foreign-key-wrap.patch` | local | catch nested/wrapped FK constraints on modern error wrappers |
| 10 | `event-session-scope.patch` | local | optional `?session_ids=` filter on `GET /event` (pool-of-K serves) |
| 11 | `event-cold-start-directory.patch` | local | fix cold-start live-delivery race (apply after #10) |
| 12 | `createnext-readback.patch` | local | `Session.createNext` reads durable row back after `Created` |
| 13 | `serve-lease.patch` | local | serve-side session-lease participation (routing-lease CAS, heartbeat, fenced run loop; `OPENCODE_ROUTING_DB`-gated) |
| 14 | `registry-port-fence.patch` | local | PID fence on serve pool slots (apply after #13) |
| 15 | `attach-route-resolve.patch` | local | pool-aware `opencode attach` + per-attempt SSE teardown (leak fix) |
| 16 | `globalbus-maxlisteners.patch` | local | uncap GlobalBus listener ceiling |
| 17 | `event-log-gate.patch` | local | gate durable event log behind `OPENCODE_EXPERIMENTAL_WORKSPACES` |
| 18 | `session-door-routes.patch` | local | `?session_ids=` on `event.subscribe` schema + session-scoped permission/question routes |
| 19 | `session-mcp-routes.patch` | local | session-scoped MCP status/connect/disconnect routes (apply after #18) |
| 20 | `tui-door-tests.patch` | local | client contract test for session-scoped door SDK |
| 21 | `tui-mcp-dialog.patch` | local | MCP status/connect/disconnect dialog UI |
| 22 | `plugin-loader-observability.patch` | local | structured plugin load-failure logging |
| 23 | `vcs-untracked-normal.patch` | local | respect `.gitignore`, prevent VCS crash on large repos |
| 24 | `revert-orphan-parents.patch` | local | reparent orphaned messages after `/undo` revert cleanup (upstream #38864) |

Dependency constraints: #11 after #10, #14 after #13, #19 after #18.

## Patch details

Detailed writeups for the patches shared with the upstream fork
(johnnymo87/opencode-patched).

### Retry cap (`retry-cap.patch`)

Caps per-step model-stream re-issues at `MAX_RETRIES = 8`. Each retry is a full,
billable provider request, so an uncapped schedule turned any persistently-retryable
condition into an unbounded burst of provider calls — the runaway behind the 2026-06
Vertex/Gemini cost surge. Also adds *downward-only* jitter (`RETRY_JITTER_RATIO = 0.2`)
to the no-header exponential backoff so concurrent stuck sessions don't re-issue their
streams in lockstep against a shared quota (thundering herd). Explicit `retry-after` /
`retry-after-ms` hints are honored exactly and never jittered.

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

## Patch independence

Files touched per patch (from patch headers; overlaps apply cleanly in `apply.sh` order
because they modify disjoint regions):

| Patch | Files |
|-------|-------|
| retry-cap | `session/retry.ts`, `test/session/retry.test.ts` |
| tool-fix | `session/message-v2.ts`, `test/session/message-v2.test.ts` |
| cache-thinking-skip | `provider/transform.ts` |
| step-end-diff-bound | `snapshot/index.ts` |
| project-copy-debounce | `core/src/project/copy.ts` + test |
| bootstrap-disposed-filter | `tui/context/sync.tsx` |
| available-cache | `core/src/catalog.ts` + test |
| compaction-bounded-load | `session/message-v2.ts` + test (same file as tool-fix, disjoint region) |
| sqlite-foreign-key-wrap | `core/src/session/projector.ts` |
| event-session-scope | `httpapi/handlers/event.ts` + test |
| event-cold-start-directory | `httpapi/handlers/event.ts` (same file as event-session-scope) |
| createnext-readback | `session/session.ts` + test |
| serve-lease | `core/src/flag`, `cli/cmd/serve.ts`, `session/prompt.ts`, serve-process tests |
| registry-port-fence | extends serve-lease files (`core/src/serve/routing-lease.ts`, `serve.ts`, flag) |
| attach-route-resolve | `cli/cmd/attach.ts`, `tui/app.tsx`, `tui/context/sdk.tsx` |
| globalbus-maxlisteners | `bus/global.ts` |
| event-log-gate | `core/src/event.ts` |
| session-door-routes | `httpapi/groups/{event,session}.ts`, sdk gen files |
| session-mcp-routes | same files as session-door-routes (disjoint regions) |
| tui-door-tests | new client contract test |
| tui-mcp-dialog | `dialog-mcp.tsx`, `context/{sync,local}.tsx`, `util/session.ts` |
| plugin-loader-observability | `plugin/index.ts` |
| vcs-untracked-normal | `git/index.ts` |
| revert-orphan-parents | `session/revert.ts` |

## Dropped patches

Full ledger with reasons lives in the `patches/apply.sh` header. Highlights:

- `prompt-loop-cache.patch` (#25367) + `cache-aligned-compaction.patch` (#25100) — dropped by upstream, pending a measured cache-economics pass
- `mcp-reconnect.patch` — incompatible with OAuth-aware MCP in v1.17+; upstream removed it too
- `eager-input-streaming.patch`, `prefill-fix.patch` — merged upstream
- `caching.patch` — dropped by upstream (opencode-cached PR #5422)
- `gemini-empty-parts.patch`, `vim.patch`, `opus5-adaptive-thinking.patch` — removed by user preference (upstream still carries some)
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
git -C opencode-src checkout v1.18.15

# apply the patch stack
./patches/apply.sh opencode-src            # must print "All patches applied successfully"

# build (bun install is REQUIRED for v1.18.15+ — vendored @opencode-ai/client tarball)
bun install --cwd opencode-src
OPENCODE_VERSION=1.18.15 OPENCODE_CHANNEL=prod \
  bun run --cwd opencode-src/packages/opencode build

# binary lands at opencode-src/packages/opencode/dist/opencode-linux-x64/bin/opencode
```

## Maintenance

### Roll forward to a new upstream release

1. Fetch the new tag into `opencode-src`; verify with `git apply --check` on a clean checkout.
2. Run `bun install` before the first build (newer builds vendor `@opencode-ai/client`).
3. `./patches/apply.sh` — any failure means the corresponding patch needs a rebase.
   Rebase, then verify a fresh clone applies 24/24 and builds.
4. Install the binary with a versioned name and back up `~/.local/share/opencode/opencode.db`.
5. Update the version pins in `AGENTS.md`, this README, and the `apply.sh` header.
6. Commit and push.

### Align with johnnymo87/opencode-patched

The upstream fork carries patches ahead of upstream opencode. Periodically:

1. `git fetch upstream` (johnnymo87) and diff `upstream/main`'s `patches/` against ours.
2. Decide per patch: **adopt** (rebased here), **skip** (applies/rebases with heavy friction, e.g. `tui-door-attach`, `tui-reconcile-bound`, which depend on upstream architecture not present in older tags), or **drop** (user preference).
3. Update the `apply.sh` header (patch set + dropped ledger) and the table above.
4. Verify: clean-clone apply + build before committing.

### When a patch breaks (build failure)

`apply.sh` fails on the first patch that doesn't apply; that's the one needing a rebase.
Behavioral guides per patch:

- **retry-cap**: re-derive the `MAX_RETRIES` cap + jitter logic against the new
  `packages/opencode/src/session/retry.ts`. Verify with
  `bun test test/session/retry.test.ts` from `packages/opencode`. Drop if upstream ever
  caps retries natively.
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