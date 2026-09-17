#!/usr/bin/env bash
# Is the whole local platform healthy? About a minute; changes nothing.
#
#   bash scripts/check-platform.sh
#
# One line per check, PASS or FAIL, and a non-zero exit if anything failed.
# Covers: the cluster, each installed tool, the service answering (health,
# readiness, a real transcription, the chart's own test), Prometheus scraping
# it and loading its rules, no alerts firing, the Grafana dashboard, the
# autoscaler or the canary controller, and - if you're logged in to Google
# Cloud - that nothing is left running there.
set -uo pipefail
cd "$(dirname "$0")/.."
NS=switchboard
REL=switchboard
URL=http://localhost:8000
GRAFANA=http://localhost:3000
PROM=http://localhost:9090
CLIP=loadtest/probe/1089-134686-0002.wav
pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s  -> %s\n' "$1" "$2"; fail=$((fail+1)); }
check() { # check <label> <hint on failure> <command...>
  local label=$1 hint=$2; shift 2
  if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label" "$hint"; fi
}
section() { echo; echo "$*"; }

section "The cluster"
kubectl config use-context docker-desktop >/dev/null 2>&1
check "Docker Desktop Kubernetes answers" "start Docker Desktop, enable Kubernetes" kubectl get --raw /readyz
NODE_OK=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l)
[ "$NODE_OK" -ge 1 ] && ok "node Ready" || bad "node Ready" "kubectl get nodes"

section "Installed tools (Helm releases)"
for r in "kps monitoring Prometheus+Grafana" "keda keda KEDA" "http-add-on keda KEDA-HTTP-add-on" "argo-rollouts argo-rollouts Argo-Rollouts" "switchboard switchboard switchboard"; do
  set -- $r
  st=$(helm status "$1" -n "$2" -o json 2>/dev/null | jq -r '.info.status' 2>/dev/null)
  [ "$st" = deployed ] && ok "$3 release deployed" || bad "$3 release deployed" "status '${st:-missing}' - run scripts/up-local.sh"
done
for ns in monitoring keda argo-rollouts switchboard; do
  notready=$(kubectl -n $ns get pods --no-headers 2>/dev/null | awk '{split($2,a,"/"); if ($3!="Completed" && a[1]!=a[2]) print $1}')
  total=$(kubectl -n $ns get pods --no-headers 2>/dev/null | wc -l)
  if [ "$total" -gt 0 ] && [ -z "$notready" ]; then ok "all $total pods ready in $ns"
  else bad "all pods ready in $ns" "not ready: ${notready:-no pods}"; fi
done

section "The service"
check "/healthz answers (process alive)" "kubectl -n $NS get pods" curl -sf --max-time 5 "$URL/healthz"
check "/readyz answers (model loaded)" "pods may still be loading - wait and re-run" curl -sf --max-time 5 "$URL/readyz"
resp=$(curl -s --max-time 60 -F "file=@$CLIP" "$URL/v1/transcribe")
text=$(jq -r '.text // empty' <<<"$resp" 2>/dev/null)
if [ -n "$text" ]; then ok "transcription: \"${text:0:60}\" ($(jq -r '.model.class' <<<"$resp"))"
else bad "transcription" "response: ${resp:0:120}"; fi
check "chart's own test (helm test)" "kubectl -n $NS logs $REL-test" helm test $REL -n $NS

section "Monitoring"
kubectl -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090 >/dev/null 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null' EXIT
for i in $(seq 1 20); do curl -sf "$PROM/-/ready" >/dev/null && break; sleep 1; done
up=$(curl -s "$PROM/api/v1/targets?state=active" | jq -r '[.data.activeTargets[] | select(.labels.job=="'$REL'") | .health] | unique | join(",")' 2>/dev/null)
[ "$up" = up ] && ok "Prometheus scrapes switchboard" || bad "Prometheus scrapes switchboard" "target health: '${up:-missing}' (new pods take ~1 min)"
rules=$(curl -s "$PROM/api/v1/rules" | jq -r '[.data.groups[] | select(.name|startswith("switchboard")) | .rules[]] | length' 2>/dev/null)
[ "${rules:-0}" -ge 10 ] && ok "switchboard rules loaded ($rules)" || bad "switchboard rules loaded" "found ${rules:-0}, expected 10"
firing=$(curl -s "$PROM/api/v1/alerts" | jq -r '[.data.alerts[] | select(.state=="firing") | select(.labels.alertname|startswith("Switchboard")) | .labels.alertname] | unique | join(",")' 2>/dev/null)
[ -z "$firing" ] && ok "no switchboard alerts firing" || bad "no switchboard alerts firing" "firing: $firing"
check "Grafana answers on localhost:3000" "kubectl -n monitoring get svc kps-grafana" curl -sf --max-time 5 "$GRAFANA/api/health"
dash=$(curl -s --max-time 5 "$GRAFANA/api/search?query=switchboard" | jq -r '.[0].uid // empty' 2>/dev/null)
[ "$dash" = switchboard ] && ok "switchboard dashboard present ($GRAFANA/d/switchboard)" || bad "switchboard dashboard present" "values-monitoring.yaml not applied?"

section "Scaling / delivery"
if kubectl -n $NS get rollout $REL >/dev/null 2>&1; then
  ph=$(kubectl -n $NS get rollout $REL -o jsonpath='{.status.phase}')
  [ "$ph" = Healthy ] && ok "canary mode: Rollout Healthy" || bad "canary mode: Rollout Healthy" "phase $ph - see http://localhost:3100/rollouts/$REL"
else
  so=$(kubectl -n $NS get scaledobject $REL -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  [ "$so" = True ] && ok "autoscaling: KEDA ScaledObject ready" || bad "autoscaling: KEDA ScaledObject ready" "Ready='${so:-missing}'"
  check "autoscaling: HPA exists" "KEDA creates keda-hpa-$REL" kubectl -n $NS get hpa keda-hpa-$REL
fi
check "Argo Rollouts dashboard answers on localhost:3100" "kubectl -n argo-rollouts get svc" curl -sf --max-time 5 http://localhost:3100/

section "Google Cloud (costs money if anything is listed)"
acct=$(gcloud config get-value account 2>/dev/null)
if [ -n "$acct" ] && [ "$acct" != "(unset)" ]; then
  if bash scripts/cloud-check.sh >/tmp/cloud-check.out 2>&1; then ok "nothing running in the cloud"
  else bad "nothing running in the cloud" "$(grep '^!!' /tmp/cloud-check.out | head -3 | tr '\n' ' ') - run scripts/destroy-task5.sh"; fi
else
  echo "  skip  not logged in to gcloud"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
