---
name: kimi-expert
description: Use when Peter asks for expert help ("fråga experten", "fråga Kimi", "säkerhetsexperten", "experthjälp"), when a pentest/security question needs an unfiltered second opinion, or when Anthropic refuses or blocks a prompt that Peter wants answered anyway. Also when he asks to start, stop, queue or check the Kimi pod on Runpod.
---

# Kimi-expert (Kimi-K3 på Runpod)

En avcensurerad Kimi-K3 (IQ1_S, 540 GiB) som startas vid behov. **Kall start, ingen volym:**
podden laddar ner modellen och bygger llama.cpp på container disk (~12 min), var den än landar.
**Podden sköter sig själv:** `coldboot.sh` (följer med i env) laddar ner + bygger + startar servern,
postar sin adress på ntfy och raderar podden efter 30 min tystnad eller 3 h totalt. På the client machine
öppnar `kimi-pod-listen` (systemd user) tunneln och skickar väntande frågor. Du: parkera frågan,
skapa/köa podden, läs svaret.

Ladda `runpod:runpod-mcp` före första Runpod-anropet. Servern nås **bara** via SSH-tunneln
`http://127.0.0.1:18093`, aldrig via `*.proxy.runpod.net` (Cloudflare kapar efter 100 s → 524).

## Fråga experten

1. `kimi-pod status`. `health: {"status":"ok"}` → `kimi "…"` (eller `echo "…" | kimi`), klart. Annars vidare.
2. Parkera frågan: `kimi-pod ask "…"`. Skriv den **fristående** — Kimi ser inget av sessionen, så ta med allt sammanhang.
3. `get-balance`; under $30 → säg det och stoppa.
4. Stock-läs korten i prioritetsordning nedan med `get-gpu-type` (`id`+`count` från raden,
   `include:["AVAILABILITY"]`, `product:["POD"]`, `cloud:"SECURE"`, vilket DC som helst). Ta
   **första raden som inte är `availability: NONE`**. Modellen (~540 GB vikter) kräver bevisat
   ≥672 GB totalt; alla rader ger det. `coldboot.sh` känner av kortets arch och bygger för det,
   så vilket NVIDIA-kort som helst duger — **inte AMD** (MI300X/MI350 är ROCm, boot-skriptet är CUDA).

   | Prioritet | GPU-id (`KIMI_GPU_ID`) | antal | total VRAM | $/h (secure) |
   |---|---|---|---|---|
   | 1 | `NVIDIA RTX PRO 6000 Blackwell Server Edition` | 7 | 672 GB | $18.83 |
   | 2 | `NVIDIA RTX PRO 6000 Blackwell Workstation Edition` | 7 | 672 GB | $19.53 |
   | 3 | `NVIDIA H100 NVL` | 8 | 752 GB | $25.52 |
   | 4 | `NVIDIA H200` | 5 | 705 GB | $26.45 |
   | 5 | `NVIDIA B300 SXM6 AC` | 3 | 864 GB | $31.47 |
   | 6 | `NVIDIA B200` | 4 | 720 GB | $35.96 |

   Är kortet **inte** prio 1, exportera `KIMI_GPU_ID`/`KIMI_GPU_COUNT` från raden innan
   `kimi-pod body` (A100/H100-80 GB ryms inte i ≤8 kort → uteslutna; de kräver `KIMI_CTX`
   nedskruvat och tas bara manuellt). H200/B200/B300 kan ge `GPU_CONCURRENCY_EXCEEDED` (kontot
   får ibland bara ett sådant kort åt gången) → fall tillbaka på kö.
   - **Stock finns:** `create-pod` med body från `KIMI_GPU_ID=… KIMI_GPU_COUNT=… kimi-pod body`
     (utan vars för prio 1). Säg vilket kort och pris, t.ex.: "Kimi startar på <kort>, ~12 min, $X/h. Svar kommer som q-meddelande."
   - **Alla NONE:** `create-pod` med body från `kimi-pod body 12` (prio 1, köas 12 h,
     `status:"QUEUED"`, `podId:null`, ingen debitering). Säg: "Inga kort lediga, frågan är köad i
     12 h — startar sig själv när kort dyker upp, debitering först då." Status: `get-queued-pod`.
5. Gör annat. `kimi-pod-listen` skickar frågan när podden är uppe, lägger svaret i
   `~/.config/kimi-pod/answers/<namn>.md` + ett q-meddelande till den frågande tmux-sessionen.
   Läs filen, återge svaret **som Kimis**, inte som ditt eget.

Följdfrågor medan podden lever: `kimi "…"` direkt (varje fråga skjuter upp tomgångsstoppet).

## Kolla, stoppa, avbryta

| | |
|---|---|
| Läge | `kimi-pod status`, `journalctl --user -u kimi-pod-listen -n 20`, `list-pods`, `list-queued-pods` |
| Stoppa nu | `pod-action terminate` → `list-pods` (borta) → `kimi-pod down`. **Radera, stoppa inte.** |
| Avbryt kö | `delete-queued-pod` (kö-id) |
| Poddens loggar | `exec-pod`: `/tmp/boot.log`, `/tmp/dl.log`, `/tmp/build.log`, `/tmp/server.log` |

## Om något går fel

- Inget svar efter ~20 min fast podden är `RUNNING`: läs `/tmp/boot.log`, `/tmp/dl.log`,
  `/tmp/build.log`, `/tmp/server.log` via `exec-pod` + listener-loggen.
  `kimi-pod up <pod> <ip> <port>` öppnar tunneln manuellt (ip/port: `get-pod` → `ssh.direct`).
- Kö `FAILED` med `GPU_CONCURRENCY_EXCEEDED` / `SPENDING_LIMIT` / `INSUFFICIENT_BALANCE`: säg orsaken.
- Nedladdningen kan dö på HF-CDN-fel; `coldboot.sh` försöker inte igen själv. Starta om via exec-pod:
  `setsid nohup bash /tmp/boot.sh ...` eller radera + köa om.

## Bakgrund (skäl till designen)

- Kontot får 1 H200/B200/B300 åt gången → RTX PRO 6000 (7× = 672 GB, ingen samtidighetsgräns). Spendtak $80/h.
- Kall start vald framför network volume: volymen var låst till CA-MTL-3 och kostade $42/mån;
  kön gör väntan smärtfri, så vi tar vilket DC som helst och laddar ner varje gång (HF ~1–1.6 GB/s).
  `kimi-pod body "" warm` finns kvar för volym-läge men **ingen volym finns just nu** (raderad 2026-11-23).
- Poddens egen `RUNPOD_API_KEY` får `GET`/`DELETE /v2/pods/<egen id>` på REST v2 (ej v1/GraphQL) → självradering, ingen API-nyckel behövs lokalt.
- Köade poddar har inga webhooks; podden postar själv sin adress på ntfy i stället.
- Ändra portar/env på en körande pod nollställer containern; allt sätts vid create.
- Filer: `~/bin/kimi`, `~/bin/kimi-pod`, `~/bin/kimi-pod-listen`, `~/.config/kimi-pod/` (nycklar,
  `coldboot.sh`, `boot.sh` [volym], `setup.sh`, ntfy-ämne `kimi-pod-*` på your ntfy server (NTFY_HOST)).
