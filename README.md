# opencode-patched

**OpenCode v1.15.12 with [prompt caching](https://github.com/anomalyco/opencode/pull/5422) + [prompt-loop byte identity](https://github.com/anomalyco/opencode/pull/25367) + [cache-aligned compaction](https://github.com/anomalyco/opencode/pull/25100) + [Gemini empty parts fix](https://github.com/anomalyco/opencode/pull/28669) + [vim keybindings](https://github.com/anomalyco/opencode/pull/12679) + [tool use/result fix](https://github.com/anomalyco/opencode/pull/16751) + [MCP auto-reconnect](https://github.com/anomalyco/opencode/issues/15247) + [eager_input_streaming workaround](https://github.com/anomalyco/opencode/issues/23541)**

This repository layers prompt caching and local patches into a single OpenCode binary, built automatically for 4 platforms.

## Patches Included

### 1. Prompt Caching Improvements ([PR #5422](https://github.com/anomalyco/opencode/pull/5422))

Fetched at build time from [opencode-cached](https://github.com/johnnymo87/opencode-cached). Adds provider-specific cache configuration for 19+ providers, reducing cache write costs by ~44% and effective costs by ~73%.

### 2. Prompt-Loop Byte Identity ([PR #25367](https://github.com/anomalyco/opencode/pull/25367))

Stored locally as `patches/prompt-loop-cache.patch`. Caches the conversation array across prompt-loop iterations so tool-call continuations preserve byte identity. This targets the flat-cache-read + growing-uncached-input pattern where repeated tool-loop calls keep paying full input price for the same growing tail.

Captured from PR head `810aaffd44472f6e6d1accff53048f9e2009e41c`.

### 3. Cache-Aligned Compaction ([PR #25100](https://github.com/anomalyco/opencode/pull/25100))

Stored locally as `patches/cache-aligned-compaction.patch`. Rationale: compaction request construction was provider-independent uncached work; aligning compaction with normal prompt-loop context lets future compactions reuse prefix cache where provider/model conditions allow. Applied after `prompt-loop-cache.patch` and before existing vim/tool/MCP/eager patches.

Captured from PR #25100 head `972380a75249b01a424010e8bc0453e15a3a14c2`.

### 4. Gemini Empty Parts Fix ([PR #28669](https://github.com/anomalyco/opencode/pull/28669), [Issue #17519](https://github.com/anomalyco/opencode/issues/17519))

Stored locally as `patches/gemini-empty-parts.patch`. Vertex/Gemini rejects any
`contents[]` entry with `parts: []` with `Unable to submit request because it must
include at least one parts field`. This patch fixes that on **two independent code
paths**:

- **Native runtime** (`packages/llm/src/protocols/gemini.ts`): pads completely
  empty Gemini user, assistant, or tool messages with an empty-string text part
  before serialization. This is the PR #28669 fix, extended to cover an empty
  tool-message regression. NOTE: the native runtime gate
  (`session/llm/native-runtime.ts`) only admits `openai`/`anthropic`/`opencode*`
  providers, so Gemini never actually reaches this path today — this hunk tracks
  PR #28669 and is future-proofing if upstream ever routes Gemini natively.

- **AI SDK runtime** (`packages/opencode/src/provider/transform.ts`): this is the
  path Gemini actually uses (`google-vertex` / `google` via `@ai-sdk/google`).
  `ProviderTransform.message()` → `normalizeMessages()` now drops empty
  text/reasoning parts and any resulting empty message for `@ai-sdk/google` /
  `@ai-sdk/google-vertex`, exactly like the pre-existing `@ai-sdk/anthropic` and
  `@ai-sdk/amazon-bedrock` blocks. The `@ai-sdk/google` converter drops
  empty-text parts itself (`part.text.length === 0 ? undefined : ...`), so a turn
  whose only content is an empty part — e.g. the empty "structural separator"
  text part that Anthropic adaptive-thinking turns persist between `step-start`
  boundaries, replayed cross-model into a Gemini compaction request — serializes
  to `parts: []` and 400s the whole request. This is the intermittent
  compaction failure tracked in Issue #17519; the original `packages/llm` hunk
  alone never fixed it because Gemini doesn't use that path.

### 5. Vim Keybindings ([PR #12679](https://github.com/anomalyco/opencode/pull/12679))

Stored locally as `patches/vim.patch`. Adds optional vim motions to the prompt input. Disabled by default -- enable with `tui.vim: true` or toggle from the command palette.

Supported motions:
- Mode switching: `i I a A o O S`, `cc`, `cw`, `Esc`
- Motions: `h j k l`, `w b e`, `W B E`, `0 ^ $`
- Deletes: `x`, `dd`, `dw`
- Session navigation: `gg/G`
- Scrolling: `Ctrl+e/y/d/u/f/b`
- `Enter` in normal mode submits

### 6. Tool Use/Result Mismatch Fix ([PR #16751](https://github.com/anomalyco/opencode/pull/16751))

Stored locally as `patches/tool-fix.patch`. Fixes the widespread `tool_use ids were found without tool_result blocks` error ([#16749](https://github.com/anomalyco/opencode/issues/16749)) that corrupts sessions when stream errors cause lost step boundaries. Injects synthetic step-start boundaries at message reconstruction time to prevent interleaved tool_use/text in assistant messages that the Anthropic API rejects.

### 7. MCP Auto-Reconnect ([Issue #15247](https://github.com/anomalyco/opencode/issues/15247))

Stored locally as `patches/mcp-reconnect.patch`. Automatically reconnects remote MCP servers when the server restarts and the session becomes stale. Without this patch, `callTool` fails at the transport layer with "Session not found" / HTTP 404 errors, requiring a manual MCP toggle (ctrl+p) or full OpenCode restart.

The patch wraps remote MCP tool execution with a try/catch that detects transport-level errors (stale sessions, connection refused, etc.), closes the stale client, creates a fresh transport + client, refreshes tool definitions, and retries the call once.

### 8. Eager Input Streaming Workaround ([Issue #23541](https://github.com/anomalyco/opencode/issues/23541), [#23257](https://github.com/anomalyco/opencode/issues/23257), [#23767](https://github.com/anomalyco/opencode/issues/23767))

Stored locally as `patches/eager-input-streaming.patch`. Disables `toolStreaming` for all `@ai-sdk/anthropic`-backed providers (including `@ai-sdk/google-vertex/anthropic`).

Since `@ai-sdk/anthropic >= 3.0.58`, the `fine-grained-tool-streaming-2025-05-14` beta header (hardcoded in `provider.ts`) causes the SDK to inject `eager_input_streaming: true` into every tool definition. Anthropic-shape endpoints with strict schema validation (Google Vertex Anthropic, AWS Bedrock proxies, GitHub Copilot's `/v1/messages` shim, corporate gateways) reject the unknown field with HTTP 400:

```
tools.0.custom.eager_input_streaming: Extra inputs are not permitted
```

Upstream only fixes this for github-copilot via the `chat.params` plugin hook (gated on `providerID`), leaving Vertex/Bedrock/etc. broken. PRs that proposed a generalized fix ([#23766](https://github.com/anomalyco/opencode/pull/23766), [#23542](https://github.com/anomalyco/opencode/pull/23542)) were rejected by upstream maintainers. This patch defaults `toolStreaming = false` in `ProviderTransform.options()` whenever the model uses `@ai-sdk/anthropic` or `@ai-sdk/google-vertex/anthropic`. Users can opt back in by setting `toolStreaming: true` in their model or agent options.

## DROPPED patches (sunset history)

- **bus-eager-subscribe.patch (PR #27959)** — DROPPED on 2026-05-25 when this repo cut over from v1.15.0 to v1.15.10. PR #27959 (`fix(bus): acquire PubSub subscription eagerly`) was merged upstream on 2026-05-18 and shipped in v1.15.5. Any opencode release >= v1.15.5 contains the fix natively.
- **Bus instance context fix (PR #28051)** — never had its own patch in this repo, but the closely-related bug it fixes (sync events publishing on the wrong bus runtime, partitioning `message.updated` from `session.idle` across plugin instances) was the root cause of dropped Telegram stop notifications throughout April/May 2026. The load-bearing fix is actually PR #27825 (`fix(sync): publish events on injected project bus`), with #27757, #28051, and #28187 as supporting changes. ALL of these are in v1.15.5+. See `docs/plans/2026-05-22-bus-fix-investigation-HANDOFF.md` and `docs/plans/2026-05-25-28051-verification-report.md` in the pigeon repo for the full investigation chain.
- **prefill-fix.patch** — DROPPED on 2026-05-28 when this repo cut over to v1.15.12. v1.15.12's release notes line *"Used the persisted session directory for existing-session requests"* corresponds to an upstream implementation of the same fix in `packages/opencode/src/server/routes/instance/httpapi/middleware/workspace-routing.ts`: `planRequest`'s `Local` plan construction now does `directory: session?.directory || defaultDirectory(request, url)`, which closes the multi-cwd race our patch did by routing session-bound requests to the session's canonical directory. Upstream's implementation collapses the choice into the existing `directory` field rather than threading our richer `sessionDirectory` value through `RequestPlan.Local` + `WorkspaceRouteContext` + `InstanceContextMiddleware`, but the net behavior matches. See `docs/plans/2026-05-15-prefill-fix-redesign-{plan,question,answer}.md` for the original v1.15.0 redesign and `docs/plans/2026-04-21-opencode-prefill-fix-design.md` (workstation repo) for the root-cause analysis.

## Installation

### Linux (arm64)

```bash
curl -sL https://github.com/johnnymo87/opencode-patched/releases/latest/download/opencode-linux-arm64.tar.gz | tar xz
sudo mv bin/opencode /usr/local/bin/
opencode --version
```

### Linux (x64)

```bash
curl -sL https://github.com/johnnymo87/opencode-patched/releases/latest/download/opencode-linux-x64.tar.gz | tar xz
sudo mv bin/opencode /usr/local/bin/
opencode --version
```

### macOS (arm64)

```bash
curl -sL https://github.com/johnnymo87/opencode-patched/releases/latest/download/opencode-darwin-arm64.zip -o opencode.zip
unzip opencode.zip
sudo mv bin/opencode /usr/local/bin/
opencode --version
```

### macOS (x64)

```bash
curl -sL https://github.com/johnnymo87/opencode-patched/releases/latest/download/opencode-darwin-x64.zip -o opencode.zip
unzip opencode.zip
sudo mv bin/opencode /usr/local/bin/
opencode --version
```

### Nix

See the [workstation repo](https://github.com/johnnymo87/workstation) for Nix integration example.

## How It Works

```
Timing Chain (every 8 hours):

:00  opencode-cached/sync-upstream    -- detects new upstream release
      |-> builds v{VER}-cached        -- applies caching patch, publishes

:01  opencode-patched/sync-cached     -- detects new -cached release
        |-> builds v{VER}-patched       -- applies caching + prompt-loop-cache + cache-aligned-compaction + gemini-empty-parts + vim + tool fix + mcp reconnect + eager-input-streaming + instance-state-partition patches, publishes
:01  opencode-patched/sync-vim-pr     -- checks PR #12679 for changes
:01  opencode-patched/sync-tool-fix-pr -- checks PR #16751 for changes

:02  workstation/update-opencode-patched -- updates Nix config, opens PR
```

### Build Process

1. Clone upstream OpenCode at the release tag
2. Fetch `caching.patch` from [opencode-cached](https://github.com/johnnymo87/opencode-cached) (always latest from `main`)
3. Apply `caching.patch`, then local `prompt-loop-cache.patch`, then `cache-aligned-compaction.patch`, then `gemini-empty-parts.patch`, then `vim.patch`, then `tool-fix.patch`, then `mcp-reconnect.patch`, then `eager-input-streaming.patch`, then `instance-state-partition.patch`
4. Build with Bun for 4 platforms (linux/darwin x arm64/x64)
5. Publish release as `v{VERSION}-patched`

### Patch Independence

The patches modify mostly different areas of the codebase:
- **Caching**: `config/agent.ts`, `config/provider.ts`, `provider/config.ts`, `provider/transform.ts`, `session/prompt.ts`
- **Prompt-loop cache**: `app/vite.js`, `session/prompt.ts`
- **Cache-aligned compaction**: `session/prompt.ts`
- **Gemini empty parts**: `packages/llm/src/protocols/gemini.ts`, `packages/llm/test/provider/gemini.test.ts`, `packages/opencode/src/provider/transform.ts`, `packages/opencode/test/provider/transform.test.ts`
- **Vim**: `cli/cmd/tui/component/vim/*`, `cli/cmd/tui/component/prompt/index.tsx`, `cli/cmd/tui/app.tsx`, `cli/cmd/tui/config/tui-schema.ts`
- **Tool fix**: `session/message-v2.ts`, `test/session/message-v2.test.ts`
- **MCP reconnect**: `mcp/index.ts`
- **Eager input streaming**: `provider/transform.ts` (different region from caching -- inserts a single `toolStreaming = false` block at the end of `options()`)

The files touched by more than one patch are `provider/transform.ts` (caching + eager-input-streaming) and `session/prompt.ts` (caching + prompt-loop-cache + cache-aligned-compaction). The overlapping patches modify disjoint regions and apply cleanly in the documented order.

## Patch Ownership

Each patch is owned by a specific repo. Do not edit a patch in the wrong repo.

| Patch | Owned by | Upstream PR guide |
|-------|----------|-------------------|
| `caching.patch` | [opencode-cached](https://github.com/johnnymo87/opencode-cached) (`patches/caching.patch`) | PR #5422 |
| `prompt-loop-cache.patch` | **this repo** (`patches/prompt-loop-cache.patch`) | PR #25367 |
| `cache-aligned-compaction.patch` | **this repo** (`patches/cache-aligned-compaction.patch`) | PR #25100 |
| `gemini-empty-parts.patch` | **this repo** (`patches/gemini-empty-parts.patch`) | PR #28669 |
| `vim.patch` | **this repo** (`patches/vim.patch`) | PR #12679 |
| `tool-fix.patch` | **this repo** (`patches/tool-fix.patch`) | PR #16751 |
| `mcp-reconnect.patch` | **this repo** (`patches/mcp-reconnect.patch`) | Issue #15247 |
| `eager-input-streaming.patch` | **this repo** (`patches/eager-input-streaming.patch`) | Issue #23541 / PR #23766 (rejected upstream) |

When an upstream PR is merged, the corresponding patch can be dropped. `caching.patch` is
managed in the sibling repo `~/projects/opencode-cached`; edits belong there, not here.

## Maintenance

### When the Caching Patch Breaks (Build Failure)

This is handled by [opencode-cached](https://github.com/johnnymo87/opencode-cached). If the caching patch fails on a new upstream version, opencode-cached won't release, and this repo won't attempt a build.

To refresh: edit `~/projects/opencode-cached/patches/caching.patch` (not this repo).

### When the Prompt-Loop Cache Patch Breaks (Build Failure)

The build fails and creates a GitHub issue automatically. This blocks publication.

Use PR [#25367](https://github.com/anomalyco/opencode/pull/25367) as the behavioral guide when refreshing. The patch should preserve prompt-loop message byte identity across tool-call continuations while forcing full reloads after compaction, subtasks, and overflow recovery.

1. Check whether upstream already has the fix; if yes, remove `patches/prompt-loop-cache.patch` and update `patches/apply.sh`
2. If the fix is absent, regenerate from the PR: `gh pr diff 25367 --repo anomalyco/opencode > patches/prompt-loop-cache.patch`
3. Review, commit, push
4. Re-trigger: `gh workflow run build-release.yml --field version=X.Y.Z`

### When the Cache-Aligned Compaction Patch Breaks (Build Failure)

The build fails and creates a GitHub issue automatically. This blocks publication.

Maintenance note: refresh from PR #25100 if it drifts; drop when upstream includes it. Use PR [#25100](https://github.com/anomalyco/opencode/pull/25100) as the behavioral guide. The patch should align compaction requests with normal prompt-loop context.

1. Check whether upstream already has the fix; if yes, remove `patches/cache-aligned-compaction.patch` and update `patches/apply.sh`
2. If the fix is absent, regenerate from the PR: `gh pr diff 25100 --repo anomalyco/opencode > patches/cache-aligned-compaction.patch`
3. Review, commit, push
4. Re-trigger: `gh workflow run build-release.yml --field version=X.Y.Z`

### When the Gemini Empty Parts Patch Breaks (Build Failure)

The build fails and creates a GitHub issue automatically. This blocks publication.

The patch has **two hunks on two code paths** (see section 4 above); a refresh
must keep both unless upstream has fixed the corresponding path.

- **`packages/llm/src/protocols/gemini.ts`** (native runtime): use PR
  [#28669](https://github.com/anomalyco/opencode/pull/28669) as the behavioral
  guide. Pads empty user/assistant/tool messages with an empty-string text part.
- **`packages/opencode/src/provider/transform.ts`** (AI SDK runtime, the path
  Gemini actually uses): a `@ai-sdk/google` / `@ai-sdk/google-vertex` block in
  `normalizeMessages()` that drops empty text/reasoning parts and resulting-empty
  messages, mirroring the sibling `@ai-sdk/anthropic` / `@ai-sdk/amazon-bedrock`
  blocks. Tracked by Issue [#17519](https://github.com/anomalyco/opencode/issues/17519).
  Behavioral check: run `bun test test/provider/transform.test.ts -t "gemini empty parts"`
  from `packages/opencode`.

1. Check whether upstream already handles empty Gemini parts on **both** paths.
2. If a path is fixed upstream: drop that hunk; if both are fixed, remove
   `patches/gemini-empty-parts.patch` and update `patches/apply.sh`.
3. If absent: refresh the failing hunk (regenerate the `packages/llm` hunk from
   PR #28669, keep the empty tool-message regression coverage; re-derive the
   `transform.ts` hunk against the post-cache-aligned-compaction baseline).
4. Review, commit, push.
5. Re-trigger: `gh workflow run build-release.yml --field version=X.Y.Z`

### When the Vim Patch Breaks (Build Failure)

The build fails and creates a GitHub issue automatically. This blocks publication.

Use PR [#12679](https://github.com/anomalyco/opencode/pull/12679) as the behavioral guide when rebasing: the PR defines the intended vim motions and config surface. Port only behavior still missing upstream; drop anything already present.

1. Fetch the PR as a behavioral reference: `gh pr diff 12679 --repo anomalyco/opencode > /tmp/vim-pr-12679.patch`
2. Rebase `patches/vim.patch` onto the new upstream, using the PR diff as the source of truth for intended behavior
3. Review, commit, push
4. Re-trigger: `gh workflow run build-release.yml --field version=X.Y.Z`

### When the Vim PR Drifts (Review Signal, Not Breakage)

`sync-vim-pr.yml` checks every 8 hours whether PR #12679's raw diff matches `patches/vim.patch`.
If the hashes differ, it opens a GitHub issue labeled `patch-drift`.

**Drift does not mean the build is broken.** The build continues to use the committed
`patches/vim.patch` as-is. The build/release workflow is the source of truth for whether
publication is blocked. The drift issue is a prompt to review what changed upstream and
decide whether to adopt it.

### When the Tool Fix Patch Breaks (Build Failure)

The build fails and creates a GitHub issue automatically. This blocks publication.

Use PR [#16751](https://github.com/anomalyco/opencode/pull/16751) as the behavioral guide when refreshing. If the upstream release already includes the fix (verify by running the regression test), **drop `patches/tool-fix.patch` entirely** rather than refreshing it.

1. Check whether upstream already has the fix: run the regression test from PR #16751 against a plain upstream checkout
2. If fix is present upstream: remove `patches/tool-fix.patch` and update `patches/apply.sh`
3. If fix is absent: regenerate from the PR: `gh pr diff 16751 --repo anomalyco/opencode > patches/tool-fix.patch`
4. Review, commit, push
5. Re-trigger: `gh workflow run build-release.yml --field version=X.Y.Z`

### When the Tool Fix PR Drifts (Review Signal, Not Breakage)

`sync-tool-fix-pr.yml` checks every 8 hours whether PR #16751's raw diff matches `patches/tool-fix.patch`.
If the hashes differ, it opens a GitHub issue labeled `patch-drift`.

**Drift does not mean the build is broken.** The build continues to use the committed
`patches/tool-fix.patch` as-is. The build/release workflow is the source of truth for whether
publication is blocked. The drift issue is a prompt to review what changed upstream and
decide whether to adopt it.

### When the MCP Reconnect Patch Breaks (Build Failure)

The build fails and creates a GitHub issue automatically. This blocks publication.

1. Review the upstream changes to `packages/opencode/src/mcp/index.ts`
2. Regenerate or manually update `patches/mcp-reconnect.patch`
3. Review, commit, push
4. Re-trigger: `gh workflow run build-release.yml --field version=X.Y.Z`

**Sunset**: This patch can be dropped when [issue #15247](https://github.com/anomalyco/opencode/issues/15247) is resolved upstream. Unlike the other patches, this one has no upstream PR to track -- it is original work. If an upstream PR appears, add a sync workflow for it.

### When the Eager Input Streaming Patch Breaks (Build Failure)

The build fails and creates a GitHub issue automatically. This blocks publication.

1. Review the upstream changes to `packages/opencode/src/provider/transform.ts`. The patch inserts a small `toolStreaming = false` block at the end of `ProviderTransform.options()` -- look for where the function returns `result` and re-add the block before it.
2. Regenerate or manually update `patches/eager-input-streaming.patch`
3. Review, commit, push
4. Re-trigger: `gh workflow run build-release.yml --field version=X.Y.Z`

**Sunset**: This patch can be dropped if upstream merges a generalized fix that defaults `toolStreaming = false` for all `@ai-sdk/anthropic`-backed providers (not just `github-copilot`). Track [issue #23541](https://github.com/anomalyco/opencode/issues/23541), [#23257](https://github.com/anomalyco/opencode/issues/23257), and [#23767](https://github.com/anomalyco/opencode/issues/23767). Note: the obvious upstream fixes ([PR #23766](https://github.com/anomalyco/opencode/pull/23766), [#23542](https://github.com/anomalyco/opencode/pull/23542)) were rejected by maintainers, so this patch may need to live indefinitely.

### Sunset Criteria

Monthly automated check (`check-sunset.yml`) monitors all upstream PRs:
- **Any PR merged**: Drop the corresponding patch from `apply.sh`
- **All merged**: Switch workstation to upstream OpenCode, archive this repo and opencode-cached

## Credits

- **OpenCode**: [anomalyco/opencode](https://github.com/anomalyco/opencode)
- **Caching PR**: [PR #5422](https://github.com/anomalyco/opencode/pull/5422) by [@ormandj](https://github.com/ormandj)
- **Caching builds**: [opencode-cached](https://github.com/johnnymo87/opencode-cached)
- **Prompt-loop cache PR**: [PR #25367](https://github.com/anomalyco/opencode/pull/25367) by [@BYK](https://github.com/BYK)
- **Cache-aligned compaction PR**: [PR #25100](https://github.com/anomalyco/opencode/pull/25100)
- **Gemini empty parts PR**: [PR #28669](https://github.com/anomalyco/opencode/pull/28669)
- **Vim PR**: [PR #12679](https://github.com/anomalyco/opencode/pull/12679) by [@leohenon](https://github.com/leohenon)
- **Tool fix PR**: [PR #16751](https://github.com/anomalyco/opencode/pull/16751) by [@altendky](https://github.com/altendky)
- **MCP reconnect**: [Issue #15247](https://github.com/anomalyco/opencode/issues/15247) -- original patch
- **Eager input streaming workaround**: [Issue #23541](https://github.com/anomalyco/opencode/issues/23541) -- original patch (upstream fixes rejected)

## License

MIT (same as upstream OpenCode)
