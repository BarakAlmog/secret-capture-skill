#!/usr/bin/env bash
# Adapter: n8n credential (via REST).
# Uses the n8n public API: POST /api/v1/credentials. Request body built by jq on a pipe
# (never in argv or a file).
#
# Stdout: n8n-cred:<name> (id=<id>)
#
# Config: defaults.n8n.instances.<alias>.url
#         defaults.n8n.instances.<alias>.api_key_source

set -euo pipefail

# shellcheck source=../lib/config.sh
source "${SKILL_ROOT:?SKILL_ROOT not set}/scripts/lib/config.sh"
# shellcheck source=../lib/slot.sh
source "$SKILL_ROOT/scripts/lib/slot.sh"

INSTANCE=""
CRED_NAME=""
CRED_TYPE=""
DATA_FIELD="value"
FIELDS_JSON='{}'   # Extra non-secret fields for richer credential types.
                   # Example: --fields-json '{"name":"X-API-Key"}' merges into .data
                   # alongside the secret field. Good for httpHeaderAuth (needs a name +
                   # value), httpBasicAuth (needs user + password), oAuth2Api, etc.

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance) INSTANCE="$2"; shift 2 ;;
    --name) CRED_NAME="$2"; shift 2 ;;
    --type) CRED_TYPE="$2"; shift 2 ;;
    --data-field) DATA_FIELD="$2"; shift 2 ;;
    --fields-json) FIELDS_JSON="$2"; shift 2 ;;
    *) echo "USAGE_ERROR: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

[[ -z "$INSTANCE" ]]  && { echo "USAGE_ERROR: --instance required" >&2; exit 2; }
[[ -z "$CRED_NAME" ]] && { echo "USAGE_ERROR: --name required" >&2; exit 2; }
[[ -z "$CRED_TYPE" ]] && { echo "USAGE_ERROR: --type required (e.g. anthropicApi, httpHeaderAuth)" >&2; exit 2; }

URL=$(config_get "defaults.n8n.instances.${INSTANCE}.url")
[[ -n "$URL" ]] || { echo "CONFIG_ERROR: defaults.n8n.instances.${INSTANCE}.url not set" >&2; exit 9; }

API_KEY_SOURCE=$(config_get "defaults.n8n.instances.${INSTANCE}.api_key_source")
[[ -n "$API_KEY_SOURCE" ]] || { echo "CONFIG_ERROR: defaults.n8n.instances.${INSTANCE}.api_key_source not set" >&2; exit 9; }

ROTATE="${ROTATE:-}"
key_bytes=$(resolve_source "$API_KEY_SOURCE" | wc -c) \
  || { echo "CONFIG_ERROR: defaults.n8n.instances.${INSTANCE}.api_key_source did not resolve (above)" >&2; exit 9; }
(( key_bytes > 0 )) \
  || { echo "CONFIG_ERROR: defaults.n8n.instances.${INSTANCE}.api_key_source resolved to nothing" >&2; exit 9; }
printf '%s' "$FIELDS_JSON" | jq -e 'type == "object"' >/dev/null \
  || { echo "USAGE_ERROR: --fields-json must be a JSON object" >&2; exit 2; }

CREDS_URL="${URL%/}/api/v1/credentials"

# find_cred_id — the id of the credential named $CRED_NAME of type $CRED_TYPE, or nothing.
# GET /credentials lists names and types, never secrets (n8n public API), page by page.
find_cred_id() {
  local cursor="" page ids="" query
  while :; do
    query="limit=250"
    [[ -n "$cursor" ]] && query="$query&cursor=$(jq -rn --arg c "$cursor" '$c | @uri')"
    page=$(curl -sS --fail "$CREDS_URL?$query" \
             -H @<(printf 'X-N8N-API-KEY: '; resolve_source "$API_KEY_SOURCE"; printf '\n')) \
      || { echo "ADAPTER_ERROR: could not list n8n credentials (GET /api/v1/credentials, above)" >&2; return 7; }
    ids="$ids $(printf '%s' "$page" | jq -r --arg n "$CRED_NAME" --arg t "$CRED_TYPE" '[.data[] | select(.name == $n and .type == $t) | .id] | join(" ")')"
    cursor=$(printf '%s' "$page" | jq -r '.nextCursor // empty')
    [[ -n "$cursor" ]] || break
  done
  local found=()
  read -r -a found < <(printf '%s\n' "$ids")
  case "${#found[@]}" in
    0) ;;
    1) printf '%s\n' "${found[0]}" ;;
    *) echo "ADAPTER_ERROR: ${#found[@]} n8n credentials are named '$CRED_NAME' ($CRED_TYPE): ${found[*]}; keep one" >&2; return 7 ;;
  esac
}

cred_id=$(find_cred_id) || exit $?
if [[ -n "$ROTATE" ]]; then
  [[ -n "$cred_id" ]] || { echo "NOT_FOUND: no n8n credential '$CRED_NAME' ($CRED_TYPE); nothing to rotate" >&2; exit 7; }
else
  [[ -z "$cred_id" ]] || { echo "DUPLICATE: n8n credential '$CRED_NAME' ($CRED_TYPE) exists (id=$cred_id); pass --rotate to overwrite" >&2; exit 6; }
fi

# SC_CHECK=1: capture.sh runs this before the dialog, with no value.
[[ -n "${SC_CHECK:-}" ]] && exit 0

# The request body is built by jq from the value piped out of the sealed slot and handed to
# curl on stdin; the API key reaches curl through a pipe (-H @<(...)). The response goes
# straight into jq, which keeps only the credential's id. --fail turns a non-2xx status into
# a non-zero exit. Rotate: PATCH by id with isPartialData, so the credential's other data
# fields are kept. Write-only: n8n never returns credential data, so success is the HTTP
# status alone.
if [[ -n "$ROTATE" ]]; then
  METHOD=PATCH; WRITE_URL="$CREDS_URL/$cred_id"
  BODY_JQ='{ data: ($extra + { ($field): . }), isPartialData: true }'
else
  METHOD=POST; WRITE_URL="$CREDS_URL"
  BODY_JQ='{ name: $name, type: $type, data: ($extra + { ($field): . }) }'
fi
written_id=$(
  slot_value value \
    | jq -c -Rs \
        --arg name "$CRED_NAME" \
        --arg type "$CRED_TYPE" \
        --arg field "$DATA_FIELD" \
        --argjson extra "$FIELDS_JSON" \
        "$BODY_JQ" \
    | curl -sS --fail -X "$METHOD" "$WRITE_URL" \
        -H @<(printf 'X-N8N-API-KEY: '; resolve_source "$API_KEY_SOURCE"; printf '\n') \
        -H 'content-type: application/json' \
        --data-binary @- \
    | jq -r '.id // empty'
) || { echo "ADAPTER_ERROR: n8n write failed (above)" >&2; exit 7; }

if [[ -z "$written_id" ]]; then
  echo "ADAPTER_ERROR: n8n response missing credential id" >&2
  exit 7
fi

printf 'n8n-cred:%s (id=%s)\n' "$CRED_NAME" "$written_id"
