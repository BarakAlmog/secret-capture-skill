#!/usr/bin/env bash
# Adapter: Coolify application env var.
# Uses Coolify REST directly — the Coolify MCP response body echoes the env var value
# back, which would leak into the agent's tool_result. Shell + curl + >/dev/null avoids that.
#
# Stdout: coolify-env:<app-uuid>#<key>
#
# Config (~/.config/secret-capture/config.yaml):
#   defaults.coolify.instances.<alias>.url            — Coolify base URL for this instance
#   defaults.coolify.instances.<alias>.api_key_source — where to read the Coolify API token from
#
# Multi-instance shape mirrors the n8n adapter. One alias per Coolify instance
# (e.g. d1dx, dsh, cfr). Operators select the target via --coolify-instance.

set -euo pipefail

# shellcheck source=../lib/config.sh
source "${SKILL_ROOT:?SKILL_ROOT not set}/scripts/lib/config.sh"
# shellcheck source=../lib/slot.sh
source "$SKILL_ROOT/scripts/lib/slot.sh"

INSTANCE=""
APP_UUID=""
KEY=""
IS_PREVIEW="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --coolify-instance) INSTANCE="$2"; shift 2 ;;
    --app-uuid) APP_UUID="$2"; shift 2 ;;
    --key) KEY="$2"; shift 2 ;;
    --preview) IS_PREVIEW="true"; shift ;;
    # --build-time dropped: Coolify API (v4.0.0-beta.471) returns 422
    # "is_build_time: This field is not allowed" on the envs POST endpoint.
    # The stored record has an `is_buildtime` field (one word), defaulting to
    # true, but it's not settable via POST. Use Coolify UI if you need to
    # control it per variable.
    *) echo "USAGE_ERROR: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

[[ -z "$INSTANCE" ]] && { echo "USAGE_ERROR: --coolify-instance required (config alias under defaults.coolify.instances)" >&2; exit 2; }
[[ -z "$APP_UUID" ]] && { echo "USAGE_ERROR: --app-uuid required" >&2; exit 2; }
[[ -z "$KEY" ]]      && { echo "USAGE_ERROR: --key required" >&2; exit 2; }

ROTATE="${ROTATE:-}"

COOLIFY_URL=$(config_get "defaults.coolify.instances.${INSTANCE}.url")
[[ -n "$COOLIFY_URL" ]] || { echo "CONFIG_ERROR: defaults.coolify.instances.${INSTANCE}.url not set" >&2; exit 9; }

API_KEY_SOURCE=$(config_get "defaults.coolify.instances.${INSTANCE}.api_key_source")
[[ -n "$API_KEY_SOURCE" ]] || { echo "CONFIG_ERROR: defaults.coolify.instances.${INSTANCE}.api_key_source not set" >&2; exit 9; }

METHOD="POST"
if [[ -n "$ROTATE" ]]; then
  METHOD="PATCH"
fi

# The POST body is built by jq from the value piped out of the sealed slot and handed to curl
# on stdin (--data-binary @-). The API token reaches curl through a pipe (-H @<(...)), never
# a file, argv or env. The response is discarded entirely: Coolify echoes the value back in
# both create and get. --fail turns a non-2xx status into a non-zero exit.
slot_value value \
  | jq -c -Rs --arg k "$KEY" --argjson pre "$IS_PREVIEW" '{ key: $k, value: ., is_preview: $pre }' \
  | curl -sS --fail -X "$METHOD" \
      "${COOLIFY_URL%/}/api/v1/applications/${APP_UUID}/envs" \
      -H @<(printf 'authorization: Bearer '; resolve_source "$API_KEY_SOURCE"; printf '\n') \
      -H 'content-type: application/json' \
      --data-binary @- \
      -o /dev/null \
  || { echo "ADAPTER_ERROR: Coolify write failed (above)" >&2; exit 7; }

printf 'coolify-env:%s#%s\n' "$APP_UUID" "$KEY"
