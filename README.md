# kimi-expert

An on-demand, **uncensored Kimi-K3** (IQ1_S, ~540 GiB) you spin up on
[Runpod](https://runpod.io) only when you need it, ask one question, and let it
delete itself. Built as a [Claude Code](https://docs.claude.com/claude-code) skill, but
the scripts work from any shell.

The point: a 540 GiB model is far too big to keep running. So this treats it as a
**cold, queued, self-deleting function call** — you park a question, a GPU pod boots when
capacity appears, answers, and tears itself down after 30 min of silence (3 h hard cap).
No idle spend, no babysitting.

## How it works

```
you ──ask──► pending/question.json
             │
   create a pod (or queue it if no GPU is free)
             │
   pod boots ─► coldboot.sh: download model + build llama.cpp (parallel, ~12 min)
             ─► serve llama-server on 127.0.0.1:8080 (localhost only)
             ─► announce "up <ip> <port>" on ntfy
             │
   kimi-pod-listen hears it ─► opens an SSH tunnel ─► runs every pending question
             │
   answer ──► answers/question.md     pod self-deletes when idle
```

Key design choices:

- **No network volume.** The model is re-downloaded and `llama.cpp` rebuilt on the
  container disk every cold boot (~12 min). A volume was $42/mo and locked to one data
  center; the queue makes the wait painless, so any data center works.
- **Fat CUDA binary.** `coldboot.sh` builds for arch `80;90;100;120` (A100 / H100·H200 /
  B200·B300 / RTX PRO 6000), so the same build runs on whatever card you land on. Pin one
  with `KIMI_ARCH=120` for a faster single-card build.
- **Reachable only over SSH.** `llama-server` binds `127.0.0.1`; you reach it through
  `ssh -L`, never the public Runpod proxy (Cloudflare cuts long requests at ~100 s → 524).
- **Self-deleting.** The pod's own `RUNPOD_API_KEY` can `DELETE` its own pod on Runpod
  REST v2. No API key is stored on your machine.

## Files

| Path | What |
|---|---|
| `SKILL.md` | The Claude Code skill (in Swedish) — the operator playbook. |
| `bin/kimi` | Ask the running pod a question; streams the answer. |
| `bin/kimi-pod` | Tunnel + state + the `create-pod` body (`body [QUEUE_HOURS]`). |
| `bin/kimi-pod-listen` | systemd user service: hears the ntfy announcement, opens the tunnel, answers pending questions. |
| `config/coldboot.sh` | Runs **on the pod**: download + build + serve + watchdog (no volume). |
| `config/boot.sh` | Volume-mode variant (prewarm from a network volume). |
| `config/setup.sh` | Manual one-shot build/serve, for driving a pod by hand. |

## Setup

1. **Config dir** `~/.config/kimi-pod/` — create these (all git-ignored):
   - `api_key` — a random token; becomes `--api-key` on `llama-server`.
   - `ntfy_topic` — your ntfy topic, e.g. `kimi-pod-<random>`.
   - `ntfy_pod_token` — ntfy token the pod uses to **publish**.
   - `ntfy_listen_token` — ntfy token the listener uses to **subscribe**.
   - `url` — `http://127.0.0.1:18093` (the local end of the tunnel).
2. **SSH key** `~/.ssh/id_runpod[.pub]` — the pod gets the public half via `PUBLIC_KEY`.
3. **Environment** (optional):
   - `NTFY_HOST` — your ntfy server (default `ntfy.sh`).
   - `KIMI_NOTIFY_EMAIL` — Runpod queue notification address.
   - `KIMI_ARCH`, `KIMI_CTX`, `KIMI_NP` — override CUDA archs / context / parallel slots.
4. **Listener** — run `bin/kimi-pod-listen` as a systemd user service.
5. **Create a pod** — feed `kimi-pod body` (or `kimi-pod body 12` to queue 12 h) to
   Runpod's `create-pod` (REST v2, MCP, or `runpodctl`). Price the GPU first.

### A note on the glue

This is a personal setup, published as a working example. The listener shells out to a
private helper (`q`) and `tmux` to notify the asking session; swap those for however you
want to be told the answer landed. The model
([`Ryanchen911/Kimi-K3-Uncensored-GGUF`](https://huggingface.co/Ryanchen911/Kimi-K3-Uncensored-GGUF))
and the [unsloth `llama.cpp` fork](https://github.com/unslothai/llama.cpp) PR are pinned in
`coldboot.sh`.

## Secrets

No tokens are committed — the scripts read them from `~/.config/kimi-pod/` at runtime, and
`.gitignore` keeps those files out. Rotate anything that ever lands in a commit.

MIT. Use at your own cost and risk; GPU time is billable.
