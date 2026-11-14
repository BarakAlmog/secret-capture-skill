#!/usr/bin/env bash
# Adapter: GitHub Actions secret (repo / org / env).
# `gh secret set NAME` reads the value from stdin when --body is absent: the value is piped
# out of the sealed slot (lib/slot.sh) straight into it.
# Stdout: gh-secret:<scope-path>#<name>

set -euo pipefail

# shellcheck source=../lib/slot.sh
source "${SKILL_ROOT:?SKILL_ROOT not set}/scripts/lib/slot.sh"

SCOPE="repo"
NAME=""
REPO=""
ORG=""
ENV_NAME=""
VISIBILITY="all"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) SCOPE="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --org) ORG="$2"; shift 2 ;;
    --env) ENV_NAME="$2"; shift 2 ;;
    --visibility) VISIBILITY="$2"; shift 2 ;;
    *) echo "USAGE_ERROR: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

[[ -z "$NAME" ]] && { echo "USAGE_ERROR: --name required" >&2; exit 2; }

case "$SCOPE" in
  repo) [[ -n "$REPO" ]] || { echo "USAGE_ERROR: --repo required for scope=repo" >&2; exit 2; }
        DEST=(--repo "$REPO"); REF="$REPO#$NAME" ;;
  org)  [[ -n "$ORG" ]] || { echo "USAGE_ERROR: --org required for scope=org" >&2; exit 2; }
        DEST=(--org "$ORG" --visibility "$VISIBILITY"); REF="org/$ORG#$NAME" ;;
  env)  [[ -n "$REPO" && -n "$ENV_NAME" ]] || { echo "USAGE_ERROR: --repo and --env required for scope=env" >&2; exit 2; }
        DEST=(--repo "$REPO" --env "$ENV_NAME"); REF="$REPO/env/$ENV_NAME#$NAME" ;;
  *)    echo "USAGE_ERROR: --scope must be repo|org|env" >&2; exit 2 ;;
esac

# SC_CHECK=1: capture.sh runs this before the dialog, with no value.
[[ -n "${SC_CHECK:-}" ]] && exit 0

# Write-only: GitHub never returns a secret's value, so success is gh's exit code alone.
slot_value value | gh secret set "$NAME" "${DEST[@]}" >/dev/null \
  || { echo "ADAPTER_ERROR: gh secret set failed (above)" >&2; exit 7; }

printf 'gh-secret:%s\n' "$REF"
