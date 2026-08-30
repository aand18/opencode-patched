# 2026-08-30 — Windows-native opencode: pros/cons research

Research doc (not a plan to execute). Question: should the opencode server run
natively on Windows instead of in WSL2, to bypass the WSL2 NAT forwarder
issues we keep patching around?

## Context: the documented WSL2 NAT problem classes (all measured, in this repo)

1. **SSE idle-kill** — `2026-08-27-sse-wsl2-nat-idle-kill-findings.md`. The
   Windows-side WSL2 NAT forwarder kills browser SSE streams that go quiet
   for ~5–10 s (jittery). opencode's 10 s heartbeat sat at the margin.
   **Fix shipped: patch #30 (4 s heartbeat), verified in prod.** Residuals:
   one-sided kills leave zombie ESTAB sockets; the forwarder's *per-port*
   state can clog (the :4096 clog survived server restarts — state lives in
   Windows svchost, cleared by stopping churn).
2. **Connection-burst SYN race** — `2026-08-28-wsl2-nat-burst-stagger-proxy.md`.
   The forwarder drops *simultaneous* SYNs to the same destination
   (browser per-origin burst of 6) → "Failed to reload" toasts (~1–2/6
   pre-fix). A staggered TCP reverse proxy on Windows (≥60 ms between
   upstream connects) is designed + reference-implemented in that doc and
   probe-verified (staggered dials: 6/6) but **NOT deployed** (verified
   2026-08-30: no proxy process on Windows; the `netsh portproxy` rule
   `0.0.0.0:4096 → 172.23.51.127:4096` is still the active forwarder).
   Partial mitigation in prod: patch #31 (2026-08-28, `Cache-Control:
   immutable` + gzip) stops warm reloads from re-bursting (hashed assets
   served from disk cache) — cold-load bursts can still race. Note: that
   doc's TL;DR line "Deployed to prod `:4096`" refers to patch #31, not the
   proxy — easy to misread.
3. **localhost-forward artifact** — Windows → `127.0.0.1:port` for a server
   bound *only* to 127.0.0.1 inside WSL: RST after ~2–3 s (different
   signature from the idle-kill). Avoided by 0.0.0.0 binds.
4. **Per-port state clogging** (see 1) — clogged forwarder ports behave
   badly until the Windows-side state clears; fresh ports are clean.

Host constraint: **Windows 10 Pro build 19045 (22H2)** — WSL2 *mirrored*
networking is Windows 11 22H2+ only, so the NAT cannot be switched off on
this machine.

## The option: opencode server natively on Windows

Browser → `127.0.0.1:4096` becomes a pure Windows loopback connection.
No WSL2 forwarder, no portproxy, no NAT dial in the browser path at all —
every class above (1–4) is eliminated *structurally*, not patched.

Feasibility notes:
- Upstream ships a native `opencode-windows-x64` binary + desktop `.exe`
  (scoop/choco). Upstream Windows support is a known-rough area: tracking
  issue anomalyco/opencode#631 ("windows support is lacking"), npm wrapper
  broken on Windows (#2447), bun install on Windows "in progress".
- Our patch stack is buildable for Windows in principle
  (`packages/opencode/script/build.ts` has a win32 target), but an unverified
  patch + build for `opencode-windows-x64` is real work (the Linux build is
  what we currently verify end-to-end).

## Pros

- **Browser path = pure localhost.** All four documented NAT failure classes
  gone by construction — including the burst race, whose staggered-proxy fix
  exists on paper but was never deployed (see context #2). No 4 s heartbeat
  needed on that path (could relax patch #30 later), no per-port forwarder
  state to clog.
- **Phone/LAN access direct** — server binds the Windows host's LAN IP; no
  portproxy rule, no forwarder in the path.
- **chrome-devtools MCP** would run in the same OS as the Windows Chrome
  under test (verify current cross-boundary setup before counting on this).
- **Standard localhost semantics** — none of the "bound to 127.0.0.1 only →
  RST" artifacts.

## Cons

- **Leaves the production Linux dev environment.** The repos live in
  `/home/dev` (WSL); a Windows-native opencode would reach them via
  `\\wsl.localhost\...` / VM IP — slow, with file-locking and path-separator
  friction. The entire AGENTS.md workflow (bash tool, `apply.sh`, bun
  install/build, sqlite backup) assumes Linux.
- **Linux-only MCP servers.** `engram` is a native Linux binary
  (`/home/dev/.local/bin/engram serve` + `mcp`); a Windows opencode would
  have to spawn it through WSL interop (`wsl.exe`), i.e. stdio-MCP across an
  OS boundary — unproven, flaky-prone, adds latency. (semble = uvx/python,
  cross-platform OK; context-mode = JS plugin OK.)
- **Inference is NOT "no NAT".** llama.cpp runs in Docker Desktop
  (`docker-desktop-user-distro`, nvidia/cuda images). Windows-native
  opencode → container goes through Docker Desktop's own VM port-publish
  (127.0.0.1) — standard and much stabler than the WSL2 forwarder, but a
  NAT-ish hop remains. Any service bound directly to the WSL VM IP breaks on
  WSL restart (VM IP churn).
- **Data directory split.** The 4.6 GB `~/.local/share/opencode/opencode.db`
  (WAL mode) cannot be shared across the OS boundary; a Windows instance
  gets its own `%APPDATA%` DB → duplicate session history, two stacks to
  keep in sync during/after transition.
- **Windows 10 22H2 is EOL** (driver/WSL updates stopped); the OS-side
  infrastructure we'd be depending on (Docker Desktop, WSL interop) gets no
  security fixes.
- **Unverified patched Windows build** + upstream rough edges (#631): the
  first Windows build of our 32-patch stack will surface unknowns (path
  handling, shell tool semantics, plugin loader, TUI assumptions).
- **EOL/patch discipline.** Windows worktrees are where CRLF noise is born
  (the very `eol=lf` pin we just committed repo-wide exists for this).
  Patch application from a Windows checkout stays a footgun even with
  `.gitattributes`.

## Cheaper alternatives (same goal, less cost)

1. **Status quo (recommended).** The idle-kill class is fixed in prod
   (patch #30, 4 s heartbeat, verified end-to-end). The burst class is *not*
   fixed in prod — the staggered proxy was designed and probe-verified but
   never deployed (2026-08-30 check: no proxy process, portproxy rule still
   active); patch #31's cache headers only stop warm-reload bursts. If
   "Failed to reload" toasts recur, deploy the proxy (design + reference
   impl ready in the 2026-08-28 doc — a cheap Windows-side process, no
   re-architecture). Residuals (zombie ESTAB sockets, rare per-port clog)
   are managed by observation, not architecture.
2. **Windows 11 22H2+ host** → `.wslconfig` `networkingMode=mirrored`.
   Host ↔ WSL then use `127.0.0.1` directly (no forwarder) and WSL becomes
   LAN-reachable — *the same structural fix as Windows-native, while
   keeping the server in the Linux dev environment.* Strictly better than
   option "Windows-native" if/when the host is upgraded. Currently blocked
   by the Win10 host.
3. **Browser → WSL VM IP directly** (`http://172.23.x.x:4096` instead of
   127.0.0.1): bypasses the localhost forwarder for the Windows tab; but the
   VM IP churns across WSL restarts and the phone (LAN) still can't reach
   the NAT subnet. Marginal.

## Recommendation

**Do not switch to Windows-native now.** The idle-kill class is mitigated in
prod (4 s heartbeat, verified end-to-end); the burst class has a cheap,
ready-made mitigation (staggered proxy — designed, probe-verified, awaiting
deployment) plus #31's cache headers, so there is no prod incident forcing
the move. Windows-native's cost — abandoning the Linux dev environment,
Linux-MCP interop (engram), DB duplication, and an unverified patched
Windows build on an EOL OS — outweighs the gain of removing the forwarder.

Revisit triggers:
- WSL2 forwarder regression reappears after a Windows update (the forwarder
  behavior has shifted before — the 2026-08-27 doc's open items).
- Host moves to Windows 11 22H2+: prefer **mirrored networking** over
  Windows-native (same benefit, no environment change).
- WSL/Docker Desktop becomes unmanageable on this host.

## References

- `docs/plans/2026-08-27-sse-wsl2-nat-idle-kill-findings.md` (idle-kill +
  clog evidence; patch #30)
- `docs/plans/2026-08-28-wsl2-nat-burst-stagger-proxy.md` (burst race +
  proxy design/deployment)
- Microsoft docs: WSL networking (NAT vs mirrored; mirrored = Win11 22H2+;
  `localhostForwarding` semantics)
- anomalyco/opencode#631 (Windows support tracking), #2447 (npm wrapper
  broken on Windows)
