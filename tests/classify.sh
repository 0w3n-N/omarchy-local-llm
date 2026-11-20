#!/usr/bin/env bash
# Tests for `lllm classify`: label-probability aggregation, batch order, the refusal
# rubric, error handling, what its temporary server is started with (CPU by default,
# localhost only, cross-origin requests refused, no web UI, the API key file when one
# is set), that the server is stopped even when lllm is killed, and the same server
# flags for the `lllm bench` quiz server.
#
# Runs in a throwaway $HOME with a fake llama-server (a small Python HTTP server on
# PATH that answers /health and /v1/chat/completions with canned logprobs), so no
# model is loaded and nothing on the real machine is read or changed.
# Run:  tests/classify.sh
set -u
LLLM=${LLLM:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/lllm}
[ -f "$LLLM" ] || { echo "no lllm at $LLLM"; exit 2; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
export HOME=$WORK/home XDG_CONFIG_HOME=$WORK/home/.config XDG_CACHE_HOME=$WORK/home/.cache XDG_STATE_HOME=$WORK/home/.local/state
export LLM_MODELS_DIR=$WORK/models LLM_SERVER=http://127.0.0.1:9   # no router: the PATH llama-server is used
mkdir -p "$HOME" "$LLM_MODELS_DIR/tiny" "$WORK/stubs"; : > "$LLM_MODELS_DIR/tiny/tiny-Q4_K_M.gguf"
cat > "$WORK/stubs/llama-server" <<'PY'
#!/usr/bin/env python3
import json, math, os, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer
port = int(sys.argv[sys.argv.index("--port") + 1])
open(os.path.expanduser("~/argv.log"), "a").write(" ".join(sys.argv[1:]) + "\n")
open(os.path.expanduser("~/pids.log"), "a").write(f"{os.getpid()}\n")
# canned first-token distributions, picked by a marker in the user message
CANNED = {
    "CASE_YESNO": [(" Yes", 0.6), ("yes", 0.2), ("YES", 0.1), ("No", 0.05), ("Maybe", 0.05)],
    "CASE_PREFIX": [("pos", 0.5), ("neg", 0.3), ("ne", 0.15), ("x", 0.05)],   # "ne" is ambiguous: dropped
    "CASE_LOWMASS": [("Sure", 0.9), ("yes", 0.06), ("no", 0.04)],
    "REQUEST:": [("R", 0.7), ("D", 0.2), ("P", 0.06), ("C", 0.04)],
}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self): self._send(200, {"status": "ok"})
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        open(os.path.expanduser("~/requests.log"), "a").write(json.dumps({"auth": self.headers.get("Authorization"), "body": body}) + "\n")
        user = body["messages"][-1]["content"]
        if "CASE_SLOW" in user:
            time.sleep(30)
        if "CASE_NOLOGPROBS" in user:
            return self._send(200, {"choices": [{"message": {"content": "a"}, "logprobs": None}]})
        dist = next((v for k, v in CANNED.items() if k in user), [("a", 1.0)])
        top = [{"token": t, "logprob": math.log(p)} for t, p in dist]
        self._send(200, {"choices": [{"message": {"content": dist[0][0]}, "logprobs": {"content": [{"token": dist[0][0], "top_logprobs": top}]}}]})
HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
chmod +x "$WORK/stubs/llama-server"; export PATH=$WORK/stubs:$PATH
pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }
L() { python3 -I "$LLLM" classify "$@"; }

out=$(L tiny -l yes,no --json "CASE_YESNO is it?")
ok "case/space variants of a label are summed" '[ "$(echo "$out" | python3 -c "import json,sys;d=json.load(sys.stdin);print(round(d[\"probs\"][\"yes\"],3))")" = "0.947" ]'
ok "label_mass counts only label tokens" '[ "$(echo "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)[\"label_mass\"])")" = "0.95" ]'
ok "default appends the label list" 'tail -1 "$HOME/requests.log" | grep -q "Answer with one of: yes, no"'
L tiny -l yes,no --raw --json "CASE_YESNO raw" >/dev/null
ok "--raw sends the text unchanged" 'tail -1 "$HOME/requests.log" | python3 -c "import json,sys;d=json.load(sys.stdin);sys.exit(d[\"body\"][\"messages\"][-1][\"content\"]!=\"CASE_YESNO raw\")"'
ok "max_tokens 1, temperature 0, thinking off" 'tail -1 "$HOME/requests.log" | python3 -c "import json,sys;b=json.load(sys.stdin)[\"body\"];sys.exit(not(b[\"max_tokens\"]==1 and b[\"temperature\"]==0 and b[\"chat_template_kwargs\"][\"enable_thinking\"] is False and b[\"logprobs\"]))"'

out=$(L tiny -l positive,negative,neutral --json "CASE_PREFIX")
ok "unique prefixes count, ambiguous ones are dropped" '[ "$(echo "$out" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d[\"label\"], d[\"label_mass\"], d[\"probs\"][\"neutral\"])")" = "positive 0.8 0.0" ]'

L tiny -l yes,no "CASE_LOWMASS" > "$WORK/o.txt" 2> "$WORK/e.txt"
ok "low label mass is warned about" 'grep -q "only 10% of the answer probability" "$WORK/e.txt"'
ok "human output lists every label" '[ "$(wc -l < "$WORK/o.txt")" = 2 ]'

out=$(L tiny -s "Be strict." -l yes,no --json "CASE_YESNO sys")
ok "system prompt is sent first" 'tail -1 "$HOME/requests.log" | python3 -c "import json,sys;m=json.load(sys.stdin)[\"body\"][\"messages\"];sys.exit(not(m[0]==dict(role=\"system\",content=\"Be strict.\")))"'
echo "Be careful." > "$WORK/sys.txt"; L tiny -S "$WORK/sys.txt" -l yes,no --json "CASE_YESNO f" >/dev/null
ok "--system-file is read" 'tail -1 "$HOME/requests.log" | grep -q "Be careful."'

out=$(L tiny --refusal --request "How?" --response "No." --json)
ok "--refusal: labels CPDRI, attempted = C+P" '[ "$(echo "$out" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d[\"label\"], list(d[\"probs\"]), d[\"attempted\"])")" = "R [%sC%s, %sP%s, %sD%s, %sR%s, %sI%s] 0.1" ] || [ "$(echo "$out" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d[\"label\"], \"\".join(d[\"probs\"]), d[\"attempted\"])")" = "R CPDRI 0.1" ]'
ok "--refusal sends the rubric and the REQUEST/RESPONSE template" 'tail -1 "$HOME/requests.log" | python3 -c "import json,sys;m=json.load(sys.stdin)[\"body\"][\"messages\"];sys.exit(not(\"refusal behaviour\" in m[0][\"content\"] and m[1][\"content\"].startswith(\"REQUEST:\nHow?\n\nRESPONSE:\nNo.\")))"'

printf '%s\n' '{"id":1,"text":"CASE_YESNO a"}' '' '{"id":2,"text":"CASE_LOWMASS b"}' '{"id":3,"text":"CASE_YESNO c"}' | L tiny -l yes,no --jsonl > "$WORK/b.jsonl" 2>/dev/null
ok "--jsonl keeps order and fields, skips blank lines" '[ "$(python3 -c "import json;print([json.loads(l)[\"id\"] for l in open(\"$WORK/b.jsonl\")])")" = "[1, 2, 3]" ]'
ok "--jsonl adds label and probs" '[ "$(python3 -c "import json;print(\" \".join(json.loads(l)[\"label\"] for l in open(\"$WORK/b.jsonl\")))")" = "yes yes yes" ]'
printf '%s\n' '{"request":"r","response":"x"}' | L tiny --refusal --jsonl > "$WORK/r.jsonl"
ok "--refusal --jsonl adds attempted" 'grep -q "\"attempted\": 0.1" "$WORK/r.jsonl"'

ok "one label is rejected" '! L tiny -l yes x 2>/dev/null'
ok "duplicate labels are rejected" '! L tiny -l Yes,yes x 2>/dev/null'
ok "--refusal without a pair is rejected" '! L tiny --refusal 2>/dev/null'
ok "bad JSONL is rejected" '! (echo "nope" | L tiny -l a,b --jsonl 2>/dev/null)'
ok "unknown model is rejected" '! L nosuch -l a,b x 2>/dev/null'
ok "-l with --refusal is rejected" '! L tiny --refusal -l a,b --request r --response x 2>/dev/null'
ok "TEXT with --jsonl is rejected" '! (echo "{\"text\":\"x\"}" | L tiny -l a,b --jsonl extra 2>/dev/null)'
ok "--request without --refusal is rejected" '! L tiny -l a,b --request r x 2>/dev/null'
ok "a reply without logprobs is an error, not a crash" '! L tiny -l a,b CASE_NOLOGPROBS 2>"$WORK/nl.txt" && grep -q "no logprobs" "$WORK/nl.txt" && ! grep -q Traceback "$WORK/nl.txt"'
ok "unknown option is rejected" '! L tiny -l a,b --frobnicate x 2>/dev/null'
ok "a .gguf path works" 'L "$LLM_MODELS_DIR/tiny/tiny-Q4_K_M.gguf" -l yes,no --json CASE_YESNO >/dev/null'

: > "$HOME/argv.log"; L tiny -l yes,no CASE_YESNO >/dev/null
ok "CPU by default (-ngl 0), localhost only" 'grep -q -- "-ngl 0" "$HOME/argv.log" && grep -q -- "--host 127.0.0.1" "$HOME/argv.log"'
ok "web pages can't use it (--cors-origins localhost), no web UI" 'grep -q -- "--cors-origins localhost" "$HOME/argv.log" && grep -q -- "--no-webui" "$HOME/argv.log"'
ok "no key file: no --api-key-file, no auth header" '! grep -q -- "--api-key-file" "$HOME/argv.log" && [ "$(tail -1 "$HOME/requests.log" | python3 -c "import json,sys;print(json.load(sys.stdin)[\"auth\"])")" = None ]'
: > "$HOME/argv.log"; L tiny -l yes,no --gpu CASE_YESNO >/dev/null
ok "--gpu offloads (-ngl 99)" 'grep -q -- "-ngl 99" "$HOME/argv.log"'
mkdir -p "$XDG_CONFIG_HOME/local-llm"; echo "sekrit" > "$XDG_CONFIG_HOME/local-llm/api-key"; chmod 600 "$XDG_CONFIG_HOME/local-llm/api-key"
: > "$HOME/argv.log"; L tiny -l yes,no CASE_YESNO >/dev/null
ok "with a key: the temporary server requires it, and lllm sends it" 'grep -q -- "--api-key-file $XDG_CONFIG_HOME/local-llm/api-key" "$HOME/argv.log" && tail -1 "$HOME/requests.log" | grep -q "Bearer sekrit"'
ok "the key never appears in argv" '! grep -q sekrit "$HOME/argv.log"'
# killed mid-request (closed terminal / kill): the temporary server must not be left running
for sig in TERM HUP; do
    : > "$HOME/pids.log"
    python3 -I "$LLLM" classify tiny -l yes,no "CASE_SLOW $sig" >/dev/null 2>&1 & lp=$!
    for _ in $(seq 50); do grep -q "CASE_SLOW $sig" "$HOME/requests.log" 2>/dev/null && break; sleep 0.1; done
    kill -$sig $lp; t0=$SECONDS; wait $lp; rc=$?
    spid=$(head -1 "$HOME/pids.log")
    ok "SIG$sig mid-request: lllm exits promptly ($((SECONDS - t0)) s, code $rc)" '[ $((SECONDS - t0)) -le 5 ] && [ $rc -ne 0 ]'
    ok "SIG$sig mid-request: its server is stopped" '! kill -0 "$spid" 2>/dev/null'
done
: > "$HOME/pids.log"; L tiny -l yes,no CASE_YESNO >/dev/null

ok "no input from a terminal: says what it needs instead of waiting" 'script -qec "python3 -I $LLLM classify tiny -l a,b" /dev/null </dev/null | grep -q "give the text as an argument or pipe it in"'

# the bench quiz server gets the same flags (unit test of the command builder)
python3 - "$LLLM" > "$WORK/quiz.txt" <<'PYQ'
import sys, importlib.machinery, importlib.util
loader = importlib.machinery.SourceFileLoader("lllm", sys.argv[1]); spec = importlib.util.spec_from_loader("lllm", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
model = {"status": {"args": ["/x/llama-server"], "preset": "[m]\nmodel = /m.gguf\ncors-origins = *\nwebui = true\nhost = 0.0.0.0\nn-gpu-layers = 99"}}
cmd, port = m._quiz_server_cmd(model)
print(" ".join(cmd))
PYQ
ok "bench quiz server: localhost, cors localhost (preset override dropped), no web UI, key" 'grep -q -- "--host 127.0.0.1" "$WORK/quiz.txt" && [ "$(grep -o -- "--cors-origins [^ ]*" "$WORK/quiz.txt")" = "--cors-origins localhost" ] && grep -q -- "--no-webui" "$WORK/quiz.txt" && ! grep -q -- "--webui\b" "$WORK/quiz.txt" && ! grep -q "0.0.0.0" "$WORK/quiz.txt" && grep -q -- "--api-key-file" "$WORK/quiz.txt" && grep -q -- "--n-gpu-layers 99" "$WORK/quiz.txt"'

alive=0; while read -r pid; do kill -0 "$pid" 2>/dev/null && alive=$((alive+1)); done < "$HOME/pids.log"
ok "every temporary server was stopped ($(wc -l < "$HOME/pids.log") started)" '[ $alive = 0 ]'

echo "classify: $pass passed, $fail failed"; [ $fail = 0 ]
