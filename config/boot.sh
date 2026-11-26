#!/bin/bash
# Boot entry for Kimi pods, copied to /vol/boot.sh. The pod's start command runs it next to the
# image's own /start.sh, so a queued pod comes up with nobody watching:
#   1. /vol/start.sh (prewarm + llama-server on 127.0.0.1:8080)
#   2. announce "up POD IP PORT SECS" on ntfy, so the client machine can open the SSH tunnel
#   3. watchdog: delete this pod after KIMI_IDLE_MIN quiet minutes or KIMI_MAX_MIN total.
#      The pod's own RUNPOD_API_KEY may DELETE its pod on REST v2 (not on v1/GraphQL).
# Env from create-pod: LLAMA_API_KEY NTFY_TOPIC NTFY_TOKEN [KIMI_IDLE_MIN=30] [KIMI_MAX_MIN=180]
N=https://${NTFY_HOST:-ntfy.sh}/$NTFY_TOPIC
IDLE=${KIMI_IDLE_MIN:-30}
MAX=${KIMI_MAX_MIN:-180}
LOG=/tmp/server.log

say() { curl -s -m 10 -H "Authorization: Bearer $NTFY_TOKEN" -d "$*" "$N" > /dev/null; }
bye() {
  say "down $RUNPOD_POD_ID $1"
  curl -s -m 15 -X DELETE -H "Authorization: Bearer $RUNPOD_API_KEY" "https://api.runpod.io/v2/pods/$RUNPOD_POD_ID"
  exit 0
}

t0=$(date +%s)
mins() { echo $(( ($(date +%s) - $1) / 60 )); }

/vol/start.sh &
until grep -q "listening on" $LOG 2>/dev/null; do
  sleep 10
  [ "$(mins $t0)" -ge 30 ] && bye "server not up after 30 min"
  pgrep -f llama-server > /dev/null || [ ! -f $LOG ] || bye "server died during load: $(tail -1 $LOG)"
done
say "up $RUNPOD_POD_ID $RUNPOD_PUBLIC_IP $RUNPOD_TCP_PORT_22 $(( $(date +%s) - t0 ))s"

while sleep 60; do
  pgrep -f llama-server > /dev/null || bye "server died: $(tail -1 $LOG)"
  # llama-server writes a line for every request and every few hundred generated tokens
  [ "$(mins "$(stat -c %Y $LOG)")" -ge "$IDLE" ] && bye "idle ${IDLE} min"
  [ "$(mins $t0)" -ge "$MAX" ] && bye "max ${MAX} min"
done
