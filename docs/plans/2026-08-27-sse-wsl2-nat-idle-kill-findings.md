# 2026-08-27 — Web UI sluggishness: SSE re-bootstrap loop root cause

## TL;DR

- **Root cause (verified, binary-independent):** the Windows-side WSL2 NAT
  forwarder kills SSE streams that go quiet for roughly **5–10 s** (jittery,
  sits at the margin of opencode's 10 s heartbeat). opencode's SSE heartbeat
  is exactly `Stream.tick("10 seconds")`, so the stream is killed just past a
  10 s boundary — observed kills at **10, 10, 10, 11, 20, 30 s (all multiples
  of the tick)**. The web client then reconnects and re-bootstraps ~13
  endpoints → perceived sluggishness + `ERR_INCOMPLETE_CHUNKED_ENCODING` /
  `ERR_EMPTY_RESPONSE` console spam.
- **Patch #29 (plugin outdated indicator) is exonerated** for the SSE loop:
  controlled A/B shows the pre-#29 binary fails identically (10–11 s, 3/3)
  with the same 0.0.0.0 bind and same FIN-mid-chunk failure mode. #29 contains
  no SSE code; its only fetch (`GET /plugin`) fires solely when the status
  popover is open AND the Plugins tab is active, and the endpoint responds in
  0.6 s (15-min TTL cache, async, 10 s remote timeouts).
- **The user's "pre-patch binary is fine" A/B was confounded** — see
  "Why the A/B misled". The pre-patch run in the server log was *also*
  reconnecting (every 50–100 s).
- **Proposed fix (2 lines):** `Stream.tick("10 seconds")` →
  `Stream.tick("4 seconds")` in `handlers/global.ts:43` and
  `handlers/event.ts:92`. Evidence: 5-s-interval data survived 90 s+ through
  the Windows path, 3 s survived too, 10 s dies.
- **Secondary finding:** the server never detects one-sided NAT kills
  (2,568 "global event connected" / **0** "disconnected" in one log) → zombie
  SSE connections + unbounded per-connection queues accumulate. Pre-existing;
  the heartbeat fix stops the browser path from creating new zombies but does
  not cure detection.

## Symptoms

- Web UI (Chrome on Windows → `http://127.0.0.1:4096`) periodically sluggish;
  console net errors every ~10–15 s: `ERR_INCOMPLETE_CHUNKED_ENCODING` on
  `GET /global/event`, `ERR_EMPTY_RESPONSE` on the re-bootstrap batch
  (config, models, sessions, …).
- Server-side `ss` showed 1,000+ ESTAB connections on :4096, growing ~+1/15 s
  while the browser looped.

## Environment / topology

- WSL2, NAT mode. Browser on Windows → `127.0.0.1:4096` → WSL2 automatic
  port-forward (Windows-side NAT) → WSL server (VM eth0 `172.23.51.127`).
- `curl.exe` via WSL interop is a **Windows process**, so
  `curl.exe http://127.0.0.1:PORT/...` exercises the same Windows-loopback
  forwarder path as the browser — a valid probe substitute (used throughout).
- Direct WSL connections (127.0.0.1 or VM IP) are **never** killed
  (45 s+ controls) — the forwarder is the only kill source found.

## Evidence (all measured 2026-08-27)

| # | Probe | Path | Result |
|---|-------|------|--------|
| 1 | WSL curl → patched server :4096 `/global/event` | WSL direct | survived 20 s (control) |
| 2 | WSL curl → pre-patch server :4097 (isolated) | WSL direct | survived 45 s (control) |
| 3 | Python SSE, `data: {"t":1}` every **2 s** (earlier session) | Windows path | survived 120 s+ |
| 4 | Python SSE every **3 s** | Windows path | survived full 90 s |
| 5 | Python SSE every **5 s** | Windows path | survived full 90 s |
| 6 | opencode **patched** :4096 (10 s heartbeat) | Windows path | dies 10, 20, 30 s (3/3); three earlier samples ~10 s |
| 7 | opencode **pre-patch** :4097, **0.0.0.0 bind** (10 s heartbeat) | Windows path | dies 10, 10, 11 s (3/3) — **identical** FIN-mid-chunk failure |
| 8 | opencode pre-patch :4097, **127.0.0.1 bind** | Windows path | RST after 2–3 s (3/3), connections **never reach the server handler** — separate artifact, see Secondary #2 |

- Failure mode in #6/#7: server-side FIN mid-chunk
  (`curl: (18) transfer closed with outstanding read data remaining`;
  browser: `ERR_INCOMPLETE_CHUNKED_ENCODING`). Forwarder-initiated, not
  server-initiated: the pre-patch server log shows no errors, and in #8 the
  server never logs the connection at all.
- Kill times are all **multiples of the 10 s tick** → the forwarder's idle
  timer (~5–10 s, jittery) fires inside a heartbeat window; when a heartbeat
  wins the race the cycle repeats (hence the 20 s / 30 s kills). Any data
  interval ≤ 5 s is always safe.
- `server.heartbeat` is the only periodic wire traffic:
  `Stream.tick("10 seconds") → { type: "server.heartbeat" }` in
  `global.ts:43-46` (root `/global/event`, used by the web app) and
  `event.ts:92-95` (instance `/event`, used by TUI and per-session streams).
- No app/SDK code consumes `server.heartbeat` (grep over `packages/app`,
  `packages/sdk`; the one reference is a deliberate no-op in
  `packages/opencode/src/control-plane/workspace.ts:399`) — the event passes
  through unhandled, so a faster cadence is client-safe (~100 B per event on
  `/global/event`, ~90 KB/h per connection at 4 s).

## Why the A/B misled

User observation (2026-08-27): pre-patch binary = "fine", current patched
binary = looping. Controlled re-test shows both die identically. Confounders:

1. **Both binaries were looping.** Server log
   (`~/.local/share/opencode/log/opencode.log`): run `c7cc7418`
   (17:58–18:05, the pre-patch A/B window) shows `/global/event` reconnects
   every **50–100 s**; run `f597c486` (17:04–17:55, patched, under active
   debugging) every **2–40 s**. 50–100 s hiccups read as "fine" next to a
   10–15 s loop.
2. **Fresh vs long-lived server.** The patched :4096 had accumulated ~1,000+
   zombie SSE connections by 17:55 (each NAT kill leaves one, since the
   server can't detect the one-sided close — 2,568 connects / 0 disconnects).
   Fan-out of every bus event to thousands of dead queues plausibly degraded
   the patched server and shortened its loop. *Unproven — honest gap; the
   heartbeat fix should normalize both, then re-measure.*
3. **Background-tab reconnect throttling** could stretch the pre-patch cycle
   further if the tab wasn't focused during the A/B.
4. **127.0.0.1-bind RST artifact** (#8): any test binary bound to loopback
   only fails in 2–3 s with a *different* signature (RST, not FIN) — don't
   confuse it with the idle-kill.

## Secondary findings

1. **Zombie SSE connections / no disconnect detection.**
   `Stream.ensuring(Effect.logInfo("global event disconnected"))` never fires
   for NAT kills (server side of the socket stays ESTAB until it writes
   enough to fill buffers). Per-connection `Stream.callback` queues are
   unbounded (`Queue.offerUnsafe`, no backpressure) → memory grows per
   zombie. Fresh 19:56 server: 135 ESTAB by ~20:15. Heartbeat fix stops new
   zombies on the browser path; a real cure needs TCP liveness detection
   (out of scope for now).
2. **WSL2 localhost-forward artifact:** Windows → `127.0.0.1:<port>` for a
   port bound **only to 127.0.0.1 inside WSL** gets RST after ~2–3 s and the
   connection never reaches the server. 0.0.0.0 bind proxies fine. Always
   bind test servers to 0.0.0.0 for Windows-path tests.
3. **db-isolation-guard patch works:** refused to start a probe server with
   `XDG_DATA_HOME` redirected but absolute `OPENCODE_DB` outside it (by
   design). For isolated probe servers set
   `OPENCODE_DB=$XDG_DATA_HOME/opencode/opencode.db`.
4. **Live server log location:** `~/.local/share/opencode/log/opencode.log`
   is append-mode, but the 19:56 server (pid 14638) has fd1 → `/dev/pts/0`,
   so the *current* run may not be in the file. Check `/proc/<pid>/fd/1`
   before concluding a run is "missing" from logs.

## Fix (shipped as patch #30, 2026-08-28)

Small patch (#30), 2 lines:

- `packages/opencode/src/server/routes/instance/httpapi/handlers/global.ts:43`
  — `Stream.tick("10 seconds")` → `Stream.tick("4 seconds")`
- `packages/opencode/src/server/routes/instance/httpapi/handlers/event.ts:92`
  — same

Why 4 s: 5-s-interval data survived 90 s through the Windows path (3 s too);
4 s keeps margin on both sides of the (5 s, 10 s) threshold band. Revisit if
a future Windows/WSL update shifts the timeout. TUI also benefits (same
`/event` stream) e.g. when used over an SSH/remote path.

Validation plan:

1. Build a **test binary** with the 2-line change; run isolated on :4098
   (0.0.0.0 bind, scratch `XDG_DATA_HOME`+`OPENCODE_DB`); Windows probe
   `curl.exe -N` for 120 s+ → must survive.
2. Full build, install to `~/.opencode/bin/` (versioned name), sqlite `.backup`
   of the DB, restart :4096. **Restart kills the active opencode session and
   the open web UI — coordinate timing with the user.**
3. Web UI verification: no `/global/event` reconnects in DevTools Network for
   10+ min; console net errors gone; `ss` zombie growth stops.

**Result (2026-08-28, Postscript 3/4):** plan executed, fix verified.
Binary confirmed to contain the 4 s tick (30/30 clean-clone apply,
commit `782db9496`). Server-side cadence 22 heartbeats / 75 s;
decisive differential: fake 4-s-tick SSE on a fresh port (:4397)
survived 60 s through the Windows path while 10-s died. Once the
residual :4096 clog was cleared by stopping tab churn (no reboot
needed), a fresh tab's `/global/event` survived 168 s+ end-to-end
(vs 9.8 s jammed); zero SSE reconnects in a 9.4-min window; final
wire gaps 2.82-4.01 s. (The isolated :4098 test-binary step was
superseded by the :4397 differential + the shipped-binary tick check.)

## Open items

1. **Chevron bug (patch #29, separate from the SSE loop):** in the status
   popover → Plugins tab, clicking a plugin's version chevron
   (`DropdownMenu.Trigger`, icon `chevron-down`) dismisses the **entire**
   status popover. Mechanism hypothesis: `DropdownMenu.Portal` content mounts
   outside the popover DOM; the popover's outside-pointer handler
   (`useDialog`-based) treats it as an outside click. The wrapper div stops
   `mousedown`/`click` propagation but not `pointerdown` — if the popover
    listens for document-level `pointerdown`, that's the leak. chrome-devtools
    MCP is now live (Chrome on 9222 confirmed); repro can run against an
    isolated patched server on a spare port (e.g. :4098, 0.0.0.0 bind) without
    touching :4096.
2. **Reconnect-rate discrepancy** (patched 2–40 s vs pre-patch 50–100 s in
   the log) — no proven cause; suspected zombie load on the long-lived server.
   Re-measure loop rate + zombie count after the heartbeat fix.
3. MTP-KV bench work remains on hold (separate track,
   `bench/mtp-kv/NOTES.md`).

## Postscript (2026-08-27, evening) — browser-side "blank new window" incident

A new window opened on the current server showed a blank page plus a CSP
violation ("inline script violates CSP `sha256-ZuZQORX8…`; required
`sha256-jURJv6M3…`"). **Diagnosed as stale Chrome disk cache + a NAT
mid-transfer kill — not a server bug.**

1. **Stale cache is the CSP source.** The browser's document (2952 B,
   `content-length` intact) contained an `oc-theme-preload-script` hashing to
   `jURJv6M3…` while the served CSP allows `ZuZQORX8…`. All 11 patched builds
   embed `ZuZQOR…`; the **vanilla 1.18.23** binary at
   `~/.opencode/bin/opencode` (unversioned, mtime 2026-08-25 08:11) embeds
   `jURJv6M3…` — an exact match. The tab's cached document is from an earlier
   server run of that vanilla binary.
2. **Blank page's fatal cause:** the 2.7 MB `index-5_JYNEla.js`
   (`content-length: 2740277`) was cut mid-transfer by the forwarder →
   `ERR_CONTENT_LENGTH_MISMATCH` → app never boots. Probabilistic (manual
   reload usually gets through). Note: the forwarder's kills are **not
   limited to idle SSE** — it also truncated a large chunked transfer here.
   The heartbeat fix cures the idle-kill class; mid-transfer kills of big
   bundles are residual NAT flakiness, mitigated by reload.
3. **Server proven correct 3 ways (byte-identical):** WSL `curl`, Windows
   `curl` through the NAT forwarder, and in-page
   `fetch(location.href, {cache:"reload"})` all return document sha256
   `F74uHzPxpfWKv3Mc+TbvrwzTySVmMl05lynG2FQCjHM=`; script hash = CSP hash.
4. **Shadow server ruled out:** every Windows-side :4096 socket belongs to
   svchost PID 2416 (WSL2 forwarder; service group incl. hns/SharedAccess/
   iphlpsvc; outbound dials 172.23.51.127:4096). One WSL distro running; no
   opencode process on Windows.
5. **Fix for the stale tab:** Ctrl+Shift+R (per-request cache bypass;
   localStorage untouched). **Footgun:** bare `~/.opencode/bin/opencode` is
   vanilla 1.18.23 — any launch by bare `opencode` name silently serves
   vanilla, not the patched build.

## Postscript 2 (2026-08-27, evening) — forwarder state clogging on :4096 (UI bricked)

- Desktop tab ended up on `chrome-error://` — the re-bootstrap loop finally lost.
- Server 100% healthy: WSL-direct worker fetch 200/533159 B in 18–112 ms (3/3);
  fd 713/1M; RSS 2.6 GB.
- Windows path → :4096: 9–10/10 rapid requests → `rc=52` **empty reply** (conn
  accepted, closed, zero bytes) + one `rc=18` mid-chunk kill (135 KB of 533 KB).
- Same 10-request burst → fresh port :4397 (python http.server, 0.0.0.0):
  **10/10 OK**, incl. the 2.7 MB bundle.
- ⇒ Degradation is **port-specific**: the WSL2 forwarder's per-port state is
  clogged by 643 zombie ESTAB connections on :4096 (6 h run + re-bootstrap
  churn). Fresh ports are clean. This confirms the long-suspected zombie
  accumulation, but the victim is the forwarder's per-port table, not the
  server.
- **No no-restart mitigation exists:** `ss -K` (as root via
  `wsl.exe -u root`) is rejected by the WSL2 kernel
  (`RTNETLINK answers: Invalid argument`) — connection killing is not
  available in this WSL. A server restart is the only way to flush the
  zombies. The forwarder clog is also **transient**: :4096 went from
  0–1/10 OK to 7/10 OK within ~10 min with no intervention; zombie ESTAB
  kept growing meanwhile (643 → 1112).
- **Phone "Markdown highlighting worker failed"**
  (`markdown-worker.ts:217`; the exact fallback string means empty
  `event.message` = worker-script load failure, not eval error): the 533 KB
  `/assets/markdown.worker-*.js` fetch failed at page load over the clogged
  :4096 path. `fail()` sets `disabled` permanently for that page load —
  reload fixes it. Server serves the chunk correctly (`text/javascript`,
  valid JS); no wasm/extra asset fetches inside the worker (grammar chunks
  are dynamic imports).
- Heartbeat-fix case strengthened: the churn it eliminates is what clogs the
  forwarder and bricks the UI.

## Postscript 3 (2026-08-28, morning) — patch #30 shipped; :4096 clog survives server restart

- **Shipped:** patch #30 `sse-heartbeat-4s.patch` (commit `782db9496`, 3 files:
  patch + `apply.sh` + README; constraint `#30 after #5`). 30/30 clean-clone
  apply at v1.18.21; binary `opencode-v1.18.21-patched-prod-202608280344`
  verified to contain the 4 s tick; DB backup `opencode.db.bak.202608280344`.
- **Server-side heartbeat confirmed:** WSL-direct `/event` probe received
  22 `server.heartbeat` events in 75 s = exactly the 4 s cadence. (An earlier
  "22 events / 25 s" anomaly was a probe bug — the wait loop slept
  5+10+15+20+25 s cumulatively, not 25 s.)
- **Zombie behaviour re-confirmed:** a Windows-path `/event` probe on :4096
  stalled at 89 B (only `server.connected`), 0 heartbeats in 60 s, client
  died; the server log shows **no** `global event disconnected` line for that
  probe — the server kept writing into a void connection.
- **Decisive differential:** a fake 4 s-tick SSE on a **fresh port :4397
  survived the full 60 s through the Windows path** (steady byte growth,
  client alive). 4 s cadence is sufficient to defeat the idle-kill on a clean
  port. The fix pattern is proven; what remains is the stale :4096 state.
- **The :4096 clog is Windows-side and survives a server restart.** After the
  restart, WSL-side zombies were cleared (88 ESTAB at t0), yet Windows-path
  :4096 SSE still stalled (0 heartbeats / 60 s) while :4397 was clean. The
  forwarder's per-port NAT state lives in the Windows svchost, and the
  restart's FINs cannot clear it — they must traverse the jammed path
  itself. Self-sealing jam.
- **Loop still active post-restart:** 158 `global event connected` in 11 min
  (one every 2–6 s), ESTAB 88 → 243. Five OpenCode browser tabs were all
  re-bootstrapping against the jammed :4096; connections now die **< 4 s**
  (a clogged path kills faster than the old 5–10 s idle window). The
  heartbeat fix is demonstrably working (ticks flow); the jam simply is not
  cleared, and the multi-tab churn re-pollutes faster than it decays.
- **Clearing the current jam:** `wsl --shutdown` (reboots the WSL VM *and*
  the Windows-side forwarder) is the only full reset. Alternative: close all
  but one OpenCode tab (churn reduction) and let the jam decay — with low
  churn it took ~10 min last time. After reset: start the server (new
  binary), test with 1–2 tabs; expect the reconnect loop to stop.
- **Upstream bug references** (repeatedly fixed, repeatedly regressed; only a
  Microsoft fix is a real cure): microsoft/WSL #4340 (idle localhost kill,
  2019), #7979 (FIN never reaches peer = zombies, 2022), #10601 (wslrelay
  dead per-port state, 2023), #6918 (wslhost stops listening, 2021), #8797
  (random resets, 2022), #13690 (still open as of 2025-11);
   openclaw/openclaw #72735 (2026: NAT drops idle TCP ~60 s; fix =
   sub-timeout traffic — exactly patch #30's approach).

## Postscript 4 (2026-08-28, midday) — jam cleared by stopping churn; fix verified end-to-end

- **Correction — the browser is Brave, not Chrome.** The chrome-devtools MCP
  browser's `sec-ch-ua` is `"Brave";v="151"`. All 6 OpenCode tabs were ONE Brave
  browser (pid 81048) = the same process holding the ESTAB to :4096. The earlier
  "frozen Chrome + churning Brave" split was wrong and is dropped.
- **In-browser differential (fresh tab, jammed state):** full 2.7 MB JS bundle
  (`index-KXP1iLE3.js`) + dozens of 200 REST delivered, but **every `/global/event`
  received exactly 101 B (only `server.connected`, 0 heartbeats)** and died at
  ~9.8 s, reconnecting on a ~40 s cycle. The initial REST burst also hit
  `net::ERR_EMPTY_RESPONSE` (half-open keep-alive reuse); retries succeeded [200].
  Jam signature: a fresh connection's initial burst passes, but the forwarder
  drops the *subsequent* writes — which is precisely what the 4 s heartbeats are.
- **Churn-attribution was speculation and is dropped** (do not re-assert a
  definitive churn *source*). What is measured: the jam was **re-fed by live
  reconnect churn** — 6 tabs reconnecting every few seconds re-polluted faster
  than the path could decay.
- **The jam survived a prior `wsl --shutdown`/WSL restart** — a restart alone
  does not hold, because the live tabs immediately re-pollute the cleared path.
- **Clearing the jam needed no reboot:** close all but one OpenCode tab →
  reconnect churn stops → the server reaps the half-open pile. Measured decay of
  WSL-side `:4096` ESTAB: **469 → 347 → 287 → 229 → 191 → ~60** over ~23 min
  (≈87% cleared), with a **~9.4-min window (03:50:01→03:59:25) of zero SSE
  reconnects** (vs one every 5–10 s while churning).
- **End-to-end proof the heartbeat now reaches the browser:** a fresh tab's
  `/global/event` stayed **alive 168 s+** (vs 9.8 s jammed, ~17×). The original
  bug was NAT idle-kill of a *silent* SSE at ~10–54 s; a connection surviving
  168 s through the same path must be receiving the 4 s ticks (a silent one would
  still idle-kill). So the ticks are flowing browser-side, not just server-side.
- **Final server probe** (pid 937, WSL-direct, 6 events / 18.86 s): gaps
  **2.82 / 4.00 / 4.01 / 4.00 / 4.01 s** — 4 s cadence confirmed live at sign-off.
- **Bottom line:** patch #30 is verified working end-to-end. The residual :4096
  clog was being re-fed by multi-tab reconnect churn. **Mitigation: keep few
  OpenCode tabs open** (each churning tab re-pollutes the path); a full reset is
  still `wsl --shutdown` if the clog ever re-accumulates.
- **Tooling note:** a test tab's `ERR_EMPTY_RESPONSE` retry burst clogged the
  chrome-devtools MCP (every call, including browser-level `list_pages`, timed
  out) until the tab was closed. Close heavy tabs before driving the browser via
  the MCP. A long-lived SPA tab's `performance.getEntriesByType('resource')`
  buffer mixes navigation baselines — use the WSL-direct probe for the clean
  heartbeat read, not the in-browser resource timing.

## Repro / test commands

```bash
# Windows-path SSE probe (rc=124 survived window; rc=18 FIN-mid-chunk kill; rc=56 RST)
s=$(date +%s); timeout 45 curl.exe -sS -N -u opencode:12341234 \
  http://127.0.0.1:4096/global/event -o NUL; \
  echo "rc=$? elapsed=$(( $(date +%s) - s ))s"

# Keepalive-interval probe server (sends data: {"t":1}\n\n every N s)
setsid python3 /tmp/opencode/keepalive-probe.py 5 4397 </dev/null >/dev/null 2>&1 &
# then probe with curl.exe as above against :4397; pkill -f keepalive-probe.py after

# Zombie connection count on :4096
ss -tn state established '( sport = :4096 )' | wc -l

# Server-side SSE connect/disconnect evidence
grep "global event" ~/.local/share/opencode/log/opencode.log | tail -20

# Isolated probe server (pre-patch binary example; MUST bind 0.0.0.0)
setsid env XDG_DATA_HOME=/tmp/opencode/ab-data \
  OPENCODE_DB=/tmp/opencode/ab-data/opencode/opencode.db \
  ~/.opencode/bin/opencode-v1.18.21-patched-prod-202608251528 \
  serve --hostname 0.0.0.0 --port 4097
```

## References

- Binaries: current = `opencode-v1.18.21-patched-prod-202608280344` (30
  patches; #30 = commit `782db9496`, 4 s heartbeat); pre-#30 =
  `opencode-v1.18.21-patched-prod-202608261226` (29 patches; #29 = commit
  `08404797e`); pre-#29 =
  `opencode-v1.18.21-patched-prod-202608251528` (28 patches). All v1.18.21
  upstream.
- Code: `handlers/global.ts:33-66` (`eventResponse`), `handlers/event.ts`
  (~70–105).
- Patches: #29 = `patches/plugin-outdated-indicator.patch` — exonerated for
  the SSE loop; still owns the chevron bug.
- Browser constraint: when driving the user's browser via chrome-devtools
  MCP, **never clear/delete localStorage** (UI settings such as the
  `settings.v3` layout flags live there) — read-only.
