#!/usr/bin/env bash
# Task 3 proof, inside WSL Ubuntu, from the repo root:
#   bash scripts/prove-task3.sh              # 3 replicas
#   REPLICAS=2 bash scripts/prove-task3.sh   # if the host is short of memory
#
# 1. apply the manifests, wait for every pod to be ready
# 2. transcribe the probe clip through the Service
# 3. delete a pod; watch Kubernetes replace it; time it
# 4. rolling update while requests are flowing; count failures (want: 0)
# Leaves the deployment running (task 4 reuses it). Clean up with:
#   kubectl delete namespace switchboard
set -uo pipefail
cd "$(dirname "$0")/.."
NS=switchboard
REPLICAS="${REPLICAS:-3}"
URL="${URL:-http://localhost:8000}"
CLIP=loadtest/probe/1089-134686-0002.wav
mkdir -p results

echo "=== cluster ==="
kubectl config current-context && kubectl get nodes -o wide | tail -n +1

echo "=== 1. apply, scale to $REPLICAS, wait for ready ==="
kubectl apply -f k8s/00-namespace.yaml >/dev/null   # the namespace must exist before anything in it
kubectl apply -f k8s/ >/dev/null
kubectl -n $NS scale deployment/switchboard --replicas="$REPLICAS" >/dev/null
t0=$(date +%s)
kubectl -n $NS rollout status deployment/switchboard --timeout=300s
up=$(( $(date +%s) - t0 ))
echo "all $REPLICAS ready after ${up} s"
kubectl -n $NS get pods -o wide
kubectl -n $NS get svc switchboard

echo "=== 2. one request through the Service ($URL) ==="
for i in $(seq 1 30); do curl -sf "$URL/readyz" >/dev/null && break; sleep 1; done
curl -s -F "file=@$CLIP" "$URL/v1/transcribe" | grep -oE '"(text|latency_ms)":[^,]+' | tr '\n' ' '; echo

echo "=== 3. self-healing: delete a pod ==="
victim=$(kubectl -n $NS get pods -l app=switchboard -o jsonpath='{.items[0].metadata.name}')
t0=$(date +%s)
kubectl -n $NS delete pod "$victim" --wait=false >/dev/null
echo "deleted $victim; watching..."
for i in $(seq 1 120); do
  ready=$(kubectl -n $NS get deployment switchboard -o jsonpath='{.status.readyReplicas}')
  [ "${ready:-0}" -ge "$REPLICAS" ] && [ "$(kubectl -n $NS get pods -l app=switchboard --no-headers | grep -c Terminating)" -eq 0 ] && break
  sleep 2
done
heal=$(( $(date +%s) - t0 ))
echo "back to $ready/$REPLICAS ready after ${heal} s"
kubectl -n $NS get pods -l app=switchboard

echo "=== 4. rolling update under load ==="
total=0; failed=0
( while true; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -F "file=@$CLIP" "$URL/v1/transcribe" --max-time 20)
    echo "$code" >>/tmp/sb-load.codes
    sleep 0.3
  done ) &
LOAD=$!
rm -f /tmp/sb-load.codes; sleep 2
t0=$(date +%s)
kubectl -n $NS rollout restart deployment/switchboard >/dev/null
kubectl -n $NS rollout status deployment/switchboard --timeout=300s
elapsed=$(( $(date +%s) - t0 ))
sleep 2; kill $LOAD 2>/dev/null; wait $LOAD 2>/dev/null
total=$(wc -l </tmp/sb-load.codes); failed=$(grep -cv '^200$' /tmp/sb-load.codes)
echo "rollout took ${elapsed}s; requests during it: $total, non-200: $failed"
[ "$failed" -eq 0 ] && echo "ZERO failed requests through the update." || { echo "codes seen:"; sort /tmp/sb-load.codes | uniq -c; }

echo "=== events (last 8) ==="
kubectl -n $NS get events --sort-by=.lastTimestamp | tail -8

{
  echo "# Task 3 - local cluster, measured $(date +%F)"
  echo
  echo "Docker Desktop Kubernetes, $(kubectl get nodes --no-headers | wc -l) node, $REPLICAS replicas, CPU only (fp32)."
  echo
  echo "| check | result |"
  echo "|---|---:|"
  echo "| pods ready from apply | ${up} s |"
  echo "| pod deleted -> replaced and ready | ${heal} s |"
  echo "| rolling update duration | ${elapsed} s |"
  echo "| requests during the update | $total |"
  echo "| failed requests during the update | **$failed** |"
} >results/task3-cluster.md
echo "=== wrote results/task3-cluster.md ==="
