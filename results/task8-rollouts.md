# Task 8 - canary rollouts with Argo Rollouts, measured 2026-09-17

Docker Desktop Kubernetes, Argo Rollouts chart 2.43.1, 4 replicas, fake pods
with the real model's timing (FAKE_RTF 0.185); the bad version uses FAKE_RTF 0.6.
Steps: 25% -> pause 90 s -> 50% -> pause 60 s -> 100%. Analysis every 30 s after
60 s: canary p95 model time <= 1.5x stable's, and zero canary errors.

| | good version (v2) | bad version (v3, 3x slower) |
|---|---:|---:|
| outcome | Healthy | Degraded (aborted) |
| time from helm upgrade | 169 s | 94 s |
| requests during the rollout / failed | 382 / 0 | 177 / 0 |

- good analysis: `Successful | inference-p95-vs-stable: Successful last=[1] | canary-errors: Successful last=[0]`
- bad analysis: `Failed | canary-errors: Successful last=[0] | inference-p95-vs-stable: Failed last=[3.3220338983050848]`
- pods after the abort: ` 4 6866dc87f6;` (stable = `6866dc87f6`)
- Helm's view of the release while the cluster ran v2: **deployed**
- `helm rollback` to v2: Healthy in 0 s
