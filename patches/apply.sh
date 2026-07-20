#!/usr/bin/env bash
# Apply local patches to opencode source for the v1.18 release line.
# Usage: ./apply.sh <path-to-opencode-source>
#
# TARGET UPSTREAM: opencode v1.18.3
#
# PATCH SET (v1.18 line; rebased 2026-07-20 from the v1.17 line):
#   1. retry-cap.patch          (local)     - MAX_RETRIES=8 + backoff jitter (Vertex/Gemini runaway cure)
#   2. tool-fix.patch           (PR #16751) - synthetic step-start boundaries (tool_use/result mismatch)
#   3. step-end-diff-bound.patch (local)     - bound step-end summary diff to prevent CPU pin freeze
#   4. project-copy-debounce.patch (local)   - single-flight dedup + concurrency cap on ProjectCopy.refresh
#   5. bootstrap-disposed-filter.patch (local) - filter+debounce TUI disposed storm
#   6. available-cache.patch    (local)     - herd-collapse cache for CatalogV2 provider/model availability
#   7. compaction-bounded-load.patch (local) - bound prompt loop message load to compaction window
#   8. sqlite-foreign-key-wrap.patch (local) - catch nested/wrapped FK constraints on modern error wrappers
#
# DROPPED patches:
#   - prompt-loop-cache.patch (#25367) + cache-aligned-compaction.patch (#25100):
#     upstream dropped, pending measured cache-economics pass on v1.17+
#   - gemini-empty-parts.patch: user requested removal
#   - vim.patch: user requested removal
#   - mcp-reconnect.patch: v1.17+ MCP is OAuth-aware, patch bypasses OAuth (incompatible)
#   - instance-state-partition.patch: instance-layer.ts deleted in v1.18, fixed upstream differently
#   - cache-thinking-skip.patch: transform.ts heavily rewritten in v1.18, needs manual rebase later
#   - eager-input-streaming.patch: upstream-merged (PRs #23223, #24573, #24642)
#   - prefill-fix.patch: upstream-merged (commit 69910f361, PR #29640)
#   - caching.patch: dropped by upstream (opencode-cached PR #5422)

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Error: Missing argument"
  echo "Usage: $0 <path-to-opencode-source>"
  exit 1
fi

SOURCE_DIR="$1"
SCRIPT_DIR="$(dirname "$0")"

PATCH_NAMES=(
  retry-cap
  tool-fix
  step-end-diff-bound
  project-copy-debounce
  bootstrap-disposed-filter
  available-cache
  compaction-bounded-load
  sqlite-foreign-key-wrap
)

if [ ! -d "$SOURCE_DIR" ]; then
  echo "Error: Source directory not found: $SOURCE_DIR"
  exit 1
fi

# Validate patch files exist before applying
for name in "${PATCH_NAMES[@]}"; do
  patch="$SCRIPT_DIR/${name}.patch"
  if [ ! -f "$patch" ]; then
    echo "Error: Patch file not found: $patch"
    exit 1
  fi
done

cd "$SOURCE_DIR"

for name in "${PATCH_NAMES[@]}"; do
  patch="$SCRIPT_DIR/${name}.patch"
  echo "Applying ${name}.patch..."
  if ! git apply --check "$patch" 2>/dev/null; then
    echo ""
    echo "❌ ${name} PATCH FAILED TO APPLY"
    echo ""
    echo "Attempting to apply for diagnostics..."
    git apply "$patch" 2>&1 || true
    echo ""
    echo "The ${name} patch may need updating for this upstream version."
    exit 1
  fi

  git apply "$patch"
  echo "✓ ${name} patch applied"
done

# --- Summary ---

echo ""
echo "✓ All patches applied successfully"
echo ""
echo "Files modified:"
git status --short
