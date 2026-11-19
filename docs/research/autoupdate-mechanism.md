# Autoupdate mechanism in OpenCode v2

## TL;DR

OpenCode has NO in-process binary re-exec. The CLI binary is never replaced while running.
Autoupdate works in three layers: (1) installer overwrites the file, (2) background
service (server daemon) is stopped+respawned on version mismatch, (3) Windows-only
RetainedImage hard-link keeps the running image replaceable.

## 1. Binary replacement (Linux/macOS)

The curl installer (https://opencode.ai/v2/install) downloads a tarball and does:
  mv $tmp/package/bin/opencode ~/.opencode/bin/opencode
On Linux the running process keeps the old inode open, so it keeps running the old
binary until exit; every new invocation picks up the new file. No restart signal.
For manual builds: build, then `mv`/`cp` over ~/.opencode/bin/opencode-<ver>; the
old process is unaffected. To "use the new binary" you just start a new process.

## 2. Background service replacement (version mismatch) -- the "clean close" part

opencode runs a long-lived background server (opencode serve --service) discovered
via a registration file (~/.local/state/opencode/service.json) holding url/pid/
version/password. When a client's version differs, it does:
  Service.stop({ file, pty: "handoff" })   # SIGTERM, escalate SIGKILL after poll
  Service.ensure(options)                  # spawn contender until discoverable

The new server is spawned with:
  spawn(command, args, { detached, stdio:["ignore","ignore","pipe"], env:{...process.env, ...env} })
  command/args default to ["opencode", "serve", "--service"]
  env = PtyHandoff.environment(file, env)  # adds OPENCODE_PTY_HANDOFF=<json> if a
                                          # terminal handoff was published

So "same env, flags": the contender inherits process.env plus the handoff env var,
and uses the same argv. The old server is terminated (SIGTERM then SIGKILL) and
its registration file removed; the new one re-registers.

Persistent terminals survive via PtyHandoff: before stopping, the old server
publishes a handoff ticket (OPENCODE_PTY_HANDOFF) with an expiry; the new server
adopts it. This is the "clean close" -- graceful SIGTERM first, then SIGKILL.

## 3. Autoupdate policy loop

`opencode` (default command) runs a background check every 10 minutes:
  updater.run(onInstall) -> inspect() -> latest() (hits opencode.ai/update/api/...)
  policy = readPolicy() from config.json/opencode.json/opencode.jsonc
    update: "disable" | "notify" | "auto"  (legacy autoupdate: bool/"notify")
  if policy == "auto": install via detected method (curl/npm/pnpm/bun/yarn/vp/brew/winget)
  onInstall(version) notifies the TUI; the installed binary is on disk but the
  running process is NOT restarted -- the user must restart opencode (or the
  background service swaps itself on next version-mismatch).

Install method detection: from process.execPath location (curlBinary path, brew
Cellar, winget packages dir, or npm package name from package.json).

## 4. Windows: RetainedImage

Windows can't delete/overwrite a running executable's last hard link. opencode keeps a
second hard link to its own image in ~/.opencode/cache (opencode-{service|upgrade}-
<pid>-<rand>.exe) for the lifetime of the process. The installer replaces the
primary path; the retained link is swept later when the pid is dead. Applies to
both service ("service") and upgrade ("upgrade") roles. Rename of a running image
is allowed, so retained links can be relocated.

## 5. Manual-build recipe (what to copy)

For a single binary (no background service):
  1. Build new binary.
  2. `mv new ~/.opencode/bin/opencode` (Linux keeps old inode alive).
  3. Next `opencode` invocation uses the new binary. No restart needed.

For a long-running daemon that must swap without dropping clients:
  1. Keep a registration file (url, pid, version, password, 0600).
  2. Client compares versions; on mismatch:
     a. Publish a handoff ticket (state + expiry) to <regfile>.pty-handoff.
     b. SIGTERM the old pid; poll; SIGKILL after timeout; remove reg file.
  3. Spawn new daemon: spawn(cmd, args, { detached, stdio, env:{...process.env, ...handoffEnv} })
     cmd/args = same as before (e.g. ["opencode","serve","--service"]); env inherits.
  4. New daemon reads OPENCODE_PTY_HANDOFF and adopts terminals.
  5. Wait for registration file to appear (poll ~5s), then connect.

Windows: retain a hard link to the image so the installer can overwrite it.

## Sources
- packages/cli/src/services/updater.ts (policy, install, method detection)
- packages/cli/src/services/server-connection.ts (ensure/replace/stop)
- packages/client/src/effect/service.ts (ensure, stop, terminate, spawnServiceContender)
- packages/client/src/pty-handoff.ts (handoff publish/adopt/clear)
- packages/cli/src/services/retained-image.ts (Windows hard-link retention)
- https://opencode.ai/v2/install (curl installer)

## Decision (2026-11-19): plain `serve` stays on this box

The registered background service (`serve --service`, :49374) was retired after the
v2.3.2 swap; nothing is attached to it. The local workflow keeps plain
`opencode serve --hostname 0.0.0.0 --port 4096`, because each thing `--service` adds
is wrong here:

- **Auto-discovery via `service.json`** solves zero-config client find-a-server; the
  openchamber client is configured with an explicit URL + `OPENCODE_PASSWORD` anyway.
- **Loopback binding**: LAN/phone clients need the `0.0.0.0` binding plain `serve`
  already provides.
- **Version-mismatch auto-replacement** (client-triggered `Service.stop`+`ensure`):
  kills attached sessions at unpredictable moments and races the deliberate,
  rollback-armed swap (`scripts/upgrade-prod.sh`). Controlling builds is the point of
  the fork; this mechanism removes that control.

Persistence of sessions does not need `--service`: plain `serve` is the long-lived
server and sessions survive client disconnects (and binary swaps) because :4096
stays up.

E2E proof of the respawn path before relying on it: launching `opencode serve
--service` exactly as a client would (PATH-resolved `opencode`) bound :49374 on
`~/.opencode/bin/opencode-v2.3.2-latest-202611191829` (verified via
`/proc/PID/exe`), wrote registration version 2.3.2, and answered `/api/info` with
version=2.3.2; retiring the test daemon freed the port and cleared the registration.
The PATH chain is `~/.local/bin/opencode` → `~/.opencode/bin/opencode` → the newest
verified binary (repointed by the swap script's step 8).
