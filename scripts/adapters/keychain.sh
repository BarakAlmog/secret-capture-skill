#!/usr/bin/env bash
# Adapter: macOS Keychain (login keychain).
# Uses `expect` to drive `security add-generic-password -w` interactively so the value
# never appears on argv of the `security` process. `expect` is preinstalled on macOS.
#
# Flags:
#   --service <name>   keychain service name (required)
#   --account <name>   keychain account (default: $USER)
#   --silent-read      grant Apple-signed command-line tools (e.g. /usr/bin/security)
#                      silent, non-interactive read access to this item by setting its
#                      ACL partition list to `apple-tool:,apple:`. Use for secrets read
#                      by a background process (an MCP-launch wrapper, a cron job). Without
#                      it, the first non-interactive read pops a blocking Keychain auth
#                      dialog and fails ("auth prompt dismissed"). Setting the ACL requires
#                      unlocking the keychain, so this prompts once for the login password.
#
# Stdout: keychain:<service>

set -euo pipefail

# shellcheck source=../lib/slot.sh
source "${SKILL_ROOT:?SKILL_ROOT not set}/scripts/lib/slot.sh"

SERVICE=""
ACCOUNT=""
SILENT_READ=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service) SERVICE="$2"; shift 2 ;;
    --account) ACCOUNT="$2"; shift 2 ;;
    --silent-read) SILENT_READ=1; shift ;;
    *) echo "USAGE_ERROR: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

[[ -z "$SERVICE" ]] && { echo "USAGE_ERROR: --service required" >&2; exit 2; }
[[ -z "$ACCOUNT" ]] && ACCOUNT="${USER}"

ROTATE="${ROTATE:-}"

if security find-generic-password -s "$SERVICE" -a "$ACCOUNT" >/dev/null 2>&1; then
  if [[ -z "$ROTATE" ]]; then
    echo "DUPLICATE: keychain entry '$SERVICE' (account '$ACCOUNT') exists; pass --rotate to overwrite" >&2
    exit 6
  fi
fi

# SC_CHECK=1: capture.sh runs this before the dialog, with no value. Flags and the
# duplicate check are done.
[[ -n "${SC_CHECK:-}" ]] && exit 0

# The expect script is passed with -c (it holds no secret), so expect's stdin is free for the
# value, piped out of the sealed slot (lib/slot.sh). SC_ACCOUNT and SC_SERVICE reach the
# expect process via env — they are NOT secrets. The value only lives in expect's Tcl memory
# and goes to `security` over a pty, never on its argv.
TCL='
log_user 0
set acc $env(SC_ACCOUNT)
set svc $env(SC_SERVICE)
set val [read stdin]
if {$val eq ""} { exit 7 }
spawn -noecho /usr/bin/security add-generic-password -a $acc -s $svc -U -w
expect {
  -re {password (data )?for (new|existing) item:} {}
  timeout { exit 7 }
}
send -- "$val\r"
expect {
  -re {retype password for (new|existing) item:} { send -- "$val\r"; exp_continue }
  eof {}
  timeout { exit 7 }
}
set val ""
lassign [wait] pid spawn_id os_error status
if {$os_error != 0} { exit 7 }
exit $status
'
# expect waits for `security` and exits with its status.
if ! slot_value value | SC_ACCOUNT="$ACCOUNT" SC_SERVICE="$SERVICE" expect -c "$TCL" >/dev/null; then
  echo "ADAPTER_ERROR: expect-driven 'security add-generic-password' failed" >&2
  exit 7
fi

# Read back: `security ... -w` prints the stored value and a newline; compare digests.
want=$({ slot_value value; printf '\n'; } | shasum -a 256) \
  || { echo "ADAPTER_ERROR: not verified: the sealed slot did not open (above)" >&2; exit 7; }
got=$(security find-generic-password -s "$SERVICE" -a "$ACCOUNT" -w | shasum -a 256) \
  || { echo "ADAPTER_ERROR: not verified: could not read keychain entry '$SERVICE' back (above)" >&2; exit 7; }
readback_matches "$want" "$got" "keychain entry '$SERVICE'" || exit $?

# --silent-read: open the item's ACL partition list to Apple-signed CLI tools so a
# background reader (e.g. /usr/bin/security inside an MCP-launch wrapper) gets the value
# without a Keychain prompt. Best-effort: the secret is already stored at this point, so
# a partition-list failure only loses silent access — warn and continue, never fail the
# capture. `set-generic-password-partition-list` needs the keychain unlocked and will
# prompt once for the login password.
if [[ -n "$SILENT_READ" ]]; then
  if ! security set-generic-password-partition-list \
        -S apple-tool:,apple: -s "$SERVICE" -a "$ACCOUNT" >/dev/null 2>&1; then
    echo "WARNING: could not set partition list for '$SERVICE'; first non-interactive read may show a Keychain prompt. Fix manually: security set-generic-password-partition-list -S apple-tool:,apple: -s '$SERVICE' -a '$ACCOUNT'" >&2
  fi
fi

printf 'keychain:%s\n' "$SERVICE"
