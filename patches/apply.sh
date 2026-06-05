#!/usr/bin/env bash
# Apply prompt-loop-cache + cache-aligned-compaction + gemini-empty-parts + vim + tool-fix + mcp-reconnect + instance-state-partition + cache-thinking-skip
# patches to opencode source.
# Usage: ./apply.sh <path-to-opencode-source>
#
# Applies local prompt-loop-cache.patch, cache-aligned-compaction.patch, gemini-empty-parts.patch,
# vim.patch, tool-fix.patch, mcp-reconnect.patch,
# instance-state-partition.patch, and cache-thinking-skip.patch.
#
# NOTE (2026-06-02): the big caching.patch (formerly fetched from opencode-cached,
# PR #5422) was DROPPED. Upstream applyCaching already implements the moving-tail
# conversation anchor we cared about (`non-system.slice(-2)`), so the fork patch was
# redundant — and the fork's own unmerged variant had actually introduced an anchor
# regression. The ONLY caching-related behavior upstream lacks is skipping
# reasoning/thinking blocks when marking the cache breakpoint (Anthropic returns
# HTTP 400 if cache_control lands on a thinking block; anomalyco/opencode#17883),
# which is preserved here as the small local cache-thinking-skip.patch.
# See workstation docs/plans/2026-06-02-paring-back-opencode-cached-caching.md.
#
# TARGET UPSTREAM: opencode v1.16.0
# Patches were rebased from v1.15.13 to v1.16.0 on 2026-06-05 (the v1/v2 namespace
# migration: MessageV2 types -> SessionV1, Bus -> EventV2Bridge/events,
# AppFileSystem -> FSUtil, ProviderID/ModelID -> ProviderV2.ID/ModelV2.ID, plus
# prompt/index.tsx + AppLayer restructures). See
# docs/plans/2026-06-05-refresh-patch-stack-for-v1.16.0.md.
# eager-input-streaming.patch was DROPPED on 2026-06-05: v1.16.0's options()
# (provider/transform.ts) now sets toolStreaming=false for
# @ai-sdk/google-vertex/anthropic and non-claude @ai-sdk/anthropic upstream, which
# fully covers our usage; the patch is redundant.
# bus-eager-subscribe.patch (PR #27959) and bus instance context fix (PR #28051)
# were DROPPED because they are both upstream-merged in v1.15.5+.
# prefill-fix.patch was DROPPED on 2026-05-28 when this repo cut over to v1.15.12,
# because that release ships an equivalent upstream fix at workspace-routing.ts
# (release-notes line: "Used the persisted session directory for existing-session requests"):
# `directory: session?.directory || defaultDirectory(request, url)` in planRequest's
# Local plan construction closes the same multi-cwd race our patch did, via a smaller
# (collapsed-into-existing-field) implementation rather than threading a new
# sessionDirectory through RequestPlan.Local + WorkspaceRouteContext.
# instance-state-partition.patch (one-line server.ts memoMap fix + InstanceBootstrap
# refactor) is staged here for the upstream PR; sunset signal is the anomalyco/opencode
# PR being merged (tracked in check-sunset.yml).

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Error: Missing argument"
  echo "Usage: $0 <path-to-opencode-source>"
  exit 1
fi

SOURCE_DIR="$1"
SCRIPT_DIR="$(dirname "$0")"
PROMPT_LOOP_CACHE_PATCH="$SCRIPT_DIR/prompt-loop-cache.patch"
CACHE_ALIGNED_COMPACTION_PATCH="$SCRIPT_DIR/cache-aligned-compaction.patch"
GEMINI_EMPTY_PARTS_PATCH="$SCRIPT_DIR/gemini-empty-parts.patch"
VIM_PATCH="$SCRIPT_DIR/vim.patch"
TOOL_FIX_PATCH="$SCRIPT_DIR/tool-fix.patch"
MCP_RECONNECT_PATCH="$SCRIPT_DIR/mcp-reconnect.patch"
INSTANCE_STATE_PARTITION_PATCH="$SCRIPT_DIR/instance-state-partition.patch"
CACHE_THINKING_SKIP_PATCH="$SCRIPT_DIR/cache-thinking-skip.patch"

if [ ! -d "$SOURCE_DIR" ]; then
  echo "Error: Source directory not found: $SOURCE_DIR"
  exit 1
fi

if [ ! -f "$PROMPT_LOOP_CACHE_PATCH" ]; then
  echo "Error: Prompt-loop cache patch not found: $PROMPT_LOOP_CACHE_PATCH"
  exit 1
fi

if [ ! -f "$CACHE_ALIGNED_COMPACTION_PATCH" ]; then
  echo "Error: Cache aligned compaction patch not found: $CACHE_ALIGNED_COMPACTION_PATCH"
  exit 1
fi

if [ ! -f "$GEMINI_EMPTY_PARTS_PATCH" ]; then
  echo "Error: Gemini empty parts patch not found: $GEMINI_EMPTY_PARTS_PATCH"
  exit 1
fi

if [ ! -f "$VIM_PATCH" ]; then
  echo "Error: Vim patch not found: $VIM_PATCH"
  exit 1
fi

if [ ! -f "$TOOL_FIX_PATCH" ]; then
  echo "Error: Tool fix patch not found: $TOOL_FIX_PATCH"
  exit 1
fi

if [ ! -f "$MCP_RECONNECT_PATCH" ]; then
  echo "Error: MCP reconnect patch not found: $MCP_RECONNECT_PATCH"
  exit 1
fi

if [ ! -f "$INSTANCE_STATE_PARTITION_PATCH" ]; then
  echo "Error: Instance state partition patch not found: $INSTANCE_STATE_PARTITION_PATCH"
  exit 1
fi

if [ ! -f "$CACHE_THINKING_SKIP_PATCH" ]; then
  echo "Error: Cache thinking-skip patch not found: $CACHE_THINKING_SKIP_PATCH"
  exit 1
fi

cd "$SOURCE_DIR"

# --- Patch 1: Prompt-loop byte identity (PR #25367) ---

echo "Applying prompt-loop-cache.patch..."
if ! git apply --check "$PROMPT_LOOP_CACHE_PATCH" 2>/dev/null; then
  echo ""
  echo "❌ PROMPT LOOP CACHE PATCH FAILED TO APPLY"
  echo ""
  echo "Attempting to apply for diagnostics..."
  git apply "$PROMPT_LOOP_CACHE_PATCH" 2>&1 || true
  echo ""
  echo "Failed files:"
  find . -name "*.rej" -type f 2>/dev/null || echo "  None found"
  echo ""
  echo "The prompt-loop-cache patch may need updating for this upstream version."
  echo "Source PR: https://github.com/anomalyco/opencode/pull/25367"
  exit 1
fi

git apply "$PROMPT_LOOP_CACHE_PATCH"
echo "✓ Prompt-loop-cache patch applied"

# --- Patch 2: Cache-aligned compaction (PR #25100) ---

echo "Applying cache-aligned-compaction.patch..."
if ! git apply --check "$CACHE_ALIGNED_COMPACTION_PATCH" 2>/dev/null; then
  echo ""
  echo "❌ CACHE ALIGNED COMPACTION PATCH FAILED TO APPLY"
  echo ""
  echo "Attempting to apply for diagnostics..."
  git apply "$CACHE_ALIGNED_COMPACTION_PATCH" 2>&1 || true
  echo ""
  echo "Failed files:"
  find . -name "*.rej" -type f 2>/dev/null || echo "  None found"
  echo ""
  echo "The cache-aligned-compaction patch may need updating for this upstream version."
  echo "Source PR: https://github.com/anomalyco/opencode/pull/25100"
  exit 1
fi

git apply "$CACHE_ALIGNED_COMPACTION_PATCH"
echo "✓ Cache-aligned compaction patch applied"

# --- Patch 3: Gemini empty parts workaround (PR #28669) ---

echo "Applying gemini-empty-parts.patch..."
if ! git apply --check "$GEMINI_EMPTY_PARTS_PATCH" 2>/dev/null; then
  echo ""
  echo "❌ GEMINI EMPTY PARTS PATCH FAILED TO APPLY"
  echo ""
  echo "Attempting to apply for diagnostics..."
  git apply "$GEMINI_EMPTY_PARTS_PATCH" 2>&1 || true
  echo ""
  echo "Failed files:"
  find . -name "*.rej" -type f 2>/dev/null || echo "  None found"
  echo ""
  echo "The Gemini empty parts patch may need updating for this upstream version."
  echo "Source PR: https://github.com/anomalyco/opencode/pull/28669"
  exit 1
fi

git apply "$GEMINI_EMPTY_PARTS_PATCH"
echo "✓ Gemini empty parts patch applied"

# --- Patch 4: Vim keybindings (local) ---

echo "Applying vim.patch..."
if ! git apply --check "$VIM_PATCH" 2>/dev/null; then
  echo ""
  echo "❌ VIM PATCH FAILED TO APPLY"
  echo ""
  echo "Attempting to apply for diagnostics..."
  git apply "$VIM_PATCH" 2>&1 || true
  echo ""
  echo "Failed files:"
  find . -name "*.rej" -type f 2>/dev/null || echo "  None found"
  echo ""
  echo "The vim patch may need updating for this upstream version."
  echo "Source PR: https://github.com/anomalyco/opencode/pull/12679"
  exit 1
fi

git apply "$VIM_PATCH"
echo "✓ Vim patch applied"

# --- Patch 5: Tool use/result fix (local) ---

echo "Applying tool-fix.patch..."
if ! git apply --check "$TOOL_FIX_PATCH" 2>/dev/null; then
  echo ""
  echo "❌ TOOL FIX PATCH FAILED TO APPLY"
  echo ""
  echo "Attempting to apply for diagnostics..."
  git apply "$TOOL_FIX_PATCH" 2>&1 || true
  echo ""
  echo "Failed files:"
  find . -name "*.rej" -type f 2>/dev/null || echo "  None found"
  echo ""
  echo "The tool fix patch may need updating for this upstream version."
  echo "Source PR: https://github.com/anomalyco/opencode/pull/16751"
  exit 1
fi

git apply "$TOOL_FIX_PATCH"
echo "✓ Tool fix patch applied"

# --- Patch 6: MCP auto-reconnect (local) ---

echo "Applying mcp-reconnect.patch..."
if ! git apply --check "$MCP_RECONNECT_PATCH" 2>/dev/null; then
  echo ""
  echo "❌ MCP RECONNECT PATCH FAILED TO APPLY"
  echo ""
  echo "Attempting to apply for diagnostics..."
  git apply "$MCP_RECONNECT_PATCH" 2>&1 || true
  echo ""
  echo "Failed files:"
  find . -name "*.rej" -type f 2>/dev/null || echo "  None found"
  echo ""
  echo "The MCP reconnect patch may need updating for this upstream version."
  echo "Issue: https://github.com/anomalyco/opencode/issues/15247"
  exit 1
fi

git apply "$MCP_RECONNECT_PATCH"
echo "✓ MCP reconnect patch applied"

# --- Patch 7: InstanceStore partition fix (one-line server.ts memoMap + InstanceBootstrap refactor) ---

echo "Applying instance-state-partition.patch..."
if ! git apply --check "$INSTANCE_STATE_PARTITION_PATCH" 2>/dev/null; then
  echo ""
  echo "❌ INSTANCE STATE PARTITION PATCH FAILED TO APPLY"
  echo ""
  echo "Attempting to apply for diagnostics..."
  git apply "$INSTANCE_STATE_PARTITION_PATCH" 2>&1 || true
  echo ""
  echo "Failed files:"
  find . -name "*.rej" -type f 2>/dev/null || echo "  None found"
  echo ""
  echo "The instance-state-partition patch may need updating for this upstream version."
  echo "Refs: pigeon/docs/plans/2026-05-26-instancestate-partition-fix-design.md"
  echo "Upstream PR target: anomalyco/opencode (to be filed after burn-in)"
  exit 1
fi

git apply "$INSTANCE_STATE_PARTITION_PATCH"
echo "✓ Instance state partition patch applied"

# --- Patch 8: Cache thinking-skip (local; replaces dropped caching.patch) ---
# Upstream applyCaching marks msg.content[length-1] blindly, which can land a
# cache_control breakpoint on a trailing reasoning/thinking block -> Anthropic
# HTTP 400 (anomalyco/opencode#17883). This scans backwards to the last cacheable
# block instead. Sunset signal: upstream fix for #17883 merging.

echo "Applying cache-thinking-skip.patch..."
if ! git apply --check "$CACHE_THINKING_SKIP_PATCH" 2>/dev/null; then
  echo ""
  echo "❌ CACHE THINKING-SKIP PATCH FAILED TO APPLY"
  echo ""
  echo "Attempting to apply for diagnostics..."
  git apply "$CACHE_THINKING_SKIP_PATCH" 2>&1 || true
  echo ""
  echo "Failed files:"
  find . -name "*.rej" -type f 2>/dev/null || echo "  None found"
  echo ""
  echo "The cache-thinking-skip patch may need updating for this upstream version."
  echo "It targets applyCaching in provider/transform.ts. Issue: https://github.com/anomalyco/opencode/issues/17883"
  exit 1
fi

git apply "$CACHE_THINKING_SKIP_PATCH"
echo "✓ Cache thinking-skip patch applied"

# --- Summary ---

echo ""
echo "✓ All patches applied successfully"
echo ""
echo "Files modified:"
git status --short
