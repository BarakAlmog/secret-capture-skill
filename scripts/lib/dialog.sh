#!/usr/bin/env bash
# Dialog capture — prompts the user for a secret without echoing it anywhere.
# Emits the value to stdout (for the pipeline).

_has_gui_macos() {
  [[ "$(uname -s)" == "Darwin" ]] && pgrep -q "WindowServer" 2>/dev/null
}

_has_tty() {
  [[ -t 0 && -t 2 ]]
}

# dialog_capture <prompt-label>
# Emits the captured value (no trailing newline) to stdout.
# On cancel: exit 4 (CANCELLED). On no-GUI and no-TTY: exit 3 (NO_GUI).
dialog_capture() {
  # Defensive: silence xtrace inside this function so values never appear in
  # `bash -x` / `set -x` traces. Saved/restored around the function body.
  local _xtrace_was_on=""
  case $- in *x*) _xtrace_was_on=1 ;; esac
  set +x

  local prompt="${1:-secret}"
  local value=""

  if _has_gui_macos; then
    # The same window as dialog_capture_many (dialog-many.js), with one hidden box: it
    # comes to the front with focus and takes Cmd+V. The old `display dialog` opened
    # behind the frontmost app and looked stuck (2026-10-25).
    local dir result
    dir=$(mktemp -d -t sc-one-XXXXXX)
    result=$(osascript -l JavaScript "$SKILL_ROOT/scripts/lib/dialog-many.js" "$dir" "secret-capture" "$prompt" hidden) \
      || { rm -rf "$dir"; echo "ADAPTER_ERROR: the dialog failed" >&2; return 7; }
    if [[ "$result" != ok || ! -s "$dir/1" ]]; then
      rm -rf "$dir"; echo "CANCELLED" >&2; return 4
    fi
    value=$(cat "$dir/1")
    { shred -u "$dir/1" 2>/dev/null || rm -f "$dir/1"; }
    rmdir "$dir"
  elif _has_tty; then
    # TTY fallback: read -s suppresses echo.
    printf 'Enter %s (hidden): ' "$prompt" >&2
    IFS= read -rs value || { echo "CANCELLED" >&2; return 4; }
    printf '\n' >&2
  else
    echo "NO_GUI: no WindowServer and no TTY available" >&2
    return 3
  fi

  # Defensive newline strip: osascript's `text returned` already excludes the trailing
  # newline, and `read -rs` doesn't add one — but if upstream changes or a future
  # capture path appends one, this guarantees adapters receive a clean value.
  value="${value%$'\n'}"

  # Emit without trailing newline; adapters can handle as raw.
  #
  # Pipeline-SIGPIPE defense: some adapters (e.g. keychain via `expect`) close
  # their stdin immediately after `read stdin` returns. Bash's pipefail then
  # propagates the writer's SIGPIPE (exit 141) as a phantom pipeline failure
  # even though the value was already delivered and the adapter succeeded.
  # The subshell with `set +e`, `trap '' PIPE`, and explicit `exit 0` guarantees
  # this stage returns 0 regardless of EPIPE.
  ( set +e; trap '' PIPE; printf '%s' "$value"; exit 0 )
  value=""

  # Restore xtrace if the caller had it on.
  [[ -n "$_xtrace_was_on" ]] && set -x || true
  return 0
}

# dialog_capture_many <out-dir> <title> <spec>...
# One window with one box per spec ("name" hidden, "name:visible" shown as typed).
# Writes value n to <out-dir>/<n>, in spec order. Every box must be filled.
# On cancel: exit 4 (CANCELLED). On no-GUI and no-TTY: exit 3 (NO_GUI).
dialog_capture_many() {
  local _xtrace_was_on=""
  case $- in *x*) _xtrace_was_on=1 ;; esac
  set +x

  local outdir="$1" title="$2"; shift 2
  local spec name mode i=0 value="" args=()
  for spec in "$@"; do
    name="${spec%%:*}"
    mode=hidden; [[ "$spec" == *:visible ]] && mode=visible
    args+=("$name" "$mode")
  done

  if _has_gui_macos; then
    local result
    result=$(osascript -l JavaScript "$SKILL_ROOT/scripts/lib/dialog-many.js" "$outdir" "$title" "${args[@]}") \
      || { echo "ADAPTER_ERROR: the dialog failed" >&2; return 7; }
    [[ "$result" == ok ]] || { echo "CANCELLED" >&2; return 4; }
  elif _has_tty; then
    for spec in "$@"; do
      i=$((i + 1))
      name="${spec%%:*}"
      if [[ "$spec" == *:visible ]]; then
        printf 'Enter %s: ' "$name" >&2
        IFS= read -r value || { echo "CANCELLED" >&2; return 4; }
      else
        printf 'Enter %s (hidden): ' "$name" >&2
        IFS= read -rs value || { echo "CANCELLED" >&2; return 4; }
        printf '\n' >&2
      fi
      printf '%s' "$value" > "$outdir/$i"
      value=""
    done
  else
    echo "NO_GUI: no WindowServer and no TTY available" >&2
    return 3
  fi

  i=0
  for spec in "$@"; do
    i=$((i + 1))
    [[ -s "$outdir/$i" ]] || { echo "CANCELLED: '${spec%%:*}' was left empty" >&2; return 4; }
  done

  [[ -n "$_xtrace_was_on" ]] && set -x || true
  return 0
}
