#!/bin/bash
# Cold boot for a Kimi pod with NO network volume: download the model + build llama.cpp onto the
# container disk, serve on 127.0.0.1:8080, announce on ntfy, self-delete when idle. Baked into the
# pod env (base64) so a queued pod runs it wherever it lands. Needs a 700 GB container disk and the
# unsloth llama.cpp fork; builds a fat binary (CUDA arch 80;90;100;120) so it runs on any card.
# Env from create-pod: LLAMA_API_KEY NTFY_TOPIC NTFY_TOKEN [KIMI_IDLE_MIN=30] [KIMI_MAX_MIN=180] [KIMI_ARCH] [KIMI_CTX] [KIMI_NP]
set -u
N=https://${NTFY_HOST:-ntfy.sh}/$NTFY_TOPIC
IDLE=${KIMI_IDLE_MIN:-30}; MAX=${KIMI_MAX_MIN:-180}
CTX=${KIMI_CTX:-131072}; NP=${KIMI_NP:-2}
# Build a fat binary for every datacenter-GPU arch this model can land on, so the same build
# runs on any card we pick (A100=80, H100/H200=90, B200/B300=100, RTX PRO 6000=120). The extra
# compile time overlaps the ~540 GB download below, so it is usually free. CUDA 12.8 supports
# all four. Pin a subset with KIMI_ARCH (e.g. "120") for a faster single-card build.
ARCHS="${KIMI_ARCH:-80;90;100;120}"
M=/models/k3; SRC=/opt/llama.cpp; LOG=/tmp/server.log
say() { curl -s -m 10 -H "Authorization: Bearer $NTFY_TOKEN" -d "$*" "$N" > /dev/null; }
bye() { say "down $RUNPOD_POD_ID $1"; curl -s -m 15 -X DELETE -H "Authorization: Bearer $RUNPOD_API_KEY" "https://api.runpod.io/v2/pods/$RUNPOD_POD_ID"; exit 0; }
t0=$(date +%s); mins() { echo $(( ($(date +%s) - $1) / 60 )); }

say "boot $RUNPOD_POD_ID $RUNPOD_PUBLIC_IP $RUNPOD_TCP_PORT_22 downloading+building"
mkdir -p "$M"
( pip install -q -U "huggingface_hub[hf_xet]" &&
  HF_XET_HIGH_PERFORMANCE=1 hf download Ryanchen911/Kimi-K3-Uncensored-GGUF \
    --local-dir "$M" --include "*IQ1_S-XS-*" && echo DL_DONE ) > /tmp/dl.log 2>&1 &
dl=$!
( git clone -q https://github.com/unslothai/llama.cpp "$SRC" && cd "$SRC" &&
  git fetch -q origin pull/48/head:k3 && git checkout -q k3 &&
  export CUDACXX=/usr/local/cuda/bin/nvcc PATH=/usr/local/cuda/bin:$PATH &&
  cmake -B build -DBUILD_SHARED_LIBS=OFF -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES="$ARCHS" \
    -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=OFF &&
  cmake --build build --config Release -j "$(nproc)" --target llama-server && echo BUILD_DONE ) > /tmp/build.log 2>&1 &
bd=$!
wait $dl $bd
grep -q DL_DONE /tmp/dl.log && grep -q BUILD_DONE /tmp/build.log || bye "setup failed (dl/build)"

"$SRC/build/bin/llama-server" \
  -m "$M/Kimi-K3-abliterated-IQ1_S-XS-00001-of-00034.gguf" \
  -ngl 99 -c "$CTX" -np "$NP" --no-warmup --jinja \
  --host 127.0.0.1 --port 8080 --api-key "$LLAMA_API_KEY" \
  --temp 1.0 --top-p 0.95 > "$LOG" 2>&1 &
until grep -q "listening on" "$LOG" 2>/dev/null; do
  sleep 10
  pgrep -f llama-server > /dev/null || bye "server died on load: $(tail -1 "$LOG")"
  [ "$(mins $t0)" -ge 30 ] && bye "server not up after 30 min"
done
say "up $RUNPOD_POD_ID $RUNPOD_PUBLIC_IP $RUNPOD_TCP_PORT_22 $(( $(date +%s) - t0 ))s"

while sleep 60; do
  pgrep -f llama-server > /dev/null || bye "server died: $(tail -1 "$LOG")"
  [ "$(mins "$(stat -c %Y "$LOG")")" -ge "$IDLE" ] && bye "idle ${IDLE} min"
  [ "$(mins $t0)" -ge "$MAX" ] && bye "max ${MAX} min"
done
