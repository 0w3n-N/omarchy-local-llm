# Local LLM for Omarchy

Run local language models with [llama.cpp](https://github.com/ggml-org/llama.cpp) from your Omarchy bar.

![Local LLM panel and bar icon](preview.png)

- **One server, every model.** A single `llama-server` in router mode serves every GGUF model you've downloaded through an OpenAI-compatible API at `http://127.0.0.1:8080/v1`. A model loads the first time a request names it.
- **Easy on your GPU.** One model is kept in VRAM at a time, and its weights are freed after 10 minutes idle. Right-click the bar icon to unload it immediately.
- **Models from Hugging Face.** The Pull button searches Hugging Face, lists the quantizations of the repo you pick with a note on which ones fit your VRAM, and downloads your choice. Vision models get their `mmproj` file automatically, and a repo's speculative-decoding drafter (DFlash, DSpark) comes along named so llama.cpp attaches it (`--no-draft` skips it). Packed ternary formats that only PrismML's llama.cpp fork loads (`PQ2_0`, `PTQ1_0`) are marked and never auto-picked; stock llama.cpp runs those models from their `Q2_0` file.
- **Works with llmfit.** Models downloaded from [llmfit](https://github.com/AlexsJones/llmfit) land in the same folder and show up on their own.

## The icon

The bar icon is a small matrix split on its diagonal.

| Part | Shows | States |
|---|---|---|
| Lower triangle (bar color) | What the model is doing, drawn as a transformer's causal attention mask | faint dots: server stopped · diagonal only: idle · cells filling: loading · full triangle: ready · shrunken points: asleep · a row walking down with flickering cells: generating |
| Upper triangle (theme gradient) | How much of your GPU memory the model holds | fills outward from the diagonal, each cell a fixed share of the card (a partly used cell is drawn smaller); cells run low → mid → high colors in fill order, so the color at the tip shows the level too; a soft glow passes through the filled cells now and then and sweeps to the new level when it changes; every filled cell takes the high color, and the glow quickens, when the whole card is over 92% full |

The gradient comes from the theme: low = `ch2` from its `scope.json` (else cyan, blue, accent), mid = green (else `ch3`), high = `ch4` (else yellow, then orange). The high end is deliberately not red, which blends into pink and purple themes. With animations turned off, the glow doesn't run.

Left-click opens the panel, right-click unloads the loaded model, middle-click opens the llama.cpp web UI.

## Requirements

- Omarchy 4 (the Quickshell-based shell)
- `llama-server` from llama.cpp: `sudo pacman -S llama-cpp`, plus a GPU backend such as `ggml-cuda` (NVIDIA) or `ggml-vulkan`
- `curl`, `systemd` (user services), `python` 3.10+
- For downloading models: `sudo pacman -S python-huggingface-hub python-hf-xet fzf`
- Optional: `nvidia-smi` for the VRAM gauge (without it the gauge stays empty), `gum` for a nicer search prompt, `llmfit` for hardware-aware model recommendations

## Install

```sh
omarchy plugin add https://github.com/0w3n-N/omarchy-local-llm.git --enable
```

Then open the panel and flip the switch. The first time, this runs **setup** in a terminal. Setup:

1. checks that `llama-server` and `curl` are installed, and tells you what to install if not;
2. writes three systemd **user** units to `~/.config/systemd/user/`: `local-llm.service` (the server), and `local-llm-reload.path` / `.service` (rescan when models or presets change);
3. creates `~/.config/local-llm/presets.ini` if it doesn't exist;
4. links `~/.local/bin/lllm` to the bundled command-line tool, if nothing is there already;
5. enables and starts the service.

Setup needs no `sudo`. It never replaces an existing file that differs without asking first. You can also run it yourself: `~/.config/omarchy/plugins/io.github.0w3n-n.local-llm/bin/lllm setup`.

The service is named `local-llm` on purpose: Arch's `llama-cpp` package ships its own `llama-server.service`, and this plugin leaves that one alone.

## Use

Panel buttons, left to right: pull a model, open llmfit, open the web UI, edit presets, show server logs, open a sandbox shell. Click a model to load or unload it. Keyboard: arrows and Enter, `s` server, `u` unload, `p` pull, `f` llmfit, `w` web UI, `e` presets, `l` logs, `b` sandbox shell, `r` refresh.

The same things from a terminal (the command is `lllm`; it was `llm` before 1.3):

```
lllm search qwen3 coder           find GGUF repos on Hugging Face
lllm quants <user/repo>           list quantizations with size and fit
lllm pull                         interactive: search, pick repo, pick quant
lllm pull <user/repo>[:QUANT]     download directly
lllm ls | rm <model> | unload     list, delete, free VRAM now
lllm info <model>                 explain a model: layers, experts, quantization, memory, fit
lllm rank | bench <model…>        order models best-first; measure speed + a short quiz
lllm serve | stop | restart | status | logs
lllm edit                         per-model settings
```

The panel lists your models best-first. `lllm bench <model>` (or `--missing` / `--all`) measures each model's generation speed through the server with your settings, then answers a 4-question math quiz on a temporary copy of the model with four slots, so the questions run at once (it listens on a random localhost port and stops when the quiz ends); models you haven't benchmarked get an estimate from their file (size, active parameters, quantization, and whether they fit in VRAM). The score is 65% quality and 35% speed, so a strong model that's somewhat slower still ranks above a fast, weak one. `lllm rank` shows the order and where each number came from; the panel shows the score and size under each model (`~` = estimated) and re-sorts whenever models or presets change. To keep the server's order instead, set "Model list order" in the widget's settings. Measurements are kept in `~/.local/share/local-llm/bench.json`, the ranking in `~/.cache/local-llm/rank.json`.

Tab completes every `lllm` command, subcommand and flag in bash, including your model names (`lllm info <Tab>`), the sandbox's commands and settings, and llmfit's own subcommands under `lllm fit`. Setup installs it to `~/.local/share/bash-completion/completions/` (needs the `bash-completion` package, which Omarchy ships); on an install from before 1.3.1, run `lllm completion install` once.

`lllm info <model>` reads the model file itself and explains what it finds: the layer mix (attention, recurrent, mixture of experts), how many parameters work per token, the quantization and what it costs in quality, how much memory the context needs, built-in or sidecar speculative decoding, vision and audio input, chat-template features, and whether it fits on your GPU. Each line says what the trait means in general and what it means for that model. Any unique part of a name works: `lllm info gemma`.

Point any OpenAI-compatible client at `http://127.0.0.1:8080/v1` and use a model name from `lllm ls`. The server listens on localhost only and refuses cross-origin requests from web pages (`--cors-origins localhost`), so a website open in your browser can't list, load, or unload your models. Apps that call the API directly, like agent harnesses or `curl`, aren't affected. llama.cpp enforces this from build b12340; older builds only hide the replies from the page, which could still send requests that load or unload a model. `lllm setup` and `lllm status` warn when your build is one of those.

To close that gap on older builds, or if you just want authentication, require an API key:

```
lllm setup --api-key      # generate a key and restart the server with it
lllm key                  # print it, to paste into your clients
lllm setup --no-api-key   # back to keyless
```

The key lives in `~/.config/local-llm/api-key` (readable only by you). The panel and the `lllm` command use it automatically; give other clients the key along with `http://127.0.0.1:8080/v1`. With a key set, a web page can't load, unload, or query models on any llama.cpp version. `/health` stays open, as llama.cpp always allows it.

## Sandbox: let models run commands without touching your system

Agent harnesses give models a bash tool. With a local model, you may not want that bash running as you, on your machine. `lllm sandbox` gives you a Docker container for those commands, and you never have to use docker yourself:

```
lllm sandbox setup                one time: installs/enables docker, gives you access, builds the box
lllm sandbox shell                a shell inside (also the panel's 󰆍 button / b key)
lllm sandbox with omp             start any harness with its shell swapped for the sandbox
lllm sandbox run <command>        run one command inside
lllm sandbox status | stop | reset | offline | online | install <pkg> | config | remove
```

`~/.local/bin/sandbox-bash` is a drop-in bash for the box. It accepts the same arguments as bash (`-c`, `-l -c`, scripts, stdin), returns the same exit codes, and passes kills and timeouts through to the command inside. How a harness is pointed at it differs:

- **Claude Code:** `CLAUDE_CODE_SHELL=~/.local/bin/sandbox-bash` (`lllm sandbox with claude` sets it).
- **oh-my-pi (omp):** use `lllm sandbox with omp`. omp's bash tool runs on its own built-in shell and ignores `$SHELL` and its `shellPath` setting, so `with omp` loads `bin/omp-sandbox.ts`, a small extension that replaces the bash tool and hands each command to `sandbox-bash` as one argument. It also leaves off omp's tools that would run code on the host (`eval`, `task`, `debug`, `lsp`). Don't use omp's command-prefix setting for this: it is pasted in front of the command as text, so in `a; b` only `a` would run in the box.
- **Anything else:** set its shell setting or `SHELL=` to `~/.local/bin/sandbox-bash`, then have the model run `hostname`. Inside the box it prints `sandbox`. If it prints your computer's name, the harness doesn't use that setting for its bash tool.

What the box can reach:

- **Files:** only `~/Sandbox`, mounted at the same path inside, so a harness started there has a working directory that's valid on both sides. Files the model creates there belong to you. Nothing else in your home is visible: no keys, dotfiles, or browser profiles.
- **Environment:** none of your environment variables (API keys in your shell stay out). Add specific ones with `lllm sandbox config env NAME1,NAME2`.
- **Privileges:** an unprivileged user that can't gain root (`no-new-privileges`, no capabilities, no sudo, no docker socket). It's capped at 8 GB RAM, half your CPUs up to 8, and 1024 processes, all changeable with `lllm sandbox config`.
- **Network:** internet on, so `pip`, `npm`, and `git clone` work. `lllm sandbox offline` cuts it completely.
- **Persistence:** the container and anything installed in it persist until `lllm sandbox reset`. `lllm sandbox install <debian-pkg>` adds system packages that survive resets.

Only shell commands are sandboxed. A harness's own read, write, and edit tools still run on the host with your permissions, so start the harness inside `~/Sandbox` (`lllm sandbox with` does this) and keep its file-access settings limited to that folder. Setup adds you to the `docker` group, which is root-equivalent for programs running as you on the host. The model can't use that from inside the box.

### Settings

`~/.config/local-llm/presets.ini` holds llama-server flags. The `[*]` section applies to every model; a section named after a model overrides it. The defaults free an idle model after 10 minutes (`sleep-idle-seconds = 600`) and cap context at 32k tokens (`ctx-size = 32768`), because without a cap llama.cpp allocates each model's full trained context and can fill your VRAM. Raise it per model when you need more. Saving the file applies it; a model that is already loaded picks it up on its next load. The server's model list (`/v1/models`) reports each model's *trained* maximum as `context_length`, not this cap, so a client that sizes conversations from it can overrun the real limit. `lllm ls` shows the context each model actually runs with (CTX); enter that in clients that let you set a model's context.

Models live in `~/.cache/llmfit/models` (set `LLM_MODELS_DIR` to change where the `lllm` command looks; the service uses the default path).

The widget's own settings are the server port (default 8080) and how often it checks the server while the panel is closed (default 5 seconds).

## What the plugin runs

Plugins run unsandboxed inside the Omarchy shell, so here is everything this one executes:

- `curl` to `127.0.0.1` only (model list, load, unload); with an API key set, curl reads the header from `~/.config/local-llm/api-key.header` (`-H @file`), so the key never appears in a process list
- `systemctl --user` to start, stop, and inspect `local-llm.service`
- `nvidia-smi` and `cat /proc/<pid>/stat` for the VRAM gauge and the "generating" state, only while a model is loaded
- the bundled `bin/lllm` in a terminal, when you press a button that needs it (the sandbox button runs `lllm sandbox shell`, which runs setup with `sudo` first if needed)

It makes no network requests of its own. `lllm search` and `lllm pull` talk to huggingface.co when you run them.

## Remove

```sh
lllm sandbox remove           # deletes the sandbox container and image (keeps ~/Sandbox)
lllm uninstall                # stops the service, removes the three units and the lllm link
omarchy plugin remove io.github.0w3n-n.local-llm
```

Run `lllm uninstall` first, since it lives inside the plugin folder. It keeps your downloaded models (`~/.cache/llmfit/models`) and your settings (`~/.config/local-llm`). Delete those two folders by hand if you want them gone.

## Troubleshooting

- **"Not set up yet"**: flip the switch in the panel, or run `lllm setup`.
- **`lllm: command not found` after updating from 1.2**: 1.3 renamed `llm` to `lllm`. Running the old `llm` once (or any panel button) moves your `~/.local/bin` links and the reload unit to the new name. Or run `~/.config/omarchy/plugins/io.github.0w3n-n.local-llm/bin/lllm setup`.
- **The service fails to start**: `lllm logs`. The usual causes are a missing GPU backend package or another program on port 8080.
- **A model is slow or only partly on the GPU**: it doesn't fit in VRAM alongside its context. Pick a smaller quantization (`lllm quants <repo>`) or lower `ctx-size` for that model.
- **A new download doesn't appear**: `lllm ls` forces a rescan.
- **A folder holds two model files**: llama.cpp loads only one `.gguf` per model folder (plus its `mmproj`/drafter). `lllm ls` lists any file it never loads, so you can delete it or give it its own folder.
- **Sandbox says "log out and back in"**: setup added you to the docker group but this login doesn't have it yet. Run `lllm sandbox setup` again to bridge the session, or log out and back in.
- **Something in the sandbox is broken**: `lllm sandbox reset` gives you a fresh container. Your files in `~/Sandbox` are kept.

## License

MIT. See [LICENSE](LICENSE).
