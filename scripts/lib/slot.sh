#!/usr/bin/env bash
# The sealed slot: where a captured value waits between the dialog and the destination.
#
# One fixed slot, `f7 secret seal capture`, encrypted to this Mac's Secure Enclave and
# filed by f7 as ~/.f7/sealed/capture.sealed. It always holds one JSON object:
#   {"dest": ["<target>", "<flag>", ...], "values": {"value": v}}         one value
#   {"dest": [...],                     "values": {"<field>": v, ...}}  several
# "dest" is the destination the value was captured for (the target and its flags), so a
# --reuse never writes it anywhere else. The dialog pipes into the slot and adapters pipe
# out of it, straight into the destination's stdin: the plain value is never in a file, on
# argv or in the environment.
#
# capture.sh clears the slot when a new capture starts, deletes it after a write that
# landed and keeps it after a failure, so a rerun with --reuse writes the same value
# without another paste. A lock keeps two captures off the slot at once.

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
  slot_open | jq -je --arg k "$1" '.values[$k] | strings'
}

# slot_digest <key> — SHA-256 of one held value, for a read-back compare.
slot_digest() {
  slot_value "$1" | shasum -a 256
}

# slot_has <key>... — succeeds when the slot holds a non-empty string under every key.
# Prints nothing.
slot_has() {
  local keys
  keys=$(printf '%s\0' "$@" | jq -cRs 'split("\u0000") | .[:-1]')
  slot_open | jq -e --argjson keys "$keys" '.values as $o | $keys | all(. as $k | $o[$k] | type == "string" and length > 0)' >/dev/null
}

# slot_dest — the destination the held value was captured for (JSON array, no value).
slot_dest() {
  slot_open | jq -c '.dest'
}

# slot_since — when the slot was sealed (local time).
slot_since() {
  stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$SC_SLOT_FILE"
}

slot_delete() {
  rm -f "$SC_SLOT_FILE"
}

# readback_matches <want-digest> <got-digest> <destination> — after a write, 0 when the
# destination holds exactly the captured value. Otherwise says so and returns 7: rewriting
# the same value would store the same thing, so a --reuse is not the fix.
readback_matches() {
  [[ "$1" == "$2" ]] && return 0
  echo "ADAPTER_ERROR: stored value differs: $3 holds something other than the captured value after the write. Either the write did not land, or the destination changed the value on save (trimmed whitespace, converted line endings or characters). A --reuse would store the same value again; check $3 by hand." >&2
  return 7
}

# The lock is a symlink whose target is the holder's pid: `ln -s` creates it whole, pid
# included, or fails because it exists. No window where it exists without its pid.

# slot_lock — take the slot for this process, or return 10 (BUSY) while another live
# capture holds it. A lock whose process is gone is taken over.
slot_lock() {
  mkdir -p "$SC_SLOT_DIR"
  chmod 700 "$SC_SLOT_DIR"
  ln -s "$$" "$SC_SLOT_LOCK" 2>/dev/null && return 0
  local holder="" moved="$SC_SLOT_LOCK.stale.$$"
  holder=$(readlink "$SC_SLOT_LOCK") \
    || { echo "BUSY: the sealed slot's lock changed hands; retry" >&2; return 10; }
  if kill -0 "$holder" 2>/dev/null; then
    echo "BUSY: another capture (pid $holder) is using the sealed slot; wait for it to finish" >&2
    return 10
  fi
  # Stale: move it aside (rename is atomic), and keep it only if it is the stale one we saw.
  mv "$SC_SLOT_LOCK" "$moved" \
    || { echo "BUSY: another capture took over the stale lock just now" >&2; return 10; }
  if [[ "$(readlink "$moved")" != "$holder" ]]; then
    mv -n "$moved" "$SC_SLOT_LOCK"
    echo "BUSY: another capture took over the stale lock just now" >&2
    return 10
  fi
  rm -f "$moved"
  ln -s "$$" "$SC_SLOT_LOCK" 2>/dev/null \
    || { echo "BUSY: another capture took the sealed slot just now" >&2; return 10; }
}

# slot_unlock — release the lock if this process holds it; never another process's.
slot_unlock() {
  [[ "$(readlink "$SC_SLOT_LOCK" 2>/dev/null)" == "$$" ]] && rm -f "$SC_SLOT_LOCK"
  return 0
}
