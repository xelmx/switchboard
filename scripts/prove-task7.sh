#!/usr/bin/env bash
# Task 7 proof, inside WSL Ubuntu, from the repo root. Local cluster only - free.
# Needs task 6's monitoring stack (the scaler reads Prometheus) and the
# switchboard:0.2 image in the node.
#
#   bash scripts/prove-task7.sh
#
# What it shows, in order:
#   1. KEDA (and its HTTP add-on) installed with Helm
#   2. overload one replica; KEDA adds replicas from a Prometheus number, and
#      the client-side p95 comes back down - measured, not assumed
#   3. load removed; replicas go back to one, one at a time
#   4. the trap: a Prometheus trigger allowed to reach zero never wakes up again
#   5. scale-to-zero done properly: the HTTP add-on holds the first request
#      while a pod cold-starts, then scales out and back to zero
#
# Leaves switchboard in prometheus mode at one fake replica.
set -uo pipefail
cd "$(dirname "$0")/.."
CTX=docker-desktop
NS=switchboard
REL=switchboard
KEDA_VERSION=2.20.2
HTTP_VERSION=0.16.0
URL=http://localhost:8000
PROXY=http://localhost:8081       # port-forward to the HTTP add-on's interceptor
HOST=switchboard.local
PROM=http://localhost:9090
CLIP=loadtest/probe/1089-134686-0002.wav
CALLERS="${CALLERS:-4}"
LOAD_S="${LOAD_S:-240}"
VALUES="-f chart/switchboard/values-autoscale.yaml -f chart/switchboard/values-monitoring.yaml"
LAT=/tmp/sb7-latency.log          # one line per request: <end epoch> <seconds> <http code>
mkdir -p results

echo "=== 0. preflight: local cluster, image, monitoring ==="
kubectl config use-context "$CTX" >/dev/null || exit 1
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
IMAGES=$(docker exec "$NODE" ctr -n k8s.io images ls 2>/dev/null)
grep -q "docker.io/library/switchboard:0.2" <<<"$IMAGES" || { echo "switchboard:0.2 not in the node"; exit 1; }
helm status kps -n monitoring >/dev/null 2>&1 || { echo "run scripts/prove-task6.sh first (Prometheus)"; exit 1; }

kubectl -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090 >/dev/null 2>&1 &
PF1=$!
PF2=""; LOADPIDS=""
cleanup() { kill $PF1 $PF2 $LOADPIDS 2>/dev/null; }
trap cleanup EXIT

# kubectl prints an absent field as nothing at all - not even a newline - so
# `sed 's/^$/0/'` has no line to act on. Default it in the shell instead.
replicas() { local r; r=$(kubectl -n $NS get deploy $REL -o jsonpath='{.status.readyReplicas}' 2>/dev/null); echo "${r:-0}"; }
wait_replicas() {  # wait_replicas <n> <timeout s>; prints seconds taken or "timeout"
  local t0=$(date +%s)
  while [ $(( $(date +%s) - t0 )) -lt "$2" ]; do
    local ready=$(replicas) total=$(kubectl -n $NS get pods -l app.kubernetes.io/instance=$REL --no-headers 2>/dev/null | grep -vc Completed)
    [ "$ready" = "$1" ] && [ "$total" = "$1" ] && { echo $(( $(date +%s) - t0 )); return 0; }
    sleep 3
  done
  echo timeout; return 1
}
# load <n> <url> [host header]: n callers posting the clip in a loop, timing each request
load() {
  local n=$1 url=$2 host=${3:-}; LOADPIDS=""
  for w in $(seq 1 "$n"); do
    ( while true; do
        r=$(curl -s -o /dev/null -w '%{time_total} %{http_code}' ${host:+-H "Host: $host"} \
              -F "file=@$CLIP" "$url/v1/transcribe" --max-time 120)
        echo "$(date +%s) $r" >>"$LAT"
      done ) &
    LOADPIDS="$LOADPIDS $!"
  done
}
stop_load() { kill $LOADPIDS 2>/dev/null; wait $LOADPIDS 2>/dev/null; LOADPIDS=""; }
# p95 <from epoch> <to epoch>: client-side p95 of successful requests finishing in the window
p95() {
  awk -v a="$1" -v b="$2" '$1>=a && $1<b && $3==200 {print $2}' "$LAT" | sort -n \
    | awk '{v[NR]=$1} END{ if(NR==0){print "n/a"; exit} i=int(NR*0.95+0.999); if(i>NR)i=NR; printf "%.2f s (n=%d)", v[i], NR}'
}

echo "=== 1. KEDA $KEDA_VERSION and the HTTP add-on $HTTP_VERSION ==="
helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1
helm repo update kedacore >/dev/null
t0=$(date +%s)
helm upgrade --install keda kedacore/keda --version $KEDA_VERSION -n keda --create-namespace \
  -f autoscaling/keda.local.yaml --wait --timeout 10m >/dev/null || exit 1
helm upgrade --install http-add-on kedacore/keda-add-ons-http --version $HTTP_VERSION -n keda \
  -f autoscaling/keda-http.local.yaml --wait --timeout 10m >/dev/null || exit 1
kubectl -n keda wait --for=condition=Ready pod --all --timeout=5m >/dev/null || exit 1
keda_up=$(( $(date +%s) - t0 ))
echo "KEDA ready after ${keda_up} s"
kubectl -n keda get pods

echo "=== 2. prometheus mode: one replica, then $CALLERS callers ==="
# A clean release: the old one set replicas itself, which an autoscaled one must not.
helm uninstall $REL -n $NS --wait >/dev/null 2>&1
helm install $REL chart/switchboard -n $NS --create-namespace $VALUES --wait --timeout 5m >/dev/null || exit 1
kubectl -n $NS get scaledobject,hpa
echo "replicas before load: $(replicas)"
for i in $(seq 1 60); do curl -sf "$URL/readyz" >/dev/null && break; sleep 1; done
rm -f "$LAT"
load "$CALLERS" "$URL"
L0=$(date +%s)
echo "time  ready  demand (avg requests in flight, 1m)"
up_s="timeout"
while [ $(( $(date +%s) - L0 )) -lt "$LOAD_S" ]; do
  r=$(replicas)
  d=$(curl -s --get "$PROM/api/v1/query" --data-urlencode \
      "query=sum(rate(switchboard_request_seconds_sum{job=\"$REL\"}[1m]))" | jq -r '.data.result[0].value[1] // "-"')
  printf '%4ss  %5s  %s\n' $(( $(date +%s) - L0 )) "$r" "$d"
  [ "$up_s" = "timeout" ] && [ "$r" -ge "$CALLERS" ] && up_s=$(( $(date +%s) - L0 ))
  sleep 10
done
L1=$(date +%s)
stop_load
BEFORE=$(p95 "$L0" $(( L0 + 30 )))
if [ "$up_s" != "timeout" ]; then AFTER=$(p95 $(( L0 + up_s + 30 )) "$L1"); else AFTER="n/a"; fi
FAILED=$(awk -v a="$L0" '$1>=a && $3!=200' "$LAT" | wc -l)
TOTAL=$(awk -v a="$L0" '$1>=a' "$LAT" | wc -l)
echo "reached $CALLERS ready replicas after: ${up_s} s"
echo "client p95, first 30 s (one replica): $BEFORE"
echo "client p95, once scaled (+30 s settle): $AFTER"
echo "requests: $TOTAL, failed: $FAILED"
# Four replicas for four callers is not four callers each on their own replica:
# the Service picks a pod at random per connection. Show the deepest queue each
# pod saw while all four were up.
PERPOD="n/a"
[ "$up_s" != "timeout" ] && PERPOD=$(curl -s --get "$PROM/api/v1/query" --data-urlencode \
  "query=max by (pod) (max_over_time(switchboard_queue_depth{job=\"$REL\"}[$(( L1 - L0 - up_s - 30 ))s]))" \
  | jq -r '[.data.result[] | .value[1]] | sort | join(" ")')
echo "deepest queue per pod while scaled: $PERPOD"
kubectl -n $NS get hpa

echo "=== 3. load removed: back to one ==="
down_s=$(wait_replicas 1 300)
echo "back to 1 replica after ${down_s} s"

echo "=== 4. the trap: a Prometheus trigger with minReplicas 0 ==="
helm upgrade $REL chart/switchboard -n $NS $VALUES --set autoscaling.minReplicas=0 --wait >/dev/null || exit 1
zero_s=$(wait_replicas 0 300)
echo "scaled to zero after ${zero_s} s (no demand)"
code=$(curl -s -o /dev/null -w '%{http_code}' -F "file=@$CLIP" "$URL/v1/transcribe" --max-time 10)
echo "a request now gets HTTP $code (000 = nothing listening)"
for i in 1 2 3 4 5 6 7 8 9; do
  curl -s -o /dev/null -F "file=@$CLIP" "$URL/v1/transcribe" --max-time 5; sleep 10
done
TRAP=$(replicas)
echo "replicas after 90 s of requests knocking: $TRAP  (the metric comes from pods; there are none)"

echo "=== 5. http mode: scale-to-zero through the interceptor (add-on is ALPHA) ==="
helm upgrade $REL chart/switchboard -n $NS $VALUES \
  --set autoscaling.mode=http --set autoscaling.minReplicas=0 --wait >/dev/null || exit 1
kubectl -n $NS get httpscaledobject,scaledobject
kubectl -n keda port-forward svc/keda-add-ons-http-interceptor-proxy 8081:8080 >/dev/null 2>&1 &
PF2=$!
sleep 3
wait_replicas 0 300 >/dev/null
echo "replicas: $(replicas)"
echo "--- a cold request (no pods exist)"
t0=$(date +%s)
cold=$(curl -s -o /tmp/sb7-cold.json -w '%{time_total} %{http_code}' -H "Host: $HOST" \
        -F "file=@$CLIP" "$PROXY/v1/transcribe" --max-time 180)
echo "cold request: $cold -> $(jq -r .text /tmp/sb7-cold.json 2>/dev/null)"
warm=$(curl -s -o /dev/null -w '%{time_total} %{http_code}' -H "Host: $HOST" \
        -F "file=@$CLIP" "$PROXY/v1/transcribe" --max-time 60)
echo "warm request: $warm"
echo "--- $CALLERS callers through the interceptor for 120 s"
: >"$LAT"
load "$CALLERS" "$PROXY" "$HOST"
H0=$(date +%s); http_peak=0
while [ $(( $(date +%s) - H0 )) -lt 120 ]; do
  r=$(replicas); [ "$r" -gt "$http_peak" ] && http_peak=$r
  sleep 10
done
stop_load
HTTP_P95=$(p95 $(( H0 + 60 )) $(date +%s))
HTTP_FAILED=$(awk '$3!=200' "$LAT" | wc -l)
echo "peak replicas: $http_peak; client p95 in the last minute: $HTTP_P95; failed: $HTTP_FAILED"
back_zero=$(wait_replicas 0 300)
echo "back to zero after ${back_zero} s"

echo "=== 6. leave it in prometheus mode, one replica ==="
# The add-on made its own ScaledObject, also named switchboard. Helm will not
# create one over an object it doesn't own, so switch autoscaling off first and
# wait for the add-on's to be garbage-collected.
helm upgrade $REL chart/switchboard -n $NS $VALUES --set autoscaling.enabled=false --wait >/dev/null
for i in $(seq 1 60); do
  kubectl -n $NS get scaledobject $REL >/dev/null 2>&1 || break
  sleep 2
done
helm upgrade $REL chart/switchboard -n $NS $VALUES --wait >/dev/null || exit 1
wait_replicas 1 300 >/dev/null; echo "replicas: $(replicas)"

{
  echo "# Task 7 - autoscaling with KEDA, measured $(date +%F)"
  echo
  echo "Docker Desktop Kubernetes, KEDA $KEDA_VERSION, HTTP add-on $HTTP_VERSION (alpha)."
  echo "Fake pods with FAKE_RTF=0.185 - the real model's measured timing on this CPU."
  echo "Latency is measured by the client, per request, not from histogram buckets."
  echo
  echo "**Prometheus mode** (1..4 replicas, target 1 request in flight per replica), $CALLERS callers:"
  echo
  echo "| check | result |"
  echo "|---|---:|"
  echo "| KEDA + add-on installed and ready | ${keda_up} s |"
  echo "| load start -> $CALLERS ready replicas | ${up_s} s |"
  echo "| client p95, first 30 s on one replica | $BEFORE |"
  echo "| client p95, after scaling | $AFTER |"
  echo "| requests during the run / failed | $TOTAL / $FAILED |"
  echo "| deepest queue on each pod while scaled | $PERPOD |"
  echo "| load stopped -> back to 1 replica | ${down_s} s |"
  echo
  echo "**The trap** - same trigger, minReplicas 0:"
  echo
  echo "| check | result |"
  echo "|---|---:|"
  echo "| idle -> 0 replicas | ${zero_s} s |"
  echo "| a request at zero | HTTP $code |"
  echo "| replicas after 90 s of requests | **$TRAP** |"
  echo
  echo "**HTTP mode** (0..4 replicas via the interceptor):"
  echo
  echo "| check | result |"
  echo "|---|---:|"
  echo "| cold request from zero pods (seconds, status) | $cold |"
  echo "| next request, warm | $warm |"
  echo "| peak replicas under $CALLERS callers | $http_peak |"
  echo "| client p95, last minute of load / failed | $HTTP_P95 / $HTTP_FAILED |"
  echo "| load stopped -> back to 0 | ${back_zero} s |"
} >results/task7-autoscaling.md
echo "=== wrote results/task7-autoscaling.md ==="
