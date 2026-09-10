# Task 2 - the container, measured 2026-09-10

Image `switchboard:dev`: 6.58 GB, model /models/parakeet@541d1f99c6b0c3cd0b11a95167540bb8edefd82b.
Host: RTX 4060 8 GB, Docker Desktop on WSL2. Times are from `docker run` (image already on the host).

| run | device | alive | ready | model load | first request | warm request |
|---|---|---:|---:|---:|---:|---:|
| gpu | cuda | 3.5 s | 15.0 s | 3.5 s | 1226 ms | 198 ms |
| cpu | cpu | 2.2 s | 9.5 s | 1.0 s | 639 ms | 545 ms |

Task 1 (no container, warm process): ready at ~22-25 s, warm request ~90-230 ms.
