# Task 4 - Helm, measured 2026-09-14

Chart `chart/switchboard` on Docker Desktop Kubernetes. Steps 1-6 use `chart/switchboard/values-fake.yaml`; step 7 uses the chart's own defaults.

| check | result |
|---|---:|
| objects rendered from the chart | 3 |
| `helm install --wait` to all replicas ready | 4 s |
| `helm test` (healthz, readyz, metrics) | pass |
| scale by `--set replicaCount` | revision 2 |
| broken upgrade refused (the 90 s --wait budget) | 93 s |
| `helm rollback` to the good revision | 0 s (the good pods were never removed) |
| requests during the break + rollback | 302 |
| failed requests | **0** |
| the same chart, chart defaults (real weights) | 13 s to ready |
| what answered | ParakeetForTDT, 1626.5 ms for 6.6 s of audio |

Revision history:

```
REVISION	UPDATED                 	STATUS    	CHART            	APP VERSION	DESCRIPTION                                                                                                                   
1       	Mon Sep 14 13:47:43 2026	superseded	switchboard-0.1.0	dev        	Install complete                                                                                                              
2       	Mon Sep 14 13:47:51 2026	superseded	switchboard-0.1.0	dev        	Upgrade complete                                                                                                              
3       	Mon Sep 14 13:47:59 2026	failed    	switchboard-0.1.0	dev        	Upgrade "switchboard" failed: resource Deployment/switchboard/switchboard not ready. status: InProgress, message: Updated: ...
4       	Mon Sep 14 13:49:32 2026	superseded	switchboard-0.1.0	dev        	Rollback to 2                                                                                                                 
5       	Mon Sep 14 13:49:35 2026	deployed  	switchboard-0.1.0	dev        	Upgrade complete                                                                                                              
```
