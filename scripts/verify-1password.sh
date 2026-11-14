#!/usr/bin/env bash
# Check a 1Password capture or rotation without printing a value
# (docs/SECURITY.md › Verifying rotations without peeking).
#
# Usage: scripts/verify-1password.sh <vault> <item> <field>
#
# Prints the item's field labels, sorted, one per line (labels only, no values): run it
# before and after a rotation and compare. Then prints `ok` when <field> holds a value, or
# `empty`. Exit 0 ok, 1 empty, 2 on a usage error or when 1Password did not answer
# ("not verified", its error above).

set -euo pipefail
{ set +x; } 2>/dev/null

[[ $# -eq 3 ]] || { echo "usage: verify-1password.sh <vault> <item> <field>" >&2; exit 2; }
vault="$1"
item="$2"
field="$3"

if ! op item get "$item" --vault "$vault" --format=json |
  python3 -I -c 'import json, sys; print("\n".join(sorted(f.get("label", "") for f in json.load(sys.stdin).get("fields", []))))'; then
  echo "not verified: could not read the labels of $item in $vault (above)" >&2
  exit 2
fi

if ! value="$(op read "op://$vault/$item/$field")"; then
  echo "not verified: op read of $field failed (above)" >&2
  exit 2
fi
if [[ -n "$value" ]]; then
  echo ok
else
  echo empty
  exit 1
fi
