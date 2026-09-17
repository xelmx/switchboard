# Task 5 - the cloud from code, measured 2026-09-17

GKE Autopilot in `asia-southeast1`, image from Artifact Registry, same chart as the laptop.

| check | result |
|---|---:|
| `terraform apply` - cluster + registry from nothing | 431 s |
| image built in Cloud Build (never left Google's network) | 1052 s |
| nodes declared anywhere in this repo | 0 |
| `helm install --wait` to ready on Autopilot | 217 s |
| `helm test` against the cloud release | pass |
| external address | `35.247.166.60:8000` |
| inference for 6.6 s of audio, 2 vCPU | 3483.3 ms |

The laptop values and the cloud values differ only in image, replicas,
resources and the startup budget - `chart/switchboard/values-gke.yaml`.
