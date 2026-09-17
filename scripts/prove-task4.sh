#!/usr/bin/env bash
# Task 4 proof, inside WSL Ubuntu, from the repo root:
#
#   bash scripts/prove-task4.sh                 # FAKE_MODEL pods, ~200 MB each
#   VALUES=chart/switchboard/values.yaml \
#     bash scripts/prove-task4.sh               # the real weights, ~3 GB a pod
#
# What it shows, in order:
#   1. the chart is checked before the cluster ever sees it  (lint, template)
#   2. one command installs the whole app into a namespace   (install)
#   3. the chart carries its own smoke test                  (test)
#   4. a change is a tracked revision, not an edited file    (upgrade)
#   5. a BROKEN release is one command away from undone      (rollback)
#   6. the same chart runs the real weights, nothing edited  (upgrade)
#   7. the release has a history you can read                (history)
#
# Leaves the release installed. Remove it with:
#   helm uninstall switchboard -n switchboard && kubectl delete ns switchboard
set -uo pipefail
cd "$(dirname "$0")/.."
NS=switchboard
REL=switchboard
CHART=chart/switchboard
VALUES="${VALUES:-chart/switchboard/values-fake.yaml}"
URL="${URL:-http://localhost:8000}"
CLIP=loadtest/probe/1089-134686-0002.wav
IMAGE="${IMAGE:-switchboard:dev}"
mkdir -p results

echo "=== cluster ==="
kubectl config current-context || { echo "no cluster: start Kubernetes in Docker Desktop"; exit 1; }
kubectl get nodes || exit 1

echo "=== 0a. is the image inside the cluster node? ==="
# Task 3's first finding: the node has its own image store, separate from the
# Docker daemon that built the image. This is what a registry solves (task 5).
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
if grep -q "docker.io/library/${IMAGE}" <<<"$(docker exec "$NODE" ctr -n k8s.io images ls 2>/dev/null)"; then
  echo "$IMAGE already in node $NODE"
else
  echo "$IMAGE not in node $NODE - importing (6.6 GB, ~2-3 min)..."
  docker save "$IMAGE" | docker exec -i "$NODE" ctr -n k8s.io images import - || {
    echo "import failed; build it first: docker build -t $IMAGE ."; exit 1; }
fi

echo "=== 0b. clear anything task 3 left behind ==="
# Helm refuses to adopt objects it did not create: no ownership metadata, no
# touching them. Task 3's kubectl-applied Deployment has the same name, so it
# has to go before Helm can own one.
if kubectl -n $NS get deployment switchboard >/dev/null 2>&1 && \
   [ "$(kubectl -n $NS get deployment switchboard -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}')" != "Helm" ]; then
  echo "found task 3's kubectl-owned objects; deleting them"
  kubectl delete -f k8s/ --ignore-not-found >/dev/null
fi

if helm status "$REL" -n $NS >/dev/null 2>&1; then
  echo "a previous release is installed; removing it so this run starts clean"
  helm uninstall "$REL" -n $NS >/dev/null

fi
echo "=== 1. check the chart without a cluster ==="
helm lint "$CHART" -f "$VALUES" || exit 1
helm template "$REL" "$CHART" -f "$VALUES" >/tmp/sb-rendered.yaml
echo "rendered $(grep -c '^kind:' /tmp/sb-rendered.yaml) objects to /tmp/sb-rendered.yaml"

echo "=== 2. install ==="
t0=$(date +%s)
helm install "$REL" "$CHART" -f "$VALUES" -n $NS --create-namespace --wait --timeout 10m || exit 1
up=$(( $(date +%s) - t0 ))
REPLICAS=$(kubectl -n $NS get deployment $REL -o jsonpath='{.status.readyReplicas}')
echo "installed and $REPLICAS replicas ready after ${up} s"
helm list -n $NS
kubectl -n $NS get pods,svc

echo "=== 3. the chart's own test ==="
if helm test "$REL" -n $NS; then TEST=pass; else TEST=FAIL; fi
echo "helm test: $TEST"

echo "=== 4. one request through the Service ($URL) ==="
for i in $(seq 1 30); do curl -sf "$URL/readyz" >/dev/null && break; sleep 1; done
curl -s -F "file=@$CLIP" "$URL/v1/transcribe" | grep -oE '"(text|latency_ms)":[^,]+' | tr '\n' ' '; echo

echo "=== 5. a change is a revision: scale up with --set ==="
SCALED=$((REPLICAS + 1))
# Ask the live API server what it thinks of the change before making it.
helm upgrade "$REL" "$CHART" -f "$VALUES" -n $NS --set replicaCount=$SCALED --dry-run=server >/dev/null \
  && echo "the API server accepts the change (server-side dry run)"
helm upgrade "$REL" "$CHART" -f "$VALUES" -n $NS --set replicaCount=$SCALED --wait --timeout 10m >/dev/null
GOOD_REV=$(helm list -n $NS -o json | jq -r ".[0].revision")
echo "replicaCount=$SCALED is now revision $GOOD_REV"
kubectl -n $NS get pods --no-headers | wc -l | xargs echo "pods now:"

echo "=== 6. break it on purpose, under load, then roll back ==="
rm -f /tmp/sb4-load.codes
( while true; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -F "file=@$CLIP" "$URL/v1/transcribe" --max-time 20)
    echo "$code" >>/tmp/sb4-load.codes
    sleep 0.3
  done ) &
LOAD=$!
sleep 2
echo "--- upgrading to an image tag that does not exist (expect this to fail) ---"
t0=$(date +%s)
helm upgrade "$REL" "$CHART" -f "$VALUES" -n $NS --set replicaCount=$SCALED \
  --set image.tag=does-not-exist --wait --timeout 90s
echo "helm exit code: $? (non-zero is the point)"
broke=$(( $(date +%s) - t0 ))
kubectl -n $NS get pods
echo "--- the service, meanwhile ---"
curl -s -o /dev/null -w 'GET /readyz through the Service: %{http_code}\n' "$URL/readyz"
echo "--- rolling back ---"
t0=$(date +%s)
helm rollback "$REL" -n $NS --wait --timeout 10m && echo "rolled back to the last good revision"
back=$(( $(date +%s) - t0 ))
sleep 2; kill $LOAD 2>/dev/null; wait $LOAD 2>/dev/null
total=$(wc -l </tmp/sb4-load.codes); failed=$(grep -cv '^200$' /tmp/sb4-load.codes)
echo "during the broken upgrade and the rollback: $total requests, non-200: $failed"
[ "$failed" -eq 0 ] && echo "ZERO failed requests through a BROKEN release." || { echo "codes seen:"; sort /tmp/sb4-load.codes | uniq -c; }
kubectl -n $NS get pods


echo "=== 7. the same chart, the real weights ==="
# No -f at all: the chart's own defaults are the real model. This is the whole
# point of the task - one chart, a different set of values, no edited files.
t0=$(date +%s)
helm upgrade "$REL" "$CHART" -n $NS --set replicaCount=1 --wait --timeout 15m >/dev/null \
  && echo "upgraded to the chart defaults (real weights) in $(( $(date +%s) - t0 )) s"
real_up=$(( $(date +%s) - t0 ))
# Wait for the old pod to finish draining. A request sent the instant --wait
# returns is still answered by the dying pod, on purpose: that is the preStop
# window, and it is why the rolling update never drops anything.
for i in $(seq 1 90); do
  [ "$(kubectl -n $NS get pods -l app.kubernetes.io/name=switchboard --no-headers 2>/dev/null | wc -l)" -eq 1 ] && break
  sleep 2
done
kubectl -n $NS get pods
REAL=$(curl -s -F "file=@$CLIP" "$URL/v1/transcribe")
echo "$REAL" | jq -r '"model: \(.model.class) on \(.model.device)/\(.model.dtype)\ntext:  \(.text)\ninference: \(.inference_ms) ms for \(.audio_seconds) s of audio"'
REAL_CLASS=$(echo "$REAL" | jq -r '.model.class')
REAL_MS=$(echo "$REAL" | jq -r '.inference_ms')
echo "=== 8. the ledger ==="
helm history "$REL" -n $NS

{
  echo "# Task 4 - Helm, measured $(date +%F)"
  echo
  echo "Chart \`chart/switchboard\` on Docker Desktop Kubernetes. Steps 1-6 use \`$VALUES\`; step 7 uses the chart's own defaults."
  echo
  echo "| check | result |"
  echo "|---|---:|"
  echo "| objects rendered from the chart | $(grep -c '^kind:' /tmp/sb-rendered.yaml) |"
  echo "| \`helm install --wait\` to all replicas ready | ${up} s |"
  echo "| \`helm test\` (healthz, readyz, metrics) | $TEST |"
  echo "| scale by \`--set replicaCount\` | revision $GOOD_REV |"
  echo "| broken upgrade refused (the 90 s --wait budget) | ${broke} s |"
  echo "| \`helm rollback\` to the good revision | ${back} s (the good pods were never removed) |"
  echo "| requests during the break + rollback | $total |"
  echo "| failed requests | **$failed** |"
  echo "| the same chart, chart defaults (real weights) | ${real_up} s to ready |"
  echo "| what answered | $REAL_CLASS, ${REAL_MS} ms for 6.6 s of audio |"
  echo
  echo "Revision history:"
  echo
  echo '```'
  helm history "$REL" -n $NS
  echo '```'
} >results/task4-helm.md
echo "=== wrote results/task4-helm.md ==="
