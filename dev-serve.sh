#!/usr/bin/env bash
# Run the opencode-patched SOURCE directly — no binary build.
# Edits under opencode-src/ take effect on Ctrl-C + rerun.
#
# Source-mode notes:
#   - The Web UI is proxied from https://app.opencode.ai. The embedded
#     opencode-web-ui.gen.ts only resolves under Bun.build (a no-`./`
#     import specifier), so source mode cannot serve the local
#     packages/app/dist. Fine for backend/patch testing — the UI still
#     talks to this server's API. Run `bun run dev:web` separately if you
#     need the patched UI.
#   - OPENCODE_MODELS_DEV is unset at source, so the first model-list load
#     fetches https://models.opencode.ai (5-min cache under Global.Path.cache).
#
# Overrides (env):
#   DEV_SERVE_HOST (default 0.0.0.0)  DEV_SERVE_PORT (default 4096)
#   DEV_SERVE_MDNS (default 1)        OPENCODE_SERVER_PASSWORD
#   OPENCODE_DB
# Extra arguments are forwarded to `opencode serve`.

set -euo pipefail

SRC="/home/dev/opencode-patched/opencode-src"
VERSION="1.18.21"

export OPENCODE_EXPERIMENTAL_LSP_TOOL=true
export OPENCODE_ENABLE_EXA=1
export OPENCODE_SERVER_PASSWORD="${OPENCODE_SERVER_PASSWORD:-$(cat "$HOME/opencode_web_pw.txt")}"
export OPENCODE_DB="${OPENCODE_DB:-$HOME/.local/share/opencode/opencode.db}"

HOST="${DEV_SERVE_HOST:-0.0.0.0}"
PORT="${DEV_SERVE_PORT:-4096}"
MDNS="${DEV_SERVE_MDNS:-1}"

mdns_flag=()
if [[ "$MDNS" == "1" || "$MDNS" == "true" ]]; then
  mdns_flag=(--mdns)
fi

exec bun --conditions=browser \
  --define "OPENCODE_VERSION=\"${VERSION}\"" \
  --define "OPENCODE_CHANNEL=\"prod\"" \
  "${SRC}/packages/opencode/src/index.ts" \
  serve --hostname "$HOST" --port "$PORT" "${mdns_flag[@]}" "$@"
