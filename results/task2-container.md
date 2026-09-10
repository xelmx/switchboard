# Task 2 - the container, measured 2026-09-10

Image `switchboard:dev`: 6.58 GB, model /models/parakeet@541d1f99c6b0c3cd0b11a95167540bb8edefd82b.
Host: RTX 4060 8 GB, Docker Desktop on WSL2. Times are from `docker run` (image already on the host).

| run | device | alive | ready | model load | first request | warm request |
|---|---|---:|---:|---:|---:|---:|
| gpu | cuda | 3.1 s | 13.0 s | 2.6 s | 906 ms | 82 ms |
| cpu | cpu | 2.2 s | 9.4 s | 1.2 s | 558 ms | 515 ms |

Task 1 (no container, warm process): ready at ~22-25 s, warm request ~90-230 ms.
