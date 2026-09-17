#!/usr/bin/env bash
# Is anything still running in the cloud? Run at the end of every session.
#
#   bash scripts/cloud-check.sh
#
# Lists every kind of resource this project can create that bills by the hour.
# Exit code 0 and "NOTHING RUNNING" is the only acceptable end to a session.
# (Artifact Registry storage is listed separately: it bills per GB-month, a
# few cents for one image, and is kept between sessions on purpose.)
set -uo pipefail
PROJECT=$(gcloud config get-value project 2>/dev/null)
echo "project: $PROJECT"
found=0
check() {  # check <label> <gcloud args...>
  local label=$1; shift
  local out; out=$(gcloud "$@" --format='value(name)' 2>/dev/null)
  if [ -n "$out" ]; then
    echo "!! $label:"; echo "$out" | sed 's/^/     /'; found=1
  else
    echo "ok $label: none"
  fi
}
check "GKE clusters"                container clusters list
check "load balancers (fwd rules)"  compute forwarding-rules list
check "reserved IP addresses"       compute addresses list
check "VM instances"                compute instances list
check "persistent disks"            compute disks list
check "running Cloud Builds"        builds list --ongoing
echo "-- kept on purpose (storage, cents per month) --"
gcloud artifacts repositories list --format='table(name,sizeBytes.size(units_out=G,precision=1):label=SIZE_GB)' 2>/dev/null
echo
if [ $found -eq 0 ]; then
  echo "NOTHING RUNNING - safe to walk away."
else
  echo "SOMETHING IS STILL RUNNING - run scripts/destroy-task5.sh (or delete it by hand)."
  exit 1
fi
