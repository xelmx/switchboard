# Task 3 - local cluster, measured 2026-09-10

Docker Desktop Kubernetes (v1.36.1, one node `desktop-control-plane`), 2 replicas,
CPU only (fp32). Two replicas rather than three because the host had ~6 GB free
that evening and each pod needs ~3 GB; the manifest declares three.

| check | result |
|---|---:|
| pods ready from apply | 14 s |
| probe clip through the Service | word for word, 1.5 s first call on CPU |
| pod deleted -> replaced and ready | 13 s |
| rolling update duration | 29 s |
| requests during the update | 21 |
| failed requests during the update | **0** |

Loading the 6.6 GB image into the cluster node's own image store took 142 s.
