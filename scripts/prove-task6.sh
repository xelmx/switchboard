#!/usr/bin/env bash
# Task 6 proof, inside WSL Ubuntu, from the repo root. Local cluster only - free.
#
#   bash scripts/prove-task6.sh
#
# What it shows, in order:
#   1. one Helm install gives Prometheus, Alertmanager and Grafana
#   2. the service is found and scraped because its chart says so (ServiceMonitor)
#   3. the alert rules and the dashboard arrive the same way - from the chart
#   4. a quiet baseline: what normal looks like, in numbers
#   5. overload on purpose: the alerts fire, and the dashboard shows why
#   6. load removed: the alerts resolve on their own
#
# Leaves everything installed. Grafana stays at http://localhost:3000
# (anonymous view; admin / switchboard to edit).
set -uo pipefail
cd "$(dirname "$0")/.."
CTX=docker-desktop
NS=switchboard
MON=monitoring
REL=switchboard
KPS_VERSION=91.4.1
URL=http://localhost:8000
PROM=http://localhost:9090
AM=http://localhost:9093
GRAFANA=http://localhost:3000
CLIP=loadtest/probe/1089-134686-0002.wav
BASELINE_S="${BASELINE_S:-90}"
OVERLOAD_S="${OVERLOAD_S:-300}"
CONCURRENCY="${CONCURRENCY:-4}"
mkdir -p results

echo "=== 0. the local cluster, and only the local cluster ==="
# After task 5 the current context can still point at a GKE cluster - deleted,
# or worse, not deleted. Everything below is pinned to Docker Desktop.
kubectl config use-context "$CTX" >/dev/null || { echo "no $CTX context"; exit 1; }
kubectl get nodes || { echo "start Kubernetes in Docker Desktop"; exit 1; }
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
# Capture first, then search: `ctr ... | grep -q` under pipefail fails at random,
# because grep exits on the first match and ctr dies of SIGPIPE mid-listing.
IMAGES=$(docker exec "$NODE" ctr -n k8s.io images ls 2>/dev/null)
grep -q "docker.io/library/switchboard:dev" <<<"$IMAGES" \
  || { echo "switchboard:dev is not in the node - run scripts/prove-task4.sh first"; exit 1; }

prom() { curl -s --get "$PROM/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result[0].value[1] // "none"'; }
firing() { curl -s "$PROM/api/v1/alerts" | jq -r '[.data.alerts[] | select(.labels.alertname|startswith("Switchboard")) | select(.state=="firing") | .labels.alertname] | unique | join(",")'; }

echo "=== 1. the monitoring stack ==="
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1
helm repo update prometheus-community >/dev/null
t0=$(date +%s)
helm upgrade --install kps prometheus-community/kube-prometheus-stack --version $KPS_VERSION \
  -n $MON --create-namespace -f monitoring/kube-prometheus-stack.local.yaml \
  --wait --timeout 15m >/dev/null || exit 1
# `helm --wait` cannot see these: the chart creates Prometheus and Alertmanager
# *objects*, and the operator creates their pods afterwards. Helm is done
# before the pods exist, so wait for them explicitly.
for app in prometheus alertmanager; do
  for i in $(seq 1 60); do
    kubectl -n $MON get pod -l app.kubernetes.io/name=$app -o name 2>/dev/null | grep -q . && break
    sleep 5
  done
  kubectl -n $MON wait --for=condition=Ready pod -l app.kubernetes.io/name=$app --timeout=10m >/dev/null || exit 1
done
stack_up=$(( $(date +%s) - t0 ))
echo "kube-prometheus-stack $KPS_VERSION ready after ${stack_up} s"
kubectl -n $MON get pods

echo "=== 2. the service, with its monitoring switched on ==="
t0=$(date +%s)
helm upgrade --install "$REL" chart/switchboard -n $NS --create-namespace \
  --set replicaCount=1 -f chart/switchboard/values-monitoring.yaml \
  --wait --timeout 10m >/dev/null || exit 1
echo "switchboard (real weights, 1 replica) ready after $(( $(date +%s) - t0 )) s"
kubectl -n $NS get servicemonitor,prometheusrule,configmap -l app.kubernetes.io/instance=$REL

echo "--- port-forwards to Prometheus and Alertmanager (closed when this script ends) ---"
kubectl -n $MON port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090 >/dev/null 2>&1 &
PF1=$!
kubectl -n $MON port-forward svc/kps-kube-prometheus-stack-alertmanager 9093:9093 >/dev/null 2>&1 &
PF2=$!
LOADPIDS=""
cleanup() { kill $PF1 $PF2 $LOADPIDS 2>/dev/null; }
trap cleanup EXIT
for i in $(seq 1 30); do
  curl -sf "$PROM/-/ready" >/dev/null && curl -sf "$AM/-/ready" >/dev/null && break
  sleep 1
done
curl -sf "$PROM/-/ready" >/dev/null || { echo "Prometheus not reachable on $PROM"; exit 1; }
# Grafana needs no port-forward: its Service is a LoadBalancer on localhost:3000.
for i in $(seq 1 60); do curl -sf "$GRAFANA/api/health" >/dev/null && break; sleep 2; done

echo "=== 3. did Prometheus find it on its own? ==="
t0=$(date +%s)
for i in $(seq 1 60); do
  up=$(curl -s "$PROM/api/v1/targets?state=active" | jq -r '[.data.activeTargets[] | select(.labels.job=="'$REL'") | .health] | join(",")')
  [ "$up" = "up" ] && break
  sleep 5
done
found=$(( $(date +%s) - t0 ))
echo "switchboard target: ${up:-missing} (after ${found} s)"
RULES=$(curl -s "$PROM/api/v1/rules" | jq -r '[.data.groups[] | select(.name|startswith("switchboard")) | .rules[]] | length')
echo "switchboard rules loaded: $RULES"
DASH=$(curl -s "$GRAFANA/api/search?query=switchboard" | jq -r '.[0].title // "missing"')
echo "Grafana dashboard: $DASH  ($GRAFANA/d/switchboard)"

# One request loop per worker: post the clip, forever, until killed.
load() {
  local n=$1; LOADPIDS=""
  for w in $(seq 1 "$n"); do
    ( while true; do curl -s -o /dev/null -F "file=@$CLIP" "$URL/v1/transcribe" --max-time 60; done ) &
    LOADPIDS="$LOADPIDS $!"
  done
}
stop_load() { kill $LOADPIDS 2>/dev/null; wait $LOADPIDS 2>/dev/null; LOADPIDS=""; }

echo "=== 4. baseline: one caller at a time, ${BASELINE_S} s ==="
load 1; sleep "$BASELINE_S"
B_RPS=$(prom 'sum(switchboard:requests:rate1m)')
B_P95=$(prom 'switchboard:request_seconds:p95_1m')
B_RTF=$(prom 'switchboard:real_time_factor:1m')
B_Q=$(prom 'max_over_time(sum(switchboard_queue_depth{job="switchboard"})[1m:15s])')
stop_load
echo "rps=$B_RPS p95=${B_P95}s rtf=$B_RTF max_queue=$B_Q firing=[$(firing)]"

echo "=== 5. overload: $CONCURRENCY callers against one replica, up to ${OVERLOAD_S} s ==="
load "$CONCURRENCY"
t0=$(date +%s); FIRED=""; fire_s="-"
while [ $(( $(date +%s) - t0 )) -lt "$OVERLOAD_S" ]; do
  f=$(firing)
  if [ -n "$f" ] && [ -z "$FIRED" ]; then fire_s=$(( $(date +%s) - t0 )); echo "  firing after ${fire_s} s: $f"; fi
  [ -n "$f" ] && FIRED="$f"
  # Hold the load a little after both alerts are up, so the numbers settle.
  case "$FIRED" in *Backlog*Slow*|*Slow*Backlog*) [ $(( $(date +%s) - t0 )) -gt $(( fire_s + 30 )) ] 2>/dev/null && break;; esac
  sleep 10
done
O_RPS=$(prom 'sum(switchboard:requests:rate1m)')
O_P95=$(prom 'switchboard:request_seconds:p95_1m')
O_INF=$(prom 'histogram_quantile(0.95, sum by (le) (rate(switchboard_inference_seconds_bucket{job="switchboard"}[1m])))')
O_WAIT=$(prom 'histogram_quantile(0.95, sum by (le) (rate(switchboard_queue_wait_seconds_bucket{job="switchboard"}[1m])))')
O_Q=$(prom 'max_over_time(sum(switchboard_queue_depth{job="switchboard"})[1m:15s])')
O_CPU=$(prom 'sum(rate(container_cpu_usage_seconds_total{namespace="switchboard",container="switchboard"}[1m]))')
AM_SEEN=$(curl -s "$AM/api/v2/alerts" | jq -r '[.[] | select(.labels.alertname|startswith("Switchboard")) | .labels.alertname] | unique | join(",")')
echo "rps=$O_RPS p95=${O_P95}s (inference p95=${O_INF}s, waiting p95=${O_WAIT}s) max_queue=$O_Q cpu=$O_CPU"
echo "Prometheus firing: [${FIRED}]   Alertmanager received: [${AM_SEEN}]"
stop_load

echo "=== 6. load removed: do the alerts clear by themselves? ==="
t0=$(date +%s); clear_s="-"
for i in $(seq 1 60); do
  [ -z "$(firing)" ] && { clear_s=$(( $(date +%s) - t0 )); break; }
  sleep 10
done
echo "all switchboard alerts resolved after ${clear_s} s"

{
  echo "# Task 6 - Prometheus + Grafana, measured $(date +%F)"
  echo
  echo "Docker Desktop Kubernetes, kube-prometheus-stack $KPS_VERSION, switchboard with the real"
  echo "weights (1 replica, CPU fp32, up to 4 cores), scraped every 15 s."
  echo
  echo "| check | result |"
  echo "|---|---:|"
  echo "| monitoring stack installed and ready | ${stack_up} s |"
  echo "| service found and scraped, no Prometheus config edited | ${up:-missing} after ${found} s |"
  echo "| recording + alerting rules loaded from the chart | $RULES |"
  echo "| dashboard provisioned from the chart | $DASH |"
  echo
  echo "| | baseline (1 caller) | overload ($CONCURRENCY callers) |"
  echo "|---|---:|---:|"
  printf '| requests / s | %.2f | %.2f |\n' "$B_RPS" "$O_RPS"
  printf '| p95 end to end | %.2f s | %.2f s |\n' "$B_P95" "$O_P95"
  printf '| p95 inference / p95 waiting | - | %.2f s / %.2f s |\n' "$O_INF" "$O_WAIT"
  printf '| max requests queued | %s | %s |\n' "$B_Q" "$O_Q"
  printf '| real-time factor (baseline) | %.3f | - |\n' "$B_RTF"
  printf '| pod CPU, cores | - | %.2f |\n' "$O_CPU"
  echo
  echo "| alerting | result |"
  echo "|---|---:|"
  echo "| firing under overload | $FIRED |"
  echo "| first alert firing after overload began | ${fire_s} s |"
  echo "| reached Alertmanager | $AM_SEEN |"
  echo "| all resolved after load stopped | ${clear_s} s |"
} >results/task6-monitoring.md
echo "=== wrote results/task6-monitoring.md ==="
