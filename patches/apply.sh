#!/usr/bin/env bash
# Apply prompt-loop-cache + cache-aligned-compaction + gemini-empty-parts + tool-fix + mcp-reconnect + instance-state-partition + cache-thinking-skip + retry-cap
# patches to opencode source.
# Usage: ./apply.sh <path-to-opencode-source>
#
# Applies local prompt-loop-cache.patch, cache-aligned-compaction.patch,
# gemini-empty-parts.patch, tool-fix.patch, mcp-reconnect.patch,
# instance-state-partition.patch, cache-thinking-skip.patch, and retry-cap.patch.
# vim.patch and caching.patch are SKIPPED (see inline comments).
#
# TARGET UPSTREAM: opencode v1.17.6
# Patches were rebased from v1.15.10 to v1.17.6 on 2026-06-14.
# eager-input-streaming.patch and prefill-fix.patch were DROPPED because they are
# both upstream-merged in v1.17.6+:
#   - eager-input-streaming: PRs #23223, #24573, #24642 (since v1.15.10)
#   - prefill-fix: commit 69910f361, PR #29640 (since v1.17.x)

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
RETRY_CAP_PATCH="$SCRIPT_DIR/retry-cap.patch"

if [ ! -d "$SOURCE_DIR" ]; then
  echo "Error: Source directory not found: $SOURCE_DIR"
  exit 1
fi

# Validate patch files exist before applying
PATCH_FILES=(
  "$PROMPT_LOOP_CACHE_PATCH"
  "$CACHE_ALIGNED_COMPACTION_PATCH"
  "$GEMINI_EMPTY_PARTS_PATCH"
  "$VIM_PATCH"
  "$TOOL_FIX_PATCH"
  "$MCP_RECONNECT_PATCH"
  "$INSTANCE_STATE_PARTITION_PATCH"
  "$CACHE_THINKING_SKIP_PATCH"
  "$RETRY_CAP_PATCH"
)
for pf in "${PATCH_FILES[@]}"; do
  if [ ! -f "$pf" ]; then
    echo "Error: Patch file not found: $pf"
    exit 1
  fi
done

cd "$SOURCE_DIR"

# --- Patch 1: Prompt loop cache ---

echo "Applying prompt-loop-cache.patch..."
if ! git apply --check "$PROMPT_LOOP_CACHE_PATCH" 2>/dev/null; then
  echo ""
  echo "❌ PROMPT LOOP CACHE PATCH FAILED TO APPLY"
  echo ""
  echo "Attempting to apply for diagnostics..."
  git apply "$PROMPT_LOOP_CACHE_PATCH" 2>&1 || true
  echo ""
  echo "The prompt-loop-cache patch may need updating for this upstream version."
  exit 1
fi

git apply "$PROMPT_LOOP_CACHE_PATCH"
echo "✓ Prompt loop cache patch applied"

# --- Patch 2: Cache-aligned compaction ---

echo "Applying cache-aligned-compaction.patch..."
if ! git apply --check "$CACHE_ALIGNED_COMPACTION_PATCH" 2>/dev/null; then
  echo ""
  echo "❌ CACHE-ALIGNED COMPACTION PATCH FAILED TO APPLY"
  echo ""
  echo "Attempting to apply for diagnostics..."
  git apply "$CACHE_ALIGNED_COMPACTION_PATCH" 2>&1 || true
  echo ""
  echo "The cache-aligned-compaction patch may need updating for this upstream version."
  exit 1
fi

git apply "$CACHE_ALIGNED_COMPACTION_PATCH"
echo "✓ Cache-aligned compaction patch applied"

# --- Patch 3: Gemini empty parts ---

echo "Applying gemini-empty-parts.patch..."
if ! git apply --check "$GEMINI_EMPTY_PARTS_PATCH" 2>/dev/null; then
  echo ""
  echo "❌ GEMINI EMPTY PARTS PATCH FAILED TO APPLY"
  echo ""
  echo "Attempting to apply for diagnostics..."
  git apply "$GEMINI_EMPTY_PARTS_PATCH" 2>&1 || true
  echo ""
  echo "The gemini-empty-parts patch may need updating for this upstream version."
  exit 1
fi

git apply "$GEMINI_EMPTY_PARTS_PATCH"
echo "✓ Gemini empty parts patch applied"

# --- Patch 4: Vim mode --- SKIPPED (TUI restructured in v1.17.6) ---
echo "Skipping vim.patch (TUI moved to packages/tui/, needs manual rebase)..."

# --- Patch 5: Tool fix ---

echo "Applying tool-fix.patch..."
if ! git apply --check "$TOOL_FIX_PATCH" 2>/dev/null; then
  echo ""
  echo "❌ TOOL FIX PATCH FAILED TO APPLY"
  echo ""
  echo "Attempting to apply for diagnostics..."
  git apply "$TOOL_FIX_PATCH" 2>&1 || true
  echo ""
  echo "The tool-fix patch may need updating for this upstream version."
  exit 1
fi

git apply "$TOOL_FIX_PATCH"
echo "✓ Tool fix patch applied"

# --- Patch 6: MCP reconnect ---

echo "Applying mcp-reconnect.patch..."
if ! git apply --check "$MCP_RECONNECT_PATCH" 2>/dev/null; then
  echo ""
  echo "❌ MCP RECONNECT PATCH FAILED TO APPLY"
  echo ""
  echo "Attempting to apply for diagnostics..."
  git apply "$MCP_RECONNECT_PATCH" 2>&1 || true
  echo ""
  echo "The mcp-reconnect patch may need updating for this upstream version."
  exit 1
fi

git apply "$MCP_RECONNECT_PATCH"
echo "✓ MCP reconnect patch applied"

# --- Patch 7: Instance state partition ---

echo "Applying instance-state-partition.patch..."
if ! git apply --check "$INSTANCE_STATE_PARTITION_PATCH" 2>/dev/null; then
  echo ""
  echo "❌ INSTANCE STATE PARTITION PATCH FAILED TO APPLY"
  echo ""
  echo "Attempting to apply for diagnostics..."
  git apply "$INSTANCE_STATE_PARTITION_PATCH" 2>&1 || true
  echo ""
  echo "The instance-state-partition patch may need updating for this upstream version."
  echo "Refs: pigeon/docs/plans/2026-05-26-instancestate-partition-fix-design.md"
  echo "Upstream PR target: anomalyco/opencode (to be filed after burn-in)"
  exit 1
fi

git apply "$INSTANCE_STATE_PARTITION_PATCH"
echo "✓ Instance state partition patch applied"

# --- Patch 8: Cache thinking skip ---

echo "Applying cache-thinking-skip.patch..."
if ! git apply --check "$CACHE_THINKING_SKIP_PATCH" 2>/dev/null; then
  echo ""
  echo "❌ CACHE-THINKING-SKIP PATCH FAILED TO APPLY"
  echo ""
  echo "Attempting to apply for diagnostics..."
  git apply "$CACHE_THINKING_SKIP_PATCH" 2>&1 || true
  echo ""
  echo "The cache-thinking-skip patch may need updating for this upstream version."
  exit 1
fi

git apply "$CACHE_THINKING_SKIP_PATCH"
echo "✓ Cache thinking skip patch applied"

# --- Patch 9: Retry cap ---

echo "Applying retry-cap.patch..."
if ! git apply --check "$RETRY_CAP_PATCH" 2>/dev/null; then
  echo ""
  echo "❌ RETRY-CAP PATCH FAILED TO APPLY"
  echo ""
  echo "Attempting to apply for diagnostics..."
  git apply "$RETRY_CAP_PATCH" 2>&1 || true
  echo ""
  echo "The retry-cap patch may need updating for this upstream version."
  exit 1
fi

git apply "$RETRY_CAP_PATCH"
echo "✓ Retry cap patch applied"

# --- Summary ---

echo ""
echo "✓ All patches applied successfully"
echo ""
echo "Files modified:"
git status --short
