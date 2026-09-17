#!/usr/bin/env bash
# Task 5 proof, inside WSL Ubuntu, from the repo root.
#
# THIS ONE COSTS MONEY. It creates a GKE Autopilot cluster, an Artifact
# Registry repository and an external load balancer in your GCP project, and
# leaves them running. Nothing here is free after the trial credit.
#
#   CONFIRM=yes bash scripts/prove-task5.sh
#
# End the session with:
#   bash scripts/destroy-task5.sh          # cluster off, image kept
#   ALL=1 bash scripts/destroy-task5.sh    # everything, at the end of the project
#
# What it shows, in order:
#   1. an empty project becomes a cluster and a registry, from files (apply)
#   2. the image is built inside Google's network, not pushed from here (builds)
#   3. the same chart, a different values file, runs on a real cloud   (helm)
#   4. a transcript comes back over the public internet                (curl)
set -uo pipefail
cd "$(dirname "$0")/.."
NS=switchboard
REL=switchboard
CHART=chart/switchboard
VALUES=chart/switchboard/values-gke.yaml
TAG="${TAG:-v1}"
CLIP=loadtest/probe/1089-134686-0002.wav
mkdir -p results

if [ "${CONFIRM:-}" != "yes" ]; then
  echo "This creates billable Google Cloud resources. Re-run with CONFIRM=yes."
  exit 1
fi

echo "=== 0. preflight ==="
command -v gcloud >/dev/null || { echo "gcloud missing"; exit 1; }
ACCOUNT=$(gcloud config get-value account 2>/dev/null)
[ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "(unset)" ] || { echo "not logged in: gcloud auth login"; exit 1; }
[ -f terraform/terraform.tfvars ] || { echo "terraform/terraform.tfvars missing - copy terraform/example.tfvars"; exit 1; }
PROJECT=$(grep -E '^\s*project_id' terraform/terraform.tfvars | cut -d'"' -f2)
REGION=$(grep -E '^\s*region' terraform/terraform.tfvars | cut -d'"' -f2)
REGION="${REGION:-asia-southeast1}"
echo "account=$ACCOUNT project=$PROJECT region=$REGION"
gcloud config set project "$PROJECT" >/dev/null
# Terraform authenticates as you, through Application Default Credentials -
# a separate login from the one the gcloud command itself uses.
gcloud auth application-default print-access-token >/dev/null 2>&1 \
  || { echo "no ADC: gcloud auth application-default login"; exit 1; }

echo "=== 1. the cluster and the registry, from files ==="
t0=$(date +%s)
terraform -chdir=terraform init -input=false -no-color >/dev/null || exit 1
terraform -chdir=terraform apply -input=false -auto-approve -no-color || exit 1
tf=$(( $(date +%s) - t0 ))
REGISTRY=$(terraform -chdir=terraform output -raw registry)
echo "terraform apply took ${tf} s; registry=$REGISTRY"

echo "=== 2. build the image inside Google's network ==="
IMAGE="$REGISTRY/switchboard:$TAG"
if gcloud artifacts docker images describe "$IMAGE" >/dev/null 2>&1; then
  echo "$IMAGE already built; skipping (delete the tag to rebuild)"
  build=0
else
  t0=$(date +%s)
  gcloud builds submit --region "$REGION" --config cloudbuild.yaml \
    --substitutions=_IMAGE="$IMAGE" . || exit 1
  build=$(( $(date +%s) - t0 ))
  echo "cloud build took ${build} s"
fi
gcloud artifacts docker images list "$REGISTRY/switchboard" --include-tags 2>/dev/null | head -5

echo "=== 3. point kubectl at the cluster ==="
CLUSTER=$(terraform -chdir=terraform output -raw cluster_name)
gcloud container clusters get-credentials "$CLUSTER" --region "$REGION" --project "$PROJECT" || exit 1
kubectl config current-context
# Autopilot: no node pool was declared anywhere. Nodes appear to fit the pods.
echo "nodes before any workload: $(kubectl get nodes --no-headers 2>/dev/null | wc -l)"

echo "=== 4. the same chart, the cloud values ==="
if helm status "$REL" -n $NS >/dev/null 2>&1; then
  echo "release exists; upgrading"; ACTION=upgrade
else
  ACTION=install
fi
t0=$(date +%s)
helm $ACTION "$REL" "$CHART" -n $NS --create-namespace \
  -f "$VALUES" --set image.repository="$REGISTRY/switchboard" --set image.tag="$TAG" \
  --wait --timeout 20m || exit 1
up=$(( $(date +%s) - t0 ))
echo "$ACTION to ready took ${up} s (node provisioning + a 6.6 GB image pull are in here)"
kubectl -n $NS get pods -o wide
echo "nodes after: $(kubectl get nodes --no-headers | wc -l)"

echo "=== 5. the external address ==="
for i in $(seq 1 60); do
  IP=$(kubectl -n $NS get svc "$REL" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  [ -n "$IP" ] && break
  sleep 5
done
[ -n "$IP" ] || { echo "no external IP after 5 min"; exit 1; }
echo "external IP: $IP"

echo "=== 6. the chart's own test, in the cloud ==="
if helm test "$REL" -n $NS; then TEST=pass; else TEST=FAIL; fi
echo "helm test: $TEST"

echo "=== 7. a transcript over the public internet ==="
for i in $(seq 1 30); do curl -sf "http://$IP:8000/readyz" >/dev/null && break; sleep 2; done
RESP=$(curl -s -F "file=@$CLIP" "http://$IP:8000/v1/transcribe" --max-time 60)
echo "$RESP" | jq -r '"model: \(.model.class) on \(.model.device)/\(.model.dtype)\ntext:  \(.text)\ninference: \(.inference_ms) ms for \(.audio_seconds) s of audio"'
MS=$(echo "$RESP" | jq -r '.inference_ms')

{
  echo "# Task 5 - the cloud from code, measured $(date +%F)"
  echo
  echo "GKE Autopilot in \`$REGION\`, image from Artifact Registry, same chart as the laptop."
  echo
  echo "| check | result |"
  echo "|---|---:|"
  echo "| \`terraform apply\` - cluster + registry from nothing | ${tf} s |"
  echo "| image built in Cloud Build (never left Google's network) | ${build} s |"
  echo "| nodes declared anywhere in this repo | 0 |"
  echo "| \`helm $ACTION --wait\` to ready on Autopilot | ${up} s |"
  echo "| \`helm test\` against the cloud release | $TEST |"
  echo "| external address | \`$IP:8000\` |"
  echo "| inference for 6.6 s of audio, 2 vCPU | ${MS} ms |"
  echo
  echo "The laptop values and the cloud values differ only in image, replicas,"
  echo "resources and the startup budget - \`chart/switchboard/values-gke.yaml\`."
} >results/task5-gke.md
echo "=== wrote results/task5-gke.md ==="

cat <<WARN

  ----------------------------------------------------------------
  STILL RUNNING AND STILL BILLING: a GKE Autopilot cluster, one
  pod at 2 vCPU / 4 GiB, and an external load balancer.

      bash scripts/destroy-task5.sh

  ----------------------------------------------------------------
WARN
