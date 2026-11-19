# User tracking & fingerprinting in OpenCode v2

**Analyzed:** tag `v2.1.4`, commit `68bc26b7da1990ce10ffecfbc1e09eb13aa5d824` (2026-10-23, `release: v2.1.4`),
clean clone at `/tmp/opencode/opencode-v2` (`git clone --depth 1 --branch v2.1.4 https://github.com/anomalyco/opencode`).
**Date:** 2026-10-24. **Method:** primary-source trace of every identifier from generation → storage → the exact
outbound request, in the pinned tree; supporting sources are official docs (opencode.ai/v2/docs) and GitHub
issues/PRs. All `file:line` citations are at v2.1.4. v2 restructured the monorepo: the core CLI/server is
`packages/cli` + `packages/core` + `packages/server` (the v1 `packages/opencode` is gone).

## TL;DR / Verdict

- **No persistent install/device ID exists in v2.** Greps for `installID`/`install_id`/`machineId`/`deviceID` find
  nothing in the shipped client tree. The only *persisted random identifier* is the ChatGPT provider's
  `chatgpt-agent-host-id` (`urn:uuid:<randomUUID>`, `packages/core/src/plugin/provider/chatgpt.ts:103-105`).
- **The strongest cross-install fingerprint is the project ID**: `sha1("directory:" + <absolute path>)` or
  `sha1("git-remote:" + <normalized remote URL>)` (`packages/core/src/project.ts:397`, `:292`), sent on **every
  model request** as the `x-opencode-project` header (`packages/core/src/session/model-request.ts:282`) — to
  *every* provider, not just opencode's. Same path/repo ⇒ same ID on every machine.
- **Every LLM request carries session-correlation headers** (`x-opencode-session-id`, `x-session-affinity`,
  `X-Session-Id`, `x-opencode-session`, `x-opencode-client`) plus a `User-Agent` of
  `opencode/{channel}/{version}/{name}` (`model-request.ts:276-285`; `packages/core/src/app.ts:24-26`). The session
  affinity is also sent as the provider `promptCacheKey` (`model-request.ts:288`; `packages/ai/src/protocols/shared.ts:77-79`).
- **Default phone-home to opencode.ai is exactly two channels**: the update check
  (`https://opencode.ai/update/api/{channel}/{artifact}/{distribution}?current={version}`,
  `packages/cli/src/services/updater.ts:284`, fired at TUI startup and every 10 min, `packages/cli/src/commands/handlers/default.ts:70-84`)
  and the model catalog (`https://models.opencode.ai/api.json` every 5 min with the opencode UA,
  `packages/core/src/models-dev.ts:280,347-348,432-434`). Both are disableable.
- **OpenTelemetry is opt-in only and off by default.** OTLP export requires `OTEL_EXPORTER_OTLP_ENDPOINT`
  (`packages/cli/src/index.ts:131-132`); with no endpoint, `Otlp.loggers` returns `[]` and the tracing layer is
  empty (`packages/util/src/observability/otlp.ts:64,75`). The v1 `experimental.openTelemetry` config key is
  "accepted but unsupported" in v2 (`packages/core/src/config/normalize.ts:49`;
  https://opencode.ai/v2/docs/migrate-v1).
- **Session sharing was retired in v2** — the `share`/`enterprise` config keys are read by nothing
  (https://github.com/anomalyco/opencode/pull/55716, https://github.com/anomalyco/opencode/issues/57932); the
  old `opncd.ai` backend returns 410. No session content is uploaded by default.
- **Sentry crash reporting ships only in the Desktop app** (DSN baked in at build,
  `packages/desktop/src/renderer/startup/sentry.ts:8-13` + `.github/workflows/publish.yml:459-465`); the CLI's
  embedded web UI is built without a DSN (`publish.yml:107-116`), so the CLI/TUI have no crash reporter.
- **Console/zen/go login is the human-identity tie**: device OAuth to `https://opencode.ai/console`
  (`packages/core/src/plugin/provider/opencode.ts:34,150-154`), a config poll every **minute** with the bearer
  token (`opencode.ts:616-618,630-637`), inference to `https://opencode.ai/inference/*`
  (`packages/core/src/models-dev/snapshot.txt`), and server-side inference events feed opencode's own
  user/session/geo/retention stats lake (`packages/stats/core/src/domain/inference.ts`, `stat-sync.ts`).
- **Net fingerprintability: moderate, and mostly *derivable* rather than *declared*.** Without an account, no
  single stable ID identifies you; but project-ID (path/repo hash) + session affinity + UA + your IP at two
  opencode.ai endpoints + prompt content (absolute paths, platform, date) let a provider — or opencode itself —
  correlate requests strongly. Best hardening is listed in the Opt-out matrix.

## Identifier inventory

| Identifier | Where generated | Where stored | Stability | Sent to |
|---|---|---|---|---|
| *(no install/device ID)* | — | — | — | nowhere; no `installID`/`machineId` anywhere in the v2.1.4 client tree (grep) |
| Project ID | `sha1("directory:"+dir)` `packages/core/src/project.ts:397`; `sha1("git-remote:"+url)` `project.ts:292` | local SQLite `project` table (`packages/core/src/database/schema.gen.ts:102`) | **deterministic from path or git remote** — identical across installs/machines for the same path/repo | `x-opencode-project` header on every model request (`packages/core/src/session/model-request.ts:282`) → all providers |
| Session ID | `"ses_" + time-ordered+random` (`packages/schema/src/session-id.ts:9`, `packages/schema/src/identifier.ts:16-31`) | local SQLite `session_v2` | per-session; embeds creation timestamp | `x-opencode-session-id`, `x-opencode-parent-session-id` (`model-request.ts:276-277`); also stateless generate calls (`packages/core/src/generate.ts:71`) |
| Session affinity | parent/fork-source session ID (`packages/core/src/session/affinity.ts:8-9`) | derived | per-session-tree | `x-session-affinity`, `X-Session-Id`, `x-opencode-session` (`model-request.ts:278-283`) and provider `promptCacheKey` (`model-request.ts:288`; `packages/ai/src/protocols/shared.ts:77-79`) |
| ChatGPT host ID | `urn:uuid:${crypto.randomUUID()}` `packages/core/src/plugin/provider/chatgpt.ts:104` | plugin KV namespaced in local DB (`packages/core/src/plugin.ts:65`; storage at `chatgpt.ts:103-105`) | **persistent per-install random** — survives reinstalls while the DB lives | `ext_agent_host_id` query param on OpenAI's authorize URL (`chatgpt.ts:531`) |
| Account email + tokens | Console device OAuth (`opencode.ts:80-95,147-204`) | local SQLite `account` table (`packages/core/src/account/sql.ts:7-17`) | per-login | Console API (Bearer + `x-org-id`, `opencode.ts:693-699`) |
| User-Agent | `opencode/{channel}/{version}/{name}` `packages/core/src/app.ts:24-26` | derived from build | per-build (channel/artifact/version) | models catalog (`models-dev.ts:348`), Console (`plugin/provider/opencode.ts:219`), all model requests (`model-request.ts:281`), websearch plugins (`plugin/websearch/parallel.ts:84` etc.), xAI/azure/copilot/snowflake providers |
| `x-opencode-client` | `App.Metadata.name` ← `OPENCODE_CLIENT`/artifact (`packages/cli/src/server-process.ts:103`) | derived | per-client-kind (cli/desktop/acp) | model requests (`model-request.ts:284`) |
| OTel run ID | 8-hex `randomUUID` per process (`packages/util/src/observability/shared.ts:5-8`) | memory | per-process | **only** to a user-configured OTLP endpoint as `opencode.run`/`service.instance.id` (`packages/util/src/observability/otlp.ts:57-58`) |
| Server instance ID | `randomUUID()` `packages/cli/src/server-process.ts:97` | local service registration | per-process | local only (pty handoff), never outbound |
| Pairing code | `randomBytes(16)` `packages/server/src/pairing.ts:25` | in-memory cache | one-shot, 5 min TTL | local pairing URL only |
| GitLab UA extras | `os.platform() os.release(); os.arch()` `packages/core/src/plugin/provider/gitlab.ts:306` | derived | per-machine OS build | GitLab AI gateway UA string |
| Prompt env block | working dir, workspace root, platform, tmp path `packages/core/src/instructions/builtins.ts:36-45`; date `:25-31` | in prompt | per-session | **the model provider** (prompt body) |
| Report-skill diagnostics | version, channel, `os.type/release/platform/arch`, terminal env, shell, plugin list `packages/core/src/plugin/skill.ts:54-69` | in prompt | per-invocation | the model provider (when the built-in report skill is used) |

## Outbound request inventory

| Destination | Trigger | Identifying data sent | Opt-out |
|---|---|---|---|
| `opencode.ai/update/api/{channel}/{artifact}/{distribution}?current={version}` (`packages/cli/src/services/updater.ts:284`) | `opencode` default command startup + every 10 min (`packages/cli/src/commands/handlers/default.ts:70-84`); default policy is `notify`, which still checks (`updater.ts:171,542-546`) | IP + Bun UA + channel, artifact, distribution (npm/homebrew), current version | config `"update": "disable"` (`updater.ts:543-546`) or `OPENCODE_DISABLE_AUTOUPDATE=1` (`updater.ts:534`); brew-core installs query `formulae.brew.sh` instead (`updater.ts:283`) |
| `models.opencode.ai/api.json` (`packages/core/src/models-dev.ts:280,347`) | server boot + every 5 min (`models-dev.ts:331,432-434`) | IP + UA `opencode/{channel}/{version}/{name}` (`models-dev.ts:348`) | `OPENCODE_DISABLE_MODELS_FETCH=1` (`packages/cli/src/server-process.ts:119`); `OPENCODE_MODELS_URL`/`OPENCODE_MODELS_PATH` (`server-process.ts:117-118`); a bundled snapshot is the offline floor (`models-dev.ts:16,364`) |
| Provider inference (any provider) | every model call | `x-opencode-session-id`, `x-opencode-parent-session-id`, `x-session-affinity`, `X-Session-Id`, `x-parent-session-id`, `x-opencode-project`, `x-opencode-session`, `x-opencode-client`, UA (`packages/core/src/session/model-request.ts:276-285`); promptCacheKey = affinity (`:288`); prompt body contains absolute paths/platform/date (`instructions/builtins.ts:36-45`) | headers are rewritable by the `session.model.request` plugin hook (`model-request.ts:298-312`) — a plugin can strip them |
| `opencode.ai/console` (Console/zen/go) | only when the `opencode` integration is connected: device OAuth (`plugin/provider/opencode.ts:150-154,728-744`), `/api/v2/config` poll **every 1 min** (`:616-618,630-637`) | Bearer token + `x-org-id` (`:693-699`), UA (`:219` — comment: "the Console … reads the User-Agent to tell which OpenCode a member runs") | don't log in; `policies` deny the provider (config `policies`, `packages/schema/src/config.ts:58`) |
| `opencode.ai/inference/*` (zen/go inference; base URLs in `packages/core/src/models-dev/snapshot.txt`) | inference with opencode/`opencode-go` providers | full prompts + all model-request headers + Bearer | same as above; `OPENCODE_DISABLE_FREE_MODELS=1` drops free models (`packages/core/src/model.ts:224-228`) |
| Console websearch proxy `POST {server}/api/websearch` (`plugin/provider/opencode.ts:515`) | websearch tool while Console-connected; Console config *sets the default provider* (`:545`) | query text + Bearer | config `"websearch": false` (`packages/core/src/config/plugin/websearch.ts:13-15`) or permissions `{action:"websearch",effect:"deny"}` |
| `mcp.exa.ai/mcp` (`packages/core/src/plugin/websearch/exa.ts:8`) | websearch tool with exa selected | query text; API key in query param (`exa.ts:48-49`) | websearch off; `OPENCODE_DISABLE_MODELS_FETCH` does not affect this |
| parallel/tinyfish/firecrawl/tavily websearch | websearch tool | query + UA (`plugin/websearch/parallel.ts:84`, `tinyfish.ts:73`, `firecrawl.ts:66`, `tavily.ts:53`) | as above |
| arbitrary URLs via webfetch tool | agent tool | UA `Mozilla/5.0 … OpenCode-User/1.0; +https://opencode.ai` + `Accept-Language: en-US,en;q=0.9` (`packages/core/src/tool/plugin/webfetch.ts:53-60`) | deny the tool via permissions |
| ChatGPT/OpenAI auth (`{issuer}/api/accounts/authorize`) | `opencode auth login` for chatgpt | **persistent `ext_agent_host_id`**, `agent_name_hint`, scopes incl. `email` (`chatgpt.ts:526-537`) | don't use the provider; delete the DB row / `chatgpt-agent-host-id` KV key |
| Sentry (Desktop only) | renderer crash/error capture (`packages/app/src/app.tsx:67`; `packages/app/src/shell/errors/error.tsx:286-287`) | release `desktop@{version}`, environment, tag `platform:desktop` (`packages/desktop/src/renderer/startup/sentry.ts:10-18`); Sentry server-side also sees IP + browser UA | only active if built with `VITE_SENTRY_DSN` — official Desktop builds set it (`publish.yml:463`); CLI builds do not (`publish.yml:107-116`) |
| npm registry | `opencode plugin add`, configured-plugin install/update (`packages/util/src/npm.ts`; `packages/core/src/plugin/update.ts:40,57`) | package names + IP | don't configure registry plugins |
| OpenTunnel (`@opentunnel/client` 0.4.1, `packages/cli/package.json:41`) | `opencode pair --remote` / `service set remote true` | **per-device tunnel identity** with certificate, stored in an XDG profile (`packages/cli/src/services/remote-tunnel.ts:7,47-55,68`) | opt-in only; never enable remote |
| user OTLP endpoint | only if `OTEL_EXPORTER_OTLP_ENDPOINT` set (`packages/cli/src/index.ts:131-132`) | logs/traces incl. `opencode.run`, `service.instance.id`, channel, version (`otlp.ts:45-61`) | off by default (`otlp.ts:64,75`) |
| GitHub Copilot / xAI / GitLab / etc. auth | provider login/inference | UA (+ GitLab OS/arch, `gitlab.ts:306`); Copilot/xAI standard OAuth | provider-specific |

## Fingerprinting analysis

**1. Stable per-install vs per-session vs per-request.**
Per-install: the ChatGPT `ext_agent_host_id` (random UUID persisted in the local DB KV,
`chatgpt.ts:103-105`) and the OpenTunnel device identity (opt-in). Per-path/repo (hence cross-install): the
project ID, `sha1("directory:"+path)` / `sha1("git-remote:"+url)` (`project.ts:397,292`) — this is the one
identifier that *correlates two installs on different machines* whenever they share a checkout path or a git
remote. Per-session: session IDs and affinity (time-ordered + random, `identifier.ts:16-31`). Per-process:
OTel `runID`, server `instanceID` (never sent by default).

**2. Machine-attribute derivation.** No identifier is derived from machine-id, MAC, hostname, or
`os.userInfo()` for outbound use — `os.userInfo().username` appears only in local config-path discovery
(`packages/core/src/config/discovery.ts:114`) and `os.hostname()` only in lock files
(`packages/util/src/flock.ts:208`). But machine attributes leak *in content*: the GitLab UA embeds
`os.platform()/release()/arch()` (`gitlab.ts:306`); the system-prompt `<env>` block carries the absolute working
directory and `global.tmp` (`instructions/builtins.ts:38-44` — on macOS `os.tmpdir()` is a per-user
`/var/folders/<hash>` path); the report skill adds OS/terminal/shell (`skill.ts:66-68`).

**3. Combination identifiability without any explicit ID.** For opencode.ai's own endpoints (update check,
models catalog), each request carries IP + UA (`opencode/prod/2.1.4/opencode`) + version + channel + artifact +
distribution + timestamp. That is a per-*cohort* fingerprint, but the update check's 10-minute cadence plus IP
makes an individual install trivially distinguishable over time. For *providers*, the combination
`x-opencode-project` (path/repo hash) + session affinity + UA + prompt content (paths, date, platform) uniquely
clusters a user's traffic even with no account — and for a public git remote, the same project ID appears across
different users of that repo, so it is not a private salt.

**4. Human-identity ties.** Console/zen/go login binds the install to an email via device OAuth
(`opencode.ts:80-95,147-204`; email stored locally `account/sql.ts:8`); every Console request carries the Bearer
token, and Console inference events feed opencode's stats lake with user/session/geo/retention dimensions
(`packages/stats/core/src/domain/inference.ts` — "distinct user/session aggregates", geo; `stat-sync.ts`).
`opencode pair --remote` binds the install to an OpenTunnel device certificate. ChatGPT login binds the
persistent host ID to the OpenAI account. The config `username` field ("used for telemetry identity",
`packages/schema/src/config.ts:52-54`) is a v1 leftover — nothing in v2.1.4 reads it (only normalized at
`packages/core/src/config/normalize.ts:212`).

**5. v1 vs v2 deltas (instructive).** v1 had `experimental.openTelemetry` config (opt-in spans) — removed in v2
(`normalize.ts:49`, migrate doc). v1's session-sharing backend (`opncd.ai`) is retired; v2 keeps the `share`
config key but nothing reads it (PR #55716, issue #57932). v1's models.dev fetch is now opencode's own mirror
`models.opencode.ai` (still UA-identified). v1's free title-gen fallback to zen was removed (issue #10416,
maintainer comment 2026-10-17); v2 title generation stays on the session's own provider
(`packages/core/src/session/context.ts:93-110`).

## Opt-out matrix

| Channel | Off switch | Verified at |
|---|---|---|
| Update check | `"update": "disable"` in config, or `OPENCODE_DISABLE_AUTOUPDATE=1` | `updater.ts:534,542-546` |
| Models catalog | `OPENCODE_DISABLE_MODELS_FETCH=1` (or `OPENCODE_MODELS_URL`/`OPENCODE_MODELS_PATH` to a local file) | `server-process.ts:117-119`; snapshot floor `models-dev.ts:16,364` |
| Console/zen/go | never log in; or `policies` deny the `opencode`/`opencode-go` providers | `plugin/provider/opencode.ts:240-246` (no connection ⇒ no polls); `schema/src/config.ts:58` |
| Free opencode models | `OPENCODE_DISABLE_FREE_MODELS=1` | `model.ts:214-228` |
| Websearch | `"websearch": false` or permissions `{action:"websearch",resource:"*",effect:"deny"}` | `config/plugin/websearch.ts:14`; `plugin/agent.ts:86` (default allow) |
| webfetch tool | permissions deny the tool | permissions ruleset (`schema/src/config.ts:55`) |
| OTLP | off unless `OTEL_EXPORTER_OTLP_ENDPOINT` is set | `cli/src/index.ts:131-132`; `otlp.ts:64,75` |
| Sentry (Desktop) | not configurable at runtime; use CLI/TUI instead (no DSN in CLI build) | `publish.yml:107-116` vs `:459-465` |
| Remote tunnel | never `pair --remote` / `service set remote true` | `pair.ts:22-26`; `remote-tunnel.ts` |
| Provider request headers | strip `x-opencode-*` via a `session.model.request` plugin hook | `model-request.ts:298-312` |
| Sharing | nothing to disable — retired (`share`/`enterprise` are dead keys) | PR #55716; issue #57932 |

**What still phones home with all of the above set:** (a) your chosen LLM provider receives the
`x-opencode-*` headers, UA, and prompt content unless stripped by a plugin hook; (b) npm registry lookups if any
plugins are configured (`plugin/update.ts:40`); (c) MCP servers, skill/instruction URLs, and OAuth well-known
discovery you configured yourself (`cli/src/commands/handlers/auth/login.ts:68`); (d) the Desktop app's Sentry on
crashes. With `update: disable` + `OPENCODE_DISABLE_MODELS_FETCH=1` + no Console login + BYOK provider + no
plugins, the shipped CLI makes **no default background request to opencode.ai**.

## Best hardening steps (for this fork)

1. Build with `OPENCODE_CHANNEL`/`OPENCODE_ARTIFACT` you control, and set `update: "disable"` +
   `OPENCODE_DISABLE_AUTOUPDATE=1` + `OPENCODE_DISABLE_MODELS_FETCH=1` in managed config (`/etc/opencode`).
2. Ship a small plugin that hooks `session.model.request` and deletes `x-opencode-project`,
   `x-opencode-session*`, `x-session-affinity`, `X-Session-Id` (the hook fully replaces the header map,
   `model-request.ts:307-312`).
3. Avoid the ChatGPT provider or wipe `chatgpt-agent-host-id` from the DB KV; never enable remote pairing.
4. Prefer CLI/TUI over Desktop if Sentry exposure matters.

## Sources

- Pinned tree: tag v2.1.4, commit `68bc26b7da1990ce10ffecfbc1e09eb13aa5d824` (all `file:line` above).
- https://opencode.ai/v2/docs/migrate-v1 — `openTelemetry` listed under "Accepted but unsupported fields".
- https://github.com/anomalyco/opencode/issues/5554 — "Disable Telemetry"; maintainer: "there isnt any telemetry…
  requests are for models.dev"; v2 env-var-only OTLP.
- https://github.com/anomalyco/opencode/pull/55716 — "retire session sharing backend" (opncd.ai returns 410).
- https://github.com/anomalyco/opencode/issues/57932 — `share`/`enterprise` config keys read by nothing in v2.
- https://github.com/anomalyco/opencode/issues/10416 — v1 zen free-model title-gen fallback; removed ("stopped
  offering free title gen models by default", 2026-10-17).
- https://opencode.ai/v2/docs — install/update endpoints (`opencode.ai/update/api/latest/...`), `opencode pair`.
