#!/usr/bin/env bash
# Take task 5 back down. The whole point of building it from files.
#
#   bash scripts/destroy-task5.sh          # end of a session: cluster off, image kept
#   ALL=1 bash scripts/destroy-task5.sh    # the end of the project: everything
#
# Order matters: the Service owns a Google load balancer that Terraform never
# created and does not know about. Remove the cluster first and that load
# balancer is orphaned - still billing, invisible to Terraform. Uninstall the
# release first and Kubernetes deletes it properly on the way out.
set -uo pipefail
cd "$(dirname "$0")/.."

if kubectl config current-context 2>/dev/null | grep -q '^gke_'; then
  echo "=== 1. uninstall the release (releases the load balancer) ==="
  helm uninstall switchboard -n switchboard 2>/dev/null
  echo "waiting for the load balancer to be released..."
  for i in $(seq 1 60); do
    kubectl -n switchboard get svc switchboard >/dev/null 2>&1 || break
    sleep 5
  done
  kubectl delete namespace switchboard --ignore-not-found --timeout=5m
else
  echo "kubectl is not pointed at a GKE cluster; skipping the release"
fi

if [ "${ALL:-0}" = "1" ]; then
  echo "=== 2. destroy everything: cluster, registry, image ==="
  terraform -chdir=terraform destroy -input=false -auto-approve -no-color || exit 1
else
  echo "=== 2. cluster off, registry kept ==="
  terraform -chdir=terraform apply -input=false -auto-approve -no-color \
    -var cluster_enabled=false || exit 1
fi

echo "=== 3. is anything still billing? ==="
bash scripts/cloud-check.sh
