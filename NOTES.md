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
