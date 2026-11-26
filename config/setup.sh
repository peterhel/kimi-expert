#!/bin/bash
# Bootstrap Kimi-K3 IQ1_S on a fresh Runpod pod (runpod/pytorch cu1281 image, 7x RTX PRO 6000).
# Downloads the model and builds the unsloth llama.cpp fork in parallel, then serves
# on 127.0.0.1:8080 only — reach it through `ssh -L`, never through the Runpod proxy.
# Logs: /tmp/dl.log /tmp/build.log /tmp/server.log
# Run it through exec-pod (container env), not an SSH login shell: SSH gets the system
# Python (pip refuses, PEP 668) and no LLAMA_API_KEY.
set -u
MODEL_DIR=/models/k3
SRC=/opt/llama.cpp

mkdir -p "$MODEL_DIR"
( pip install -q -U "huggingface_hub[hf_xet]" &&
  HF_XET_HIGH_PERFORMANCE=1 hf download Ryanchen911/Kimi-K3-Uncensored-GGUF \
    --local-dir "$MODEL_DIR" --include "*IQ1_S-XS-*" && echo DL_DONE ) > /tmp/dl.log 2>&1 &
DL=$!

[ -x "$SRC/build/bin/llama-server" ] && echo BUILD_DONE > /tmp/build.log ||
( git clone -q https://github.com/unslothai/llama.cpp "$SRC" && cd "$SRC" &&
  git fetch -q origin pull/48/head:kimi-k3-fullsize-vision &&
  git checkout -q kimi-k3-fullsize-vision && git log -1 --format=%H &&
  export CUDACXX=/usr/local/cuda/bin/nvcc PATH=/usr/local/cuda/bin:$PATH &&
  cmake -B build -DBUILD_SHARED_LIBS=OFF -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=120 \
    -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=OFF &&
  cmake --build build --config Release -j 96 --target llama-server && echo BUILD_DONE ) > /tmp/build.log 2>&1 &
BUILD=$!

wait $DL $BUILD
grep -q DL_DONE /tmp/dl.log && grep -q BUILD_DONE /tmp/build.log || { echo "setup failed"; exit 1; }

exec "$SRC/build/bin/llama-server" \
  -m "$MODEL_DIR/Kimi-K3-abliterated-IQ1_S-XS-00001-of-00034.gguf" \
  -ngl 99 -c 131072 -np 2 --no-warmup --jinja \
  --host 127.0.0.1 --port 8080 --api-key "$LLAMA_API_KEY" \
  --temp 1.0 --top-p 0.95 > /tmp/server.log 2>&1
