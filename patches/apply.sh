#!/usr/bin/env bash
# Apply caching + prompt-loop-cache + cache-aligned-compaction + gemini-empty-parts + vim + tool-fix + mcp-reconnect + eager-input-streaming + prefill-fix
# patches to opencode source.
# Usage: ./apply.sh <path-to-opencode-source>
#
# Fetches caching.patch from opencode-cached (never duplicated here),
# then applies local prompt-loop-cache.patch, cache-aligned-compaction.patch, gemini-empty-parts.patch,
# vim.patch, tool-fix.patch, mcp-reconnect.patch, eager-input-streaming.patch, and prefill-fix.patch on top.

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
EAGER_INPUT_STREAMING_PATCH="$SCRIPT_DIR/eager-input-streaming.patch"
PREFILL_FIX_PATCH="$SCRIPT_DIR/prefill-fix.patch"
CACHING_PATCH_URL="https://raw.githubusercontent.com/johnnymo87/opencode-cached/main/patches/caching.patch"

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

if [ ! -f "$EAGER_INPUT_STREAMING_PATCH" ]; then
  echo "Error: Eager input streaming patch not found: $EAGER_INPUT_STREAMING_PATCH"
  exit 1
fi

if [ ! -f "$PREFILL_FIX_PATCH" ]; then
  echo "Error: Prefill fix patch not found: $PREFILL_FIX_PATCH"
  exit 1
fi

cd "$SOURCE_DIR"

# --- Patch 1: Caching (fetched from opencode-cached) ---

echo "Fetching caching.patch from opencode-cached..."
CACHING_PATCH="/tmp/caching-$$.patch"
if ! curl -sfL "$CACHING_PATCH_URL" -o "$CACHING_PATCH"; then
  echo ""
  echo "❌ FAILED TO FETCH CACHING PATCH"
  echo "URL: $CACHING_PATCH_URL"
  echo ""
  echo "Check that opencode-cached repo is accessible and patches/caching.patch exists on main."
  rm -f "$CACHING_PATCH"
  exit 1
fi

echo "Applying caching.patch..."
if ! git apply --check "$CACHING_PATCH" 2>/dev/null; then
  echo ""
  echo "❌ CACHING PATCH FAILED TO APPLY"
  echo ""
  echo "Attempting to apply for diagnostics..."
  git apply "$CACHING_PATCH" 2>&1 || true
  echo ""
  echo "Failed files:"
  find . -name "*.rej" -type f 2>/dev/null || echo "  None found"
  echo ""
  echo "The caching patch (from opencode-cached) may need updating for this upstream version."
  echo "See: https://github.com/johnnymo87/opencode-cached"
  rm -f "$CACHING_PATCH"
  exit 1
fi

git apply "$CACHING_PATCH"
echo "✓ Caching patch applied"
rm -f "$CACHING_PATCH"

# --- Patch 2: Prompt-loop byte identity (PR #25367) ---

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

# --- Patch 3: Cache-aligned compaction (PR #25100) ---

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

# --- Patch 4: Gemini empty parts workaround (PR #28669) ---

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

# --- Patch 5: Vim keybindings (local) ---

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

# --- Patch 6: Tool use/result fix (local) ---

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

# --- Patch 7: MCP auto-reconnect (local) ---

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

# --- Patch 8: Eager input streaming workaround (local) ---

echo "Applying eager-input-streaming.patch..."
if ! git apply --check "$EAGER_INPUT_STREAMING_PATCH" 2>/dev/null; then
  echo ""
  echo "❌ EAGER INPUT STREAMING PATCH FAILED TO APPLY"
  echo ""
  echo "Attempting to apply for diagnostics..."
  git apply "$EAGER_INPUT_STREAMING_PATCH" 2>&1 || true
  echo ""
  echo "Failed files:"
  find . -name "*.rej" -type f 2>/dev/null || echo "  None found"
  echo ""
  echo "The eager input streaming patch may need updating for this upstream version."
  echo "Refs: anomalyco/opencode#23257, #23541, #23767"
  exit 1
fi

git apply "$EAGER_INPUT_STREAMING_PATCH"
echo "✓ Eager input streaming patch applied"

# --- Patch 9: Prefill race fix (rebind session routes to session.directory) ---

echo "Applying prefill-fix.patch..."
if ! git apply --check "$PREFILL_FIX_PATCH" 2>/dev/null; then
  echo ""
  echo "❌ PREFILL FIX PATCH FAILED TO APPLY"
  echo ""
  echo "Attempting to apply for diagnostics..."
  git apply "$PREFILL_FIX_PATCH" 2>&1 || true
  echo ""
  echo "Failed files:"
  find . -name "*.rej" -type f 2>/dev/null || echo "  None found"
  echo ""
  echo "The prefill fix patch may need updating for this upstream version."
  echo "Refs: workstation/docs/plans/2026-04-21-opencode-prefill-fix-design.md"
  exit 1
fi

git apply "$PREFILL_FIX_PATCH"
echo "✓ Prefill fix patch applied"

# --- Summary ---

echo ""
echo "✓ All patches applied successfully"
echo ""
echo "Files modified:"
git status --short
