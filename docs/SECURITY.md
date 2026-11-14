# Security model

`secret-capture` is designed so that a captured value **never appears in any agent tool result, log, chat transcript, or shell history**. This document enumerates the leak vectors the skill defends against, how each adapter defends against them, and the known residual risks.

## Threat model

The skill assumes:

- A trusted local user on a single macOS machine.
- A Claude Code (or similar) agent running in the same shell the user invoked the skill from, with the ability to read the skill's stdout and stderr.
- A possibly-adversarial other-UID process on the same machine (via `ps` / `/proc/<pid>/cmdline`).
- An adversarial *future* reader of shell history, log files, and process accounting.
- The destination system itself (1Password, GitHub, Cloudflare, Coolify, n8n) is trusted — if the destination is compromised, this skill offers no defense.

The skill does **not** defend against:

- A compromised dialog interceptor (malware running as the user).
- Memory dumps of the running `capture.sh` / adapter / `expect` / `jq` processes.
- The destination service leaking the value after the skill has written it.

## Leak vectors and mitigations

| Vector | Mitigation |
|---|---|
| **argv exposure** (`ps`, `/proc/<pid>/cmdline`) | Values never appear on argv. Adapters pipe the value out of the sealed slot: `jq -Rs` reads stdin; `curl --data-binary @-` reads the body from stdin and `-H @<(...)` the API token from a pipe; `op item create/edit` read the template from stdin; `expect` gets its script with `-c` and the value on stdin, and drives `security` over a pty. |
| **Environment inheritance** (`/proc/<pid>/environ`) | The value is never `export`ed. Only non-secret metadata (service names, accounts) is passed via env to subprocesses (e.g., `expect`). |
| **Shell history** | `capture.sh` sets `set +o history`, `HISTFILE=/dev/null`. No invocation ever contains the value as a literal. |
| **Stdout/stderr leakage to the agent transcript** | Every subcommand that could echo the value is redirected to `/dev/null`. The only stdout the caller ever sees is the reference string (`op://...`, `keychain:...`, etc). |
| **Disk** | No temp files. The dialog prints the value(s) as one JSON object into `f7 secret seal capture`, which encrypts it to this Mac's Secure Enclave (`~/.f7/sealed/capture.sealed`); adapters read it back with `f7 secret open capture` into a pipe. The slot is deleted after a write that landed and kept after a failure (`--reuse`). `shred` was never a guarantee: it is not installed on macOS, and on an SSD it cannot overwrite in place. `scripts/lint-adapters.sh` fails on `mktemp`, a redirect into a file, `tee`, `curl -o`, `op --template`, an unpiped `--reveal`. Exceptions, marked `# sc-allow-file:`: the `env-file` destination itself and the slot lock's pid. |
| **Coolify response echo** | Coolify's REST API echoes the env var value in create/read responses. The adapter bypasses the Coolify MCP (whose response would enter the agent transcript) and uses `curl ... -o /dev/null` to discard the response. |
| **Wrangler** | `wrangler secret bulk` with no file reads `{"NAME": "value"}` from stdin (wrangler 4.x); jq builds it in the pipe. |
| **n8n response echo** | The response goes straight into `jq -r .id`; nothing else of it is kept or printed. |
| **Dialog cancellation race** | The dialog exits 4 on cancel or an empty box and prints nothing; `slot_seal` seals nothing, and capture.sh reads each stage's exit code before the adapter runs. |
| **1Password exit codes** | Not trusted. After every write the item is read back and the stored values are compared with the slot by SHA-256 inside the pipes. Rotation edits the item in place by ID: `op item get --reveal` piped through jq into `op item edit`, the template held in process memory only until jq succeeded. |

## Verifying rotations without peeking

When validating that a rotation worked, it is easy to accidentally leak the new value by "just checking the first few characters" — e.g., `jq '.value[0:6]'` or printing length. **Don't.**

Safe verification of a rotation:

1. **Field parity and a non-empty target** — `scripts/verify-1password.sh <vault> <item> <field>` before and after: it prints the item's sorted field labels (no values), then `ok` or `empty` for the target field. Compare the label lists for equality. Exit 2 is "not verified", never "empty".
2. **End-to-end sanity** — a script feeds the value to the actual consumer (HTTP API call, CLI command): it reads it with `op read` or `op run` inside and pipes it to the consumer's stdin or header. The agent runs the script and reads only the consumer's status. If the consumer returns 200, the rotation is real.

Agents type no `op read`, `op item get --reveal` or `--format=json`: the shell gate refuses them (2026-11-14). Secrets stay inside scripts.

Never print `.value`, `.value[0:N]`, or `.value | length` for the rotated field.

## Defense against `bash -x` / `set -x` xtrace

Bash's `xtrace` mode prints every expanded command — including variable values — to stderr. Without protection, an operator running `bash -x scripts/capture.sh ...` for debugging would leak the captured value via the `+ printf %s <VALUE>` and `+ value=<VALUE>` trace lines.

`scripts/lib/dialog.sh:dialog_capture` defends against this by saving the caller's xtrace state, calling `set +x` on entry, and restoring the original state on exit. If you write a custom adapter that holds the value in a shell variable, **do the same** — wrap the value-touching block in `set +x` / `set -$_x_was`.

## Status

As of commit `9a08853`, the two bugs surfaced during initial smoke testing (CANCELLED-pipe allowed adapter to run with empty stdin; macOS Automation permission required for System Events) are **resolved**. No outstanding critical implementation risks remain in v1. Residual risks below are inherent to the local-secret-capture threat model, not implementation defects.

## Residual risks

1. **In-process memory**: the value lives briefly in the memory of `osascript`, `expect`, `jq`, `curl`, and the dialog `TextField`. Same-UID processes with access to `/proc/<pid>/mem` can read them during execution. The skill does not use `mlock`.
2. **Keychain-adapter argv of `security`**: argv is `[-a ACCOUNT -s SERVICE -U -w]` — the `-w` has no value because `expect` drives the interactive prompt. Verify with `ps -ax | grep security` during a write — you should see no value.
3. **The sealed slot**: after a failed write the value stays in `~/.f7/sealed/capture.sealed` until a `--reuse` succeeds or the next capture replaces it. It is encrypted to this Mac's Secure Enclave, but any process running as the user on this Mac can open it with no prompt (the f7 trade-off). The `env-file` and `ssh` targets write plain-text files by design.
4. **osascript limits**: no GUI → skill hard-errors with `NO_GUI` (configurable). osascript auto-dismisses the dialog after 120s (`TIMEOUT`). SSH sessions without `launchctl asuser` cannot show a dialog.
5. **User-supplied `command:` source spec in config**: `command:<shell-fragment>` is evaluated via `bash -c`. The user controls this line in their own config file; it is not attacker-controlled unless the user's config file is.

## Verifying no leaks locally

During a write, in another terminal:

```bash
# Confirm no `security` argv leak (keychain adapter)
ps -axo args | grep 'security add-generic-password'   # should NOT contain the value

# Confirm no history entry
tail -n 1 ~/.zsh_history   # should not be the capture command

# Confirm shell history disabled in the capturing shell
echo "$HISTFILE"            # /dev/null
```

For curl-based adapters (`coolify`, `n8n`):

```bash
# Start mitmproxy or a local HTTPS intercept to confirm the request body is POSTed with the correct shape.
# The adapter never logs the request body.
```

## Reporting a vulnerability

If you discover a way the skill leaks a captured value, please open a GitHub issue tagged `security` — or, for sensitive disclosures, email the repo owner directly.
