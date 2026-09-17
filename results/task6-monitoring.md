# Task 6 - Prometheus + Grafana, measured 2026-09-17

Docker Desktop Kubernetes, kube-prometheus-stack 91.4.1, switchboard with the real
weights (1 replica, CPU fp32, up to 4 cores), scraped every 15 s.

| check | result |
|---|---:|
| monitoring stack installed and ready | 25 s |
| service found and scraped, no Prometheus config edited | up after 75 s |
| recording + alerting rules loaded from the chart | 10 |
| dashboard provisioned from the chart | switchboard |

| | baseline (1 caller) | overload (4 callers) |
|---|---:|---:|
| requests / s | 0.80 | 0.75 |
| p95 end to end | 1.60 s | 10.17 s |
| p95 inference / p95 waiting | - | 4.13 s / 5.00 s |
| max requests queued | 0 | 3 |
| real-time factor (baseline) | 0.185 | - |
| pod CPU, cores | - | 3.97 |

| alerting | result |
|---|---:|
| firing under overload | SwitchboardBacklog,SwitchboardSlow |
| first alert firing after overload began | 81 s |
| reached Alertmanager | SwitchboardBacklog,SwitchboardSlow |
| all resolved after load stopped | 81 s |
