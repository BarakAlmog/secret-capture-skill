#!/usr/bin/env bash
# Adapter: local .env file (dotenv format).
# Writes / updates a KEY='VALUE' line in the target file. File mode locked to 0600.
# Idempotent: if KEY already exists, --rotate is required to overwrite.
#
# The destination is itself a plain-text file: that is what this target is for. The new file
# is written beside it as <file>.sc-new (0600) from the old file's other lines plus the line
# jq builds from the value piped out of the sealed slot, then renamed over it. No copy goes
# anywhere else.
#
# Stdout: env-file:<path>#<key>

set -euo pipefail

# shellcheck source=../lib/slot.sh
source "${SKILL_ROOT:?SKILL_ROOT not set}/scripts/lib/slot.sh"

FILE=""
KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) FILE="$2"; shift 2 ;;
    --key) KEY="$2"; shift 2 ;;
    *) echo "USAGE_ERROR: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

[[ -z "$FILE" ]] && { echo "USAGE_ERROR: --file required" >&2; exit 2; }
[[ -z "$KEY" ]]  && { echo "USAGE_ERROR: --key required" >&2; exit 2; }
[[ "$KEY" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "USAGE_ERROR: --key must be a shell variable name" >&2; exit 2; }

FILE="${FILE/#\~/$HOME}"
ROTATE="${ROTATE:-}"

umask 077
if [[ -f "$FILE" ]] && grep -Eq "^${KEY}=" "$FILE"; then
  [[ -n "$ROTATE" ]] || { echo "DUPLICATE: $KEY already set in $FILE; pass --rotate to overwrite" >&2; exit 6; }
fi

next="${FILE}.sc-new"
trap 'rm -f "$next"' EXIT

# Every other line of the old file, then KEY='value' with each ' in the value written '\''.
{
  if [[ -f "$FILE" ]]; then
    grep -Ev "^${KEY}=" "$FILE" || [[ $? -eq 1 ]]
  fi
  slot_value value | jq -jRs --arg k "$KEY" --arg q "'" '$k + "=" + $q + gsub($q; $q + "\\" + $q + $q) + $q + "\n"'
} > "$next"  # sc-allow-file: the destination itself, renamed over it below

chmod 600 "$next"
mv "$next" "$FILE"
trap - EXIT

printf 'env-file:%s#%s\n' "$FILE" "$KEY"
