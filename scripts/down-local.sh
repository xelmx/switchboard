#!/usr/bin/env bash
# Take the local platform down and give the memory back (~3 GB). Free.
#
#   bash scripts/down-local.sh
#
# Removes everything scripts/up-local.sh installed. The image stays in the
# cluster node, so bringing it back up is quick. Docker Desktop's Kubernetes
# keeps running; switch it off in Docker Desktop's settings if you want that
# memory too.
set -uo pipefail
kubectl config use-context docker-desktop >/dev/null || exit 1
for r in "switchboard switchboard" "argo-rollouts argo-rollouts" "http-add-on keda" "keda keda" "kps monitoring"; do
  set -- $r
  if helm status "$1" -n "$2" >/dev/null 2>&1; then
    helm uninstall "$1" -n "$2" --wait --timeout 5m >/dev/null && echo "removed $1"
  fi
done
echo "waiting for the pods to go..."
for i in $(seq 1 60); do
  [ "$(kubectl get pods -A --no-headers 2>/dev/null | grep -cE '^(switchboard|monitoring|keda|argo-rollouts) ')" -eq 0 ] && break
  sleep 3
done
kubectl get pods -A --no-headers | grep -E '^(switchboard|monitoring|keda|argo-rollouts) ' || echo "all gone"
