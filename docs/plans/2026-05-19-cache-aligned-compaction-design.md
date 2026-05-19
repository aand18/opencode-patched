# Cache-Aligned Compaction Design

Date: 2026-05-19

## Decision

Ship `anomalyco/opencode#25100` as `patches/cache-aligned-compaction.patch`, on top of the already-added `prompt-loop-cache.patch` from #25367. Keep #27377 deferred.

## Why

Recent compaction rows prove compaction is uncached across providers:

- `openai/gpt-5.5` compaction rows show large uncached inputs with `cache.write=0` and mostly `cache.read=0`; OpenCode DB cost is currently zero, but that is accounting, not free compute.
- Opus compaction rows show the same uncached shape plus visible nominal cost.

The issue is therefore provider-independent: compaction builds a request shape that misses the normal agent-loop prefix cache.

## Approach

Add PR #25100 after #25367 in `patches/apply.sh`. The patch aligns compaction request construction to the normal prompt loop by passing the resolved prompt context into compaction and using that context when constructing the compaction LLM call.

The prior probe found two mechanical rejects against v1.15.0:

- `session/compaction.ts` import-block context drift.
- `session/prompt.ts` context collision with #25367's `needsFullReload = true` line.

Both are anchor refreshes, not semantic conflicts.

## Scope

In scope:

- Add `patches/cache-aligned-compaction.patch` captured from PR #25100 head `972380a75249b01a424010e8bc0453e15a3a14c2`.
- Refresh the two known rejects against `v1.15.0 + caching.patch + prompt-loop-cache.patch`.
- Wire patch order: `caching.patch -> prompt-loop-cache.patch -> cache-aligned-compaction.patch -> existing patches`.
- Update README patch docs.
- Verify full stack against fresh `anomalyco/opencode@v1.15.0`.

Out of scope:

- #27377 system prompt split.
- OpenAI/GPT-5.5 DB price accounting fix.
- Release publishing or workstation version bump.

## Success Criteria

- `patches/apply.sh` applies the complete stack cleanly to v1.15.0.
- README clearly documents cache-aligned compaction and its provider-independent rationale.
- Future measurement can check `message.data.mode = "compaction"` rows for increased `cache.read` and lower uncached input/cost.
