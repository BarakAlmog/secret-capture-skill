#!/usr/bin/env bash
# secret-capture — entry script.
#
# Parses --target and adapter flags, loads config, runs preflight, then invokes
# the adapter in a single subshell with the dialog-captured value piped into it.
# The only thing this script emits on stdout is the adapter's reference string.
#
# Exit codes (every error is also tagged on stderr with its NAMED CODE):
#   0  — success
#   2  — USAGE_ERROR        (bad args, unknown target, target not enabled in config)
#   3  — NO_GUI             (no WindowServer + no TTY)
#   4  — CANCELLED          (user dismissed dialog or Ctrl-C at TTY)
#   5  — FORMAT_MISMATCH    (--expect regex didn't match)
#   6  — DUPLICATE          (record exists at destination, --rotate not passed)
#   7  — ADAPTER_ERROR      (subcommand non-zero / missing tool)
#   8  — AUTH_FAIL          (op not signed in / gh auth expired / destination 401)
#   9  — CONFIG_ERROR       (required config field missing in ~/.config/secret-capture/config.yaml)

SKILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SKILL_ROOT

# shellcheck source=lib/hygiene.sh
source "$SKILL_ROOT/scripts/lib/hygiene.sh"
# shellcheck source=lib/dialog.sh
source "$SKILL_ROOT/scripts/lib/dialog.sh"
# shellcheck source=lib/config.sh
source "$SKILL_ROOT/scripts/lib/config.sh"
# shellcheck source=lib/preflight.sh
source "$SKILL_ROOT/scripts/lib/preflight.sh"
# shellcheck source=lib/validate.sh
source "$SKILL_ROOT/scripts/lib/validate.sh"

usage() {
  cat >&2 <<'USAGE'
secret-capture — capture a secret via hidden-input dialog and route it to a destination.

Usage:
  capture.sh --target <target> [target-flags] [--rotate] [--expect <shape>] [--prompt <label>]
             [--field <name>[:visible]]...

Two or more --field flags open one window with a box per field (1password only);
":visible" shows that box as typed (a username), every other box is hidden.

Targets: 1password | keychain | gh-secret | wrangler | coolify | n8n | env-file | ssh

See SKILL.md for target-specific flags, or the README for examples.
USAGE
}

TARGET=""
ROTATE=""
EXPECT=""
PROMPT_LABEL=""
ADAPTER_ARGS=()
FIELD_SPECS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --field) FIELD_SPECS+=("$2"); shift 2 ;;
    --rotate) ROTATE="1"; shift ;;
    --expect) EXPECT="$2"; shift 2 ;;
    --prompt) PROMPT_LABEL="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --*)
      if [[ $# -ge 2 && "${2:0:2}" != "--" ]]; then
        ADAPTER_ARGS+=("$1" "$2"); shift 2
      else
        ADAPTER_ARGS+=("$1"); shift
      fi
      ;;
    *)
      echo "USAGE_ERROR: unexpected arg '$1'" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  usage
  exit 2
fi

ADAPTER_SCRIPT="$SKILL_ROOT/scripts/adapters/${TARGET}.sh"
[[ -f "$ADAPTER_SCRIPT" ]] \
  || { echo "USAGE_ERROR: unknown target '$TARGET'" >&2; exit 2; }

# Several --field flags: one window, one value per field, handed to the adapter
# as files in SC_VALUES_DIR. Only an adapter that reads SC_VALUES_DIR takes them.
MULTI=""
if (( ${#FIELD_SPECS[@]} > 1 )); then
  grep -q 'SC_VALUES_DIR' "$ADAPTER_SCRIPT" \
    || { echo "USAGE_ERROR: target '$TARGET' takes one value; pass one --field" >&2; exit 2; }
  [[ -n "$EXPECT" ]] \
    && { echo "USAGE_ERROR: --expect checks one value; drop it when passing several --field" >&2; exit 2; }
  dupes=$(printf '%s\n' "${FIELD_SPECS[@]%%:*}" | sort | uniq -d)
  [[ -z "$dupes" ]] || { echo "USAGE_ERROR: field named twice: $dupes" >&2; exit 2; }
  MULTI=1
fi
for spec in ${FIELD_SPECS[@]+"${FIELD_SPECS[@]}"}; do
  if [[ -n "$MULTI" ]]; then ADAPTER_ARGS+=(--field "$spec"); else ADAPTER_ARGS+=(--field "${spec%%:*}"); fi
done

config_adapter_enabled "$TARGET" \
  || { echo "DISABLED: '$TARGET' is not in adapters.enabled" >&2; exit 2; }

preflight_check "$TARGET" || exit $?

# A1 — rotation confirmation prompt (opt-in via config).
# hygiene.require_rotation_confirm=true in ~/.config/secret-capture/config.yaml
# asks "rotate <target>? (y/N)" on /dev/tty before running the destructive
# side of a --rotate. Useful for shared items where a mistaken rotation
# would require recovery (e.g. 1P archive restore + token reissue at source).
if [[ -n "$ROTATE" ]]; then
  if [[ "$(config_get hygiene.require_rotation_confirm false)" == "true" ]] && [[ -e /dev/tty ]]; then
    printf 'Rotate %s? This overwrites the existing record. (y/N): ' "$TARGET" > /dev/tty
    read -r reply < /dev/tty || reply=""
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
      echo "CANCELLED: rotation confirmation declined" >&2
      exit 4
    fi
  fi
fi

[[ -z "$PROMPT_LABEL" ]] && PROMPT_LABEL="$TARGET"

# Nothing that can fail without the value may fail after the user pastes it.
# The pattern is looked up now, and an adapter that supports SC_CHECK checks
# its destination now (reachable, duplicate, rotate target), with no stdin.
# Only adapters that name SC_CHECK run this: the rest would read the empty
# stdin as a value and write it.
if [[ -n "$EXPECT" ]]; then
  lookup_pattern "$EXPECT" >/dev/null || exit $?
fi
if grep -q 'SC_CHECK' "$ADAPTER_SCRIPT"; then
  SC_CHECK=1 ROTATE="$ROTATE" SKILL_ROOT="$SKILL_ROOT" bash "$ADAPTER_SCRIPT" ${ADAPTER_ARGS[@]+"${ADAPTER_ARGS[@]}"} </dev/null || exit $?
fi

# Two-stage capture:
#   1. dialog_capture → 0600 tempfile (exit code CHECKED before continuing)
#   2. optional validate → same tempfile
#   3. adapter reads from tempfile via stdin redirect
#
# Why: if dialog_capture is piped directly to the adapter, a CANCELLED dialog
# (exit 4, empty stdout) still lets the adapter run with empty input and
# possibly write an empty value at the destination before pipefail aborts.
# Gating on the dialog's exit code BEFORE the adapter runs closes that gap.
# Tempfile is 0600, shredded on exit — same threat model as the adapter
# tempfiles (wrangler/coolify/n8n all already do this).

umask 077

if [[ -n "$MULTI" ]]; then
  valdir=$(mktemp -d -t sc-values-XXXXXX)
  cleanup_values() {
    local f
    for f in "$valdir"/*; do [[ -e "$f" ]] && { shred -u "$f" 2>/dev/null || rm -f "$f"; }; done
    rmdir "$valdir"
  }
  trap cleanup_values EXIT
  dialog_capture_many "$valdir" "$PROMPT_LABEL" "${FIELD_SPECS[@]}" || exit $?
  SC_VALUES_DIR="$valdir" ROTATE="$ROTATE" SKILL_ROOT="$SKILL_ROOT" bash "$ADAPTER_SCRIPT" "${ADAPTER_ARGS[@]}" </dev/null
  exit $?
fi

valfile=$(mktemp -t sc-value-XXXXXX)
cleanup_value() { shred -u "$valfile" 2>/dev/null || rm -f "$valfile"; }
trap cleanup_value EXIT

dialog_capture "$PROMPT_LABEL" > "$valfile" || exit $?

if [[ -n "$EXPECT" ]]; then
  # Advisory only: a shape is a guess, and providers change key formats. A
  # mismatch is reported and the value is stored anyway; it never drops the
  # paste or reopens the dialog. The user checks the warning, and rotates if
  # the paste really was wrong.
  validate_and_forward "$EXPECT" < "$valfile" > /dev/null 2>&1 \
    || echo "WARNING: value does not look like '$EXPECT'; stored anyway" >&2
fi

ROTATE="$ROTATE" SKILL_ROOT="$SKILL_ROOT" bash "$ADAPTER_SCRIPT" ${ADAPTER_ARGS[@]+"${ADAPTER_ARGS[@]}"} < "$valfile"
