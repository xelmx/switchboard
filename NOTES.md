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
