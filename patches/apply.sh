#!/usr/bin/env bash
# Apply local patches to opencode source for the v1.18 release line.
# Usage: ./apply.sh <path-to-opencode-source>
#
# TARGET UPSTREAM: opencode v1.18.21
#
# PATCH SET (v1.18 line; rebased 2026-07-20 from the v1.17 line,
# rolled forward v1.18.3 -> v1.18.15 on 2026-08-09 -> v1.18.21 on 2026-08-23,
# then aligned 2026-08-23 to johnnymo87/opencode-patched upstream/main @ 853da6382
# (v1.18.18, 27 active) — adopt parent's new patches, drop divergences except
# user-requested exclusions; + sse-heartbeat-4s added 2026-08-27,
# + ui-asset-compression-cache added 2026-08-28 (31 total)):
#   1. tool-fix.patch           (PR #16751) - synthetic step-start boundaries (tool_use/result mismatch)
#   2. cache-thinking-skip.patch (#17883)    - cache breakpoints scan past trailing thinking/reasoning blocks
#   3. sqlite-foreign-key-wrap.patch (local) - catch nested/wrapped FK constraints on modern error wrappers
#   4. event-session-scope.patch  (local)   - optional ?session_ids=a,b,c filter on GET /event (pool-of-K serves)
#   5. event-cold-start-directory.patch (local) - fix cold-start live-delivery race; MUST apply after
#       event-session-scope (session-aggregate membership, no directory-equality match)
#   6. createnext-readback.patch (local)    - Session.createNext reads durable row back after Created
#   7. serve-lease.patch        (local)     - serve-side session-lease participation (routing-lease.ts CAS,
#       worker-thread heartbeat, fenced run-loop wrap; OPENCODE_ROUTING_DB-gated)
#   8. attach-route-resolve.patch (local)   - pool-aware `opencode attach` (parseServeUrl/resolveServeUrl)
#       + per-attempt SSE teardown (connection/listener leak fix)
#   9. bootstrap-disposed-filter.patch (local) - filter+debounce TUI disposed storm
#   10. project-copy-debounce.patch (local)  - single-flight dedup + concurrency cap on ProjectCopy.refresh
#   11. step-end-diff-bound.patch (local)    - bound step-end summary diff to prevent CPU pin freeze
#   12. globalbus-maxlisteners.patch (local) - uncap GlobalBus listener ceiling
#   13. event-log-gate.patch     (local)     - gate durable event log behind OPENCODE_EXPERIMENTAL_WORKSPACES
#   14. compaction-bounded-load.patch (local) - bound prompt loop message load to compaction window
#   15. available-cache.patch    (local)     - herd-collapse cache for CatalogV2 provider/model availability
#   16. session-door-routes.patch (local)    - Phase 8: ?session_ids= query field on event.subscribe schema
#       (else HttpApi 400s) + session-scoped permission/question routes
#   17. tui-door-attach.patch   (local, parent) - Phase 8 front-door TUI: session-scoped /event?session_ids=,
#       door-owned REST, drop pigeon /route self-resolve; MUST apply after attach-route-resolve
#   18. tui-door-tests.patch     (local)     - client contract test for session-scoped door SDK
#   19. session-mcp-routes.patch (local)     - session-scoped MCP status/connect/disconnect routes;
#       MUST apply after session-door-routes
#   20. tui-mcp-dialog.patch     (local)     - MCP status/connect/disconnect dialog UI
#   21. tui-reconcile-bound.patch (local, parent) - bound TUI pending-reconcile (workstation-fdb1): swallow
#       persistent failures after N=3, proceed degraded, slow-cadence retry; MUST apply last (diffs full stack)
#   22. registry-port-fence.patch (local)    - PID fence on serve pool slots + identity-fenced markDead;
#       MUST apply after serve-lease (extends routing-lease.ts)
#   23. plugin-loader-observability.patch (local) - structured plugin load-failure logging (missing/error/success)
#   24. message-serve-provenance.patch (local, parent) - stamp serve provenance on assistant rows (workstation-63wo);
#       MUST apply after sqlite-foreign-key-wrap (disjoint hunks in projector.ts)
#   25. db-isolation-guard.patch (local, parent) - refuse to open DB when XDG_DATA_HOME isolation is requested
#       but OPENCODE_DB points outside it (incident 2026-08-14); order-independent
#   26. vcs-untracked-normal.patch    (local) - respect .gitignore for untracked files, prevent VCS crash on large repos
#       (parent does not carry; kept as local safety — upstream #33928/#21699/#3176 still present at v1.18.21)
#   27. revert-orphan-parents.patch  (local) - reparent orphaned assistant messages after /undo revert cleanup (upstream #38864)
#       (parent does not carry; kept as local safety — still useful at v1.18.21)
#   28. status-popover-widen.patch   (local) - widen status popover 360px -> 600px so plugin/MCP identifiers
#       are not truncated to their URL/path prefix (informative name is at the end); order-independent
#       Sizing basis: 7 real specifiers measured at text-14-regular = 372-474px (longest: git URL); 600px
#       leaves ~120px headroom, >=530px is the floor. Width is duplicated in SIX places and must stay in
#       sync (else 360->600 jump on lazy-load / narrow V2): status-popover.tsx old-layout + V2 popover
#       classes + 2 Suspense fallbacks, status-popover-body.tsx 2 body containers. Placement bottom-end +
#       shift -168 stays anchored (panel extends left). ALL SIX sites carry max-w-[calc(100vw-40px)]
#       (not just the 2 outer popover classes) -- the 4 inner ones (2 Suspense fallbacks + 2 body containers)
#       were previously uncapped: on a 390px viewport the 600px inner overflowed 242px (right edge 632 ->
#       382 after the cap), cutting the plugin list + version chevrons off the right edge.
#       Rejected: break-words (URLs have no spaces -> overflow), break-all (2 lines per entry -> list 2x
#       taller), name-extraction (changes displayed content, loses the path).
#   29. plugin-outdated-indicator.patch (local) - plugin version/outdated indicator: GET /plugin route
#       (PluginInfo node + pluginHandlers wired in server.ts), isOutdated = semver.lt(installed, latest-stable),
#       and a status-popover plugin tab. SDK is a TARGETED v2 addition (Plugin class + 12 Plugin* types incl.
#       PluginError, getter, 4 imports), NOT a full regen -- full regen restructures Session2 and drops #19's
#       mcpStatus/mcpConnect additions -> TUI typecheck errors. MUST follow #28 (its status-popover-body.tsx context includes #28's capped body-root div).
#   30. sse-heartbeat-4s.patch     (local)     - lower SSE heartbeat tick 10s -> 4s (prevents WSL2 NAT
#       idle-kill of idle SSE streams). WHY (evidence-derived, not guessed): the Windows-side WSL2
#       NAT forwarder kills SILENT SSE in ~5-10 s — pre-patch kills landed at 10/10/10/11/20/30 s
#       (all multiples of the old tick) while 2/3/5 s-interval control streams survived 90-120 s
#       through the same Windows path. 4 s sits below the whole observed band with margin on both
#       sides (5-s data survived 90 s; 10-s data died). Revisit if a Windows/WSL update shifts the
#       timeout. Verified post-ship (findings doc PS3/PS4): 4 s cadence on the wire (gaps
#       2.82-4.01 s), fake 4-s SSE survived 60 s on a clean port while 10-s died, fresh-tab
#       /global/event alive 168 s+ end-to-end, zero reconnects in 9.4 min. Cost ~100 B per event
#       (~90 KB/h per connection); client-safe (no app/SDK code consumes server.heartbeat; one
#       deliberate no-op in control-plane workspace.ts:399). Scope: fixes ONLY the idle-kill class
#       — NOT clogged-path kills (<4 s), zombie/one-sided-kill detection, mid-transfer truncation,
#       or burst-race drops (2026-08-28 doc). Full evidence:
#       docs/plans/2026-08-27-sse-wsl2-nat-idle-kill-findings.md
#       Shared file handlers/event.ts with event-session-scope (#4) and event-cold-start-directory
#       (#5), disjoint hunks (heartbeat line sits below both patches' regions) -> MUST apply after #5
#   31. ui-asset-compression-cache.patch (local) - gzip-eligible body + cache-control on embedded UI
#       assets. Fixes: catch-all served via HttpServerResponse.raw (body _tag "Raw"), which the
#       compression middleware (httpapi middleware compression.ts:41) declines -> 2.7 MB index-*.js
#       bundle transferred uncompressed, and no cache-control on any embedded asset (full re-fetch
#       on every reload). Switches the body to HttpServerResponse.uint8Array(body, { headers })
#       (contentType flows from headers; passes every compression gate) and sets cache-control:
#       hashed assets/* -> "public, max-age=31536000, immutable", stable-named files (index.html,
#       manifest, icons, Inter.ttf, JetBrainsMonoNerdFontMono-Regular.woff2) -> "no-cache".
#       Hash rule verified against v1.18.21 dist: Vite's 8-char hashes use charset [A-Za-z0-9_-]
#       (hashes may contain - and _, e.g. B-XKn8Dv); the only stable-named assets/ files are
#       Inter.ttf and JetBrainsMonoNerdFontMono-Regular.woff2 (7-char "Regular" suffix -> correctly
#       no-cache); 934 of 952 embedded files come out immutable. Measured: index-KXP1iLE3.js
#       2,741,090 B -> 814,864 B gzipped (~3.4x). Layer offers gzip/deflate only (no br/zstd) and
#       gzips per request (no dist changes, no prebuilt .gz). Context: docs/plans/2026-08-28-wsl2-nat-
#       burst-stagger-proxy.md "Complementary server-side" section.
#       Order-independent (touches only shared/ui.ts; no other patch modifies it)
#
# DROPPED / EXCLUDED patches (aligned with upstream/main 2026-08-14 + user preference):
#   - retry-cap.patch: REMOVED to align with parent (upstreamed c78986831c in v1.18.17, MAX=5 stricter than local 8;
#     parent tombstone 4, do not re-litigate 5-vs-8). Verified at v1.18.21: RETRY_MAX_RETRIES=5 present.
#   - gemini-empty-parts.patch (PR #28669): USER-REQUESTED EXCLUSION (parent carries it; we drop per user preference)
#   - vim.patch (PR #12679): USER-REQUESTED EXCLUSION (parent carries it; we drop per user preference)
#   - opus5-adaptive-thinking.patch: USER-REQUESTED EXCLUSION (pay-to-play models; parent tombstone 24 upstreamed 2b2aacc939)
#   - prompt-loop-cache.patch (#25367) + cache-aligned-compaction.patch (#25100):
#     dropped by upstream, pending measured cache-economics pass
#   - mcp-reconnect.patch: v1.17+ MCP is OAuth-aware, patch bypasses OAuth (incompatible; upstream also removed it)
#   - instance-state-partition.patch: instance-layer.ts deleted in v1.18, fixed upstream differently (upstream also removed it)
#   - tui-follow-owner.patch: removed upstream (superseded by tui-door-attach, Phase 8)
#   - integration-list-batch.patch: removed upstream (v1.17.13 Integration.list does the bulk Map.groupBy natively)
#   - eager-input-streaming.patch: upstream-merged (PRs #23223, #24573, #24642)
#   - prefill-fix.patch: upstream-merged (commit 69910f361, PR #29640)
#   - caching.patch: dropped by upstream (opencode-cached PR #5422)
#   Dependency constraints: #9 after #4, #22 after #6, #19 after #16, #17 after #7, #21 last, #24 after #3, #30 after #5.

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Error: Missing argument"
  echo "Usage: $0 <path-to-opencode-source>"
  exit 1
fi

SOURCE_DIR="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PATCH_NAMES=(
  tool-fix
  cache-thinking-skip
  sqlite-foreign-key-wrap
  event-session-scope
  createnext-readback
  serve-lease
  attach-route-resolve
  bootstrap-disposed-filter
  event-cold-start-directory
  project-copy-debounce
  step-end-diff-bound
  globalbus-maxlisteners
  event-log-gate
  compaction-bounded-load
  available-cache
  session-door-routes
  tui-door-attach
  tui-door-tests
  session-mcp-routes
  tui-mcp-dialog
  tui-reconcile-bound
  registry-port-fence
  plugin-loader-observability
  message-serve-provenance
  db-isolation-guard
  vcs-untracked-normal
  revert-orphan-parents
  status-popover-widen
  plugin-outdated-indicator
  sse-heartbeat-4s
  ui-asset-compression-cache
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
