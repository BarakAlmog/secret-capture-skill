#!/usr/bin/env bash
# Static check over every script that touches a captured value: capture.sh, scripts/lib and
# scripts/adapters. Two families of rules:
#
#   argv / env / stdout (adapters): a value never on argv, in an exported env var, or echoed.
#   no plain text on disk (every script): a value, or a 1Password item revealed with its
#     values, is never written to a file. It moves through pipes, from the sealed slot
#     (lib/slot.sh) into the destination's stdin. Refused: mktemp, a `>`/`>>` redirect to
#     anything but /dev/null, /dev/stderr, /dev/stdout, /dev/tty or a descriptor, tee, curl
#     -o/--output to a file, op --template/--out-file, --reveal not piped straight on, and a
#     dialog script that writes a file.
#
# A redirect that must write a file says why on the same line: `# sc-allow-file: <reason>`.
# Today: env-file's destination (a .env file is plain text by definition) and the slot
# lock's pid.
#
# Usage: lint-adapters.sh [<skill-root>]   (default: this script's repo; tests pass a fixture)
# Exit 0 — clean. Exit 1 — one or more violations, printed on stdout.

set -euo pipefail

SKILL_ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ADAPTER_DIR="$SKILL_ROOT/scripts/adapters"

violations=0

emit() {
  echo "FAIL: $1"
  echo "   file: $2"
  echo "   line: $3"
  echo "   text: $4"
  echo
  violations=$((violations+1))
}

# ---------------------------------------------------------------- argv / env / stdout

declare -a patterns=(
  # Literal value on argv via the --body / --value / --data flag.
  '--body[ =]"?\$' 'value flag with direct expansion'
  '--value[ =]"?\$' 'value flag with direct expansion'
  '--data[ =]"?\$\{?[A-Za-z_]' 'data flag with shell var (pipe it: --data-binary @-)'
  # `-w $VAR` (macOS security and similar).
  '-w[ =]\$[A-Za-z_]' 'inline -w with shell var (use expect/pty or stdin)'
  # export of a value (leaks via /proc/<pid>/environ).
  '^[[:space:]]*export[[:space:]]+[A-Z_]+=\$\(' 'export of $(...) — leaks via env'
  # `password=$VAR` inline assignment to op item create — leaks via argv.
  'password=\$[A-Za-z_]' 'op password= assignment on argv'
  'token=\$[A-Za-z_]' 'op token= assignment on argv'
  'credential=\$[A-Za-z_]' 'op credential= assignment on argv'
  # `echo "$VALUE"` that could reach stdout.
  '^[[:space:]]*echo[[:space:]]+"?\$[A-Za-z_]+"?[[:space:]]*$' 'bare echo of a shell var'
  # printf of a variable to stdout (if it's the capture value).
  'printf[[:space:]]+"\%s"[[:space:]]+"?\$[A-Za-z_]*VALUE' 'printf of a *VALUE variable'
)

n=${#patterns[@]}
for ((i=0; i<n; i+=2)); do
  re="${patterns[i]}"
  desc="${patterns[i+1]}"
  hits=$(grep -nE -e "$re" "$ADAPTER_DIR"/*.sh) || [[ $? -eq 1 ]]
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    file="${hit%%:*}"
    rest="${hit#*:}"
    emit "$desc" "$file" "${rest%%:*}" "${rest#*:}"
  done <<<"$hits"
done

# ---------------------------------------------------------------- no plain text on disk

# logical_lines <file> — one line per shell command line: "<lineno>\t<allow>\t<code>".
# Continuations are joined; comments, heredoc bodies and the inside of quotes are dropped
# (a quoted word is kept as Q, so `> "$file"` still shows its target), and (( )) arithmetic
# is dropped so its `>` is not read as a redirect. <allow> is 1 when the line carries
# `# sc-allow-file:`.
logical_lines() {
  awk '
    function flush() {
      if (code != "" || allow) {
        gsub(/\(\([^)]*\)\)/, "", code)
        printf "%d\t%d\t%s\n", start, allow, code
      }
      code = ""; allow = 0; start = 0
    }
    {
      raw = $0
      if (heredoc != "") {
        line = raw; sub(/^\t+/, "", line)
        if (line == heredoc) heredoc = ""
        next
      }
      if (start == 0) start = NR
      if (raw ~ /# sc-allow-file:/) allow = 1
      cont = 0
      out = ""
      n = length(raw)
      for (i = 1; i <= n; i++) {
        c = substr(raw, i, 1)
        if (sq) { if (c == "\047") { sq = 0; out = out "Q" } ; continue }
        if (dq) {
          if (c == "\\") { i++; continue }
          if (c == "\"") { dq = 0; out = out "Q" }
          continue
        }
        if (c == "\\" && i == n) { cont = 1; break }
        if (c == "\\") { out = out substr(raw, i, 2); i++; continue }
        if (c == "\047") { sq = 1; continue }
        if (c == "\"") { dq = 1; continue }
        if (c == "#" && (i == 1 || substr(raw, i - 1, 1) ~ /[[:space:]]/)) break
        out = out c
      }
      code = code " " out
      # A heredoc (<<TAG, <<\047TAG\047, <<-TAG; not a <<< here-string): skip its body.
      if (match(raw, /(^|[^<])<<-?[[:space:]]*[\047"]?[A-Za-z_]+/)) {
        tag = substr(raw, RSTART, RLENGTH)
        sub(/^[^<]?<<-?[[:space:]]*[\047"]?/, "", tag)
        heredoc = tag
      }
      if (!cont && !sq && !dq) flush()
    }
    END { flush() }
  ' "$1"
}

shell_files=("$SKILL_ROOT/scripts/capture.sh" "$SKILL_ROOT"/scripts/lib/*.sh "$ADAPTER_DIR"/*.sh)

safe_target='(/dev/(null|stderr|stdout|tty)([^A-Za-z0-9_/]|$)|&|\()'

for f in "${shell_files[@]}"; do
  while IFS=$'\t' read -r lineno allow code; do
    if [[ "$code" =~ (^|[^A-Za-z0-9_-])mktemp([^A-Za-z0-9_-]|$) ]]; then
      emit "mktemp: a temp file; keep the value in pipes" "$f" "$lineno" "$code"
    fi
    if [[ "$allow" != 1 ]]; then
      rest="$code"
      while [[ "$rest" =~ [\>][\>]?[[:space:]]*(.*)$ ]]; do
        target="${BASH_REMATCH[1]}"
        if ! [[ "$target" =~ ^$safe_target ]]; then
          emit "redirect into a file (only /dev/null, /dev/stderr, /dev/tty or a descriptor)" "$f" "$lineno" "$code"
          break
        fi
        rest="$target"
      done
    fi
    if [[ "$code" =~ (^|[^A-Za-z0-9_-])tee([^A-Za-z0-9_-]|$) ]]; then
      emit "tee writes a file" "$f" "$lineno" "$code"
    fi
    if [[ "$code" == *curl* && "$code" =~ (^|[[:space:]])(-o|--output)[[:space:]]+([^[:space:]]+) ]] \
       && [[ "${BASH_REMATCH[3]}" != /dev/null ]]; then
      emit "curl output into a file" "$f" "$lineno" "$code"
    fi
    if [[ "$code" =~ (--template|--out-file)([[:space:]=]|$) ]]; then
      emit "op template file: pipe the template on stdin (op item create/edit -)" "$f" "$lineno" "$code"
    fi
    piped="${code//||/ OR }"   # `cmd || fallback` is not a pipe
    if [[ "$code" == *--reveal* ]] && ! [[ "$piped" =~ --reveal[^|]*\| ]]; then
      emit "--reveal not piped straight into the next command" "$f" "$lineno" "$code"
    fi
  done < <(logical_lines "$f")
done

for f in "$SKILL_ROOT"/scripts/lib/*.js; do
  [[ -e "$f" ]] || continue
  hits=$(grep -nE 'writeToFile|writeFile|createFileAtPath|NSFileManager' "$f") || [[ $? -eq 1 ]]
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    emit "dialog script writes a file; print the JSON to stdout" "$f" "${hit%%:*}" "${hit#*:}"
  done <<<"$hits"
done

# ---------------------------------------------------------------- advisory

# Every adapter should send op/curl/wrangler output to /dev/null or straight into jq.
for f in "$ADAPTER_DIR"/*.sh; do
  name=$(basename "$f" .sh)
  case "$name" in
    env-file|keychain) continue ;;  # no network call / no response echo to worry about
  esac
  hits=$(grep -nE '(op item (create|edit)|curl -[sS]|wrangler secret)' "$f") || [[ $? -eq 1 ]]
  while IFS=: read -r lineno text; do
    [[ -z "$lineno" ]] && continue
    [[ "$text" =~ ^[[:space:]]*# ]] && continue
    [[ "$text" =~ ADAPTER_ERROR ]] && continue
    window=$(sed -n "${lineno},$((lineno+10))p" "$f")
    [[ "$window" =~ /dev/null || "$window" =~ \|[[:space:]]*jq ]] && continue
    echo "WARN: potential un-redirected command"
    echo "   file: $f"
    echo "   line: $lineno"
    echo "   text: $text"
    echo
  done <<<"$hits"
done

if (( violations > 0 )); then
  echo "lint-adapters: $violations violation(s)" >&2
  exit 1
fi

echo "lint-adapters: OK (${#shell_files[@]} scripts checked, 0 violations)"
