#!/usr/bin/env bash
# Format validation — optional regex check against a named pattern in patterns/common.yaml.

: "${SC_PATTERNS_FILE:=$SKILL_ROOT/patterns/common.yaml}"
: "${SC_USER_PATTERNS_FILE:=$HOME/.config/secret-capture/patterns.yaml}"

# _pattern_regex <file> <name>
# The `regex:` value under `  <name>:` in a patterns file, quotes stripped.
# awk, not yq: the shape is fixed (patterns > name > regex), and a missing yq
# used to fail --expect only after the user had already pasted the secret.
_pattern_regex() {
  awk -v want="  $2:" '
    $0 == want { inside = 1; next }
    inside && /^  [^ ]/ { exit }
    inside && /^    regex:/ {
      sub(/^    regex:[[:space:]]*/, "")
      if ($0 ~ /^'\''.*'\''$/ || $0 ~ /^".*"$/) $0 = substr($0, 2, length($0) - 2)
      print
      exit
    }
  ' "$1"
}

# lookup_pattern <name>
# Emits the regex to stdout, or exits non-zero if not found.
lookup_pattern() {
  local name="$1" regex=""
  if [[ -f "$SC_USER_PATTERNS_FILE" ]]; then
    regex=$(_pattern_regex "$SC_USER_PATTERNS_FILE" "$name")
  fi
  if [[ -z "$regex" ]]; then
    regex=$(_pattern_regex "$SC_PATTERNS_FILE" "$name")
  fi
  if [[ -z "$regex" ]]; then
    echo "FORMAT_MISMATCH: unknown pattern '$name'" >&2
    return 5
  fi
  printf '%s' "$regex"
}

# validate_and_forward <pattern-name>
# Reads value from stdin. If it matches the pattern, emits to stdout. Else exits 5.
validate_and_forward() {
  local pattern="$1" regex buf
  regex=$(lookup_pattern "$pattern") || return $?
  IFS= read -r -d '' buf || true
  if [[ "$buf" =~ ^${regex}$ ]]; then
    printf '%s' "$buf"
    buf=""
  else
    buf=""
    echo "FORMAT_MISMATCH: value does not match '$pattern'" >&2
    return 5
  fi
}
