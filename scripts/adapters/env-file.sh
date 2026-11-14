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
[[ -d "$(dirname "$FILE")" ]] || { echo "USAGE_ERROR: the directory of $FILE does not exist" >&2; exit 2; }
if [[ -f "$FILE" ]] && grep -Eq "^${KEY}=" "$FILE"; then
  [[ -n "$ROTATE" ]] || { echo "DUPLICATE: $KEY already set in $FILE; pass --rotate to overwrite" >&2; exit 6; }
fi

# SC_CHECK=1: capture.sh runs this before the dialog, with no value.
[[ -n "${SC_CHECK:-}" ]] && exit 0

# The KEY='value' line, with each ' in the value written '\''.
LINE_JQ='$k + "=" + $q + gsub($q; $q + "\\" + $q + $q) + $q + "\n"'

next="${FILE}.sc-new"
trap 'rm -f "$next"' EXIT

# Every other line of the old file, then the KEY='value' line, last.
{
  if [[ -f "$FILE" ]]; then
    grep -Ev "^${KEY}=" "$FILE" || [[ $? -eq 1 ]]
  fi
  slot_value value | jq -jRs --arg k "$KEY" --arg q "'" "$LINE_JQ"
} > "$next"  # sc-allow-file: the destination itself, renamed over it below

chmod 600 "$next"
mv "$next" "$FILE"
trap - EXIT

# Read back: from the KEY= line to the end of the file is the line written above.
want=$(slot_value value | jq -jRs --arg k "$KEY" --arg q "'" "$LINE_JQ" | shasum -a 256) \
  || { echo "ADAPTER_ERROR: not verified: the sealed slot did not open (above)" >&2; exit 7; }
got=$(sed -n "/^${KEY}=/,\$p" "$FILE" | shasum -a 256) \
  || { echo "ADAPTER_ERROR: not verified: could not read $FILE back (above)" >&2; exit 7; }
readback_matches "$want" "$got" "$FILE" || exit $?

printf 'env-file:%s#%s\n' "$FILE" "$KEY"
