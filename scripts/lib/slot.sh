#!/usr/bin/env bash
# The sealed slot: where a captured value waits between the dialog and the destination.
#
# One fixed slot, `f7 secret seal capture`, encrypted to this Mac's Secure Enclave and
# filed by f7 as ~/.f7/sealed/capture.sealed. It always holds one JSON object: {"value": v}
# for one value, {"<field>": v, ...} for several. The dialog pipes into it and adapters
# pipe out of it, straight into the destination's stdin: the plain value is never in a
# file, on argv or in the environment.
#
# capture.sh deletes the slot after a write that landed and keeps it after a failure, so a
# rerun with --reuse writes the same value without another paste. A lock keeps two
# captures off the slot at once.

SC_SLOT_NAME="capture"
SC_SLOT_DIR="$HOME/.f7/sealed"
SC_SLOT_FILE="$SC_SLOT_DIR/$SC_SLOT_NAME.sealed"
SC_SLOT_LOCK="$SC_SLOT_DIR/$SC_SLOT_NAME.lock"

slot_exists() {
  [[ -f "$SC_SLOT_FILE" ]]
}

# slot_seal — stdin (the JSON object) into the slot, replacing what it held.
# Returns 4 on empty stdin (nothing was captured) without calling f7.
slot_seal() {
  local first=""
  IFS= read -r -d '' -n 1 first || [[ -n "$first" ]] || return 4
  { printf '%s' "$first"; first=""; cat; } | f7 secret seal "$SC_SLOT_NAME" >/dev/null
}

# slot_open — the slot's JSON object on stdout. Pipe it; never capture it in a variable.
slot_open() {
  f7 secret open "$SC_SLOT_NAME"
}

# slot_value <key> — one held value on stdout, raw, no newline. Pipe it into the destination.
slot_value() {
  slot_open | jq -je --arg k "$1" '.[$k] | strings'
}

# slot_has <key>... — succeeds when the slot holds a non-empty string under every key.
# Prints nothing.
slot_has() {
  slot_open | jq -e --args '. as $o | $ARGS.positional | all(. as $k | $o[$k] | type == "string" and length > 0)' "$@" >/dev/null
}

# slot_keys — the held keys (names only, never values), comma-separated.
slot_keys() {
  slot_open | jq -r 'keys_unsorted | join(", ")'
}

# slot_since — when the slot was sealed (local time).
slot_since() {
  stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$SC_SLOT_FILE"
}

slot_delete() {
  rm -f "$SC_SLOT_FILE"
}

# slot_lock — take the slot for this process, or return 10 (BUSY) while another live
# capture holds it. A lock whose process is gone is taken over.
slot_lock() {
  mkdir -p "$SC_SLOT_DIR"
  chmod 700 "$SC_SLOT_DIR"
  if ! mkdir "$SC_SLOT_LOCK" 2>/dev/null; then
    [[ -d "$SC_SLOT_LOCK" ]] || { echo "ADAPTER_ERROR: cannot create the lock $SC_SLOT_LOCK" >&2; return 7; }
    local holder=""
    [[ -f "$SC_SLOT_LOCK/pid" ]] && holder=$(<"$SC_SLOT_LOCK/pid")
    if [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null; then
      echo "BUSY: another capture (pid $holder) is using the sealed slot; wait for it to finish" >&2
      return 10
    fi
    rm -rf "$SC_SLOT_LOCK"
    mkdir "$SC_SLOT_LOCK" \
      || { echo "BUSY: another capture took the sealed slot just now" >&2; return 10; }
  fi
  printf '%s\n' "$$" > "$SC_SLOT_LOCK/pid"  # sc-allow-file: the lock holder's pid, no value
}

slot_unlock() {
  rm -rf "$SC_SLOT_LOCK"
}
