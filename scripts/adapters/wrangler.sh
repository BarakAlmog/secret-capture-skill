#!/usr/bin/env bash
# Adapter: Cloudflare Workers secret.
# `wrangler secret bulk` with no file reads {"<name>": "<value>"} from stdin (wrangler 4.x):
# the value is piped out of the sealed slot (lib/slot.sh), through jq, into it. No file.
#
# Stdout: wrangler-secret:<worker>#<name>

set -euo pipefail

# shellcheck source=../lib/slot.sh
source "${SKILL_ROOT:?SKILL_ROOT not set}/scripts/lib/slot.sh"

WORKER=""
NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worker) WORKER="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    *) echo "USAGE_ERROR: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

[[ -z "$WORKER" ]] && { echo "USAGE_ERROR: --worker required" >&2; exit 2; }
[[ -z "$NAME" ]]   && { echo "USAGE_ERROR: --name required" >&2; exit 2; }

slot_value value \
  | jq -cRs --arg name "$NAME" '{ ($name): . }' \
  | wrangler secret bulk --name "$WORKER" >/dev/null \
  || { echo "ADAPTER_ERROR: wrangler secret bulk failed (above)" >&2; exit 7; }

printf 'wrangler-secret:%s#%s\n' "$WORKER" "$NAME"
