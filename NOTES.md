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

**What it measured:** *pending — needs a Google account and
`gcloud auth login`; nothing cloud-side exists yet.*

**Explain-back** *(mine, after the task)*:

- 

---
