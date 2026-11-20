#!/usr/bin/env bash
# Tests for what `lllm setup` and `lllm uninstall` may touch, and for when setup
# requires an API key.
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

# Stubs. systemctl only logs its arguments; keys.log also notes whether a key was set
# at that moment (key=y/n), to show what the server would have started with.
STUBS=$WORK/stubs; mkdir -p "$STUBS"
cat > "$STUBS/systemctl" <<'SH'
#!/bin/sh
echo "systemctl $*" >> "$HOME/systemctl.log"
if [ -e "$XDG_CONFIG_HOME/local-llm/api-key" ]; then k=y; else k=n; fi
echo "$* key=$k" >> "$HOME/keys.log"
exit 0
SH
printf '#!/bin/sh\nexit 0\n' > "$STUBS/llama-server"
printf '#!/bin/sh\nexit 0\n' > "$STUBS/curl"
chmod +x "$STUBS"/*

# A fake llama-server, so setup's "does the server refuse other websites?" probe
# answers at once. $WORK/mode picks the build it plays:
#   new  (default) b12340+: 403 to everything, like a request from another website
#   old  older build: ignores Origin; 401 without the key once one is set, else 200
#   down a server that isn't answering properly (503)
python3 - "$WORK/port" "$WORK" <<'PY' &
import http.server, os, sys
work = sys.argv[2]
def read(path):
    try: return open(path).read().strip()
    except OSError: return ""
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        mode = read(os.path.join(work, "mode")) or "new"
        if mode == "new": return self.send_error(403)
        if mode == "down": return self.send_error(503)
        key = read(os.path.join(read(os.path.join(work, "confdir")), "api-key"))
        if key and self.headers.get("Authorization") != f"Bearer {key}":
            return self.send_error(401)
        body = b'{"data": []}'
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
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
  K=$XDG_STATE_HOME/local-llm/keyless
  echo "$C" > "$WORK/confdir"; echo new > "$WORK/mode"
}
build() { echo "$1" > "$WORK/mode"; }
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

echo "C. install from before the record existed: nothing counts as setup's"
fresh C; run setup >/dev/null; rm -rf "$XDG_STATE_HOME"; : > "$HOME/systemctl.log"
out=$(run uninstall -y)
ck "uninstall -y keeps all three units" '[ "$(ls "$U" | wc -l)" = 3 ]'
ck "it says why" 'grep -q "no setup record" <<<"$out"'
ck "nothing was disabled" '! grep -q disable "$HOME/systemctl.log"'
fresh C2; run setup >/dev/null; rm -rf "$XDG_STATE_HOME"
out=$(ask uninstall $'y\ny\ny\ny\n')
ck "interactively, it asks about each unit" '[ "$(grep -o "no setup record" <<<"$out" | wc -l)" -ge 3 ]'
ck "answering yes removes them" '[ -z "$(ls "$U" 2>/dev/null)" ]'
fresh C3; run setup >/dev/null; rm -rf "$XDG_STATE_HOME"; run setup >/dev/null
ck "re-running setup writes the record" '[ -s "$R" ]'
run uninstall -y >/dev/null
ck "after that, uninstall -y removes the units" '[ -z "$(ls "$U" 2>/dev/null)" ]'

echo "D. install from before the record existed, one unit also edited: all kept"
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

echo "L. no record, unit whose only change is the llama-server path: not setup's, so kept"
fresh L; run setup >/dev/null; rm -rf "$XDG_STATE_HOME"
sed -i "s|^ExecStart=[^ ]*llama-server|ExecStart=/opt/other/bin/llama-server|" "$U/$SVC"
grep -q "^ExecStart=/opt/other/bin/llama-server" "$U/$SVC" || { echo "  (test setup failed: path not edited)"; fail=1; }
: > "$HOME/systemctl.log"
run uninstall -y >/dev/null
ck "the unit is kept" '[ -e "$U/$SVC" ]'
ck "it was never disabled" '! grep disable "$HOME/systemctl.log" | grep -qF local-llm.service'
out=$(ask uninstall $'y\nn\n')
ck "interactive uninstall asks about it" 'grep -q "Remove it anyway" <<<"$out"'
ck "answering n keeps it" '[ -e "$U/$SVC" ]'

echo "M. server.env that can't be read (or written) is never overwritten or deleted"
if [ "$(id -u)" = 0 ]; then echo "  SKIP root can read and write any file, so these checks can't run"; else
fresh M; run setup >/dev/null
printf 'KEEP=1\n' > "$C/server.env"; chmod 200 "$C/server.env"
run setup --api-key >/dev/null; rc=$?
chmod 600 "$C/server.env"
ck "--api-key leaves its content alone" '[ "$(cat "$C/server.env")" = "KEEP=1" ]'
ck "--api-key fails instead of half-finishing" '[ $rc -ne 0 ] && [ ! -e "$C/api-key" ]'
mv "$C/server.env" "$C/server.env.keep"; : > "$C/server.env"; chmod 200 "$C/server.env"
printf 'secret\n' > "$C/api-key"; printf 'Authorization: Bearer secret\n' > "$C/api-key.header"
run setup --no-api-key >/dev/null; rc=$?
chmod 600 "$C/server.env"
ck "--no-api-key fails and keeps the key files" '[ $rc -ne 0 ] && [ -e "$C/api-key" ] && [ -e "$C/api-key.header" ]'
fresh M3; run setup >/dev/null
printf 'KEEP=1\n' > "$C/server.env"; chmod 400 "$C/server.env"
run setup --api-key >/dev/null; rc=$?
chmod 600 "$C/server.env"
ck "--api-key on a read-only server.env fails before writing any key file" '[ $rc -ne 0 ] && [ ! -e "$C/api-key" ] && [ "$(cat "$C/server.env")" = "KEEP=1" ]'
fi

echo "N. no record, user pointed ExecStart at their own llama-server that is also first on PATH"
fresh N; run setup >/dev/null; rm -rf "$XDG_STATE_HOME"
mkdir -p "$WORK/mine"; cp "$STUBS/llama-server" "$WORK/mine/llama-server"
sed -i "s|^ExecStart=[^ ]*llama-server|ExecStart=$WORK/mine/llama-server|" "$U/$SVC"
: > "$HOME/systemctl.log"
PATH=$WORK/mine:$PATH run uninstall -y >/dev/null
ck "the unit is kept" '[ -e "$U/$SVC" ]'
ck "it was never disabled" '! grep disable "$HOME/systemctl.log" | grep -qF local-llm.service'

echo "O. older llama.cpp, fresh setup: the key is on, and was on before the server started"
fresh O; build old
out=$(run setup)
ck "a key is set" '[ -s "$C/api-key" ] && [ -s "$C/api-key.header" ]'
ck "server.env points the server at it" 'grep -q "^LLAMA_ARG_API_KEY_FILE=$C/api-key$" "$C/server.env"'
ck "the server was first started with the key" 'grep -q "^--user enable --now local-llm.service local-llm-reload.path key=y$" "$HOME/keys.log"'
ck "it never ran without it" '! grep -q "local-llm.service.* key=n$" "$HOME/keys.log"'
ck "setup says why" 'grep -q "lllm turned the API key on" <<<"$out"'
ck "no keyless choice is recorded" '[ ! -e "$K" ]'

echo "P. llama.cpp that refuses other websites, fresh setup: keyless, after testing with the key on"
fresh P; mkdir -p "$C"; printf 'X=1\n' > "$C/server.env"
out=$(run setup)
ck "no key is left" '[ ! -e "$C/api-key" ] && [ ! -e "$C/api-key.header" ]'
ck "the user's server.env is as it was" '[ "$(cat "$C/server.env")" = "X=1" ]'
ck "the server started with the key, then restarted without it" 'grep -q "^--user enable --now .* key=y$" "$HOME/keys.log" && [ "$(tail -n1 "$HOME/keys.log")" = "--user restart local-llm.service key=n" ]'
ck "setup says no key is needed" 'grep -q "api key  not needed" <<<"$out"'
ck "and doesn't warn" '! grep -q "^warning:" <<<"$out"'

echo "Q. re-running setup on a keyless server that refuses other websites changes nothing"
fresh Q; run setup >/dev/null; : > "$HOME/keys.log"
run setup >/dev/null
ck "no key was created, not even briefly" '! grep -q "key=y" "$HOME/keys.log"'
ck "the server wasn't restarted" '! grep -q restart "$HOME/keys.log"'

echo "R. keyless install from an earlier version on an older build: re-running setup turns the key on"
fresh R; run setup >/dev/null; build old; : > "$HOME/keys.log"
out=$(run setup)
ck "a key is set" '[ -s "$C/api-key" ]'
ck "the server was restarted with it" 'grep -q "^--user restart local-llm.service key=y$" "$HOME/keys.log"'
ck "setup says why" 'grep -q "lllm turned the API key on" <<<"$out"'

echo "S. --no-api-key on an older build: keyless, remembered, with a warning"
fresh S; build old
out=$(run setup --no-api-key)
ck "no key" '[ ! -e "$C/api-key" ]'
ck "the choice is recorded" '[ -e "$K" ]'
ck "it warns about other websites" 'grep -q "^warning: this llama.cpp doesn.t enforce" <<<"$out"'
: > "$HOME/keys.log"; out=$(run setup)
ck "a plain setup afterwards keeps it keyless" '[ ! -e "$C/api-key" ] && ! grep -q "key=y" "$HOME/keys.log"'
ck "and still warns" 'grep -q "^warning: this llama.cpp doesn.t enforce" <<<"$out"'
run setup --api-key >/dev/null
ck "--api-key clears the choice" '[ ! -e "$K" ] && [ -s "$C/api-key" ]'
run setup --no-api-key >/dev/null; run uninstall -y >/dev/null
ck "uninstall removes the choice" '[ ! -e "$K" ] && [ ! -e "$XDG_STATE_HOME/local-llm" ]'

echo "T. server not answering the test: the key stays on"
fresh T; build down
out=$(run setup)
ck "a key is set" '[ -s "$C/api-key" ]'
ck "setup says it couldn't check" 'grep -q "Couldn.t check whether" <<<"$out"'

echo "U. a key the user set stays, on any build"
fresh U; run setup --api-key >/dev/null; key=$(cat "$C/api-key"); : > "$HOME/keys.log"
run setup >/dev/null
ck "same key after a plain setup" '[ "$(cat "$C/api-key")" = "$key" ]'
ck "no restart" '! grep -q restart "$HOME/keys.log"'

echo
if [ $fail = 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; fi
exit $fail
