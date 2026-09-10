#!/usr/bin/env bash
# Task 2 proof, inside WSL Ubuntu, from the repo root:
#   bash scripts/prove-task2.sh            # build + measure GPU and CPU starts
#   SKIP_BUILD=1 bash scripts/prove-task2.sh
#
# Measures, for the container: time to alive (/healthz 200), time to ready
# (/readyz 200), first-request latency, warm-request latency - with the GPU and
# then with DEVICE=cpu. Writes results/task2-container.md.
set -uo pipefail
cd "$(dirname "$0")/.."
IMAGE="${IMAGE:-switchboard:dev}"
PORT="${PORT:-8000}"
OUT=results/task2-container.md
mkdir -p results

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  echo "=== build $IMAGE ==="
  DOCKER_BUILDKIT=1 docker build -t "$IMAGE" . 2>&1 | grep -E "^#[0-9]+ (DONE|ERROR)|error|exporting to image" | tail -8
fi
echo "=== image ==="
docker image inspect "$IMAGE" --format 'size: {{.Size}} bytes  layers: {{len .RootFS.Layers}}  model: {{index .Config.Labels "switchboard.model"}}' \
  | awk '{ $2 = sprintf("%.2f GB", $2/1e9); print }'
docker history "$IMAGE" --format '{{.Size}}\t{{.CreatedBy}}' --no-trunc | awk -F'\t' '$1 ~ /GB|[0-9]{3}MB/ {printf "  %-8s %s\n", $1, substr($2, 1, 90)}'

measure() {  # $1 = label, rest = extra docker args
  local label="$1"; shift
  docker rm -f sb-proof >/dev/null 2>&1
  local t0 alive ready first warm text
  t0=$(date +%s.%N)
  docker run -d --name sb-proof -p "$PORT:8000" "$@" "$IMAGE" >/dev/null
  for i in $(seq 1 600); do curl -sf "localhost:$PORT/healthz" >/dev/null && break; sleep 0.1; done
  alive=$(echo "$(date +%s.%N) - $t0" | bc)
  for i in $(seq 1 1200); do curl -sf "localhost:$PORT/readyz" >/dev/null && break; sleep 0.25; done
  ready=$(echo "$(date +%s.%N) - $t0" | bc)
  if ! curl -sf "localhost:$PORT/readyz" >/dev/null; then
    echo "!! $label: never became ready. readyz says: $(curl -s "localhost:$PORT/readyz")"
    echo "!! container log (last lines, access lines removed):"
    docker logs sb-proof 2>&1 | grep -vE "GET /(readyz|healthz)" | tail -20
    docker rm -f sb-proof >/dev/null 2>&1
    exit 1
  fi
  first=$(curl -s -F "file=@loadtest/probe/1089-134686-0002.wav" "localhost:$PORT/v1/transcribe")
  text=$(echo "$first" | grep -oE '"text":"[^"]+"' | cut -c9- | tr -d '"')
  first=$(echo "$first" | grep -oE '"latency_ms":[0-9.]+' | cut -d: -f2)
  warm=$(curl -s -F "file=@loadtest/probe/1089-134686-0002.wav" "localhost:$PORT/v1/transcribe" | grep -oE '"latency_ms":[0-9.]+' | cut -d: -f2)
  local dev; dev=$(curl -s "localhost:$PORT/readyz" | grep -oE '"device":"[^"]+"' | cut -d: -f2 | tr -d '"')
  local load; load=$(curl -s "localhost:$PORT/readyz" | grep -oE '"load_seconds":[0-9.]+' | cut -d: -f2)
  printf "%-6s device=%-7s alive=%5.1fs  ready=%6.1fs (model load %5.1fs)  first=%7.0f ms  warm=%6.0f ms\n" "$label" "$dev" "$alive" "$ready" "$load" "$first" "$warm"
  echo "       text: $text"
  echo "| $label | $dev | $(printf %.1f "$alive") s | $(printf %.1f "$ready") s | $(printf %.1f "$load") s | $(printf %.0f "$first") ms | $(printf %.0f "$warm") ms |" >>"$OUT.rows"
  docker rm -f sb-proof >/dev/null 2>&1
}

rm -f "$OUT.rows"
echo "=== start with the GPU ==="
measure gpu --gpus all
echo "=== start with DEVICE=cpu ==="
measure cpu -e DEVICE=cpu

{
  echo "# Task 2 - the container, measured $(date +%F)"
  echo
  echo "Image \`$IMAGE\`: $(docker image inspect "$IMAGE" --format '{{.Size}}' | awk '{printf "%.2f GB", $1/1e9}'), model $(docker image inspect "$IMAGE" --format '{{index .Config.Labels "switchboard.model"}}')."
  echo "Host: RTX 4060 8 GB, Docker Desktop on WSL2. Times are from \`docker run\` (image already on the host)."
  echo
  echo "| run | device | alive | ready | model load | first request | warm request |"
  echo "|---|---|---:|---:|---:|---:|---:|"
  cat "$OUT.rows"
  echo
  echo "Task 1 (no container, warm process): ready at ~22-25 s, warm request ~90-230 ms."
} >"$OUT"
rm -f "$OUT.rows"
echo "=== wrote $OUT ==="
cat "$OUT"
