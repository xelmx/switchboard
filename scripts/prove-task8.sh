#!/usr/bin/env bash
# Task 8 proof, inside WSL Ubuntu, from the repo root. Local cluster only - free.
# Needs task 6's monitoring stack (the analysis reads Prometheus) and the
# switchboard:0.2 image in the node.
#
#   bash scripts/prove-task8.sh
#
# What it shows, in order:
#   1. Argo Rollouts installed with Helm, its dashboard on localhost:3100
#   2. switchboard as a Rollout: four pods, the Deployment kept as the pod spec
#   3. a good new version under load: canary steps, analysis passes, promoted
#   4. a bad new version under load (3x slower model): analysis fails, the
#      rollout aborts itself, every pod is back on the good version
#   5. the gap that leaves: Helm says the bad version is deployed, the cluster
#      runs the good one - closed with `helm rollback`
#
# Leaves switchboard as a healthy Rollout on the good version.
# Watch it live:  http://localhost:3100/rollouts/switchboard
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/bin:$PATH"   # kubectl-argo-rollouts lives here
CTX=docker-desktop
NS=switchboard
REL=switchboard
ARGO_VERSION=2.43.1
URL=http://localhost:8000
CLIP=loadtest/probe/1089-134686-0002.wav
CALLERS="${CALLERS:-4}"
VALUES="-f chart/switchboard/values-rollout.yaml -f chart/switchboard/values-monitoring.yaml"
LAT=/tmp/sb8-latency.log
mkdir -p results

echo "=== 0. preflight ==="
kubectl config use-context "$CTX" >/dev/null || exit 1
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
IMAGES=$(docker exec "$NODE" ctr -n k8s.io images ls 2>/dev/null)
grep -q "docker.io/library/switchboard:0.2" <<<"$IMAGES" || { echo "switchboard:0.2 not in the node"; exit 1; }
helm status kps -n monitoring >/dev/null 2>&1 || { echo "run scripts/prove-task6.sh first (Prometheus)"; exit 1; }
kubectl argo rollouts version >/dev/null 2>&1 || { echo "kubectl-argo-rollouts plugin missing"; exit 1; }

LOADPIDS=""
cleanup() { kill $LOADPIDS 2>/dev/null; }
trap cleanup EXIT
load() {
  : >"$LAT"; LOADPIDS=""
  for w in $(seq 1 "$CALLERS"); do
    ( while true; do
        r=$(curl -s -o /dev/null -w '%{time_total} %{http_code}' -F "file=@$CLIP" "$URL/v1/transcribe" --max-time 60)
        echo "$(date +%s) $r" >>"$LAT"
      done ) &
    LOADPIDS="$LOADPIDS $!"
  done
}
stop_load() { kill $LOADPIDS 2>/dev/null; wait $LOADPIDS 2>/dev/null; LOADPIDS=""; }
failed() { awk '$3!=200' "$LAT" | wc -l; }
total() { wc -l <"$LAT"; }
phase() { kubectl argo rollouts status $REL -n $NS --timeout 1s 2>/dev/null | tail -1; }
# watch_rollout <new|any|healthy> <timeout s>: print status changes until Healthy or
# Degraded ("healthy": only Healthy counts - after an abort the rollout starts Degraded).
# With workloadRef, `helm upgrade` changes the Deployment, not the Rollout, and
# for a moment the Rollout still reports Healthy - for the *old* version. "new"
# first waits until Argo has noticed a pod template that isn't the stable one.
watch_rollout() {
  local t0=$(date +%s) last="" s
  if [ "$1" = new ]; then
    for i in $(seq 1 60); do
      [ "$(kubectl -n $NS get rollout $REL -o jsonpath='{.status.currentPodHash}')" != "$(stable_hash)" ] && break
      sleep 1
    done
  fi
  while [ $(( $(date +%s) - t0 )) -lt "$2" ]; do
    s=$(kubectl -n $NS get rollout $REL -o jsonpath='{.status.phase} step={.status.currentStepIndex} {.status.message}' 2>/dev/null)
    [ "$s" != "$last" ] && { printf '  %4ss  %s\n' $(( $(date +%s) - t0 )) "$s"; last=$s; }
    case "$1:$s" in healthy:Healthy*|new:Healthy*|new:Degraded*|any:Healthy*|any:Degraded*) echo $(( $(date +%s) - t0 )) >/tmp/sb8-elapsed; return 0;; esac
    sleep 3
  done
  echo timeout >/tmp/sb8-elapsed; return 1
}
stable_hash() { kubectl -n $NS get rollout $REL -o jsonpath='{.status.stableRS}'; }
pod_hashes() { kubectl -n $NS get pods -l app.kubernetes.io/instance=$REL -o jsonpath='{range .items[*]}{.metadata.labels.rollouts-pod-template-hash}{"\n"}{end}' | sort | uniq -c | tr -s ' ' | tr '\n' ';'; }
last_analysis() {
  local run; run=$(kubectl -n $NS get analysisrun --sort-by=.metadata.creationTimestamp -o name | tail -1)
  kubectl -n $NS get "$run" -o jsonpath='{.status.phase}{range .status.metricResults[*]} | {.name}: {.phase} last={.measurements[-1:].value}{end}'
}

echo "=== 1. Argo Rollouts $ARGO_VERSION ==="
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1
helm repo update argo >/dev/null
t0=$(date +%s)
helm upgrade --install argo-rollouts argo/argo-rollouts --version $ARGO_VERSION \
  -n argo-rollouts --create-namespace -f rollouts/argo-rollouts.local.yaml --wait --timeout 10m >/dev/null || exit 1
echo "Argo Rollouts ready after $(( $(date +%s) - t0 )) s; dashboard http://localhost:3100/rollouts/$REL"

echo "=== 2. switchboard as a Rollout (v1) ==="
# KEDA from task 7 must not own these pods any more.
helm uninstall $REL -n $NS --wait >/dev/null 2>&1
t0=$(date +%s)
helm install $REL chart/switchboard -n $NS --create-namespace $VALUES \
  --set-string podAnnotations.switchboard/version=v1 >/dev/null || exit 1
watch_rollout any 300
echo "v1 healthy after $(( $(date +%s) - t0 )) s"
kubectl argo rollouts get rollout $REL -n $NS | head -20
V1=$(stable_hash)
for i in $(seq 1 60); do curl -sf "$URL/readyz" >/dev/null && break; sleep 1; done

echo "=== 3. a good new version (v2), under load ==="
load
sleep 20   # a baseline for the stable version before the canary appears
t0=$(date +%s)
helm upgrade $REL chart/switchboard -n $NS $VALUES \
  --set-string podAnnotations.switchboard/version=v2 >/dev/null || exit 1
watch_rollout new 600
good_s=$(cat /tmp/sb8-elapsed)
GOOD_PHASE=$(kubectl -n $NS get rollout $REL -o jsonpath='{.status.phase}')
GOOD_ANALYSIS=$(last_analysis)
stop_load
GOOD_TOTAL=$(total); GOOD_FAILED=$(failed)
V2=$(stable_hash)
echo "v2: $GOOD_PHASE after ${good_s} s; analysis: $GOOD_ANALYSIS"
echo "requests during the rollout: $GOOD_TOTAL, failed: $GOOD_FAILED; stable is now $V2 (was $V1)"

echo "=== 4. a bad new version (v3: the model got 3x slower), under load ==="
load
sleep 20
t0=$(date +%s)
helm upgrade $REL chart/switchboard -n $NS $VALUES \
  --set-string podAnnotations.switchboard/version=v3 --set model.fakeRtf=0.6 >/dev/null || exit 1
HELM_SAYS=$(helm status $REL -n $NS -o json | jq -r '.info.status')
watch_rollout new 600
bad_s=$(cat /tmp/sb8-elapsed)
BAD_PHASE=$(kubectl -n $NS get rollout $REL -o jsonpath='{.status.phase}')
BAD_MSG=$(kubectl -n $NS get rollout $REL -o jsonpath='{.status.message}')
BAD_ANALYSIS=$(last_analysis)
# Give the abort a moment to finish replacing the canary pod.
for i in $(seq 1 40); do
  [ "$(kubectl -n $NS get pods -l app.kubernetes.io/instance=$REL --no-headers | wc -l)" -eq 4 ] && break; sleep 3
done
stop_load
BAD_TOTAL=$(total); BAD_FAILED=$(failed)
AFTER_ABORT=$(pod_hashes)
echo "v3: $BAD_PHASE after ${bad_s} s - $BAD_MSG"
echo "analysis: $BAD_ANALYSIS"
echo "pods by version after the abort: $AFTER_ABORT (stable v2 = $V2)"
echo "requests during the bad rollout: $BAD_TOTAL, failed: $BAD_FAILED"
echo "meanwhile, Helm reports the release as: $HELM_SAYS"

echo "=== 5. close the gap: Helm back to v2 ==="
t0=$(date +%s)
helm rollback $REL -n $NS >/dev/null || exit 1
watch_rollout healthy 300
fix_s=$(cat /tmp/sb8-elapsed)
FINAL=$(kubectl -n $NS get rollout $REL -o jsonpath='{.status.phase}')
echo "after helm rollback: $FINAL in ${fix_s} s; pods: $(pod_hashes)"
kubectl argo rollouts get rollout $REL -n $NS | head -25
helm history $REL -n $NS

{
  echo "# Task 8 - canary rollouts with Argo Rollouts, measured $(date +%F)"
  echo
  echo "Docker Desktop Kubernetes, Argo Rollouts chart $ARGO_VERSION, 4 replicas, fake pods"
  echo "with the real model's timing (FAKE_RTF 0.185); the bad version uses FAKE_RTF 0.6."
  echo "Steps: 25% -> pause 90 s -> 50% -> pause 60 s -> 100%. Analysis every 30 s after"
  echo "60 s: canary p95 model time <= 1.5x stable's, and zero canary errors."
  echo
  echo "| | good version (v2) | bad version (v3, 3x slower) |"
  echo "|---|---:|---:|"
  echo "| outcome | $GOOD_PHASE | $BAD_PHASE (aborted) |"
  echo "| time from helm upgrade | ${good_s} s | ${bad_s} s |"
  echo "| requests during the rollout / failed | $GOOD_TOTAL / $GOOD_FAILED | $BAD_TOTAL / $BAD_FAILED |"
  echo
  echo "- good analysis: \`$GOOD_ANALYSIS\`"
  echo "- bad analysis: \`$BAD_ANALYSIS\`"
  echo "- pods after the abort: \`$AFTER_ABORT\` (stable = \`$V2\`)"
  echo "- Helm's view of the release while the cluster ran v2: **$HELM_SAYS**"
  echo "- \`helm rollback\` to v2: $FINAL in ${fix_s} s"
} >results/task8-rollouts.md
echo "=== wrote results/task8-rollouts.md ==="
