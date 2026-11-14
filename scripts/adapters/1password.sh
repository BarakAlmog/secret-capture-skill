#!/usr/bin/env bash
# Adapter: 1Password item.
# Reads the value(s) from the sealed slot (lib/slot.sh), never from a file. Creates a new
# item, or (with --rotate) edits the existing item in place: same ID, every other field kept.
# Stdout: op://<vault>/<item>/<field>, one line per field.
#
# Create: the slot's JSON -> jq builds the item template -> `op item create --vault V -`.
# Rotate: `op item get <id> --reveal` -> jq swaps the target fields' values for the slot's ->
#   `op item edit <id>`. A template edit replaces the item's whole field list (checked live,
#   op 2.39), so the template carries the full item, other fields' values included.
# Either template is built in this process's memory first and handed to op on stdin only
# when jq succeeded: op never reads a half-built or empty template. It is never in a file,
# on argv or in the environment.
#
# Verify by result: 1Password's exit code is not trusted (this service account has reported
# a 404 on an edit that applied). After every write the item is read back and the stored
# values are compared with the slot's by SHA-256 inside the pipes; nothing is printed.
#
# Items are found by exact title with `op item list` (no values in its output, archived
# items left out) and then addressed by ID.
#
# Several fields (SC_MULTI=1, one --field per value): the slot holds {"<field>": value}.
# One field: the slot holds {"value": value}. On LOGIN, "username" and "password" carry
# 1Password's login purposes; on PASSWORD, "password" is the built-in password field. A
# ":visible" field is plain text, every other field is concealed.
#
# SC_CHECK=1: capture.sh runs this before the dialog, with no value. Everything that can
# fail without the value fails there: an unsupported category, an unreachable vault, a
# duplicate, a missing rotate target or field.

set -euo pipefail
{ set +x; } 2>/dev/null

# shellcheck source=../lib/slot.sh
source "${SKILL_ROOT:?SKILL_ROOT not set}/scripts/lib/slot.sh"

# Normalize a --category value to the UPPERCASE_UNDERSCORE template id form that
# op item create --category requires. Accepts "API Credential", "api-credential",
# "API_CREDENTIAL", "Login", etc. and produces "API_CREDENTIAL", "LOGIN", etc.
normalize_category() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:lower:]' '[:upper:]' | tr ' -' '_'
}

VAULT=""
ITEM=""
FIELDS=()
CATEGORY="API_CREDENTIAL"
TITLE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vault) VAULT="$2"; shift 2 ;;
    --item) ITEM="$2"; shift 2 ;;
    --field) FIELDS+=("$2"); shift 2 ;;
    --category) CATEGORY="$(normalize_category "$2")"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    *) echo "USAGE_ERROR: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

[[ -z "$VAULT" ]] && { echo "USAGE_ERROR: --vault required" >&2; exit 2; }
[[ -z "$ITEM" ]]  && { echo "USAGE_ERROR: --item required" >&2; exit 2; }
[[ -z "$TITLE" ]] && TITLE="$ITEM"
(( ${#FIELDS[@]} > 0 )) || FIELDS=(credential)
ROTATE="${ROTATE:-}"
SC_MULTI="${SC_MULTI:-}"

# One entry per field: its name, its key in the slot, and the type and purpose a new item
# gives it. Names and kinds only, never a value.
SPECS=$(
  for spec in "${FIELDS[@]}"; do
    name="${spec%%:*}"
    key=value; [[ -n "$SC_MULTI" ]] && key="$name"
    type=CONCEALED; purpose=""
    [[ "$spec" == *:visible ]] && type=STRING
    if [[ "$CATEGORY" == LOGIN && "$name" == username ]]; then type=STRING; purpose=USERNAME; fi
    if [[ "$CATEGORY" == LOGIN && "$name" == password ]]; then type=CONCEALED; purpose=PASSWORD; fi
    if [[ "$CATEGORY" == PASSWORD && "$name" == password ]]; then type=CONCEALED; purpose=PASSWORD; fi
    jq -nc --arg n "$name" --arg k "$key" --arg t "$type" --arg p "$purpose" '{name: $n, key: $k, type: $t, purpose: $p}'
  done | jq -cs .
)

has_field() {
  local want="$1" spec
  for spec in "${FIELDS[@]}"; do [[ "${spec%%:*}" == "$want" ]] && return 0; done
  return 1
}

# A category whose required built-in fields this adapter does not write fails in 1Password
# after the paste ("Password item requires ps value", 2026-11-14). Refuse it before.
check_category() {
  case "$CATEGORY" in
    API_CREDENTIAL|SECURE_NOTE|DATABASE|SERVER) ;;
    LOGIN)
      has_field username && has_field password \
        || { echo "USAGE_ERROR: a LOGIN item needs --field username:visible and --field password" >&2; return 2; }
      ;;
    PASSWORD)
      has_field password \
        || { echo "USAGE_ERROR: a PASSWORD item needs its built-in field: pass --field password, or use --category API_CREDENTIAL" >&2; return 2; }
      ;;
    *)
      echo "USAGE_ERROR: category '$CATEGORY' is not supported; use API_CREDENTIAL, LOGIN, PASSWORD, DATABASE, SECURE_NOTE or SERVER" >&2
      return 2
      ;;
  esac
}

# find_item_id — the ID of the active item titled exactly $ITEM, or nothing when there is none.
# Fails when the vault cannot be listed, or when several items share the title.
find_item_id() {
  local listing ids=()
  listing=$(op item list --vault "$VAULT" --format json | jq -r --arg t "$ITEM" '[.[] | select(.title == $t) | .id] | join(" ")') \
    || { echo "ADAPTER_ERROR: could not list vault '$VAULT' (above)" >&2; return 7; }
  read -r -a ids <<<"$listing"
  case "${#ids[@]}" in
    0) ;;
    1) printf '%s\n' "${ids[0]}" ;;
    *) echo "ADAPTER_ERROR: ${#ids[@]} items in vault '$VAULT' are titled '$ITEM' (${ids[*]}); keep one" >&2; return 7 ;;
  esac
}

# The jq definition every template uses: the slot's value under a key, or an error.
HELD_DEF='def held($v; $k): $v[$k] | if type == "string" and length > 0 then . else error("the sealed slot holds no value under \"\($k)\"") end;'

# verify <id> — 0 when the item's target fields hold exactly the slot's values, 1 when they
# do not, 2 when that could not be checked ("not verified"). Compares SHA-256 digests.
verify() {
  local want got
  want=$(slot_open | jq -cS --argjson specs "$SPECS" '. as $v | [$specs[] | {(.name): $v[.key]}] | add' | shasum -a 256) \
    || return 2
  got=$(op item get "$1" --vault "$VAULT" --format json --reveal | jq -cS --argjson specs "$SPECS" '.fields as $f | [$specs[] | .name as $n | {($n): ([$f[] | select(.id == $n or .label == $n) | .value] | first)}] | add' | shasum -a 256) \
    || return 2
  [[ "$want" == "$got" ]]
}

# settle <id> <op-failed> — report a write by what the item holds, not by op's exit code.
settle() {
  local v=0
  verify "$1" || v=$?
  case "$v" in
    0) [[ -z "$2" ]] || echo "WARNING: 1Password reported a failure (above), but item $1 holds the new value (verified)" >&2 ;;
    1) echo "ADAPTER_ERROR: item $1 does not hold the captured value after the write" >&2; exit 7 ;;
    *) echo "ADAPTER_ERROR: not verified: item $1 could not be read back (above)" >&2; exit 7 ;;
  esac
}

if [[ -n "${SC_CHECK:-}" ]]; then
  [[ -n "$ROTATE" ]] || check_category || exit $?
  id=$(find_item_id) || exit $?
  if [[ -z "$ROTATE" ]]; then
    [[ -z "$id" ]] || { echo "DUPLICATE: item '$ITEM' exists in vault '$VAULT'; pass --rotate to overwrite" >&2; exit 6; }
    exit 0
  fi
  [[ -n "$id" ]] || { echo "NOT_FOUND: item '$ITEM' is not in vault '$VAULT'; nothing to rotate" >&2; exit 7; }
  set +e
  op item get "$id" --vault "$VAULT" --format json \
    | jq -e --argjson specs "$SPECS" '([$specs[].name] - [.fields[] | .id, .label]) as $m | if ($m | length) > 0 then ("NOT_FOUND: field(s) not on item '" + .title + "': " + ($m | join(", ")) + "\n" | halt_error(7)) else true end' >/dev/null
  st=("${PIPESTATUS[@]}")
  set -e
  (( st[0] == 0 )) || { echo "ADAPTER_ERROR: could not read item '$ITEM' (above)" >&2; exit 7; }
  (( st[1] == 0 )) || exit 7
  exit 0
fi

id=$(find_item_id) || exit $?
op_failed=""

if [[ -z "$ROTATE" ]]; then
  check_category || exit $?
  [[ -z "$id" ]] || { echo "DUPLICATE: item '$ITEM' exists in vault '$VAULT'; pass --rotate to overwrite" >&2; exit 6; }
  template=$(slot_open | jq -c --arg title "$TITLE" --arg cat "$CATEGORY" --argjson specs "$SPECS" "$HELD_DEF"'
    . as $v
    | {title: $title, category: $cat,
       fields: [$specs[] | {id: .name, label: .name, type: .type, value: held($v; .key)} + (if .purpose == "" then {} else {purpose: .purpose} end)]}') \
    || { echo "ADAPTER_ERROR: could not build the item from the sealed slot (above)" >&2; exit 7; }
  id=$(printf '%s' "$template" | op item create --vault "$VAULT" --format json - | jq -r '.id') || op_failed=1
  template=""
  if [[ -n "$op_failed" || -z "$id" ]]; then
    op_failed=1
    id=$(find_item_id) || { echo "ADAPTER_ERROR: not verified: op item create failed and the vault could not be listed" >&2; exit 7; }
    [[ -n "$id" ]] || { echo "ADAPTER_ERROR: op item create failed (above); no item '$ITEM' was made" >&2; exit 7; }
  fi
else
  [[ -n "$id" ]] || { echo "NOT_FOUND: item '$ITEM' is not in vault '$VAULT'; nothing to rotate" >&2; exit 7; }
  template=$(op item get "$id" --vault "$VAULT" --format json --reveal | jq -c --argjson specs "$SPECS" --slurpfile slot <(slot_open) "$HELD_DEF"'
    ($slot[0] // {}) as $v
    | ([$specs[].name] - [.fields[] | .id, .label]) as $missing
    | if ($missing | length) > 0 then error("field(s) not on the item: \($missing | join(", "))") else . end
    | .fields |= map(. as $f
        | ([$specs[] | select(.name == $f.id or .name == $f.label)] | first) as $s
        | if $s then .value = held($v; $s.key) else . end)') \
    || { echo "ADAPTER_ERROR: could not build the rotated item (above); nothing was written" >&2; exit 7; }
  printf '%s' "$template" | op item edit "$id" --vault "$VAULT" --format json >/dev/null || op_failed=1
  template=""
fi

settle "$id" "$op_failed"

for spec in "${FIELDS[@]}"; do printf 'op://%s/%s/%s\n' "$VAULT" "$ITEM" "${spec%%:*}"; done
