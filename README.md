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
| 2 | the container | Docker | |
| 3 | a local cluster | Kubernetes (Docker Desktop) | |
| 4 | packaging | Helm | |
| 5 | the cloud, from code | Terraform + GKE Autopilot | |
| 6 | seeing it | Prometheus + Grafana | |
| 7 | scaling | KEDA | |
| 8 | canary | Argo Rollouts | |
| 9 | the GPU + the numbers | L4 pod, DCGM, k6 | |
| 10 | Azure appendix | Terraform azurerm + AKS | |
| 11 | tear down + write-up | | |
