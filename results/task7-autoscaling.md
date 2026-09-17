# Task 7 - autoscaling with KEDA, measured 2026-09-17

Docker Desktop Kubernetes, KEDA 2.20.2, HTTP add-on 0.16.0 (alpha).
Fake pods with FAKE_RTF=0.185 - the real model's measured timing on this CPU.
Latency is measured by the client, per request, not from histogram buckets.

**Prometheus mode** (1..4 replicas, target 1 request in flight per replica), 4 callers:

| check | result |
|---|---:|
| KEDA + add-on installed and ready | 3 s |
| load start -> 4 ready replicas | 71 s |
| client p95, first 30 s on one replica | 4.96 s (n=23) |
| client p95, after scaling | 3.69 s (n=299) |
| requests during the run / failed | 449 / 0 |
| deepest queue on each pod while scaled | 1 1 2 2 |
| load stopped -> back to 1 replica | 105 s |

**The trap** - same trigger, minReplicas 0:

| check | result |
|---|---:|
| idle -> 0 replicas | 20 s |
| a request at zero | HTTP 000 |
| replicas after 90 s of requests | **0** |

**HTTP mode** (0..4 replicas via the interceptor):

| check | result |
|---|---:|
| cold request from zero pods (seconds, status) | 6.060189 200 |
| next request, warm | 1.247372 200 |
| peak replicas under 4 callers | 4 |
| client p95, last minute of load / failed | 3.67 s (n=134) / 0 |
| load stopped -> back to 0 | 68 s |
