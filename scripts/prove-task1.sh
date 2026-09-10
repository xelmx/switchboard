#!/usr/bin/env bash
# Task 1 proof, end to end, inside WSL Ubuntu:
#   tests (fake model, no GPU) -> real model on the GPU -> liveness before
#   readiness -> the probe clip transcribed -> metrics.
# Run from the repo root:  bash scripts/prove-task1.sh
set -uo pipefail
cd "$(dirname "$0")/.."
PORT="${PORT:-8000}"
LOG=/tmp/switchboard.log

echo "=== 1. tests (FAKE_MODEL, no GPU) ==="
bash scripts/sb.sh pytest -q -p no:cacheprovider 2>&1 | grep -vE "^\s*$" | tail -3

echo "=== 2. start the service with the real model ==="
PORT="$PORT" bash scripts/sb.sh switchboard >"$LOG" 2>&1 &
SB=$!
trap 'kill $SB 2>/dev/null; wait $SB 2>/dev/null' EXIT
sleep 2
echo "healthz at +2s : $(curl -s "localhost:$PORT/healthz")"
echo "readyz  at +2s : HTTP $(curl -s -o /dev/null -w '%{http_code}' "localhost:$PORT/readyz")   <- alive but not ready"

for i in $(seq 1 120); do
  curl -sf "localhost:$PORT/readyz" >/dev/null && break
  sleep 1
done
echo "readyz after ~${i}s : $(curl -s "localhost:$PORT/readyz")"

echo "=== 3. transcribe the probe clip (first call, includes warm-up) ==="
curl -s -F "file=@loadtest/probe/1089-134686-0002.wav" "localhost:$PORT/v1/transcribe"; echo
echo "reference        : $(cat loadtest/probe/1089-134686-0002.txt)"

echo "=== 4. again, warm ==="
curl -s -F "file=@loadtest/probe/1089-134686-0002.wav" "localhost:$PORT/v1/transcribe" \
  | grep -oE '"(latency_ms|inference_ms)":[0-9.]+' | tr '\n' ' '; echo

echo "=== 5. metrics ==="
curl -s "localhost:$PORT/metrics" \
  | grep -E '^switchboard_(requests_total|request_seconds_count|inference_seconds_sum|queue_depth|in_flight|audio_seconds_total|model_load_seconds|ready)'

echo "=== server log ==="
grep -E "model ready|ERROR|Traceback" "$LOG" | tail -3
