#!/usr/bin/env bash
# End-to-end tests for capture.sh, every adapter but keychain, with stubs on PATH for the
# dialog (osascript), f7, op, gh, wrangler, ssh, curl and yq (tests/stubs). No window opens,
# nothing leaves this machine; HOME and TMPDIR point into a scratch directory, so the real
# ~/.f7 slot and 1Password are untouched. All values are fake ("sc-test-...").
#
# After every case: the value never reached stdout or stderr, no file outside the fake
# destinations holds it, TMPDIR is empty and the slot lock is released.
#
# Usage: tests/run.sh          Exit 0 when every check passes.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STUBS="$REPO/tests/stubs"
mkdir -p "$REPO/tmp"
ROOT=$(mktemp -d "$REPO/tmp/test-run.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

PATH="$STUBS:$PATH"
export PATH
unset OP_SERVICE_ACCOUNT_TOKEN SC_FAKE_OP_FAIL SC_FAKE_F7_FAIL SC_TEST_DIALOG SC_FAKE_HTTP_STATUS SC_FAKE_SSH_DOWN SC_FAKE_COOLIFY_MANGLE

for tool in osascript f7 op gh wrangler ssh curl yq; do
  [[ "$(command -v "$tool")" == "$STUBS/$tool" ]] \
    || { echo "ABORT: '$tool' does not resolve to the stub (would touch the real thing)" >&2; exit 2; }
done

passed=0
failed=0
case_n=0
C=""

check() {   # check <description> <command...>
  local what="$1"; shift
  if "$@"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    echo "  FAIL [$CASE] $what" >&2
    [[ -f "$C/err" ]] && sed 's/^/        stderr: /' "$C/err" >&2
  fi
}

fresh() {   # fresh <case name> — a clean world for one case
  CASE="$1"
  case_n=$((case_n + 1))
  C="$ROOT/$case_n"
  mkdir -p "$C/home" "$C/tmp" "$C/dest/op/f7-test" "$C/dest/remote"
  export HOME="$C/home" TMPDIR="$C/tmp" SC_TEST_DIR="$C" SC_TEST_DEST="$C/dest" SC_FAKE_OP_DIR="$C/dest/op"
  unset SC_FAKE_OP_FAIL SC_FAKE_F7_FAIL SC_TEST_DIALOG SC_FAKE_HTTP_STATUS SC_FAKE_SSH_DOWN SC_FAKE_COOLIFY_MANGLE SC_TEST_API_KEY
  echo "- $CASE"
}

capture() {   # capture <args...> — runs capture.sh; sets RC
  RC=0
  bash "$REPO/scripts/capture.sh" "$@" > "$C/out" 2> "$C/err" || RC=$?
}

rc_is() { [[ "$RC" == "$1" ]]; }
out_is() { [[ "$(<"$C/out")" == "$1" ]]; }
err_has() { grep -qF -- "$1" "$C/err"; }
dialogs() { local n=0; [[ -f "$C/dialog-count" ]] && n=$(<"$C/dialog-count"); [[ "$n" == "$1" ]]; }
slot_held() { [[ -f "$HOME/.f7/sealed/capture.sealed" ]]; }
slot_gone() { ! slot_held; }
op_calls() { local n; n=$(grep -c . "$C/dest/op/calls" 2>/dev/null) || n=0; [[ "$n" == "$1" ]]; }
op_writes() { local n; n=$(grep -cE '^item (create|edit)' "$C/dest/op/calls" 2>/dev/null) || n=0; [[ "$n" == "$1" ]]; }

# no_leak <value>... — the values are nowhere but in the fake destinations.
no_leak() {
  local v hits
  for v in "$@"; do
    hits=$(grep -rlF --exclude-dir=dest -- "$v" "$C") || [[ $? -eq 1 ]]
    [[ -z "$hits" ]] || { echo "        leaked into: $hits" >&2; return 1; }
  done
  [[ -z "$(ls -A "$C/tmp")" ]] || { echo "        TMPDIR not empty: $(ls -A "$C/tmp")" >&2; return 1; }
  [[ ! -e "$HOME/.f7/sealed/capture.lock" ]] || { echo "        lock left behind" >&2; return 1; }
}

# The single item titled <title> in the fake vault.
item_file() { grep -lF "\"title\": \"$1\"" "$C/dest/op/f7-test/"*.json; }
field() { jq -r --arg f "$2" '.fields[] | select(.id == $f or .label == $f) | .value' "$(item_file "$1")"; }
field_attr() { jq -r --arg f "$2" --arg a "$3" '.fields[] | select(.id == $f or .label == $f) | .[$a] // ""' "$(item_file "$1")"; }
item_id() { jq -r .id "$(item_file "$1")"; }
field_count() { jq '.fields | length' "$(item_file "$1")"; }

seed_item() {   # seed_item <id> <title> <category> <fields-json>
  jq -n --arg id "$1" --arg t "$2" --arg c "$3" --argjson f "$4" '{id: $id, title: $t, category: $c, version: 1, fields: $f}' \
    > "$C/dest/op/f7-test/$1.json"
}

OLD_FIELDS='[{"id":"notesPlain","label":"notesPlain","type":"STRING","purpose":"NOTES","value":"sc-test-note"},
             {"id":"credential","label":"credential","type":"CONCEALED","value":"sc-test-old"},
             {"id":"keep","label":"keep","type":"STRING","value":"sc-test-keep"}]'

# ------------------------------------------------------------------ lint

echo "lint"
check "lint passes on the repo" bash "$REPO/scripts/lint-adapters.sh" >/dev/null
fixture="$ROOT/lint-fixture"
mkdir -p "$fixture/scripts/adapters" "$fixture/scripts/lib"
cp "$REPO/scripts/capture.sh" "$fixture/scripts/"
cp "$REPO/scripts/lib/"* "$fixture/scripts/lib/"
lint_refuses() {   # lint_refuses <adapter body line> — the lint fails on it
  printf '#!/usr/bin/env bash\n%s\n' "$1" > "$fixture/scripts/adapters/bad.sh"
  ! bash "$REPO/scripts/lint-adapters.sh" "$fixture" >/dev/null 2>&1
}
CASE=lint
check "refuses mktemp"                lint_refuses 'tmp=$(mktemp -t sc-x)'
check "refuses a redirect of the value into a file" lint_refuses 'slot_value value > "$file"'
check "refuses an append into a file" lint_refuses 'printf x >> out.txt'
check "refuses --reveal into a file"  lint_refuses 'op item get "$i" --reveal --format json > "$f" || exit 7'
check "refuses --reveal into a variable" lint_refuses 'x=$(op item get "$i" --reveal)'
check "refuses tee"                   lint_refuses 'slot_value value | tee /tmp/x | gh secret set N'
check "refuses curl -o file"          lint_refuses 'curl -sS -o "$out" https://x'
check "refuses op --template"         lint_refuses 'op item create --template "$f"'
check "refuses a here-string"         lint_refuses 'gh secret set N <<<"$(slot_value value)"'
check "refuses an unquoted heredoc"   lint_refuses $'cat <<EOF | gh secret set N\n$(slot_value value)\nEOF'
check "refuses a dialog writing a file" bash -c "printf 'x.writeToFileAtomicallyEncodingError(p, true, 4, null)\n' > '$fixture/scripts/lib/dialog-many.js'; printf '#!/usr/bin/env bash\ntrue\n' > '$fixture/scripts/adapters/bad.sh'; ! bash '$REPO/scripts/lint-adapters.sh' '$fixture' >/dev/null"
cp "$REPO/scripts/lib/dialog-many.js" "$fixture/scripts/lib/"
check "allows an annotated destination write" bash -c "printf '#!/usr/bin/env bash\nslot_value value > \"\$f\"  # sc-allow-file: test\n' > '$fixture/scripts/adapters/ok.sh'; bash '$REPO/scripts/lint-adapters.sh' '$fixture' >/dev/null"

# ------------------------------------------------------------------ 1password

echo "1password"

fresh "create, one value"
export SC_TEST_ANSWERS='{"value":"sc-test-create-1"}'
capture --target 1password --vault f7-test --item sc-a --field credential
check "exit 0" rc_is 0
check "prints the reference" out_is "op://f7-test/sc-a/credential"
check "one dialog" dialogs 1
check "value stored" test "$(field sc-a credential)" == sc-test-create-1
check "concealed" test "$(field_attr sc-a credential type)" == CONCEALED
check "slot deleted after success" slot_gone
check "4 op calls (list, list, create, verify)" op_calls 4
check "no leak" no_leak sc-test-create-1

fresh "rotate, one value, in place"
seed_item item-r sc-r API_CREDENTIAL "$OLD_FIELDS"
export SC_TEST_ANSWERS='{"value":"sc-test-rotated-1"}'
capture --target 1password --vault f7-test --item sc-r --field credential --rotate
check "exit 0" rc_is 0
check "same item ID" test "$(item_id sc-r)" == item-r
check "new value" test "$(field sc-r credential)" == sc-test-rotated-1
check "other field kept" test "$(field sc-r keep)" == sc-test-keep
check "notes kept" test "$(field sc-r notesPlain)" == sc-test-note
check "field count kept" test "$(field_count sc-r)" == 3
check "slot deleted" slot_gone
check "no leak" no_leak sc-test-rotated-1 sc-test-old sc-test-keep sc-test-note

fresh "several values, LOGIN create"
export SC_TEST_ANSWERS='{"username":"sc-test-user","password":"sc-test-pass-1"}'
capture --target 1password --vault f7-test --item sc-login --category LOGIN --field username:visible --field password
check "exit 0" rc_is 0
check "one reference per field" out_is $'op://f7-test/sc-login/username\nop://f7-test/sc-login/password'
check "one dialog for both" dialogs 1
check "username" test "$(field sc-login username)" == sc-test-user
check "username purpose" test "$(field_attr sc-login username purpose)" == USERNAME
check "password" test "$(field sc-login password)" == sc-test-pass-1
check "password purpose" test "$(field_attr sc-login password purpose)" == PASSWORD
check "slot deleted" slot_gone
check "no leak" no_leak sc-test-user sc-test-pass-1

fresh "several values, rotate"
seed_item item-m sc-m LOGIN '[{"id":"username","label":"username","type":"STRING","purpose":"USERNAME","value":"sc-test-u0"},
  {"id":"password","label":"password","type":"CONCEALED","purpose":"PASSWORD","value":"sc-test-p0"},
  {"id":"keep","label":"keep","type":"STRING","value":"sc-test-keep"}]'
export SC_TEST_ANSWERS='{"username":"sc-test-u1","password":"sc-test-p1"}'
capture --target 1password --vault f7-test --item sc-m --field username:visible --field password --rotate
check "exit 0" rc_is 0
check "same ID" test "$(item_id sc-m)" == item-m
check "username rotated" test "$(field sc-m username)" == sc-test-u1
check "password rotated" test "$(field sc-m password)" == sc-test-p1
check "purpose kept" test "$(field_attr sc-m password purpose)" == PASSWORD
check "other field kept" test "$(field sc-m keep)" == sc-test-keep
check "no leak" no_leak sc-test-u1 sc-test-p1 sc-test-p0

fresh "create fails -> held -> --reuse, no second dialog"
export SC_TEST_ANSWERS='{"value":"sc-test-retry-1"}'
SC_FAKE_OP_FAIL=create capture --target 1password --vault f7-test --item sc-t --field credential
check "exit 7" rc_is 7
check "says HELD and --reuse" err_has "rerun the same command with --reuse"
check "slot held" slot_held
check "no leak while held" no_leak sc-test-retry-1
export SC_TEST_ANSWERS='{"value":"sc-test-WRONG-should-not-be-asked"}'
capture --target 1password --vault f7-test --item sc-t --field credential --reuse
check "retry exit 0" rc_is 0
check "still one dialog" dialogs 1
check "the held value was written" test "$(field sc-t credential)" == sc-test-retry-1
check "slot deleted after the retry" slot_gone
check "no leak" no_leak sc-test-retry-1

fresh "rotate edit fails -> held -> --reuse"
seed_item item-e sc-e API_CREDENTIAL "$OLD_FIELDS"
export SC_TEST_ANSWERS='{"value":"sc-test-retry-2"}'
SC_FAKE_OP_FAIL=edit capture --target 1password --vault f7-test --item sc-e --field credential --rotate
check "exit 7" rc_is 7
check "old value untouched" test "$(field sc-e credential)" == sc-test-old
check "slot held" slot_held
capture --target 1password --vault f7-test --item sc-e --field credential --rotate --reuse
check "retry exit 0" rc_is 0
check "one dialog" dialogs 1
check "rotated" test "$(field sc-e credential)" == sc-test-retry-2
check "same ID" test "$(item_id sc-e)" == item-e
check "no leak" no_leak sc-test-retry-2

fresh "edit applies but reports 404 -> verified, success"
seed_item item-f sc-f API_CREDENTIAL "$OLD_FIELDS"
export SC_TEST_ANSWERS='{"value":"sc-test-404"}'
SC_FAKE_OP_FAIL=edit-404 capture --target 1password --vault f7-test --item sc-f --field credential --rotate
check "exit 0" rc_is 0
check "warns, verified" err_has "holds the new value (verified)"
check "op's own 404 shown" err_has "(404) Not Found"
check "rotated" test "$(field sc-f credential)" == sc-test-404
check "slot deleted" slot_gone
check "no leak" no_leak sc-test-404

fresh "create applies but exits 1 -> verified, success"
export SC_TEST_ANSWERS='{"value":"sc-test-lies"}'
SC_FAKE_OP_FAIL=create-lies capture --target 1password --vault f7-test --item sc-l --field credential
check "exit 0" rc_is 0
check "warns, verified" err_has "(verified)"
check "one item" test "$(ls "$C/dest/op/f7-test" | wc -l | tr -d ' ')" == 1
check "no leak" no_leak sc-test-lies

fresh "edit exits 0 but stores another value -> refused, held"
seed_item item-w sc-w API_CREDENTIAL "$OLD_FIELDS"
export SC_TEST_ANSWERS='{"value":"sc-test-want"}'
SC_FAKE_OP_FAIL=edit-wrong capture --target 1password --vault f7-test --item sc-w --field credential --rotate
check "exit 7" rc_is 7
check "says the stored value differs, and why" err_has "stored value differs"
check "slot held" slot_held
check "no leak" no_leak sc-test-want

fresh "preflight: PASSWORD without its password field"
export SC_TEST_ANSWERS='{"value":"sc-test-x"}'
capture --target 1password --vault f7-test --item sc-p --category PASSWORD --field credential
check "exit 2" rc_is 2
check "no dialog" dialogs 0
check "no write" op_writes 0

fresh "PASSWORD with --field password"
export SC_TEST_ANSWERS='{"value":"sc-test-pw"}'
capture --target 1password --vault f7-test --item sc-pw --category password --field password
check "exit 0" rc_is 0
check "built-in password purpose" test "$(field_attr sc-pw password purpose)" == PASSWORD
check "no leak" no_leak sc-test-pw

fresh "preflight: LOGIN without username"
capture --target 1password --vault f7-test --item sc-x --category LOGIN --field password
check "exit 2" rc_is 2
check "no dialog" dialogs 0

fresh "preflight: unsupported category"
capture --target 1password --vault f7-test --item sc-x --category CREDIT_CARD
check "exit 2" rc_is 2
check "no dialog" dialogs 0

fresh "preflight: unreachable vault"
capture --target 1password --vault nope --item sc-x
check "exit 7" rc_is 7
check "no dialog" dialogs 0

fresh "preflight: duplicate on create"
seed_item item-d sc-d API_CREDENTIAL "$OLD_FIELDS"
capture --target 1password --vault f7-test --item sc-d
check "exit 6" rc_is 6
check "no dialog" dialogs 0

fresh "preflight: two items share the title"
seed_item item-d1 sc-dd API_CREDENTIAL "$OLD_FIELDS"
seed_item item-d2 sc-dd API_CREDENTIAL "$OLD_FIELDS"
capture --target 1password --vault f7-test --item sc-dd --rotate
check "exit 7" rc_is 7
check "names both" err_has "2 items"
check "no dialog" dialogs 0

fresh "preflight: rotate target missing"
capture --target 1password --vault f7-test --item sc-none --rotate
check "exit 7" rc_is 7
check "NOT_FOUND" err_has "NOT_FOUND"
check "no dialog" dialogs 0

fresh "preflight: rotate field missing"
seed_item item-g sc-g API_CREDENTIAL "$OLD_FIELDS"
capture --target 1password --vault f7-test --item sc-g --field api-key --rotate
check "exit 7" rc_is 7
check "names the field" err_has "api-key"
check "no dialog" dialogs 0

fresh "cancel"
SC_TEST_DIALOG=cancel capture --target 1password --vault f7-test --item sc-c
check "exit 4" rc_is 4
check "no slot" slot_gone
check "no write" op_writes 0

fresh "seal fails"
export SC_TEST_ANSWERS='{"value":"sc-test-noseal"}'
SC_FAKE_F7_FAIL=seal capture --target 1password --vault f7-test --item sc-s
check "exit 7" rc_is 7
check "no write" op_writes 0
check "no leak" no_leak sc-test-noseal

fresh "--reuse with nothing held"
capture --target 1password --vault f7-test --item sc-n --reuse
check "exit 2" rc_is 2
check "no dialog" dialogs 0

fresh "--reuse with a value held for another destination"
export SC_TEST_ANSWERS='{"value":"sc-test-for-a"}'
SC_FAKE_OP_FAIL=create capture --target 1password --vault f7-test --item sc-for-a
check "first run fails, held" slot_held
capture --target 1password --vault f7-test --item sc-for-b --reuse
check "exit 2" rc_is 2
check "names both destinations" err_has '"sc-for-a"'
check "slot still held" slot_held
check "no second write" op_writes 1
capture --target 1password --vault f7-test --item sc-for-a --field credential --reuse
check "other flags (here --field) count as another destination" rc_is 2
capture --target 1password --vault f7-test --item sc-for-a --reuse
check "the same destination takes it" rc_is 0
check "written to A" test "$(field sc-for-a credential)" == sc-test-for-a
check "no leak" no_leak sc-test-for-a

fresh "a new capture discards a held value; a cancelled one leaves none"
export SC_TEST_ANSWERS='{"value":"sc-test-held-old"}'
SC_FAKE_OP_FAIL=create capture --target 1password --vault f7-test --item sc-old
check "held" slot_held
SC_TEST_DIALOG=cancel capture --target 1password --vault f7-test --item sc-old
check "cancelled" rc_is 4
check "says it discarded the held value" err_has "discarding the value held"
check "nothing held after the cancel" slot_gone
capture --target 1password --vault f7-test --item sc-old --reuse
check "--reuse finds nothing" rc_is 2
check "no leak" no_leak sc-test-held-old

fresh "--title is refused"
capture --target 1password --vault f7-test --item sc-ti --title other-name
check "exit 2" rc_is 2
check "no dialog" dialogs 0

fresh "lock held by a live capture"
mkdir -p "$HOME/.f7/sealed"
sleep 30 &
holder=$!
ln -s "$holder" "$HOME/.f7/sealed/capture.lock"
export SC_TEST_ANSWERS='{"value":"sc-test-busy"}'
capture --target 1password --vault f7-test --item sc-b
check "exit 10" rc_is 10
check "BUSY" err_has "BUSY"
check "no dialog" dialogs 0
check "the other capture's lock is left alone" test "$(readlink "$HOME/.f7/sealed/capture.lock")" == "$holder"
kill "$holder"
wait "$holder" 2>/dev/null || true
capture --target 1password --vault f7-test --item sc-b
check "a dead holder's lock is taken over" rc_is 0
check "no leak" no_leak sc-test-busy

# ------------------------------------------------------------------ other adapters

echo "other adapters"

fresh "gh-secret: missing flag refused before the dialog"
capture --target gh-secret --scope repo --name API_KEY
check "exit 2" rc_is 2
check "no dialog" dialogs 0

fresh "gh-secret"
export SC_TEST_ANSWERS='{"value":"sc-test-gh"}'
capture --target gh-secret --scope repo --repo o/r --name API_KEY
check "exit 0" rc_is 0
check "reference" out_is "gh-secret:o/r#API_KEY"
check "stored" test "$(<"$C/dest/gh/API_KEY")" == sc-test-gh
check "slot deleted" slot_gone
check "no leak" no_leak sc-test-gh

fresh "wrangler"
export SC_TEST_ANSWERS='{"value":"sc-test-wr \"quoted\""}'
capture --target wrangler --worker w1 --name TOKEN
check "exit 0" rc_is 0
check "stored as JSON" test "$(jq -r .TOKEN "$C/dest/wrangler/w1.json")" == 'sc-test-wr "quoted"'
check "no leak" no_leak sc-test-wr

envfile_value() { ( set +u; set -a; source "$1"; printf '%s' "${!2}" ); }

fresh "env-file create and rotate"
envf="$C/dest/app.env"
printf 'OTHER=keep-me\nAPI_KEY=old\n' > "$envf"
export SC_TEST_ANSWERS="{\"value\":\"sc-test-env 'q' \$HOME\"}"
capture --target env-file --file "$envf" --key API_KEY
check "duplicate without --rotate" rc_is 6
check "refused before the dialog" dialogs 0
capture --target env-file --file "$envf" --key API_KEY --rotate
check "exit 0" rc_is 0
check "value round-trips through the shell" test "$(envfile_value "$envf" API_KEY)" == "sc-test-env 'q' \$HOME"
check "other line kept" test "$(envfile_value "$envf" OTHER)" == keep-me
check "mode 600" test "$(stat -f %Lp "$envf")" == 600
check "no .sc-new left" test ! -e "$envf.sc-new"
check "one dialog" dialogs 1
check "no leak" no_leak sc-test-env

fresh "ssh file-kv create and rotate"
remote="$C/dest/remote/app.env"
printf 'OTHER=keep-me\n' > "$remote"
export SC_TEST_ANSWERS="{\"value\":\"sc-test-ssh 'q'\"}"
capture --target ssh --ssh-host box --mode file-kv --remote-path "$remote" --key DB_PASS
check "exit 0" rc_is 0
check "value" test "$(envfile_value "$remote" DB_PASS)" == "sc-test-ssh 'q'"
check "other line kept" test "$(envfile_value "$remote" OTHER)" == keep-me
export SC_TEST_ANSWERS='{"value":"sc-test-ssh-2"}'
capture --target ssh --ssh-host box --mode file-kv --remote-path "$remote" --key DB_PASS --rotate
check "rotate exit 0" rc_is 0
check "rotated" test "$(envfile_value "$remote" DB_PASS)" == sc-test-ssh-2
check "one line for the key" test "$(grep -c '^DB_PASS=' "$remote")" == 1
check "mode 600" test "$(stat -f %Lp "$remote")" == 600
check "no leak" no_leak "sc-test-ssh 'q'" sc-test-ssh-2

fresh "ssh: duplicate and unreachable host refused before the dialog"
remote="$C/dest/remote/app.env"
printf 'DB_PASS=old\n' > "$remote"
capture --target ssh --ssh-host box --mode file-kv --remote-path "$remote" --key DB_PASS
check "duplicate exit 6" rc_is 6
check "no dialog" dialogs 0
SC_FAKE_SSH_DOWN=1 capture --target ssh --ssh-host box --mode file-raw --remote-path "$C/dest/remote/k"
check "unreachable exit 7" rc_is 7
check "ssh's own error shown" err_has "Connection refused"
check "no dialog" dialogs 0

fresh "ssh file-raw"
export SC_TEST_ANSWERS='{"value":"sc-test-raw"}'
capture --target ssh --ssh-host box --mode file-raw --remote-path "$C/dest/remote/key.pem"
check "exit 0" rc_is 0
check "raw value" test "$(<"$C/dest/remote/key.pem")" == sc-test-raw
check "no leak" no_leak sc-test-raw

http_config() {
  mkdir -p "$HOME/.config/secret-capture"
  jq -n '{defaults: {coolify: {instances: {t: {url: "https://coolify.test", api_key_source: "env:SC_TEST_API_KEY"}}},
                     n8n: {instances: {t: {url: "https://n8n.test", api_key_source: "env:SC_TEST_API_KEY"}}}}}' \
    > "$HOME/.config/secret-capture/config.yaml"
  export SC_TEST_API_KEY=sc-test-apikey
}

fresh "coolify"
http_config
export SC_TEST_ANSWERS='{"value":"sc-test-cool"}'
capture --target coolify --coolify-instance t --app-uuid u1 --key DB_URL --rotate
check "exit 0" rc_is 0
check "PATCH on rotate" test "$(<"$C/dest/http/0.method")" == PATCH
check "body carries the value" test "$(jq -r .value "$C/dest/http/0.body")" == sc-test-cool
check "token header through a pipe" grep -qF "authorization: Bearer sc-test-apikey" "$C/dest/http/0.headers"
check "read back with a GET" test "$(<"$C/dest/http/1.method")" == GET
check "no leak" no_leak sc-test-cool sc-test-apikey

fresh "coolify stores a different value -> stored value differs, held"
http_config
export SC_TEST_ANSWERS='{"value":"sc-test-mangled"}'
SC_FAKE_COOLIFY_MANGLE=1 capture --target coolify --coolify-instance t --app-uuid u1 --key DB_URL
check "exit 7" rc_is 7
check "stored value differs" err_has "stored value differs"
check "slot held" slot_held
check "no leak" no_leak sc-test-mangled

fresh "coolify: config and API key checked before the dialog"
capture --target coolify --coolify-instance t --app-uuid u1 --key DB_URL
check "no config: exit 9" rc_is 9
http_config
unset SC_TEST_API_KEY
capture --target coolify --coolify-instance t --app-uuid u1 --key DB_URL
check "unresolvable API key: exit 9" rc_is 9
check "no dialog" dialogs 0

fresh "coolify HTTP 422 -> held"
http_config
export SC_TEST_ANSWERS='{"value":"sc-test-cool-2"}'
SC_FAKE_HTTP_STATUS=422 capture --target coolify --coolify-instance t --app-uuid u1 --key DB_URL
check "exit 7" rc_is 7
check "curl's error shown" err_has "returned error: 422"
check "slot held" slot_held
check "no leak" no_leak sc-test-cool-2

fresh "n8n"
http_config
export SC_TEST_ANSWERS='{"value":"sc-test-n8n"}'
capture --target n8n --instance t --name my-cred --type httpHeaderAuth --fields-json '{"name":"X-Key"}'
check "exit 0" rc_is 0
check "reference with id" out_is "n8n-cred:my-cred (id=cred-0)"
check "stored" test "$(jq -r '.[0].data.value + "|" + .[0].data.name' "$C/dest/n8n.json")" == "sc-test-n8n|X-Key"
capture --target n8n --instance t --name my-cred --type httpHeaderAuth
check "duplicate exit 6" rc_is 6
check "refused before the dialog" dialogs 1
export SC_TEST_ANSWERS='{"value":"sc-test-n8n-2"}'
capture --target n8n --instance t --name my-cred --type httpHeaderAuth --rotate
check "rotate exit 0" rc_is 0
check "same credential" out_is "n8n-cred:my-cred (id=cred-0)"
check "one credential" test "$(jq length "$C/dest/n8n.json")" == 1
check "rotated, other data kept" test "$(jq -r '.[0].data.value + "|" + .[0].data.name' "$C/dest/n8n.json")" == "sc-test-n8n-2|X-Key"
capture --target n8n --instance t --name other --type httpHeaderAuth --rotate
check "rotate missing: exit 7" rc_is 7
check "rotate missing before the dialog" dialogs 2
check "no leak" no_leak sc-test-n8n sc-test-n8n-2 sc-test-apikey

echo
echo "SKIPPED: keychain (would write the real login keychain); the TTY fallback (needs a terminal)."
echo "tests: $passed passed, $failed failed"
(( failed == 0 ))
