#!/usr/bin/env bash
# Bring the whole local platform up on Docker Desktop Kubernetes. Free.
#
#   bash scripts/up-local.sh            # fake model pods (~150 MB each)
#   REAL=1 bash scripts/up-local.sh     # the real Parakeet weights (~3 GB a pod)
#
# Installs, in order: monitoring (Prometheus, Grafana, Alertmanager), KEDA and
# its HTTP add-on, Argo Rollouts, then switchboard with monitoring and
# autoscaling on. Safe to run again - everything is `helm upgrade --install`.
# Then check it:  bash scripts/check-platform.sh
# Take it down:   bash scripts/down-local.sh
set -uo pipefail
cd "$(dirname "$0")/.."
CTX=docker-desktop
IMAGE=switchboard:0.2

step() { echo; echo "=== $* ==="; }
need() { command -v "$1" >/dev/null || { echo "missing: $1"; exit 1; }; }
need kubectl; need helm; need docker; need curl; need jq

step "0. the local cluster"
kubectl config use-context "$CTX" >/dev/null 2>&1 \
  || { echo "No '$CTX' context. Enable Kubernetes in Docker Desktop (Settings > Kubernetes)."; exit 1; }
kubectl get nodes >/dev/null 2>&1 \
  || { echo "Kubernetes isn't answering. Start Docker Desktop and wait for Kubernetes to be green."; exit 1; }
kubectl get nodes
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
IMAGES=$(docker exec "$NODE" ctr -n k8s.io images ls 2>/dev/null)
if ! grep -q "docker.io/library/$IMAGE" <<<"$IMAGES"; then
  docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "$IMAGE isn't built: docker build -t $IMAGE ."; exit 1; }
  echo "copying $IMAGE into the cluster node (6.6 GB, ~2-3 min)..."
  docker save "$IMAGE" | docker exec -i "$NODE" ctr -n k8s.io images import - >/dev/null || exit 1
fi
echo "$IMAGE is in the node"

step "1. chart repositories"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1
helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1
helm repo update prometheus-community kedacore argo >/dev/null || exit 1
echo ok

step "2. monitoring (Prometheus, Grafana, Alertmanager)"
helm upgrade --install kps prometheus-community/kube-prometheus-stack --version 91.4.1 \
  -n monitoring --create-namespace -f monitoring/kube-prometheus-stack.local.yaml \
  --wait --timeout 15m >/dev/null || exit 1
# The operator creates these after Helm is done (NOTES, task 6).
for app in prometheus alertmanager; do
  for i in $(seq 1 60); do kubectl -n monitoring get pod -l app.kubernetes.io/name=$app -o name 2>/dev/null | grep -q . && break; sleep 5; done
  kubectl -n monitoring wait --for=condition=Ready pod -l app.kubernetes.io/name=$app --timeout=10m >/dev/null || exit 1
done
echo ok

step "3. KEDA and the HTTP add-on"
helm upgrade --install keda kedacore/keda --version 2.20.2 -n keda --create-namespace \
  -f autoscaling/keda.local.yaml --wait --timeout 10m >/dev/null || exit 1
helm upgrade --install http-add-on kedacore/keda-add-ons-http --version 0.16.0 -n keda \
  -f autoscaling/keda-http.local.yaml --wait --timeout 10m >/dev/null || exit 1
echo ok

step "4. Argo Rollouts"
helm upgrade --install argo-rollouts argo/argo-rollouts --version 2.43.1 \
  -n argo-rollouts --create-namespace -f rollouts/argo-rollouts.local.yaml --wait --timeout 10m >/dev/null || exit 1
echo ok

step "5. switchboard (monitoring + autoscaling on)"
EXTRA=()
if [ "${REAL:-0}" = 1 ]; then
  # The real weights: the chart's own model settings, one to two copies.
  EXTRA=(--set model.fake=false --set autoscaling.maxReplicas=2
         --set resources.requests.memory=3Gi --set resources.limits.memory=4Gi
         --set resources.requests.cpu=1 --set resources.limits.cpu=4)
  echo "real weights, at most 2 replicas"
fi
# If the release is currently a canary Rollout (task 8), a mode switch needs a clean start.
if kubectl -n switchboard get rollout switchboard >/dev/null 2>&1; then
  helm uninstall switchboard -n switchboard --wait >/dev/null 2>&1
fi
helm upgrade --install switchboard chart/switchboard -n switchboard --create-namespace \
  -f chart/switchboard/values-autoscale.yaml -f chart/switchboard/values-monitoring.yaml \
  "${EXTRA[@]}" --wait --timeout 10m >/dev/null || exit 1
for i in $(seq 1 60); do curl -sf http://localhost:8000/readyz >/dev/null && break; sleep 2; done
echo ok

cat <<'DONE'

The platform is up.
  switchboard API     http://localhost:8000/docs
  Grafana             http://localhost:3000/d/switchboard   (admin / switchboard)
  Argo Rollouts       http://localhost:3100/rollouts

Next:  bash scripts/check-platform.sh
DONE
