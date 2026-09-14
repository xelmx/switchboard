#!/usr/bin/env bash
# Take task 5 back down. The whole point of building it from files.
#
#   bash scripts/destroy-task5.sh
#
# Order matters: the Service owns a Google load balancer that Terraform never
# created and does not know about. Destroy the cluster first and that load
# balancer is orphaned - still billing, invisible to `terraform destroy`, and
# findable only in the console. Uninstall the release first and Kubernetes
# deletes it properly on the way out.
set -uo pipefail
cd "$(dirname "$0")/.."

if kubectl config current-context 2>/dev/null | grep -q gke; then
  echo "=== 1. uninstall the release (releases the load balancer) ==="
  helm uninstall switchboard -n switchboard 2>/dev/null
  echo "waiting for the load balancer to be released..."
  for i in $(seq 1 60); do
    kubectl -n switchboard get svc switchboard >/dev/null 2>&1 || break
    sleep 5
  done
  kubectl delete namespace switchboard --ignore-not-found
else
  echo "kubectl is not pointed at a GKE cluster; skipping the release"
fi

echo "=== 2. destroy the cluster and the registry ==="
terraform -chdir=terraform destroy -input=false -auto-approve -no-color

echo
echo "Check nothing is left billing:"
echo "  gcloud compute forwarding-rules list"
echo "  gcloud container clusters list"
echo "  gcloud artifacts repositories list"
