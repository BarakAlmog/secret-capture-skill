#!/usr/bin/env bash
# Adapter: SSH — inject a secret into a remote host via SSH without the value
# ever appearing in argv, env, shell variables, or the agent transcript.
#
# Two modes:
#   file-kv   Write `KEY='value'` to a remote dotenv-style file. Idempotent;
#             --rotate required to overwrite an existing KEY. Default chmod 600.
#   file-raw  Write the raw value (no KEY=) to a remote file. For PEM, cert,
#             single-token destinations. --rotate required to overwrite.
#
# The value is piped end-to-end: sealed slot (lib/slot.sh) → jq (file-kv builds the
# KEY='value' line) → ssh stdin → remote `cat` into <path>.sc-new (umask 077) → remote
# atomic mv. Never in a local file, argv, env, or shell variable. file-kv rebuilds the
# remote file on the remote side: the old file's other lines never leave the host.
#
# Authentication: relies on your ssh-agent (1Password SSH Agent, system agent,
# or similar). No private key file is ever read by this adapter. If the SSH
# connection can't be established, the adapter fails fast with ADAPTER_ERROR.
#
# Stdout:
#   file-kv  → `ssh-kv:<user>@<host>:<path>#<key>`
#   file-raw → `ssh-file:<user>@<host>:<path>`

set -euo pipefail

# shellcheck source=../lib/slot.sh
source "${SKILL_ROOT:?SKILL_ROOT not set}/scripts/lib/slot.sh"

SSH_HOST=""
SSH_USER=""
MODE=""
REMOTE_PATH=""
KEY=""
CHMOD="600"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-host)    SSH_HOST="$2"; shift 2 ;;
    --ssh-user)    SSH_USER="$2"; shift 2 ;;
    --mode)        MODE="$2"; shift 2 ;;
    --remote-path) REMOTE_PATH="$2"; shift 2 ;;
    --key)         KEY="$2"; shift 2 ;;
    --chmod)       CHMOD="$2"; shift 2 ;;
    *) echo "USAGE_ERROR: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

[[ -z "$SSH_HOST" ]]    && { echo "USAGE_ERROR: --ssh-host required" >&2; exit 2; }
[[ -z "$MODE" ]]        && { echo "USAGE_ERROR: --mode required (file-kv|file-raw)" >&2; exit 2; }
[[ -z "$REMOTE_PATH" ]] && { echo "USAGE_ERROR: --remote-path required" >&2; exit 2; }

case "$MODE" in
  file-kv|file-raw) ;;
  *) echo "USAGE_ERROR: --mode must be 'file-kv' or 'file-raw' (got '$MODE')" >&2; exit 2 ;;
esac

if [[ "$MODE" == "file-kv" ]] && [[ -z "$KEY" ]]; then
  echo "USAGE_ERROR: --key required for --mode file-kv" >&2
  exit 2
fi

case "$CHMOD" in
  [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) ;;
  *) echo "USAGE_ERROR: --chmod must be an octal mode like 600 or 0600 (got '$CHMOD')" >&2; exit 2 ;;
esac

ROTATE="${ROTATE:-}"

# Build the SSH target — user@host form if user given.
if [[ -n "$SSH_USER" ]]; then
  SSH_TARGET="${SSH_USER}@${SSH_HOST}"
else
  SSH_TARGET="$SSH_HOST"
fi

# Common ssh options:
#   -o BatchMode=no               — allow agent prompt (1P SSH Agent, system agent)
#   -o ConnectTimeout=10          — fail fast if host unreachable
#   -o StrictHostKeyChecking=accept-new — first-use auto-accept; change if you prefer paranoid
#   -T                            — no tty allocation (stdin is the secret)
SSH_OPTS=(-o BatchMode=no -o ConnectTimeout=10 -T)

# sq <text> — <text> as one single-quoted word for the remote shell.
sq() {
  local q="'"
  printf "'%s'" "${1//$q/$q\\$q$q}"
}

if [[ "$MODE" == file-kv ]]; then
  [[ "$KEY" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
    || { echo "USAGE_ERROR: --key must be a shell variable name" >&2; exit 2; }
fi

R_PATH=$(sq "$REMOTE_PATH")
R_NEW=$(sq "${REMOTE_PATH}.sc-new")
R_MATCH=$(sq "^${KEY}=")
# Remote: the new content arrives on stdin and lands in <path>.sc-new, then replaces <path>.
# A failed step removes the half-written .sc-new.
R_INSTALL="chmod $CHMOD $R_NEW && mv $R_NEW $R_PATH || { rm -f $R_NEW; exit 1; }"

# Connectivity: a trivial remote command. </dev/null so ssh reads no stdin.
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" 'true' </dev/null >/dev/null \
  || { echo "ADAPTER_ERROR: cannot ssh to $SSH_TARGET (check host, agent, and reachability; above)" >&2; exit 7; }

# Existence probe. file-kv: 0 = KEY= line present. file-raw: 0 = file present.
if [[ "$MODE" == file-kv ]]; then
  probe="test -f $R_PATH || exit 1; grep -Eq $R_MATCH $R_PATH"
  what="$KEY already set in $REMOTE_PATH"
else
  probe="test -f $R_PATH"
  what="$REMOTE_PATH already exists"
fi
probe_rc=0
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$probe" </dev/null || probe_rc=$?
case "$probe_rc" in
  0) [[ -n "$ROTATE" ]] || { echo "DUPLICATE: $what on $SSH_TARGET; pass --rotate to overwrite" >&2; exit 6; } ;;
  1) ;;
  *) echo "ADAPTER_ERROR: could not check $REMOTE_PATH on $SSH_TARGET (exit $probe_rc, above)" >&2; exit 7 ;;
esac

# SC_CHECK=1: capture.sh runs this before the dialog, with no value.
[[ -n "${SC_CHECK:-}" ]] && exit 0

umask 077

case "$MODE" in

  file-kv)
    # jq builds KEY='value' (trailing newlines of the value dropped; each ' written '\'').
    # The remote side keeps every other line of the old file and appends it, last.
    LINE_JQ='$k + "=" + $q + (sub("\n+$"; "") | gsub($q; $q + "\\" + $q + $q)) + $q + "\n"'
    slot_value value \
      | jq -jRs --arg k "$KEY" --arg q "'" "$LINE_JQ" \
      | ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
          "umask 077; { if [ -f $R_PATH ]; then grep -Ev $R_MATCH $R_PATH || [ \$? -eq 1 ]; fi && cat; } > $R_NEW && $R_INSTALL" \
      || { echo "ADAPTER_ERROR: remote write failed on $SSH_TARGET:$REMOTE_PATH" >&2; exit 7; }

    # Read back: from the KEY= line to the end of the file is the line written above.
    want=$(slot_value value | jq -jRs --arg k "$KEY" --arg q "'" "$LINE_JQ" | shasum -a 256) \
      || { echo "ADAPTER_ERROR: not verified: the sealed slot did not open (above)" >&2; exit 7; }
    got=$(ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sed -n '/^${KEY}=/,\$p' $R_PATH" </dev/null | shasum -a 256) \
      || { echo "ADAPTER_ERROR: not verified: could not read $REMOTE_PATH back (above)" >&2; exit 7; }
    readback_matches "$want" "$got" "$SSH_TARGET:$REMOTE_PATH" || exit $?

    printf 'ssh-kv:%s:%s#%s\n' "$SSH_TARGET" "$REMOTE_PATH" "$KEY"
    ;;

  file-raw)
    # Atomic remote write: slot → ssh stdin → remote .sc-new → chmod → mv.
    slot_value value \
      | ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "umask 077; cat > $R_NEW && $R_INSTALL" \
      || { echo "ADAPTER_ERROR: remote write failed on $SSH_TARGET:$REMOTE_PATH" >&2; exit 7; }

    want=$(slot_digest value) \
      || { echo "ADAPTER_ERROR: not verified: the sealed slot did not open (above)" >&2; exit 7; }
    got=$(ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "cat $R_PATH" </dev/null | shasum -a 256) \
      || { echo "ADAPTER_ERROR: not verified: could not read $REMOTE_PATH back (above)" >&2; exit 7; }
    readback_matches "$want" "$got" "$SSH_TARGET:$REMOTE_PATH" || exit $?

    printf 'ssh-file:%s:%s\n' "$SSH_TARGET" "$REMOTE_PATH"
    ;;

esac
