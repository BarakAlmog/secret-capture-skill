#!/usr/bin/env bash
# secret-capture — entry script.
#
# Parses --target and adapter flags, loads config, runs preflight, opens the dialog, seals
# what it returns into the sealed slot (lib/slot.sh), then runs the adapter, which pipes the
# value out of the slot into the destination. The only thing this script emits on stdout is
# the adapter's reference string.
#
# The slot is deleted after a write that landed and kept after a failure: rerun the same
# command with --reuse and the held value is written without opening the dialog again.
#
# Exit codes (every error is also tagged on stderr with its NAMED CODE):
#   0  — success
#   2  — USAGE_ERROR        (bad args, unknown target, target not enabled in config,
#                            --reuse with nothing held or held for other fields)
#   3  — NO_GUI             (no WindowServer + no TTY)
#   4  — CANCELLED          (user dismissed dialog, left a box empty, or Ctrl-C at TTY)
#   5  — FORMAT_MISMATCH    (--expect names an unknown pattern)
#   6  — DUPLICATE          (record exists at destination, --rotate not passed)
#   7  — ADAPTER_ERROR      (subcommand non-zero / missing tool / write not verified) or NOT_FOUND
#   8  — AUTH_FAIL          (op not signed in / gh auth expired / destination 401)
#   9  — CONFIG_ERROR       (required config field missing in ~/.config/secret-capture/config.yaml)
#   10 — BUSY               (another capture holds the sealed slot)

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
# shellcheck source=lib/slot.sh
source "$SKILL_ROOT/scripts/lib/slot.sh"

usage() {
  cat >&2 <<'USAGE'
secret-capture — capture a secret via hidden-input dialog and route it to a destination.

Usage:
  capture.sh --target <target> [target-flags] [--rotate] [--expect <shape>] [--prompt <label>]
             [--field <name>[:visible]]... [--reuse]

Two or more --field flags open one window with a box per field (1password only);
":visible" shows that box as typed (a username), every other box is hidden.

--reuse writes the value held from a failed run instead of opening the dialog.

Targets: 1password | keychain | gh-secret | wrangler | coolify | n8n | env-file | ssh

See SKILL.md for target-specific flags, or the README for examples.
USAGE
}

TARGET=""
ROTATE=""
EXPECT=""
PROMPT_LABEL=""
REUSE=""
ADAPTER_ARGS=()
FIELD_SPECS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --field) FIELD_SPECS+=("$2"); shift 2 ;;
    --rotate) ROTATE="1"; shift ;;
    --expect) EXPECT="$2"; shift 2 ;;
    --prompt) PROMPT_LABEL="$2"; shift 2 ;;
    --reuse) REUSE="1"; shift ;;
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

# Several --field flags: one window, one value per field, held in the slot under each
# field's name. Only an adapter that names SC_MULTI takes them.
MULTI=""
if (( ${#FIELD_SPECS[@]} > 1 )); then
  grep -q 'SC_MULTI' "$ADAPTER_SCRIPT" \
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

# The slot's keys, and the dialog's boxes: "value" for one value, each field's name for several.
SLOT_KEYS=()
DIALOG_BOXES=()
if [[ -n "$MULTI" ]]; then
  for spec in "${FIELD_SPECS[@]}"; do
    mode=hidden; [[ "$spec" == *:visible ]] && mode=visible
    SLOT_KEYS+=("${spec%%:*}")
    DIALOG_BOXES+=("${spec%%:*}" "${spec%%:*}" "$mode")
  done
fi

config_adapter_enabled "$TARGET" \
  || { echo "DISABLED: '$TARGET' is not in adapters.enabled" >&2; exit 2; }

preflight_check "$TARGET" || exit $?

# A1 — rotation confirmation prompt (opt-in via config).
# hygiene.require_rotation_confirm=true in ~/.config/secret-capture/config.yaml
# asks "rotate <target>? (y/N)" on /dev/tty before running the destructive
# side of a --rotate. Useful for shared items where a mistaken rotation
# would require recovery (e.g. 1P version history + token reissue at source).
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
if [[ -z "$MULTI" ]]; then
  SLOT_KEYS=(value)
  DIALOG_BOXES=(value "$PROMPT_LABEL" hidden)
fi

# Nothing that can fail without the value may fail after the user pastes it.
# The pattern is looked up now, and an adapter that supports SC_CHECK checks
# its destination now (reachable, duplicate, rotate target, category), with no value.
if [[ -n "$EXPECT" ]]; then
  lookup_pattern "$EXPECT" >/dev/null || exit $?
fi
if grep -q 'SC_CHECK' "$ADAPTER_SCRIPT"; then
  SC_CHECK=1 SC_MULTI="$MULTI" ROTATE="$ROTATE" SKILL_ROOT="$SKILL_ROOT" bash "$ADAPTER_SCRIPT" ${ADAPTER_ARGS[@]+"${ADAPTER_ARGS[@]}"} </dev/null || exit $?
fi

slot_lock || exit $?
trap slot_unlock EXIT

if [[ -n "$REUSE" ]]; then
  slot_exists \
    || { echo "USAGE_ERROR: --reuse, but no value is held; run without --reuse to open the dialog" >&2; exit 2; }
  if ! slot_has "${SLOT_KEYS[@]}"; then
    held=$(slot_keys) || held="(the slot did not open, above)"
    echo "USAGE_ERROR: the held value has the keys [$held], this command needs [${SLOT_KEYS[*]}]; run without --reuse to capture again" >&2
    exit 2
  fi
  echo "NOTE: writing the value held since $(slot_since); no dialog" >&2
else
  slot_exists && echo "NOTE: a value held from an earlier failed capture is replaced by this one" >&2
  # The dialog's stdout goes straight into the slot. Exit codes are read per stage: a
  # cancelled dialog prints nothing, and slot_seal then seals nothing.
  set +e
  dialog_capture "secret-capture" "${DIALOG_BOXES[@]}" | slot_seal
  stages=("${PIPESTATUS[@]}")
  set -e
  (( stages[0] == 0 )) || exit "${stages[0]}"
  (( stages[1] == 0 )) \
    || { echo "ADAPTER_ERROR: the value could not be sealed (f7 secret seal, above); paste it again" >&2; exit 7; }
  slot_has "${SLOT_KEYS[@]}" \
    || { echo "ADAPTER_ERROR: the sealed slot does not open to the captured value (above); paste it again" >&2; exit 7; }
fi

if [[ -n "$EXPECT" ]]; then
  # Advisory only: a shape is a guess, and providers change key formats. A
  # mismatch is reported and the value is stored anyway; it never drops the
  # paste or reopens the dialog. The user checks the warning, and rotates if
  # the paste really was wrong.
  slot_value value | validate_and_forward "$EXPECT" >/dev/null 2>&1 \
    || echo "WARNING: value does not look like '$EXPECT'; stored anyway" >&2
fi

if SC_MULTI="$MULTI" ROTATE="$ROTATE" SKILL_ROOT="$SKILL_ROOT" bash "$ADAPTER_SCRIPT" ${ADAPTER_ARGS[@]+"${ADAPTER_ARGS[@]}"} </dev/null; then
  slot_delete
  exit 0
else
  rc=$?
  echo "HELD: the value stays sealed in $SC_SLOT_FILE. Fix the cause above, then rerun the same command with --reuse: no new paste." >&2
  exit "$rc"
fi
