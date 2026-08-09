#!/usr/bin/env bash
# Apply local patches to opencode source for the v1.18 release line.
# Usage: ./apply.sh <path-to-opencode-source>
#
# TARGET UPSTREAM: opencode v1.18.15
#
# PATCH SET (v1.18 line; rebased 2026-07-20 from the v1.17 line,
# rolled forward v1.18.3 -> v1.18.15 on 2026-08-09;
# additions folded in 2026-08-09 from johnnymo87/opencode-patched upstream/main):
#   1. retry-cap.patch          (local)     - MAX_RETRIES=8 + backoff jitter (Vertex/Gemini runaway cure)
#   2. tool-fix.patch           (PR #16751) - synthetic step-start boundaries (tool_use/result mismatch)
#   3. cache-thinking-skip.patch (#17883)    - cache breakpoints scan past trailing thinking/reasoning blocks
#   4. step-end-diff-bound.patch (local)     - bound step-end summary diff to prevent CPU pin freeze
#   5. project-copy-debounce.patch (local)   - single-flight dedup + concurrency cap on ProjectCopy.refresh
#   6. bootstrap-disposed-filter.patch (local) - filter+debounce TUI disposed storm
#   7. available-cache.patch    (local)     - herd-collapse cache for CatalogV2 provider/model availability
#   8. compaction-bounded-load.patch (local) - bound prompt loop message load to compaction window
#   9. sqlite-foreign-key-wrap.patch (local) - catch nested/wrapped FK constraints on modern error wrappers
#   10. event-session-scope.patch  (local)   - optional ?session_ids=a,b,c filter on GET /event (pool-of-K serves)
#   11. event-cold-start-directory.patch (local) - fix cold-start live-delivery race; MUST apply after
#       event-session-scope (session-aggregate membership, no directory-equality match)
#   12. createnext-readback.patch (local)    - Session.createNext reads durable row back after Created
#   13. serve-lease.patch        (local)     - serve-side session-lease participation (routing-lease.ts CAS,
#       worker-thread heartbeat, fenced run-loop wrap; OPENCODE_ROUTING_DB-gated)
#   14. registry-port-fence.patch (local)    - PID fence on serve pool slots + identity-fenced markDead;
#       MUST apply after serve-lease (extends routing-lease.ts)
#   15. attach-route-resolve.patch (local)   - pool-aware `opencode attach` (parseServeUrl/resolveServeUrl)
#       + per-attempt SSE teardown (connection/listener leak fix)
#   16. globalbus-maxlisteners.patch (local) - uncap GlobalBus listener ceiling
#   17. event-log-gate.patch     (local)     - gate durable event log behind OPENCODE_EXPERIMENTAL_WORKSPACES
#   18. session-door-routes.patch (local)    - Phase 8: ?session_ids= query field on event.subscribe schema
#       (else HttpApi 400s) + session-scoped permission/question routes
#   19. session-mcp-routes.patch (local)     - session-scoped MCP status/connect/disconnect routes;
#       MUST apply after session-door-routes
#   20. tui-door-tests.patch     (local)     - client contract test for session-scoped door SDK
#   21. tui-mcp-dialog.patch     (local)     - MCP status/connect/disconnect dialog UI
#   22. plugin-loader-observability.patch (local) - structured plugin load-failure logging (missing/error/success)
#   23. vcs-untracked-normal.patch    (local) - respect .gitignore for untracked files, prevent VCS crash on large repos
#   24. revert-orphan-parents.patch  (local) - reparent orphaned assistant messages after /undo revert cleanup (upstream #38864)
#
# DROPPED patches (aligned with upstream/main 2026-08-09; reasons match upstream's own removals):
#   - prompt-loop-cache.patch (#25367) + cache-aligned-compaction.patch (#25100):
#     dropped by upstream, pending measured cache-economics pass
#   - gemini-empty-parts.patch: user requested removal (upstream still carries it)
#   - vim.patch: user requested removal (upstream still carries it)
#   - opus5-adaptive-thinking.patch: user requested removal (pay-to-play models)
#   - mcp-reconnect.patch: v1.17+ MCP is OAuth-aware, patch bypasses OAuth (incompatible;
#     upstream also removed it)
#   - instance-state-partition.patch: instance-layer.ts deleted in v1.18, fixed upstream
#     differently (upstream also removed it)
#   - tui-follow-owner.patch: removed upstream (superseded by tui-door-attach, Phase 8)
#   - integration-list-batch.patch: removed upstream (v1.17.13 Integration.list does the
#     bulk Map.groupBy natively)
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
  cache-thinking-skip
  step-end-diff-bound
  project-copy-debounce
  bootstrap-disposed-filter
  available-cache
  compaction-bounded-load
  sqlite-foreign-key-wrap
  event-session-scope
  event-cold-start-directory
  createnext-readback
  serve-lease
  registry-port-fence
  attach-route-resolve
  globalbus-maxlisteners
  event-log-gate
  session-door-routes
  session-mcp-routes
  tui-door-tests
  tui-mcp-dialog
  plugin-loader-observability
  vcs-untracked-normal
  revert-orphan-parents
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
