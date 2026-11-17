// omp extension loaded by `lllm sandbox with omp`: the model's bash tool runs in
// the lllm sandbox container instead of omp's built-in shell on the host.
// Part of https://github.com/0w3n-N/omarchy-local-llm (MIT).
//
// omp's bash tool normally executes on its embedded shell engine and ignores
// $SHELL / shellPath (those only apply to commands you type with `!`). Its
// command-prefix setting is plain string concatenation, so `a; b` would run `b`
// on the host. This replaces the tool and hands each command to sandbox-bash
// as ONE argv element (`sandbox-bash -c <command>`), so nothing can split it.
import { spawn } from "node:child_process";
import { createBashTool } from "@oh-my-pi/pi-coding-agent";

const SHIM = process.env.LLM_SANDBOX_SHIM || `${process.env.HOME}/.local/bin/sandbox-bash`;

export default function (pi: any) {
  const cwd = process.cwd();
  pi.registerTool(
    createBashTool(cwd, {
      operations: {
        exec(command: string, dir: string, opts: { onData: (b: Buffer) => void; signal?: AbortSignal; timeout?: number; env?: Record<string, string> }) {
          return new Promise<{ exitCode: number | null }>((resolve, reject) => {
            const child = spawn(SHIM, ["-c", command], {
              cwd: dir || cwd,
              env: { ...process.env, ...(opts.env ?? {}) },
              stdio: ["ignore", "pipe", "pipe"],
            });
            let timer: ReturnType<typeof setTimeout> | undefined;
            let settled = false;
            const finish = (fn: () => void) => {
              if (settled) return;
              settled = true;
              if (timer) clearTimeout(timer);
              opts.signal?.removeEventListener("abort", onAbort);
              fn();
            };
            // SIGTERM on the shim is relayed to the command's process group inside the container.
            const onAbort = () => {
              child.kill("SIGTERM");
              finish(() => reject(new Error("aborted")));
            };
            child.stdout.on("data", (b: Buffer) => opts.onData(b));
            child.stderr.on("data", (b: Buffer) => opts.onData(b));
            if (opts.signal?.aborted) return onAbort();
            opts.signal?.addEventListener("abort", onAbort, { once: true });
            if (opts.timeout && opts.timeout > 0) {
              timer = setTimeout(() => {
                child.kill("SIGTERM");
                finish(() => reject(new Error(`timeout:${opts.timeout}`)));
              }, opts.timeout * 1000);
            }
            child.on("error", (e) => finish(() => reject(new Error(`sandbox-bash failed to start: ${e.message}`))));
            child.on("close", (code) => finish(() => resolve({ exitCode: code })));
          });
        },
      },
    }),
  );
}
