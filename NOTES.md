# switchboard — working notes

One entry per task. The first part of each entry is written before the tool is
touched (what it is, why it's here, what goes wrong without it). The **explain-back**
at the end is written by me, in my own words, after the task — a task isn't done
until that exists.

The plan: serve the model dialtone chose (Parakeet-TDT-0.6B) the way a company
would — container, cluster, infrastructure from code, dashboards, scale-to-zero,
canary, load test — first locally, then on Google Cloud, then the same thing on
Azure. One new tool per task. Roughly 5 hours a week, 9–11 weeks.

---

## Task 0 — the toolchain (WSL2 Ubuntu)

**What it is.** WSL2 is a real Linux running inside Windows, sharing the disk and
the network. Docker Desktop already runs on it (the `docker-desktop` distro).
Installing Ubuntu next to it gives a normal Linux shell where the cluster tools
are installed the way their authors intend: `apt`, official package repos, no
Windows installers.

**Why it's here.** Two reasons.

1. Cloud and cluster tooling is Linux-first. `kubectl`, `helm`, `terraform`,
   `gcloud` all have Windows builds, but every tutorial, every CI pipeline and
   every production runbook assumes a Linux shell. Learning the tools in the
   environment they'll actually be used in avoids learning them twice.
2. This PC runs Windows Smart App Control, which blocks any Windows program that
   isn't code-signed — it already blocked part of the Python toolchain during
   dialtone, and `kubectl.exe` and `k6.exe` are known to be unsigned. Linux
   binaries inside WSL aren't Windows programs, so Smart App Control never sees
   them. This sidesteps the whole problem instead of fighting it tool by tool.

**What goes wrong without it.** Either an evening lost to "this program has been
blocked" for each tool in turn, or the temptation to switch Smart App Control off
— which can't be switched back on without reinstalling Windows.

**What gets installed inside Ubuntu.** `git`, `kubectl` (talks to any Kubernetes
cluster), `helm` (packages Kubernetes deployments), `terraform` (builds cloud
infrastructure from files), `gcloud` (Google Cloud's command line). Nothing
cloud-side is created in this task — no account, no project. The 90-day credit
clock starts when the cloud is first needed, in task 5.

**The proof** (commands I run myself, expected output stated first):

```
wsl -l -v                       # Ubuntu listed, VERSION 2, alongside docker-desktop
wsl -d Ubuntu -- docker version # Client and Server both answer: Docker Desktop is reachable from Ubuntu
wsl -d Ubuntu -- kubectl version --client
wsl -d Ubuntu -- helm version
wsl -d Ubuntu -- terraform version
wsl -d Ubuntu -- gcloud version
```

**Explain-back** *(mine, after the task)*:

- 

---

## Task 1 — the service (FastAPI + uvicorn + prometheus-client)

**What it is.** A web service is a program that waits for requests over HTTP
and answers them. FastAPI is the Python framework that turns a function into
an endpoint (`POST /v1/transcribe` → run the model → return JSON); uvicorn is
the server process that actually listens on a port and hands requests to it;
prometheus-client is the small library that keeps counters and timers and
publishes them on `GET /metrics` in the text format every monitoring system
reads.

**Why it's here.** The model so far is a Python function called from a script.
Nothing else can use it — not a phone system, not a load test, not a
dashboard. Wrapping it in a service is what turns "a model" into "a thing that
serves". Everything after this task (container, cluster, scaling, canary) works
on *the service*, never on the model directly.

**What goes wrong without it.** Each caller would have to load 1.2 GB of
weights into its own process; two callers would fight for the one GPU; nobody
could tell whether it's up, how fast it is, or how many requests it dropped.

**The three endpoints that matter, and why there are three:**

- `GET /healthz` — "is the process alive?" Answers immediately, even while the
  weights are still loading. Kubernetes will restart the container if this
  fails.
- `GET /readyz` — "can it take traffic?" False until the model is loaded.
  Kubernetes sends no requests until this is true. A model server needs both,
  because the process is up for ~30 s before it can do anything useful — if
  readiness were treated as liveness, Kubernetes would kill a healthy container
  for being slow to load.
- `GET /metrics` — the numbers: request latency as a histogram (so p95 can be
  computed later, not just an average), requests in flight, queue depth, errors,
  seconds of audio processed, and how long the model took to load.

**One design choice, stated:** a single worker process and one lock around
inference. The GPU is the serialisation point; a second worker would just load
a second copy of the weights into the same 8 GB. Concurrent requests queue, and
the queue depth is a metric — that number is what scaling will key off later.

**Where it runs now:** inside WSL Ubuntu with `uv` (CUDA works on WSL2 through
the Windows driver), pointed at the Parakeet weights on the Windows disk. Tests
run without a GPU and without the real model.

**The proof** — one script, run from inside Ubuntu:

```
wsl -d Ubuntu-24.04 -- bash -lc 'cd /mnt/c/Users/lyle/Projects/xelmx/switchboard && bash scripts/prove-task1.sh'
```

It runs the tests without a GPU, starts the service with the real model, shows
`/healthz` answering at +2 s while `/readyz` is still 503, waits for ready,
posts the probe clip, posts it again warm, and prints the metrics.

**What it measured (2026-09-10, RTX 4060, fp32, weights read from the Windows disk):**

| | |
|---|---|
| alive (`/healthz`) | +2 s |
| ready (`/readyz`) | **25.4 s** — that gap is why there are two probes |
| probe clip | transcribed word for word |
| first request | 1,166 ms (includes GPU warm-up) |
| second request | **90 ms** for 6.6 s of audio — 74× real time |

The 25 s is the number task 2 (container) and task 7 (scale-from-zero) will be
measured against.

**Explain-back** *(mine, after the task)*:

- 

---

## Task 2 — the container (Docker)

**What it is.** A container image is the service, its Python, every library it
needs, *and the model weights*, frozen into one file-system snapshot that runs
identically on this PC, on a colleague's, and on a cloud node. Docker builds
the snapshot from a recipe (`Dockerfile`) and runs it in an isolated process
with its own filesystem. The snapshot is made of **layers** — one per recipe
step — and a layer that hasn't changed is reused, not rebuilt.

**Why it's here.** Kubernetes doesn't run programs; it runs images. Everything
from task 3 on takes an image name and a tag, nothing else. The image is also
the unit of a *release*: "fp32 → fp16" in task 8 is literally two tags.

**What goes wrong without it.** "Works on my machine." A cloud node has no
`uv`, no venv on the Linux disk, no `/mnt/c` with the weights on it. Every one
of those was set up by hand in task 1; the Dockerfile writes them down.

**Three decisions, stated:**

1. **Two stages.** A *builder* stage installs the Python packages (2.5 GB of
   torch and CUDA libraries) and downloads the weights; a *runtime* stage copies
   only the results. Build tools never ship.
2. **Weights baked into the image, pinned to a revision.** The alternative —
   download at start-up — adds a network failure mode at exactly the moment
   scale-from-zero is being demonstrated, and makes "cold start" depend on the
   day's bandwidth. Baked, the cold start is a property of the image and can be
   measured honestly. The cost is a ~7 GB image. That number is the lesson.
3. **One image, two switches.** `DEVICE=cpu|cuda` and `DTYPE=fp32|fp16` are
   environment variables, so the same image serves a CPU-only node (task 3's
   local cluster), a GPU node (task 9), the stable and the canary.

**What "cold start" means from now on:** the time from `docker run` to
`/readyz` returning 200. Task 1 measured the weights loading in ~22 s from a
warm process; the container adds process start, library import and, in the
cloud, pulling the image onto the node. Each layer of that is measured
separately here.

**The proof:**

```
wsl -d Ubuntu-24.04 -- bash -lc 'cd /mnt/c/Users/lyle/Projects/xelmx/switchboard && bash scripts/prove-task2.sh'
```

It builds the image, prints its size, starts it with the GPU and times
alive / ready / first request, transcribes the probe clip, then starts it
again with `DEVICE=cpu` and does the same — the CPU path is what the local
cluster will run in task 3.

**What it measured (2026-09-10, image already on the host — no pull):**

| run | alive | ready | model load | first request | warm request |
|---|---:|---:|---:|---:|---:|
| GPU | 3.1 s | **13.0 s** | **2.6 s** | 906 ms | **82 ms** |
| CPU | 2.2 s | 9.4 s | 1.2 s | 558 ms | 515 ms |

Image: 6.6 GB as Docker reports it; underneath, a 7.5 GB layer of Python +
torch + CUDA libraries, a 2.5 GB layer of weights, 0.2 GB of OS. Full table in
`results/task2-container.md`.

**Two things learned the hard way:**

1. **The 22 seconds in task 1 was never the model.** Inside the container the
   same weights load in 2.6 s. Task 1 read them across the Windows disk mount
   (`/mnt/c`), which is slow; the image keeps them on the Linux disk. Always
   ask *where the bytes are* before blaming the code. The 13 s cold start now
   breaks down as ~3 s process start, ~8 s importing torch, ~2.6 s weights —
   and it is the import, not the weights, that scale-from-zero will pay for.
2. **The first image shipped the one file it was meant to exclude.** `hf
   download REPO a b c` treats `a b c` as *files to fetch*; my `--exclude
   '*.nemo' '*.gguf' …` handed the later patterns to that positional list, so
   the image contained the `.gguf` and no weights. The service refused to
   become ready (`/readyz` 503: "no model_type in config.json") — exactly the
   failure a readiness probe exists to catch. Fix: name the six files
   explicitly, and `grep` the config in the build so a wrong download fails
   the build, not the deploy.

**Explain-back** *(mine, after the task)*:

- 

---
