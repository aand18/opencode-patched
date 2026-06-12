#!/usr/bin/env bash
# Apply local patches to opencode source for the v1.17 release line.
# Usage: ./apply.sh <path-to-opencode-source>
#
# TARGET UPSTREAM: opencode v1.17.2
#
# PATCH SET (v1.17 line, rebased 2026-06-11 from the v1.15 line):
#   1. gemini-empty-parts.patch   (PR #28669) - pad empty Gemini/Vertex parts arrays
#                                               (gemini.ts lowerMessages + transform.ts normalizeMessages)
#   2. tool-fix.patch             (PR #16751) - synthetic step-start boundaries (tool_use/result mismatch)
#   3. cache-thinking-skip.patch  (#17883)    - cache breakpoint scans past trailing thinking/reasoning blocks
#   4. retry-cap.patch            (local)     - MAX_RETRIES=8 + backoff jitter (Vertex/Gemini runaway cure)
#   5. instance-state-partition.patch (local) - share the process-global memoMap between the TCP
#                                               listener (server.ts startListener) and the in-process
#                                               webHandler/app-runtime, AND make InstanceLayer.layer a
#                                               stable reference (= InstanceStore.layer, bootstrap
#                                               injected externally) so the shared memoMap materializes
#                                               ONE InstanceStore.Service per directory. Fixes the
#                                               Question tool hang on submit (dual-instance: question
#                                               registered on one instance, reply routed to the other).
#                                               Re-ported to v1.17.2 2026-06-11 (re-verified the 1.17
#                                               listener still used Layer.makeMemoMapUnsafe()).
#   6. vim.patch                  (PR #12679) - vim keybindings, re-ported to the new
#                                               packages/tui/ TUI package for 1.17 (TUI moved
#                                               out of packages/opencode in 1.16/1.17).
#
# DROPPED on the v1.17 line (see workstation docs/plans/2026-06-11-opencode-1.17-cutover-runbook.md):
#   - prompt-loop-cache.patch (#25367) + cache-aligned-compaction.patch (#25100):
#     cost-cache optimizations that touch the rewritten event-sourced prompt.ts/compaction.ts.
#     Not redundant-by-upstreaming (1.17 still full-reloads each loop iteration), but dropped
#     pending a measured cache-economics pass on 1.17 (tracking-cache-costs skill) — whether they
#     still help on the rewritten loop is unknown, and a wrong cache patch silently burns money.
#   - eager-input-streaming.patch: SUPERSEDED by upstream. v1.17.2 transform.ts options() sets
#     toolStreaming=false for @ai-sdk/google-vertex/anthropic and non-claude @ai-sdk/anthropic
#     (better scoped than our patch, which also disabled it for first-party claude).
#   (instance-state-partition.patch was provisionally dropped at the 1.17 cutover on the theory
#    the new instance/HTTP layer made it moot — that theory was WRONG. v1.17.2 server.ts
#    startListener still used Layer.makeMemoMapUnsafe() and instance-layer.ts was byte-identical
#    to the buggy 1.15 pre-patch form, so the Question tool still hung on submit. Re-ported and
#    restored as patch #5 above on 2026-06-11. See workstation bead workstation-gwd.)
#   - mcp-reconnect.patch: 1.17 remote MCP connection is oauth-aware (McpOAuthProvider + SSE
#     fallback + connectTransport Effect); the patch's naive inline transport reconnect bypasses
#     oauth and can't call the Effect connect helpers from an async execute() without re-architecting
#     through EffectBridge. Deferred (QoL, not safety-critical).
#
# History (v1.15 line): the big caching.patch (opencode-cached PR #5422) was dropped 2026-06-02
# (upstream applyCaching does the moving-tail anchor); bus-eager-subscribe (#27959) + bus
# instance-context (#28051) dropped as upstream-merged in v1.15.5+; prefill-fix dropped at v1.15.12.

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Error: Missing argument"
  echo "Usage: $0 <path-to-opencode-source>"
  exit 1
fi

SOURCE_DIR="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -d "$SOURCE_DIR" ]; then
  echo "Error: Source directory not found: $SOURCE_DIR"
  exit 1
fi

cd "$SOURCE_DIR"

# Ordered patch list. Order matters where patches touch the same file:
# gemini-empty-parts and cache-thinking-skip both edit provider/transform.ts in
# disjoint regions, and gemini-empty-parts must apply first.
PATCHES=(
  gemini-empty-parts
  tool-fix
  cache-thinking-skip
  retry-cap
  instance-state-partition
  vim
)

for name in "${PATCHES[@]}"; do
  patch="$SCRIPT_DIR/$name.patch"
  if [ ! -f "$patch" ]; then
    echo "❌ Patch file not found: $patch"
    exit 1
  fi
  echo "Applying $name.patch..."
  if ! git apply --check "$patch" 2>/dev/null; then
    echo ""
    echo "❌ $name PATCH FAILED TO APPLY"
    echo ""
    echo "Attempting to apply for diagnostics..."
    git apply "$patch" 2>&1 || true
    echo ""
    echo "Failed files (.rej):"
    find . -name "*.rej" -type f 2>/dev/null || echo "  None found"
    echo ""
    echo "The $name patch may need updating for this upstream version."
    exit 1
  fi
  git apply "$patch"
  echo "✓ $name patch applied"
done

echo ""
echo "✓ All patches applied successfully"
echo ""
echo "Files modified:"
git status --short
