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

## Task 3 — a local cluster (Kubernetes, via Docker Desktop)

**What it is.** Kubernetes is a program that runs containers *for* you. You
tell it what you want — "three copies of this image, each needing this much
memory, answering on this port, and here's how to check they're healthy" —
and it makes that true and *keeps* it true: a copy dies, it starts another;
a node fills up, it places the next copy elsewhere; a new image version
arrives, it swaps copies one at a time without dropping requests. Docker
Desktop ships a single-node cluster; it's the same Kubernetes as the cloud,
just one machine.

**Why it's here.** Tasks 4–10 all speak Kubernetes: Helm packages Kubernetes
objects, Terraform builds a Kubernetes cluster, KEDA and Argo Rollouts are
Kubernetes controllers. Learning the four objects below on a laptop, where a
mistake costs nothing, is what makes the cloud tasks about the cloud rather
than about Kubernetes.

**What goes wrong without it.** `docker run` gives you one container that
stays dead when it dies, can't be updated without downtime, and can't be
scaled without a human. That's the gap between "a container" and "a
service someone can rely on".

**The four objects, in plain terms:**

- **Pod** — one running copy of the container (plus its own IP). The unit
  that lives and dies.
- **Deployment** — "I want N pods of this image, updated this way." It owns
  the pods and replaces them. This is where the probes and the resource
  limits are declared.
- **Service** — one stable address in front of the pods, spreading requests
  across whichever are *ready*. Pods come and go; the Service doesn't.
- **Namespace** — a folder, so this project's objects don't mix with others.

**Two declarations that matter for a model server:**

- **Probes.** `livenessProbe` → `/healthz`: fail it and Kubernetes restarts
  the pod. `readinessProbe` → `/readyz`: fail it and the Service simply
  stops sending that pod traffic. A `startupProbe` gives the model time to
  load before liveness starts judging — without it, Kubernetes would kill
  a healthy pod for taking 15 s to become useful. This is task 1's
  liveness/readiness lesson, now enforced by the platform.
- **Resources.** `requests` is what the scheduler reserves; `limits` is
  where the pod gets killed. A pod with 2.5 GB of weights in fp32 needs
  ~3 GB; declare it, or the scheduler packs pods onto a node that can't
  hold them.

**CPU-only, on purpose.** Docker Desktop's Kubernetes doesn't see the GPU
without extra plumbing that isn't worth an evening; the image's `DEVICE=cpu`
switch (task 2) runs the same model at ~13× real time, which is plenty to
prove scheduling, self-healing and rolling updates. GPU-in-Kubernetes first
happens on GKE in task 9, where the platform installs the driver itself.

**The proof:**

```
wsl -d Ubuntu-24.04 -- bash -lc 'cd /mnt/c/Users/lyle/Projects/xelmx/switchboard && bash scripts/prove-task3.sh'
```

It applies the manifests, waits for the pods to become ready, transcribes the
probe clip through the Service, **deletes a pod and watches Kubernetes replace
it**, then performs a **rolling update while requests are flowing** and counts
how many failed. The number to look for is zero.

**What it measured (2026-09-10, 2 replicas, CPU):**

| check | result |
|---|---:|
| pods ready from apply | 14 s |
| pod deleted → replaced and ready | **13 s** |
| rolling update under load | 29 s, 21 requests, **0 failed** |

The events log during the update is the lesson in one screen: the new pod's
startup probe fails with *connection refused*, then with *503* while the
weights load, and only when it turns ready does Kubernetes kill the old pod.
Task 1's readiness endpoint, now enforced by the platform.

**Three things learned the hard way:**

1. **The cluster node has its own image store.** Docker Desktop now runs its
   Kubernetes node as a separate container; an image built with `docker build`
   is not automatically inside it. Pods would sit in `ErrImagePull` forever
   with `imagePullPolicy: IfNotPresent`. Fix for a laptop: `docker save … |
   docker exec -i desktop-control-plane ctr -n k8s.io images import -`
   (142 s for 6.6 GB). This is exactly why the cloud has a *registry* — a
   shared image store every node pulls from — which is task 5's Artifact
   Registry.
2. **`kubectl apply -f dir/` goes alphabetically.** `deployment.yaml` was
   applied before `namespace.yaml` existed and was rejected; the Service (later
   in the alphabet) was created. Renamed to `00-namespace.yaml` and applied
   explicitly first. Helm (task 4) orders objects by kind for exactly this
   reason.
3. **Replicas are a memory decision, not a default.** Each fp32 CPU pod needs
   ~3 GB; a rolling update briefly runs one more. With ~6 GB free on the host
   that evening, three copies didn't fit; two did. `requests`/`limits` in the
   manifest are what make that arithmetic visible before the scheduler
   discovers it.

**Explain-back** *(mine, after the task)*:

- 

---

## Task 4 — packaging (Helm)

**What it is.** Two things wearing one name. First, a template engine: the
YAML from task 3 with every number that changes between a laptop and a cloud
pulled out into `values.yaml`, so one chart renders all of them. Second — and
the part that isn't obvious from tutorials — a **release ledger**. Helm stores
every install and upgrade in the cluster as a numbered revision, so "what is
deployed right now" is a question with an answer, and "put back what was there
before" is one command.

**Why it's here.** Two reasons, and the second is the bigger one.

1. The same service has to run in at least four shapes before this project is
   done: CPU/fp32 on a laptop, CPU on GKE, GPU/fp16 on an L4 node, and again on
   AKS. That's one difference of a dozen values, not four copies of `k8s/`.
2. Everything installed from task 6 onward *is* a Helm chart — Prometheus,
   Grafana, KEDA, Argo Rollouts. Not learning Helm means not being able to read
   what those tasks install.

**What goes wrong without it.** The `k8s/` directory from task 3 has the image
tag, the replica count and `DEVICE=cpu` written into the file. Changing an
environment means editing a tracked file or `sed`-ing it in CI; there is no
record of what is actually running, and no undo. Task 3 also found that
`kubectl apply -f k8s/` applies files *alphabetically*, which is why the
namespace had to be renamed `00-namespace.yaml` — Helm sorts objects by kind
and installs them in dependency order, so that class of bug stops existing.

**The four pieces:**

- **`Chart.yaml`** — the chart's name, its own `version`, and `appVersion`, the
  version of the software inside. Two different numbers on purpose: changing a
  probe timeout bumps the chart, not the app.
- **`values.yaml`** — every switch, with the laptop's answer as the default.
  Anything not in here is a decision the chart has taken away from you.
- **`templates/`** — the task 3 manifests with `{{ }}` where the values go,
  plus `_helpers.tpl` (names and labels computed once) and `NOTES.txt` (what
  Helm prints after an install).
- **the release** — a name plus a namespace. `switchboard` in namespace
  `switchboard` at revision 4 is a different thing from the chart on disk.

**Two details that bite:**

- **Two label sets, not one.** `selectorLabels` (name + instance) is what the
  Deployment matches pods on, and a Deployment's selector is **immutable**. The
  wider `labels` set adds chart version and `managed-by` for humans. Put the
  chart version in the selector and the first upgrade after a version bump is
  rejected by the API server, permanently, until the Deployment is deleted.
- **The namespace is not in the chart.** `--create-namespace` makes it instead.
  A templated `Namespace` object belongs to the release, so `helm uninstall`
  deletes it — and everything else anyone put in it. Tasks 6–8 install other
  charts into this namespace, so it must outlive any one release.

**What Helm adds that `kubectl apply` cannot:**

- `helm test` — the chart ships its own smoke test. Installing is not the same
  as answering; `templates/tests/transcribe.yaml` is a pod that curls
  `/healthz`, `/readyz` and `/metrics` through the Service and fails the
  release if any of them is wrong.
- `helm rollback` — the point of the ledger. The proof upgrades to an image tag
  that does not exist, watches the release fail, and puts it back with one
  command, counting the requests that failed meanwhile.

**`values-fake.yaml` — proving mechanics on a full laptop.** A real pod needs
~3 GB and this machine usually has the work stack running. `FAKE_MODEL=1`
(built in task 1) answers without loading weights, so a pod costs ~200 MB and
three fit anywhere. Rollouts, probes, revisions and rollbacks behave
identically; transcripts don't, so nothing is ever *measured* with it.

**Helm 4 is not Helm 3.** The installed version is v4.3.0, and two flags changed
shape: `--wait` is now a *strategy* (`--wait` alone means `watcher`; omitted
means `hookOnly`, which does **not** wait for pods), and `--dry-run` takes a
string (`client` or `server`) rather than being a boolean. Every Helm 3 tutorial
command that ends in `--wait --timeout 5m0s` still works; `--dry-run` alone no
longer means what it used to.

**The proof:**

```
wsl -d Ubuntu-24.04 -- bash -lc 'cd /mnt/c/Users/lyle/Projects/xelmx/switchboard && bash scripts/prove-task4.sh'
```

Lints and renders the chart with no cluster involved, installs it into a new
namespace in one command, runs the chart's own test, scales by `--set` (a new
revision, not an edited file), then **upgrades to a broken image under load**
and rolls back — counting failed requests. The number to look for is zero: a
release can be completely broken without the service ever going down, because
`maxUnavailable: 0` means the old pods are never taken away until new ones are
ready. It finishes by upgrading to the chart's own defaults — the real
weights, no `-f` at all — and transcribing the probe clip for real.

**What it measured (2026-09-14, `values-fake.yaml` unless noted):**

| check | result |
|---|---:|
| objects rendered from the chart | 3 |
| `helm install --wait` to all replicas ready | 4 s |
| `helm test` (healthz, readyz, metrics) | pass |
| scale by `--set replicaCount` | revision 2 |
| broken upgrade refused | 93 s (the 90 s `--wait` budget) |
| `helm rollback` to the good revision | **0 s** |
| requests during the break **and** the rollback | 302 |
| failed requests | **0** |
| the same chart on its own defaults (real weights) | 13 s to ready |
| what answered | ParakeetForTDT, 1626 ms for 6.6 s of audio |

The rollback taking no measurable time is the finding, not a broken timer.
`maxUnavailable: 0` meant the four good pods were never taken away; the broken
release only ever managed to create one pod that couldn't pull its image. A
rollback therefore had nothing to build — it reverted the Deployment's spec to
a ReplicaSet that was already at full size. The release was broken for 93
seconds and the service never noticed.

**Three things learned the hard way:**

1. **`--wait` is where the safety lives, and Helm 4 changed it.** Without a
   wait strategy, `helm upgrade` returns the moment the API server accepts the
   objects — success, by Helm's account, for a release whose pods will never
   start. The broken upgrade above is only *detected* because `--wait` sat
   there for 90 seconds watching pods that never became ready. In Helm 4
   `--wait` is a strategy, not a boolean, and the default when the flag is
   omitted is `hookOnly`: it waits for hooks and not for your pods.
2. **The preStop window is visible from outside.** A request sent the instant
   `helm upgrade --wait` returned came back from the *old* pod —
   `"class":"FakeModel"` after upgrading to the real weights. Nothing was
   wrong: the old pod was in its 3-second `preStop` sleep and still in the
   Service's endpoints, which is exactly the behaviour that makes a rolling
   update lossless. "The upgrade is done" and "every reply now comes from the
   new version" are two different moments, and anything that checks a
   deployment by curling it once has to know that.
3. **The node's image store survived, and that is also a trap.** Docker
   Desktop's Kubernetes wedged in `starting` for half an hour; a restart fixed
   it, and `switchboard:dev` was still in the node from task 3, so the 6.6 GB
   import didn't repeat. Convenient here, misleading in general: an image that
   is present *because of something you did a week ago* is the exact state a
   registry exists to remove. Task 5 replaces it.

**Explain-back** *(mine, after the task)*:

- 

---

## Task 5 — the cloud, from code (Terraform + GKE Autopilot)

**What it is.** Terraform is a file that describes infrastructure and a command
that makes reality match it. `apply` creates what's missing, `destroy` removes
what it created, and the difference between the file and the world is something
you can read before agreeing to it. GKE Autopilot is Google's Kubernetes with
the machines taken away: you declare pods with CPU and memory requests, and
nodes appear and disappear underneath to fit them.

**Why it's here.** Three reasons, and the third is the one that matters for a
project paid for out of a trial credit.

1. Everything from here on lives in the cloud, and the cloud is where "I
   clicked something in a console six weeks ago" becomes unrecoverable.
2. Task 3's first finding was that the cluster node had its own image store and
   the image had to be hand-imported with `ctr`. A **registry** is the real
   answer, and a registry is a thing that has to be created.
3. **`terraform destroy` is the feature.** A cluster left running overnight
   costs money whether or not anyone learns anything from it. Being able to
   take the whole thing down in one command, and put it back in one command, is
   what makes it affordable to work on this for five hours a week.

**What goes wrong without it.** Console clicking produces infrastructure nobody
can review, reproduce, or fully find again. The load balancer that survives a
deleted cluster and bills quietly for months is the canonical version of this,
and it is exactly the trap `scripts/destroy-task5.sh` is ordered to avoid.

**What Terraform manages here — and what it deliberately doesn't:**

- **Managed:** the four APIs the project needs switched on, the Artifact
  Registry repository, and the Autopilot cluster. Three files, `apis.tf`,
  `registry.tf`, `cluster.tf`.
- **Not managed:** the Google account, the billing account, and the project
  itself. Creating projects needs organisation-level permissions a personal
  trial account doesn't cleanly have, and — more importantly — putting the
  project inside the same state file means `terraform destroy` can delete the
  thing the state is about. The project is an input; Terraform owns what's in
  it.
- **State is a local file.** A team keeps it in a GCS bucket so two people
  can't apply at once. That bucket has to exist before Terraform runs, which is
  the bootstrap problem every project meets once. For one person on one laptop,
  local state is the honest answer.

**Autopilot, not Standard.** Task 3's manifests already declare what a pod
needs; that is the only input Autopilot wants. There is no node pool to size,
no autoscaler to tune, and no idle node still running at midnight because
nobody drained it. Two rules that come with it, both from Google's own docs:

- **The bill follows `requests`, not `limits`.** On a cluster that supports
  bursting a pod may use up to its limits while being billed for its requests;
  on one that doesn't, Autopilot sets the limits down to the requests. Either
  way requests are the number that costs money, which is why
  `values-gke.yaml` sets requests and limits equal — Google's recommendation,
  and it stops the pod's behaviour depending on a cluster feature you didn't
  choose.
- **CPU:memory must sit between 1:1 and 1:6.5** for the general-purpose
  compute class. 2 vCPU to 4 GiB is 1:2.

**Building the image in the cloud, not pushing it there.** The image is ~17 GB
unpacked, ~6.6 GB compressed. Pushing that from a home connection in Manila is
an afternoon. But task 2's Dockerfile *downloads* the weights during the build
rather than copying them from disk — so Cloud Build can do the whole thing
inside Google's network, pulling from HuggingFace at Google's speed and pushing
into a registry in the same region. What leaves this house is the source in
`.dockerignore`'s allowlist: a few hundred kilobytes. Two things had to be set
for that to work at all:

- **`timeout: 3600s`.** Cloud Build's default is ten minutes. Installing torch
  and downloading 2.5 GB of weights is not a ten-minute job, and this is the
  most common reason a first cloud build of a model image fails.
- **`DOCKER_BUILDKIT=1`.** The Dockerfile opens with a `# syntax=` directive
  and uses `--mount=type=cache`. The classic builder ignores the first and
  fails on the second.

`.dockerignore` also grew `terraform` — without it, `terraform.tfstate` would
be uploaded into Cloud Build's source bucket, and state files hold more than
you think.

**Two switches that exist because of how they fail:**

- **`deletion_protection = false` on the cluster.** The provider defaults it to
  true and `terraform destroy` is then refused with an error that reads like a
  bug in Terraform. This project is built to be torn down; the flag is off
  deliberately, not by accident.
- **Uninstall the Helm release *before* destroying the cluster.** The Service
  of type `LoadBalancer` owns a Google forwarding rule that Terraform never
  created and has no idea exists. Destroy the cluster first and that load
  balancer is orphaned: still billing, invisible to `terraform destroy`,
  findable only by going looking. `scripts/destroy-task5.sh` does it in the
  order that avoids this, and prints the three `gcloud ... list` commands that
  prove nothing is left.

**One permission you would otherwise meet as a failure.** Cloud Build runs as
the project's *Compute Engine* default service account, which in a new project
can do nothing useful. `terraform/build_iam.tf` grants it
`roles/cloudbuild.builds.builder` — Google's bundle of the storage, Artifact
Registry and logging permissions a build needs. Without it the first
`gcloud builds submit` fails on a service account nobody created, which is a
hard error to place.

**What it costs (checked 2026-09-14).** A flat cluster management fee of
**$0.10 per cluster per hour**, and a GKE free tier of **$74.40 of monthly
credit per billing account** — enough for exactly one Autopilot cluster's
management fee, and it covers *only* the management fee. Pods are billed on
their requests, and the external load balancer is billed per hour plus traffic.
The 90-day trial credit clock that task 0 mentioned starts the moment the first
`apply` runs.

**Sessions, not a standing cluster.** The cluster is switchable:
`cluster_enabled = false` removes it with an `apply` and leaves the registry and
its 17 GB image alone, so the next session doesn't pay for another Cloud Build.
`scripts/destroy-task5.sh` does exactly that after uninstalling the release;
`ALL=1` destroys everything. `scripts/cloud-check.sh` lists every resource type
this project can leave billing by the hour and exits non-zero if any exist —
a session isn't over until it prints `NOTHING RUNNING`. On the trial, GKE runs
one replica: half the bill, and well inside a CPU quota the trial won't raise.

**The trial's rules (Google's docs, checked 2026-09-17).** The card on file is
not charged during the trial; a verification hold of up to $1 is released.
When the credit or the 90 days run out, resources are stopped and later deleted
— nothing is charged unless the account is manually upgraded. GPUs are not
allowed, which moves task 9 onto the local RTX 4060.

**The proof:**

```
wsl -d Ubuntu-24.04 -- bash -lc 'cd /mnt/c/Users/lyle/Projects/xelmx/switchboard && CONFIRM=yes bash scripts/prove-task5.sh'
```

It refuses to run without `CONFIRM=yes`, because unlike every task before it
this one spends money. It applies the Terraform, builds the image in Cloud
Build, points `kubectl` at the cluster, installs **the same chart from task 4**
with `values-gke.yaml`, waits for a real external address, runs the chart's own
test against the cloud, and transcribes the probe clip over the public
internet. Then it tells you, loudly, what is still running.

**What it measured (2026-09-17, `asia-southeast1`, one replica, CPU):**

| check | result |
|---|---:|
| `terraform apply` — APIs, registry, cluster, IAM from an empty project | 431 s |
| image built in Cloud Build (none of the 6.6 GB crossed the home link) | 1052 s |
| nodes declared anywhere in the repo | 0 |
| what Autopilot provisioned for the pod | one `ek-standard-8` node |
| `helm install --wait` to ready, incl. node + image pull | 217 s |
| `helm test` against the cloud release | pass |
| transcript of the probe clip over the public internet | correct, word for word |
| inference, 6.6 s of audio, 2 vCPU fp32 | 3483 ms |
| end of session: release out, cluster off | 4 m 45 s for the cluster |
| `cloud-check.sh` afterwards | **NOTHING RUNNING**; registry kept (6.1 GB) |

3.5 s here against 1.6 s on the laptop is not the cloud being slow: the laptop
pod could burst to four cores, this one is held to the two it pays for. It is
the requests-equal-limits decision, visible in a number.

**Five things learned the hard way:**

1. **A new organisation is locked down by default, and it lands on GKE.**
   `iam.automaticIamGrantsForDefaultServiceAccounts` is enforced, so the
   Compute default service account — the identity Autopilot nodes run as —
   has no roles at all. Found by reading the effective policies *before* the
   first apply; without `roles/artifactregistry.reader` the pod would have sat
   in `ImagePullBackOff` with a 403 and no mention of IAM. `build_iam.tf`
   grants it and `roles/container.defaultNodeServiceAccount`.
2. **A budget on a trial account measures the wrong thing by default.** Budgets
   compare against cost *after* credits, which on a trial is always $0 — the
   alert would never fire. `--credit-types-treatment=exclude-all-credits` makes
   it watch real usage.
3. **Consent is per-scope now.** `gcloud auth application-default login` failed
   the first time with "cloud-platform scope is required but not consented":
   Google's consent page lists permissions as checkboxes, and the one Terraform
   needs was left unticked.
4. **Autopilot edits your pods.** It added a 1 GiB `ephemeral-storage` request
   to the service and invented CPU for the `helm test` pod, with a warning. A
   platform that bills by request has to make sure every pod has one; the test
   pod now declares its own rather than having one made up for it.
5. **The machine was Google's choice, and a big one.** An `ek-standard-8` for a
   2-vCPU pod looks wasteful, but Autopilot bills the pod's requests, not the
   node — the node size is Google's packing problem, not a line on the bill.


**Explain-back** *(mine, after the task)*:

- 

---

## Task 6 — seeing it (Prometheus + Grafana)

**What it is.** Prometheus is a database of numbers over time that fetches
them itself: every 15 seconds it asks each target for `/metrics` and stores
what it gets. It then evaluates rules against that history — "p95 latency above
4 s for a minute" — and hands anything that trips to **Alertmanager**, whose job
is deciding who hears about it. **Grafana** draws the history. The
**Prometheus Operator** is what makes all of this Kubernetes-shaped: instead of
editing `prometheus.yml`, you create `ServiceMonitor` and `PrometheusRule`
objects, and the operator writes the configuration.
`kube-prometheus-stack` installs the whole set in one Helm release, plus
kube-state-metrics (what Kubernetes believes: replicas, restarts, requests) and
node-exporter (what the machine believes: CPU, memory).

**Why it's here.** Task 1 made the service *report* on itself — a latency
histogram, queue depth, a readiness gauge. Nobody was reading it. Task 7 scales
on one of those numbers and task 8 decides whether a new model version is safe
by comparing them; both are built on Prometheus. And a load test (task 9) is
only a table of numbers until something recorded what the service was doing
while it ran.

**What goes wrong without it.** You find out the service is slow from the
people using it. And "slow" can't be fixed without knowing *where* the time
went: in the model, or waiting in line for it. Those two have opposite fixes —
a faster model, or more copies of the same one — and only the histograms tell
them apart.

**The service's monitoring ships with the service.** Three templates, off by
default so the chart still installs on a bare cluster
(`values-monitoring.yaml` turns them on):

- **`servicemonitor.yaml`** — "scrape `/metrics` on every pod behind this
  Service." Replicas come and go and are picked up without anyone touching
  Prometheus.
- **`prometheusrule.yaml`** — five recording rules (p50/p95/p99, request rate
  by outcome, real-time factor) and five alerts: `SwitchboardDown`,
  `SwitchboardNoReadyReplicas`, `SwitchboardSlow`, `SwitchboardBacklog`,
  `SwitchboardErrors`. Thresholds are chart values.
- **`dashboard.yaml`** — the Grafana dashboard as a ConfigMap labelled
  `grafana_dashboard: "1"`; Grafana's sidecar loads it. The dashboard is in git,
  versioned with the code it describes, not trapped in a Grafana database.

**Three decisions in the numbers:**

- **Percentiles from buckets summed across pods.** `histogram_quantile` over
  `sum by (le)`, never an average of per-pod percentiles — that would weight an
  idle pod the same as a busy one, and percentiles don't average anyway.
- **"Where the time goes" is the panel that matters.** End-to-end p95 next to
  inference p95 and queue-wait p95. Inference flat while waiting climbs means
  the model is fine and there aren't enough copies of it. That is task 7's
  signal, and `switchboard_queue_depth` is the number it will scale on.
- **Real-time factor** — model seconds per second of audio — is the one number
  that compares a CPU pod, a GPU pod and dialtone's bench on the same scale.

**One setting that silently breaks everything.** By default the operator only
reads ServiceMonitors and rules that carry *its own release's* labels. The
switchboard chart is a different release, so without
`serviceMonitorSelectorNilUsesHelmValues: false` (and the three siblings for
pods, probes and rules) Prometheus ignores it completely — no error, just no
target. It is the most common "why is my service missing" of this stack.

**Where to look.** Grafana is at **http://localhost:3000/d/switchboard** for as
long as the local cluster runs (anonymous view; `admin` / `switchboard` to
edit). Explore runs ad-hoc Prometheus queries; Alerting lists the rules.

**Laptop trimming.** Docker Desktop runs its control plane inside one container
and doesn't expose etcd, the scheduler, the controller manager or kube-proxy to
scraping. Left on, the stack shows four permanently-down targets and fires
alerts about a control plane that is fine; they're switched off in
`monitoring/kube-prometheus-stack.local.yaml`, which also caps every component's
memory. Grafana allows anonymous viewing — local only.

**The proof:**

```
wsl -d Ubuntu-24.04 -- bash -lc 'cd /mnt/c/Users/lyle/Projects/xelmx/switchboard && bash scripts/prove-task6.sh'
```

Free: local cluster only, and it pins `kubectl` to `docker-desktop` first,
because after task 5 the current context was still a GKE cluster. It installs
the stack, installs switchboard with the real weights and monitoring switched
on, checks Prometheus found the service **without any Prometheus configuration
being edited**, then runs a quiet baseline (one caller) and a deliberate
overload (four callers against one replica). The overload should make
`SwitchboardSlow` and `SwitchboardBacklog` fire and reach Alertmanager; removing
it should make them resolve on their own.

**What it measured (2026-09-17, real weights, 1 replica, CPU fp32, 4-core limit):**

| check | result |
|---|---:|
| monitoring stack ready (images already cached; 127 s the first time) | 25 s |
| switchboard found and scraped — no Prometheus config touched | up after 75 s |
| recording + alerting rules loaded from the chart | 10 |
| dashboard provisioned from the chart | yes |

| | baseline, 1 caller | overload, 4 callers |
|---|---:|---:|
| requests / s | 0.80 | **0.75** |
| p95 end to end | 1.60 s | **10.17 s** |
| p95 inference / p95 waiting for the model | — | 4.13 s / 5.00 s |
| most requests queued | 0 | 3 |
| real-time factor | 0.185 | — |
| pod CPU (limit 4) | — | 3.97 cores |

| alerting | result |
|---|---:|
| fired under overload | `SwitchboardBacklog`, `SwitchboardSlow` |
| first alert after the overload began | 81 s |
| reached Alertmanager | both |
| all cleared after the load stopped | 81 s |

**The row that matters is requests per second.** Four times the callers bought
*no* extra throughput — 0.80 became 0.75 — and p95 went from 1.6 s to 10.2 s.
One replica holding one model lock can only do one thing at a time; the extra
callers just stand in line. The dashboard says it in one panel: waiting-for-
the-model climbs while throughput stays flat. That is the case for task 7, in
the service's own numbers.

**Inference also got slower (1.6 → 4.1 s at p95),** which the lock alone
doesn't explain. The pod sat at 3.97 of its 4 cores: the queued requests'
uploads and audio decoding compete for the same CPU as the model. More copies
would fix that too; a bigger single copy would not fix the queue.

**Four things learned the hard way:**

1. **`helm --wait` finished before Prometheus existed.** The chart creates a
   `Prometheus` *object*; the operator creates its pod afterwards, when Helm has
   already declared success. The first run opened a port-forward to a pod that
   wasn't there yet — port-forward exits immediately when that happens — and
   then waited five minutes for a target it could never see. The script now
   waits for the operator's pods by label. Anything installed through an
   operator has this gap.
2. **A percentile is only as precise as its buckets.** "waiting p95 = 5.00 s" is
   not a measurement of five seconds — 5 is a bucket boundary, and
   `histogram_quantile` interpolates linearly inside a bucket. The overload's
   10.17 s sits somewhere in the 8–13 s bucket. Good enough to alert on; not good
   enough to quote to a decimal. Task 9's load test measures latency on the
   client side, where each request is timed exactly.
3. **`ctr images ls | grep -q` under `pipefail` fails at random.** grep exits at
   its first match, `ctr` is killed by SIGPIPE mid-listing, and pipefail
   reports the whole check as failed. The image was there; the check said it
   wasn't. Captured into a variable first, in tasks 4 and 6.
4. **Only one LoadBalancer can own a port.** Prometheus and Alertmanager
   Services both carry a config-reloader port 8080, so on Docker Desktop only
   Grafana gets a stable `localhost:3000`; the other two are port-forwarded
   by the script when needed.


**Explain-back** *(mine, after the task)*:

- 

---

## Task 7 — scaling (KEDA)

**What it is.** Kubernetes already has an autoscaler, the
HorizontalPodAutoscaler, but out of the box it only knows CPU and memory. KEDA
("Kubernetes Event-Driven Autoscaling") feeds it anything else — a Prometheus
query, a queue length, a schedule — and adds the one thing the HPA can't do:
go to **zero** replicas and come back. You write a `ScaledObject`; KEDA writes
and drives the HPA.

**Why it's here.** Task 6 measured the problem: four callers against one
replica gave *no* more throughput than one caller, only a queue — p95 went from
1.6 s to 10.2 s. The fix is more copies, but only while there is demand. A model
server that holds 3 GB of RAM (or a whole GPU) around the clock for traffic that
arrives in bursts is the most expensive way to run one.

**What goes wrong without it.** You size for the peak and pay for it all night,
or size for the average and queue at the peak. CPU-based autoscaling is the
usual first attempt and it is the wrong signal here: a pod waiting on its model
lock is busy by any user's definition while its CPU tells you very little
(and on a GPU pod, CPU says nothing at all).

**The signal: demand, in the service's own words.** The average number of
requests inside the service — running or queued — over the last minute,
computed from the request-time counter (see the first lesson below for why
not from the in-flight gauge). One
replica serves one request at a time (the model lock), so the target is **one
request in flight per replica**: four concurrent callers ask for four replicas.

**A fake that behaves like the model.** Four real replicas need ~12 GB this
machine doesn't have. `FAKE_RTF` (new in image `0.2`) makes the fake model hold
the inference lock for as long as the real one would — 0.185 s per second of
audio, the real-time factor measured in task 6 — so queueing and scaling behave
the same at ~150 MB a pod. What it can't reproduce is the real cold start
(weights into memory), which task 9 measures on the GPU.

**Two modes, one switch** (`autoscaling.mode`):

- **`prometheus`** — a KEDA `ScaledObject` with a Prometheus trigger, 1..4
  replicas. Stable KEDA 2.20.2. The production answer.
- **`http`** — a `HTTPScaledObject` from the KEDA **HTTP add-on** (0.16.0,
  released two days before this task and labelled *alpha, not for production*
  in its own README), 0..4 replicas. The add-on generates its own ScaledObject,
  so the two modes can't be on together.

**Why scale-to-zero needs a second tool.** The Prometheus trigger reads a
number that the *pods* report. At zero pods there is no number, and a request
sent to a Service with no endpoints is refused on the spot — it never queues
anywhere, so nothing ever registers as demand. A Prometheus-triggered service
allowed to reach zero stays there. The HTTP add-on fixes this by putting a
proxy (the *interceptor*) in front: it exists when the service doesn't, counts
requests itself, holds them while KEDA starts a pod, then forwards them. The
proof demonstrates the trap first, then the fix.

**One template change that matters.** With autoscaling on, the Deployment no
longer sets `replicas`. If it did, every `helm upgrade` would reset the count
to `replicaCount` and fight the autoscaler — a classic source of "why did my
pods just drop to two".

**The proof:**

```
wsl -d Ubuntu-24.04 -- bash -lc 'cd /mnt/c/Users/lyle/Projects/xelmx/switchboard && bash scripts/prove-task7.sh'
```

Free, local. Latency is timed by the client, per request — not read back from
histogram buckets (task 6's lesson).

**What it measured (2026-09-17, fake pods at the real model's timing, 4 callers):**

| prometheus mode, 1..4 replicas | result |
|---|---:|
| load start → 4 ready replicas | 71 s (1 → 2 → 3 → 4 as demand rose) |
| demand signal once scaled | 3.9 – 4.2 (four callers) |
| client p95, first 30 s on one replica | 4.96 s |
| client p95, after scaling | 3.69 s |
| requests / failed | 449 / **0** |
| deepest queue per pod while scaled | 1, 1, 2, 2 |
| load stopped → back to 1 replica | 105 s |

| the trap: same trigger, minReplicas 0 | result |
|---|---:|
| idle → 0 replicas | 20 s |
| a request at zero | HTTP 000 — refused, not queued |
| replicas after 90 s of requests | **0** |

| http mode (add-on, alpha), 0..4 replicas | result |
|---|---:|
| request with zero pods running | **200 in 6.06 s** |
| the next request, warm | 200 in 1.25 s |
| peak replicas under 4 callers / failed | 4 / 0 |
| client p95 while scaled | 3.67 s |
| load stopped → back to 0 | 68 s |

**Four replicas for four callers still queues.** One request takes 1.2 s, yet
p95 with four replicas was 3.7 s — three requests' worth. The Service picks a
pod *at random* for each connection, so two callers regularly land on the same
pod while another sits idle: the deepest queue per pod was 2 on half of them.
Scaling to the number of callers is necessary, not sufficient. The fixes are a
little headroom (target below 1 per replica) or smarter routing
(least-requests, which a mesh or Gateway API can do and kube-proxy cannot).

**Cold start from zero cost ~4.8 s** on top of a warm request — for a fake pod
that loads nothing. A real Parakeet pod adds its weight load on top, and on
GKE a new node and a 6.6 GB image pull (217 s in task 5). Scale-to-zero is a
cost decision paid for in first-request latency; for a phone line, where the
caller is already waiting, it probably belongs only on internal or batch
traffic.

**Five things learned the hard way:**

1. **Summing a gauge across pods is not a snapshot.** The first version scaled
   on `sum(max_over_time(switchboard_in_flight[1m]))` and read **7–9** for four
   callers. Prometheus scrapes each pod at a different moment; a caller that
   moved from pod A to pod B between the two scrapes is counted on both. Tested
   against a single pod the gauge was exact (never above 2 for 2 callers), and
   the server's request counter matched the client's to the request (483.8 vs
   483) — so nothing was duplicated; the *sampling* was. The fix reads a
   counter instead: `sum(rate(switchboard_request_seconds_sum[1m]))` —
   request-seconds accumulated per second *is* the average concurrency
   (Little's law) — and read 3.9–4.2.
2. **The correct signal is slower.** With the over-counting query the service
   reached four replicas in 20 s; with the correct one, 71 s. A rate over a
   minute of *completed* requests only notices a queue once requests have
   waited in it. The wrong query scaled faster precisely because it was wrong.
   Faster honest options: a shorter window, or scaling on queue depth.
3. **A Grafana memory limit took the control plane down.** With 512 Mi, Grafana
   13 — which runs each of its thirteen built-in data sources as a separate
   process — sat at its limit and was never OOM-killed. It thrashed instead:
   2.1 million limit hits and 98 million re-reads of its own files, disk
   pressure at 77 % "full", node load 37, etcd timing out, the API server
   killed by its liveness probe, the scheduler in CrashLoopBackOff. Fixed with
   a 1 Gi limit and `disable_plugins` for the twelve unused data sources: one
   plugin process, 402 Mi, zero limit hits. A limit slightly too low is worse
   than one far too low — the second fails loudly.
4. **`kubectl -o jsonpath` prints a missing field as nothing — no newline.**
   `sed 's/^$/0/'` then has no line to act on, "0 replicas" read as blank, and
   the wait for zero timed out while the cluster sat at zero. Defaulted in the
   shell.
5. **An autoscaled Deployment must not set `replicas`,** or every `helm
   upgrade` resets the count; and switching KEDA modes needs the add-on's own
   ScaledObject gone first, because Helm won't adopt an object it didn't
   create.


**Explain-back** *(mine, after the task)*:

- 

---

## Task 8 — canary (Argo Rollouts)

**What it is.** A Deployment replaces old pods with new ones as fast as the new
ones pass their readiness probe — and a readiness probe only asks "is it up?",
not "is it any good?". Argo Rollouts replaces the *how*: a new version first
gets a small share of the traffic (the **canary**), stays there for a while,
is **measured against the version it would replace**, and is either promoted
step by step or thrown out automatically. The measuring is an
`AnalysisTemplate`: queries Argo runs against Prometheus on a schedule, each
with a success condition.

**Why it's here.** This project exists because of one question: *is this model
good enough on phone calls?* dialtone answered it offline. A canary answers the
production half — *is the new version at least as good as the old one, on real
traffic, right now?* — and stops a bad answer from reaching everybody. Tasks
6 and 7 supplied the ingredients: the metrics, and the knowledge of which ones
move when something is wrong.

**What goes wrong without it.** Task 4 proved a rolling update can replace every
pod without dropping a request. It will replace every pod with a *worse* model
just as smoothly. A model that got three times slower — a dtype mistake, a CPU
fallback, a bigger checkpoint — passes every readiness probe there is.

**How it's wired.**

- **`workloadRef`, not a rewritten Deployment.** The Rollout points at the
  chart's existing Deployment, which stays the single description of the pod;
  the Rollout only adds the strategy. Once the first rollout is healthy, Argo
  scales the Deployment itself to zero. A `helm upgrade` still changes the
  Deployment — and Argo reacts to that.
- **No service mesh, so traffic follows pod counts.** With four replicas, the
  first step is one canary pod next to four stable ones: about a fifth of the
  requests. A mesh (or Gateway API) could split by percentage exactly; this is
  the honest version without one.
- **Canary and stable told apart by a label.** Argo stamps every pod with its
  ReplicaSet's `rollouts-pod-template-hash`; the ServiceMonitor now copies that
  onto every series (`podTargetLabels`), and the analysis is passed the two
  hashes as arguments.
- **The judgement is relative.** Canary p95 *model time* divided by stable p95
  model time, over the same minute on the same machine, must stay at or below
  1.5 — plus zero canary errors. Relative, because a busy laptop slows both
  versions and only a worse *version* moves the ratio. Model time rather than
  end to end, because task 7 showed end-to-end latency depends on which pod the
  Service happened to pick, and that is not the new version's fault.
- **Autoscaling is off in this mode.** KEDA can scale a Rollout, but two
  controllers deciding pod counts while a third splits traffic by pod count is
  a lesson for another day; the chart refuses the combination.

**The dashboard.** Argo's own UI shows each rollout, its steps, its analysis
runs and every measurement: **http://localhost:3100/rollouts/switchboard**
(read-only; promote and abort stay on the command line,
`kubectl argo rollouts ...`).

**The proof:**

```
wsl -d Ubuntu-24.04 -- bash -lc 'cd /mnt/c/Users/lyle/Projects/xelmx/switchboard && bash scripts/prove-task8.sh'
```

Free, local. Four fake pods with the real model's timing. It rolls out a good
new version under load, then a bad one — the same pods with `FAKE_RTF` raised
from 0.185 to 0.6, a model that got about three times slower — and records
what Argo did with each, how many requests failed, and what Helm believed
meanwhile.

**What it measured (2026-09-17, 4 fake pods at the real model's timing, 4 callers):**

| | good version (v2) | bad version (v3, model ~3× slower) |
|---|---:|---:|
| what Argo did | promoted through 25 % → 50 % → 100 % | **aborted at the first step** |
| time from `helm upgrade` | 169 s | 94 s |
| canary p95 model time ÷ stable's | 1.0 | **3.32** (limit 1.5) |
| canary errors | 0 | 0 |
| requests during the rollout / failed | 382 / 0 | 177 / **0** |
| pods afterwards | 4 × v2 | 4 × v2 |
| Helm's status for the release | deployed | **deployed** |
| `helm rollback` to v2 | — | healthy in 0 s |

The bad version reached one pod out of five — about a fifth of the traffic —
for about a minute and a half, and never a failed request: it was slow, not
broken. The first judgement came at 60 s, the second failure at 90 s, and
`failureLimit: 1` means the second one aborts. The measured ratio, 3.32, is
close to the real one (0.6 ÷ 0.185 = 3.24); the good version's exact 1.0 is
both p95s falling in the same histogram bucket (task 6's lesson again — fine
for a 1.5× threshold, useless for a 1.05× one).

**The finding: after an abort, Helm and the cluster disagree.** Helm recorded
revision 3 — the slow model — as `deployed`. The cluster was running v2
everywhere, with the Rollout marked `Degraded`. Anything that trusts Helm's
status — a CI job, a dashboard, the next engineer — would believe the slow
model shipped. And the next `helm upgrade` would carry the bad settings
forward. `helm rollback` closes the gap: Helm goes back to v2's values, the
Deployment's pod template matches the stable ReplicaSet again, and Argo clears
the abort without creating a single pod — "healthy in 0 s". An automated
abort is not finished until the source of truth has been rolled back too; in a
GitOps setup that means a revert commit, which is why Argo is usually paired
with Argo CD.

**Two things learned the hard way:**

1. **With `workloadRef`, `helm upgrade` changes the Deployment, not the
   Rollout** — so for a moment after the upgrade the Rollout still reports
   `Healthy`, for the version it is about to replace. A script that waits for
   "Healthy" returns immediately. The proof first waits for Argo's
   `currentPodHash` to differ from the stable one.
2. **After an abort the Rollout *starts* `Degraded`,** so "wait until Healthy
   or Degraded" ends at once after `helm rollback`. That wait has to be for
   Healthy only.


**Explain-back** *(mine, after the task)*:

- 

---
