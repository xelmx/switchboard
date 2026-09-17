# switchboard

**Serving the phone-audio speech-to-text model the way a company would.**

[dialtone](https://github.com/xelmx/dialtone) measured which open speech-to-text
model holds up on phone-quality audio: Parakeet-TDT-0.6B for the realistic bad
call. This repo runs that model as a production-style service — in a container,
on Kubernetes, built from Terraform, with metrics, scale-to-zero, a canary rollout
between model versions, and a published load test — first locally, then on Google
Cloud (GKE Autopilot), then the same deployment on Azure (AKS).

Work in progress. `NOTES.md` is the running log, one entry per tool.

## Status

| # | task | tool | state |
|---|---|---|---|
| 0 | toolchain | WSL2 Ubuntu, kubectl, helm, terraform, gcloud | done — explain-back pending |
| 1 | the service | FastAPI + prometheus-client | done — explain-back pending |
| 2 | the container | Docker | done — explain-back pending |
| 3 | a local cluster | Kubernetes (Docker Desktop) | done — explain-back pending |
| 4 | packaging | Helm | done — explain-back pending |
| 5 | the cloud, from code | Terraform + GKE Autopilot | done — explain-back pending |
| 6 | seeing it | Prometheus + Grafana | done — explain-back pending |
| 7 | scaling | KEDA (+ HTTP add-on for scale-to-zero) | done — explain-back pending |
| 8 | canary | Argo Rollouts | done — explain-back pending |
| 9 | the GPU + the numbers | local RTX 4060 (the GCP trial allows no GPUs), DCGM, k6 | |
| 10 | Azure appendix | Terraform azurerm + AKS | |
| 11 | tear down + write-up | | |

## Cost discipline

The cloud tasks run on a Google Cloud **free trial** ($300, 90 days), which is
never upgraded to a paid account: a trial cannot bill the card on file, and
when its credit or time runs out, resources are stopped rather than charged.
The trial allows no GPUs, so task 9 runs on a local RTX 4060.

Every cloud session ends the same way:

```
bash scripts/destroy-task5.sh   # release first (frees the load balancer), then the cluster
bash scripts/cloud-check.sh     # must print NOTHING RUNNING
```

The registry and its image stay between sessions (cents per month); the
cluster, which bills by the hour, does not.
