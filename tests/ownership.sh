#!/usr/bin/env bash
# Tests for what `lllm setup` and `lllm uninstall` may touch.
#
# Everything runs in a throwaway $HOME under a temp directory, with stubs for
# systemctl, llama-server and curl, so nothing on the real machine is read or
# changed and no service is started or stopped. Needs bash, python3 and `script`
# (util-linux, for the interactive prompts). Run:  tests/ownership.sh
set -u

LLLM=${LLLM:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/lllm}
[ -f "$LLLM" ] || { echo "no lllm at $LLLM (set LLLM=/path/to/bin/lllm)"; exit 2; }
command -v script >/dev/null || { echo "needs 'script' (util-linux)"; exit 2; }

WORK=$(mktemp -d)
FAKE_PID=
cleanup() { [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

# Stubs. systemctl only logs its arguments.
STUBS=$WORK/stubs; mkdir -p "$STUBS"
printf '#!/bin/sh\necho "systemctl $*" >> "$HOME/systemctl.log"\nexit 0\n' > "$STUBS/systemctl"
printf '#!/bin/sh\nexit 0\n' > "$STUBS/llama-server"
printf '#!/bin/sh\nexit 0\n' > "$STUBS/curl"
chmod +x "$STUBS"/*

# A server that answers 403 to everything, so setup's "does the server refuse other
# websites?" probe returns at once instead of waiting for a server that isn't there.
python3 - "$WORK/port" <<'PY' &
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self): self.send_error(403)
    do_POST = do_GET
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
FAKE_PID=$!
for _ in $(seq 50); do [ -s "$WORK/port" ] && break; sleep 0.1; done
[ -s "$WORK/port" ] || { echo "fake server did not start"; exit 2; }

fail=0
ck() { if eval "$2"; then echo "  PASS $1"; else echo "  FAIL $1"; fail=1; fi; }
# Fresh fake home for each scenario: `fresh <name>`.
fresh() {
  local t=$WORK/$1; rm -rf "$t"; mkdir -p "$t/home"
  export HOME=$t/home XDG_CONFIG_HOME=$t/home/.config XDG_DATA_HOME=$t/home/.local/share
  export XDG_CACHE_HOME=$t/home/.cache XDG_STATE_HOME=$t/home/.local/state
  export LLM_SERVER=http://127.0.0.1:$(cat "$WORK/port") PATH=$STUBS:$PATH
  U=$XDG_CONFIG_HOME/systemd/user; C=$XDG_CONFIG_HOME/local-llm
  R=$XDG_STATE_HOME/local-llm/setup-units.json; SVC=local-llm.service
}
run() { timeout 60 python3 "$LLLM" "$@" </dev/null 2>&1; }
# Run with a terminal on stdin and feed it answers: `ask "<args>" $'y\nn\n'`.
ask() { timeout 60 script -qec "python3 '$LLLM' $1" /dev/null <<< "$2" 2>&1 | tr -d '\r'; }

echo "A. setup, then uninstall: removes everything setup wrote"
fresh A; run setup >/dev/null; : > "$HOME/systemctl.log"
run uninstall -y >/dev/null
ck "all three units removed" '[ -z "$(ls "$U" 2>/dev/null)" ]'
ck "the record is removed" '[ ! -e "$R" ]'
ck "both units were disabled" 'grep -qx "systemctl --user disable --now local-llm.service local-llm-reload.path" "$HOME/systemctl.log"'

echo "B. a unit the user kept during setup survives uninstall"
fresh B; run setup >/dev/null
sed -i 's/--port 8080/--port 8099/' "$U/$SVC"; cp "$U/$SVC" "$WORK/mine.service"
ask setup $'n\n' >/dev/null; : > "$HOME/systemctl.log"
out=$(run uninstall -y)
ck "the user's unit is still there, unchanged" 'cmp -s "$U/$SVC" "$WORK/mine.service"'
ck "uninstall says it kept it" 'grep -q "kept .*local-llm.service" <<<"$out"'
ck "only the reload path was disabled" 'grep -qx "systemctl --user disable --now local-llm-reload.path" "$HOME/systemctl.log"'
ck "the user's service was never disabled" '! grep disable "$HOME/systemctl.log" | grep -qF local-llm.service'
ck "the two units setup wrote are removed" '[ ! -e "$U/local-llm-reload.service" ] && [ ! -e "$U/local-llm-reload.path" ]'

echo "C. install from before the record existed, units as setup writes them: removed"
fresh C; run setup >/dev/null; rm -rf "$XDG_STATE_HOME"
run uninstall -y >/dev/null
ck "all three units removed" '[ -z "$(ls "$U" 2>/dev/null)" ]'

echo "D. install from before the record existed, one unit edited: kept"
fresh D; run setup >/dev/null; rm -rf "$XDG_STATE_HOME"
sed -i 's/--port 8080/--port 8099/' "$U/$SVC"; : > "$HOME/systemctl.log"
run uninstall -y >/dev/null
ck "the edited unit is kept" '[ -e "$U/$SVC" ]'
ck "it was never disabled" '! grep disable "$HOME/systemctl.log" | grep -qF local-llm.service'

echo "E. unit edited after setup: kept"
fresh E; run setup >/dev/null
echo "# my tweak" >> "$U/$SVC"
run uninstall -y >/dev/null
ck "the edited unit is kept" 'grep -q "my tweak" "$U/$SVC"'
ck "the record is cleared" '[ ! -e "$R" ]'

echo "F. kept a unit, then re-ran setup and accepted the replacement: setup's again"
fresh F; run setup >/dev/null
sed -i 's/--port 8080/--port 8099/' "$U/$SVC"
ask setup $'y\n' >/dev/null
ck "the unit is setup's version again" 'grep -q "port 8080" "$U/$SVC"'
run uninstall -y >/dev/null
ck "uninstall removes it" '[ ! -e "$U/$SVC" ]'

echo "G. interactive uninstall asks about a unit it doesn't own"
fresh G; run setup >/dev/null; sed -i 's/--port 8080/--port 8099/' "$U/$SVC"
out=$(ask uninstall $'y\nn\n')
ck "it asks" 'grep -q "wasn.t written by lllm setup" <<<"$out"'
ck "answering n keeps the unit" '[ -e "$U/$SVC" ]'
ck "the other units are removed" '[ ! -e "$U/local-llm-reload.path" ]'

echo "H. server.env keeps the user's own settings"
fresh H; run setup >/dev/null
printf 'CUDA_VISIBLE_DEVICES=0\nFOO=bar' > "$C/server.env"          # no trailing newline
run setup --api-key >/dev/null
ck "--api-key keeps the user's lines" 'grep -qx "CUDA_VISIBLE_DEVICES=0" "$C/server.env" && grep -qx "FOO=bar" "$C/server.env"'
ck "--api-key adds exactly one key line" '[ "$(grep -c ^LLAMA_ARG_API_KEY_FILE= "$C/server.env")" = 1 ]'
ck "server.env is private (0600)" '[ "$(stat -c %a "$C/server.env")" = 600 ]'
run setup --api-key >/dev/null
ck "a second --api-key adds no duplicate" '[ "$(grep -c ^LLAMA_ARG_API_KEY_FILE= "$C/server.env")" = 1 ]'
run setup --no-api-key >/dev/null
ck "--no-api-key keeps the user's lines" 'grep -qx "CUDA_VISIBLE_DEVICES=0" "$C/server.env" && grep -qx "FOO=bar" "$C/server.env"'
ck "--no-api-key drops the key line" '! grep -q LLAMA_ARG_API_KEY_FILE "$C/server.env"'
ck "the key and header files are removed" '[ ! -e "$C/api-key" ] && [ ! -e "$C/api-key.header" ]'

echo "I. a server.env that held only the key is removed with it"
fresh I; run setup >/dev/null
run setup --api-key >/dev/null; run setup --no-api-key >/dev/null
ck "server.env is gone" '[ ! -e "$C/server.env" ]'

echo "J. server.env is untouched when no key is set"
fresh J; run setup >/dev/null
printf 'X=1\n' > "$C/server.env"; run setup --no-api-key >/dev/null
ck "left as it was" '[ "$(cat "$C/server.env")" = "X=1" ]'

echo "K. an older unit setup wrote, kept unedited by a later setup, is still setup's"
fresh K; run setup >/dev/null
echo "# older template" >> "$U/$SVC"
python3 - "$R" "$U/$SVC" <<'PY'
import hashlib, json, sys
rec = json.load(open(sys.argv[1]))
rec["local-llm.service"] = hashlib.sha256(open(sys.argv[2], "rb").read()).hexdigest()
json.dump(rec, open(sys.argv[1], "w"))
PY
run setup >/dev/null
ck "its record entry survives" 'grep -q local-llm.service "$R"'
run uninstall -y >/dev/null
ck "uninstall removes it" '[ ! -e "$U/$SVC" ]'

echo
if [ $fail = 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; fi
exit $fail
