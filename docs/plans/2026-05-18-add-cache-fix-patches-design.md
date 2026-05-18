# Design: Add three prompt-cache cost-reduction patches to opencode-patched

> **For Claude:** This is the **design** doc. The companion execution plan is
> `2026-05-18-add-cache-fix-patches-plan.md` (write that next).
> Workstation beads epic: `workstation-b4p`.
>
> Sub-beads (in dependency order):
> - `workstation-tbn` — Fetch + commit prompt-loop-cache.patch (PR #25367) [P1]
> - `workstation-7kn` — Build usage-logging plugin [P1, independent]
> - `workstation-z5b` — Fetch + commit cache-aligned-compaction.patch (PR #25100) [P2]
> - `workstation-0qg` — Fetch + commit system-prompt-split.patch (PR #27377) [P2]
> - `workstation-adw` — Cut v1.15.0-cached-pl release (blocked by tbn) [P1]
> - `workstation-qys` — Bump opencode-patched version in workstation home.base.nix (blocked by adw) [P1]
> - `workstation-y8m` — Re-measure cost on similar workload (blocked by qys) [P2]
> - `workstation-j7t` — Add sync-*-pr.yml drift-detection workflows [P3]

## TL;DR

A 28-minute Opus 4.7 session (`ses_1c70728a7ffeLlgL1FsKXdTQLu`) on
`google-vertex-anthropic` cost **$52.98** with no large output, no big new
file reads, ~170 turns of mostly Q&A and tool-result loops. ChatGPT
research (`/tmp/research-opencode-opus-cost-question.md` and answer) plus
direct DB analysis identified three distinct cost-leak vectors, each with an
unmerged upstream PR that addresses it. We're adding those three PRs to our
`opencode-patched` build pipeline, plus a small plugin to log raw provider
cache-creation token fields so we can settle one residual mystery.

## Cost forensics — what we saw

From `~/.local/share/opencode/opencode.db`, session
`ses_1c70728a7ffeLlgL1FsKXdTQLu`:

| Bucket | Tokens | Rate @Opus 4.7 5m | Cost |
|---|---|---|---|
| Uncached input | 2.21M | $5/MTok | $11.04 |
| Output | 62k | $25/MTok | $1.55 |
| Cache read | 22.92M | $0.50/MTok | $11.46 |
| Cache write (5m) | 1.75M | $6.25/MTok | $10.93 |
| **Predicted total** | | | **~$35** |
| **Actual total** | | | **$52.98** |
| **Unexplained delta** | | | **~$18** |

Three patterns drove the cost:

### Pattern A — Tool-loop tail accumulating uncached input (~$11 here)

For ~70 consecutive turns (02:56–03:03) `cache_read` was pinned flat at
exactly `178,350` tokens while uncached `input` ramped from 5k → 73k per
turn. Per-turn cost climbed from $0.10 → $0.95. This is the symptom from
[anomalyco/opencode#24841][24841]: between tool-call iterations,
`MessageV2.filterCompactedEffect()` reloads messages from the DB; tool parts
transition `pending` → `completed`; the same assistant message serializes
to different bytes; Anthropic prompt cache busts from that position
forward; the growing tail keeps paying base-input price every turn.

### Pattern B — Compaction at 2× write rate (~$15 here)

Six compaction-era messages (cost > $1) sum to $15.26 (29% of the
session). Backing out the implied cache_write rate gives ~$12.5/MTok —
2× Opus 4.7's 5-minute rate ($6.25). This is suspicious because:

1. Our `caching.patch` explicitly sets `ttl: "5m"` for
   `google-vertex-anthropic` (Vertex rejects the 1h `cache_control` shape
   from `@ai-sdk/anthropic` because the SDK doesn't auto-inject the
   `anthropic-beta: extended-cache-ttl-2025-04-11` header).
2. So either (a) the compaction code path bypasses our provider-config and
   sends 1h writes anyway, (b) opencode's cost estimator is wrong, (c)
   there's an undocumented Vertex pricing premium for compaction-shaped
   requests, or (d) something else we don't see.

[anomalyco/opencode#25100][25100] separately notes that compaction
currently builds a wholly different LLM request (empty system prompt, no
tools, filtered history) that misses the agent-loop's prefix cache
entirely — claiming ~90% compaction-cost reduction once aligned. Whether
or not the 2× rate is real, the compaction request is structurally wrong
for caching.

### Pattern C — Cross-session cold-start churn (not measured directly)

Our setup has ~250 lines of repo-level `AGENTS.md`, ~150 lines of
user-level `AGENTS.md`, ~50 skill markdown files, custom subagents,
plugins, and a swarm topology where multiple sessions run different
`cwd`s on the same machine. Anthropic hashes `tools → system → messages`
in prefix order; any change to an earlier block invalidates everything
after it. [anomalyco/opencode#27377][27377] documents that the system
prompt is currently one block, so dynamic content (env, project AGENTS.md)
invalidates the stable provider prompt. PR #14743's author measured 0%
→ 97.6% cache hit on first prompt in a new repo after the system split +
bash-tool-cwd removal + skill ordering fix.

## The three upstream PRs

All three are **OPEN, unmerged, no approving reviews** on
`anomalyco/opencode`. Same posture as PR #5422 (the caching feature
already in our `opencode-cached` fork) — high-value upstream work the
maintainer hasn't landed.

### [PR #25367][25367] — prompt-loop byte identity

- **Author:** BYK · **Branch:** `perf/session-prompt-cache`
- **Size:** +17/-1 lines, 2 files (`packages/app/vite.js`,
  `packages/opencode/src/session/prompt.ts`)
- **Closes:** #25366, fixes #24841

**What it does.** In the prompt loop, caches the conversation array
across iterations. Only does a full DB reload on first iteration, after
compaction, and after subtask/overflow recovery. On tool-call
continuations, appends only genuinely new messages.

**Why it matches our session.** Eliminates the byte-identity drift between
iterations. The "flat 178k cache_read + growing input" pattern goes away.

**Risk.** Low. Surgical change; explicitly preserves full reloads where
they're required for correctness. Author's own measurements: warm turns
went from `cache_read=614K, cache_write=1K` to maintaining that state
through tool continuations.

**v1.15.0 anchors.** The patch targets `session/prompt.ts` around line
1647 — needs verification that the anchor function `Object.entries(agent)...`
generator still exists at that surface in v1.15.0. The `vite.js` change
adds `"@opencode-ai/core"` alias — may or may not be needed depending on
v1.15.0's monorepo layout (probably skippable).

### [PR #25100][25100] — cache-aligned compaction

- **Author:** lloydzhou · **Branch:** `dev` (his fork's branch)
- **Size:** +177/-75 lines, 2 files (`session/compaction.ts`,
  `session/prompt.ts`)

**What it does.** Compaction currently builds its own LLM request with an
empty system prompt, no tools, and filtered history. Because the prefix
differs from the normal agent-loop prefix, historical messages miss the
provider cache and are charged at full input price. The PR aligns the
compaction request shape to the normal agent-loop prefix so the cached
prefix is reused. Claims ~90% compaction-cost reduction in the author's
example.

**Why it matches our session.** Directly targets the $15 (29% of session)
compaction burst.

**Risk.** Medium. Touches two of the most important files in the prompt
path. Need to verify no behavior regression on auto-compaction and
overflow-compaction paths.

**v1.15.0 anchors.** Will need verification. compaction.ts is touched by
many upstream commits; some line-number drift expected.

### [PR #27377 + #27378][27377] — system prompt split + cache stabilization (stacked)

- **Author:** martinffx · **Branch:** `feat/system-prompt-split`
- **Size:** #27377: +358/-54 lines, 9 files. (#27378 is the next layer
  in the stack with audit logging.)
- **Relationship to #14743:** #27377/#27378 are the cleaner, flag-gated,
  stacked-PR decomposition of the older monolithic #14743 by
  `bhagirathsinh-vaghela`. We prefer the stacked version.

**What it does.** Behind `OPENCODE_EXPERIMENTAL_SYSTEM_PROMPT_SPLIT`:

- `Instruction.system()` returns `{ global, project }` instead of flat array.
- `SystemPrompt.skills()` returns `{ global, project }` by scope.
- LLM layer sends two system messages: stable (global instructions +
  global skills + provider prompt) and dynamic (env + project skills +
  project instructions).

Behind `OPENCODE_EXPERIMENTAL_CACHE_STABILIZATION`:

- Caches `Instruction.system()` result for the process lifetime.
- Freezes `new Date().toDateString()` on first access.

**Why it matches our setup.** We have a large global+project AGENTS.md
and ~50 skills auto-discovered. Currently any per-turn drift in the
dynamic portion (e.g. env's process count, date rollover) re-encodes the
entire system block. Split lets the stable portion stay cached across
sessions.

**Risk.** Medium-low. Behavior is fully backwards-compatible when neither
flag is set. We can ship the patch but leave the flags off by default,
then enable them as a separate decision.

**Footgun for `CACHE_STABILIZATION=1`:** instruction file reads are
cached for process lifetime — editing AGENTS.md or skills mid-process
won't reflect until restart. We document this as a daemon-restart
discipline. Lower-risk for opencode-serve (long-lived daemon, infrequent
config edits), higher-risk for interactive sessions where you're actively
editing prompts.

## What we are NOT applying

- **PR #14743** — superseded by the cleaner #27377/#27378 stack.
- **PR #25366** — same root cause as #25367 but is the *issue*, not
  the fix.
- **`OPENCODE_EXPERIMENTAL_CACHE_1H_TTL`** — explicitly do NOT enable
  on Vertex globally. Our existing caching patch correctly forces 5m
  for `google-vertex-anthropic` because Vertex rejects the 1h
  `cache_control` shape from `@ai-sdk/anthropic`. Only revisit if/when
  the SDK auto-injects the `extended-cache-ttl-2025-04-11` beta header.
- **PR #23571 (MCP tool ordering)** — relevant to cross-restart cache
  stability but our session was within one process, so this didn't
  contribute to the observed cost.
- **PR #21518 (queued user message serialization)** — we don't queue
  messages in interactive sessions; not relevant to the observed shape.

## Out-of-band: usage-logging plugin

The 2× compaction write rate ($12.5/MTok vs published $6.25/$10/MTok)
remains unexplained. To distinguish:

- (a) opencode's cost estimator over-reporting (DB cost is wrong, no
  refund needed)
- (b) compaction code path bypasses provider-config and sends `ttl: "1h"`
  on the wire (real wire spend; the `CACHE_STABILIZATION` doc above is
  insufficient)
- (c) Vertex billing has a premium not on the public price page
- (d) opaque billable thinking tokens we don't see in
  `tokens_input/output/cache_*`

We need raw provider usage. Plan: a small opencode plugin
(`workstation/assets/opencode/plugins/cache-usage-logger.ts`) that
subscribes to the LLM-response hook and appends
`response.usage.cache_creation.ephemeral_5m_input_tokens`,
`ephemeral_1h_input_tokens`, `cache_read_input_tokens`, `input_tokens`,
`output_tokens` (plus provider, model, session_id, msg_id, timestamp)
to a JSONL file per session. After 24h of usage we should see
unambiguously whether compaction writes go to 5m or 1h on the wire.

This is decoupled from the patch work — independent bead `workstation-7kn`,
can ship in parallel. Plugin work runs in `workstation` repo, not
`opencode-patched`.

## Patch ordering in `apply.sh`

Current order (`opencode-patched/patches/apply.sh`):

1. `caching.patch` (fetched from opencode-cached)
2. `vim.patch`
3. `tool-fix.patch`
4. `mcp-reconnect.patch`
5. `eager-input-streaming.patch`
6. `prefill-fix.patch`
7. `messages-transform.patch`

**Question: where do the new patches go?**

Two natural homes:

- **opencode-cached** — these are all "caching-improvement PRs" like
  #5422 already there. Conceptually consistent. Means `opencode-cached`
  becomes a stack of all caching PRs.
- **opencode-patched** — easier to manage as separate patch files in the
  same place as our other PR-fetch patches.

**Decision: opencode-patched.** Rationale:

1. `opencode-cached`'s single `caching.patch` is a stable rebased
   version of one specific PR (#5422). Mixing in three more PRs muddies
   that contract.
2. We already have a pattern of per-PR patch files in `opencode-patched`
   (`tool-fix.patch`, `mcp-reconnect.patch`, `eager-input-streaming.patch`).
   These belong with them.
3. The `sync-*-pr.yml` drift-detection workflows already live in
   `opencode-patched`. Adding three more sync workflows next to the
   existing two keeps that pattern coherent.

New `apply.sh` order:

1. `caching.patch` (fetched from opencode-cached) ← unchanged
2. `prompt-loop-cache.patch` (NEW, PR #25367) ← apply early since it
   touches `session/prompt.ts`; subsequent patches touch the same file
3. `cache-aligned-compaction.patch` (NEW, PR #25100) ← touches
   `session/compaction.ts` + `session/prompt.ts`; apply after #25367
4. `system-prompt-split.patch` (NEW, PR #27377) ← touches many files
   including `session/prompt.ts`
5. `vim.patch` ← unchanged
6. `tool-fix.patch` ← unchanged
7. `mcp-reconnect.patch` ← unchanged
8. `eager-input-streaming.patch` ← unchanged
9. `prefill-fix.patch` ← unchanged
10. `messages-transform.patch` ← unchanged

The three new patches all touch `session/prompt.ts`. Order matters
because each patch's context lines must match the file state when it's
applied. Recommended: apply in the order **#25367 → #25100 → #27377**
because:

- #25367 is the smallest (17 lines) and most surgical;
- #25100 builds on the same prompt-loop surface;
- #27377 touches the widest surface so it goes last.

If conflicts arise, the design doc retro will need to record the
conflict-resolution decisions.

## Plan B if a patch doesn't apply cleanly

For each PR, the workflow is:

1. `gh pr diff <num> --repo anomalyco/opencode > patches/<name>.patch`
2. Test against `v1.15.0` source: `cd /tmp/opencode-v1.15.0 && git apply --check patches/<name>.patch`
3. If clean: commit, done.
4. If rejects: refresh anchors against v1.15.0 (the same pattern we used
   for the v1.15.0 refresh — see
   `2026-05-15-refresh-patch-stack-for-v1.15.0-design.md`). Mostly
   line-number drift and import-path drift; semantic conflicts are
   rare for these surgical patches.
5. If full file moved/redesigned (like prefill-fix needed for v1.15.0):
   escalate to a real redesign and write a dedicated design doc.

## Flag rollout strategy

`OPENCODE_EXPERIMENTAL_SYSTEM_PROMPT_SPLIT` and
`OPENCODE_EXPERIMENTAL_CACHE_STABILIZATION` from #27377/#27378 will
**not** be set by default. Plan:

1. Ship the patch with flags off. Behavior identical to today.
2. After 1 week of stability, enable `SYSTEM_PROMPT_SPLIT` via
   `home.sessionVariables` on cloudbox first (opencode-serve, daemon
   workload — high benefit, less churn).
3. After 1 week more, enable `CACHE_STABILIZATION` on cloudbox.
4. Once both are stable on cloudbox for 2 weeks, enable on devbox.
5. Document the "restart daemon after AGENTS.md edits" rule in
   `users/dev/home.base.nix` near the env var.

`OPENCODE_EXPERIMENTAL_CACHE_1H_TTL` stays OFF on Vertex, period.

## Measurement plan

After patches land + version bumped on cloudbox:

1. Run a similar workload to `ses_1c70728a7ffeLlgL1FsKXdTQLu` — Opus 4.7
   on the same provider, heavy tool use, ~30 min, includes a manual
   compaction.
2. Capture the new session id.
3. Run `oc-cost` for the day; cross-reference with the same query
   pattern used in this design doc.
4. Look specifically for:
   - **Disappearance of the flat-cache_read + growing-input pattern**
     (the diagnostic, not just total cost).
   - **Compaction cost change** — does the $15 burst become $1.50?
   - **Total cost delta** — does the $53 become ~$25?
5. Document in the retro section below.

## Open questions / risks

1. **Vertex compaction 2× rate.** Until the usage-logging plugin runs,
   we don't know if the 2× rate is real wire spend or estimator bug.
   The patch work proceeds regardless because #25100 fixes a different
   structural problem.

2. **PR #25367 vs. plugins.** The PR caches the message array in
   memory. Do our plugins (`opencode-beads`, `compaction-context.ts`,
   `messages-transform.patch`) mutate that array? If yes, they'd
   re-introduce byte-identity drift. Audit during execution.

3. **`messages-transform.patch` interaction.** Our own patch passes
   `sessionID` and `model` into the `messages.transform` plugin hook.
   PR #25367 changes how `msgs` is computed at the top of the loop;
   need to verify the transform hook still receives the right shape.

4. **Subagent/swarm interaction.** Our swarm topology spawns multiple
   sessions on the same machine. Each session has its own
   `OPENCODE_SESSION_ID` and its own prompt cache. #25367 caches *within*
   a session, so swarm should be unaffected. #27377 splits *system*
   prompt, which is shared across sessions — so splitting should help
   swarm cold-starts.

5. **Upstream drift.** Three open PRs may get updated by their authors
   before we ship. The `sync-*-pr.yml` drift-detection workflows
   (`workstation-j7t`, P3) eventually catch this. For the first ship
   we'll capture the diff at a specific git ref of each PR and note
   the ref in the patch file's leading comment.

## Retro (filled in after measurement, `workstation-y8m`)

> _To be filled in after the patches land and we run a comparable
> workload. Compare against baseline session `ses_1c70728a7ffeLlgL1FsKXdTQLu`
> ($52.98 / 28min)._

### Predicted vs actual cost

| Component | Baseline | Predicted post-patch | Actual post-patch |
|---|---|---|---|
| Uncached input | $11.04 | $2 (#25367 reduces tail churn) | _TBD_ |
| Cache write | $10.93 | similar (warm path same) | _TBD_ |
| Cache read | $11.46 | similar or higher (more hits) | _TBD_ |
| Compaction burst | $15.26 | $1.50 (#25100 ~90% cut) | _TBD_ |
| Output | $1.55 | similar | _TBD_ |
| **Total** | **$52.98** | **~$20** | _TBD_ |

### Pattern-disappearance diagnostic

- [ ] Flat-cache_read + growing-input pattern disappears
- [ ] Compaction messages priced at ≤$6.25/MTok cache_write
- [ ] Per-turn cost stays bounded (no $0.10 → $0.95 ramp)

### What we got wrong / unexpected findings

_TBD_

[24841]: https://github.com/anomalyco/opencode/issues/24841
[25100]: https://github.com/anomalyco/opencode/pull/25100
[25367]: https://github.com/anomalyco/opencode/pull/25367
[27377]: https://github.com/anomalyco/opencode/pull/27377
