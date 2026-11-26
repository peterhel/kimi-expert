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

## Set it up with your agent

Paste this into your coding agent (Claude Code, etc.) from any directory. It does the whole
local install; it stops to ask you only for the two things it cannot invent — your ntfy
server and your go-ahead to spend money on Runpod.

> Set up the **kimi-expert** skill from https://github.com/peterhel/kimi-expert on this
> machine. Work step by step and show me each command before running anything that writes
> outside a temp dir.
>
> 1. Clone the repo to a temp dir. Copy `SKILL.md` → `~/.claude/skills/kimi-expert/SKILL.md`;
>    `bin/*` → `~/bin/` (`chmod +x`); `config/*` → `~/.config/kimi-pod/`. Make sure `~/bin`
>    is on my `PATH`.
> 2. Create the secret files in `~/.config/kimi-pod/` (then confirm each is matched by the
>    repo's `.gitignore` and never echo their contents):
>    - `api_key` ← `openssl rand -hex 24`
>    - `ntfy_topic` ← `kimi-pod-$(openssl rand -hex 6)`
>    - `url` ← `http://127.0.0.1:18093`
>    - `ntfy_pod_token`, `ntfy_listen_token` ← **ask me** (tokens for my ntfy server, one
>      publish-capable, one subscribe-capable). Also ask me for `NTFY_HOST` if I don't use
>      `ntfy.sh`, and export it for the listener.
> 3. Generate an SSH keypair `~/.ssh/id_runpod` (ed25519, no passphrase).
> 4. Install `kimi-pod-listen` as a **systemd user** service (`systemctl --user enable --now`),
>    with `NTFY_HOST` in its environment if I set one. Note: it shells out to a `q` command
>    and `tmux` to notify me — if I don't have those, replace that glue with something that
>    tells me the answer file landed (it writes `~/.config/kimi-pod/answers/<name>.md`).
> 5. Verify: `kimi-pod body` prints valid JSON, and `kimi-pod status` prints `no pod`.
> 6. Then walk me through the Runpod side (next section): confirm my account has credit and
>    a GPU is in stock, quote the hourly price, and on my go, feed `kimi-pod body` (or
>    `kimi-pod body 12` to queue) to Runpod `create-pod`.

## Running it on Runpod

The scripts never call Runpod directly — you (or your agent) drive `create-pod` with the
body `kimi-pod body` prints. Get going:

1. **Account + credit.** Make a [Runpod](https://runpod.io) account and add credit. A cold
   boot of this model needs **7× RTX PRO 6000 (96 GB) ≈ $18.83/h** (secure), or an
   equivalent ≥672 GB rig. It bills only while the pod runs, and the pod self-deletes.
2. **A way to call the API.** Either the **Runpod MCP server**
   (`claude mcp add --transport http runpod -s user https://mcp.runpod.io/`, sign in), or
   [`runpodctl`](https://github.com/runpod/runpodctl), or raw REST v2. Your agent uses
   whichever is connected.
3. **Check stock, then create.** Read availability for the GPU
   (`get-gpu-type` / `list-gpu-types` with `include=AVAILABILITY`). If a card is free:
   `create-pod` with `kimi-pod body`. If none is free: `create-pod` with `kimi-pod body 12`
   — it **queues** (status `QUEUED`, no charge) and deploys itself the moment a card frees
   up, up to 12 h. `SKILL.md` carries a full GPU priority list (RTX PRO 6000 → H100 NVL →
   H200 → B300 → B200) with per-card counts and prices; override the pick with
   `KIMI_GPU_ID` / `KIMI_GPU_COUNT`.
4. **It runs itself from there.** The pod downloads the model, builds `llama.cpp`, serves,
   and announces on ntfy. `kimi-pod-listen` opens the tunnel and answers your parked
   questions. **Self-delete** relies on the `RUNPOD_API_KEY` that Runpod injects into every
   v2 pod — you don't store a Runpod key locally.
5. **Account limits.** Runpod caps concurrent big GPUs and total spend per account. H200 /
   B200 / B300 may return `GPU_CONCURRENCY_EXCEEDED` (often one such card at a time) — fall
   back to the queue. Set a spend cap in the Runpod console so a forgotten pod can't run away
   (the watchdog's 3 h hard cap is the second line of defence).

## Secrets

No tokens are committed — the scripts read them from `~/.config/kimi-pod/` at runtime, and
`.gitignore` keeps those files out. Rotate anything that ever lands in a commit.

MIT. Use at your own cost and risk; GPU time is billable.
