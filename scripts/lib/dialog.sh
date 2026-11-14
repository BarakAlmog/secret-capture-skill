#!/usr/bin/env bash
# Dialog capture — prompts the user for one or more secrets without echoing them anywhere.
# Emits one JSON object {"<key>": "<value>", ...} on stdout, for a pipe into slot_seal.

_has_gui_macos() {
  [[ "$(uname -s)" == "Darwin" ]] && pgrep -q "WindowServer"
}

_has_tty() {
  [[ -t 0 && -t 2 ]]
}

# dialog_capture <title> <key> <label> <hidden|visible> [<key> <label> <hidden|visible> ...]
# One window with one box per triple. Emits {"<key>": "<value>", ...}, no trailing newline.
# Every box must be filled.
# On cancel or an empty box: exit 4 (CANCELLED), nothing on stdout.
# On no-GUI and no-TTY: exit 3 (NO_GUI). On a dialog that failed: exit 7.
dialog_capture() {
  # Silence xtrace so a value never appears in a `bash -x` trace; restored on return.
  local _xtrace_was_on=""
  case $- in *x*) _xtrace_was_on=1 ;; esac
  set +x

  local title="$1"; shift
  local rc=0

  if _has_gui_macos; then
    # A window that comes to the front with focus and takes Cmd+V. The old `display dialog`
    # opened behind the frontmost app and looked stuck (2026-10-25). It prints the JSON
    # object itself, straight into this function's stdout.
    osascript -l JavaScript "$SKILL_ROOT/scripts/lib/dialog-many.js" "$title" "$@" || rc=$?
    case "$rc" in
      0|4) ;;
      *) echo "ADAPTER_ERROR: the dialog failed (exit $rc)" >&2; rc=7 ;;
    esac
  elif _has_tty; then
    # TTY fallback: read -s suppresses echo. Values stay in this shell's memory until every
    # box is answered, then go out through a pipe (printf is a builtin: no argv).
    local keys=() values=() value="" key label mode
    while (( $# >= 3 )); do
      key="$1" label="$2" mode="$3"; shift 3
      if [[ "$mode" == visible ]]; then
        printf 'Enter %s: ' "$label" >&2
        IFS= read -r value || { echo "CANCELLED" >&2; rc=4; break; }
      else
        printf 'Enter %s (hidden): ' "$label" >&2
        IFS= read -rs value || { echo "CANCELLED" >&2; rc=4; break; }
        printf '\n' >&2
      fi
      [[ -n "$value" ]] || { echo "CANCELLED: '$label' was left empty" >&2; rc=4; break; }
      keys+=("$key")
      values+=("$value")
      value=""
    done
    if (( rc == 0 )); then
      local i
      for i in "${!keys[@]}"; do
        printf '%s' "${values[i]}" | jq -cRs --arg k "${keys[i]}" '{($k): .}'
      done | jq -cjs 'add'
    fi
    values=()
  else
    echo "NO_GUI: no WindowServer and no TTY available" >&2
    rc=3
  fi

  [[ -n "$_xtrace_was_on" ]] && set -x
  return "$rc"
}
