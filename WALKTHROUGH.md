# switchboard — a walkthrough for a new user

This page takes you from nothing running to the whole platform up, checked, and
understood, in about fifteen minutes. Everything here is **local and free**.
The one part that costs money, Google Cloud, is at the end and clearly marked.

`NOTES.md` explains *why* each piece exists. This page is *how to use it*.

---

## What you are about to run

One speech-to-text model (Parakeet, the one dialtone chose) served the way a
company would serve it:

| piece | what it does, in one line | where you see it |
|---|---|---|
| **switchboard** | the service: send audio, get text back | http://localhost:8000/docs |
| **Kubernetes** | keeps copies of the service running and replaces dead ones | `kubectl get pods -A` |
| **Helm** | installs everything from one recipe, with an undo | `helm list -A` |
| **Prometheus** | records the service's numbers every 15 seconds | (behind Grafana) |
| **Grafana** | shows those numbers as a dashboard | http://localhost:3000/d/switchboard |
| **Alertmanager** | receives alerts when numbers go bad | (behind Grafana: Alerting) |
| **KEDA** | adds copies when requests queue up, removes them when quiet | `kubectl -n switchboard get hpa` |
| **Argo Rollouts** | tries a new version on a few requests first; pulls it back if worse | http://localhost:3100/rollouts |

Locally the service runs a **fake model** by default. It answers
`"fake transcript of 6.6 seconds"`, but it takes exactly as long as the real
model would, so queues, scaling and alerts behave the same while using about
150 MB instead of 3 GB. Use `REAL=1` (below) for real transcripts.

---

## 0. What you need (once)

- **Docker Desktop** running, with **Kubernetes enabled** (Settings → Kubernetes).
  Wait until its Kubernetes icon is green.
- The **WSL Ubuntu** terminal. All commands below run there, from the repo:

  ```
  cd /mnt/c/Users/lyle/Projects/xelmx/switchboard
  ```

- The service image, `switchboard:0.2`. It's already built on this machine. On a
  fresh machine: `docker build -t switchboard:0.2 .` (about 20 minutes the first
  time).

---

## 1. Start everything

```
bash scripts/up-local.sh
```

About 3–5 minutes the first time, under a minute after that. It installs, in
order: monitoring → KEDA → Argo Rollouts → switchboard, and prints three links
when it's done. It's safe to run again at any time.

Want real transcripts? `REAL=1 bash scripts/up-local.sh`. That needs about 4 GB
of free memory and allows at most 2 copies.

---

## 2. Check everything

```
bash scripts/check-platform.sh
```

About a minute. It changes nothing. Every line should say **PASS**, and the last
line should say `24 passed, 0 failed`:

```
The cluster                        is Kubernetes up?
Installed tools                    is each tool installed, and are all its pods ready?
The service                        alive? model loaded? a real transcription? the chart's own test?
Monitoring                         is Prometheus reading the service? rules loaded? any alerts? dashboard there?
Scaling / delivery                 is the autoscaler (or the canary controller) healthy?
Google Cloud                       is anything left running that costs money?
```

A **FAIL** line tells you what's wrong and where to look. The usual one right
after starting is *"Prometheus scrapes switchboard"*: new pods take about a
minute to be picked up. Wait, then run the check again.

---

## 3. Look around

**Send some audio yourself**

- In a browser: open **http://localhost:8000/docs**, then `POST /v1/transcribe`
  → *Try it out* → choose any WAV file → *Execute*.
- From the terminal:

  ```
  curl -F file=@loadtest/probe/1089-134686-0002.wav http://localhost:8000/v1/transcribe
  ```

**The dashboard**: http://localhost:3000/d/switchboard. No login needed to view.
The top row is what to check every time:

| panel | healthy | worry when |
|---|---|---|
| Ready replicas | 1 or more (green) | **0** means the service is down |
| p95 latency | green | red, above 4 s: callers are waiting |
| Queued for the model | 0 | above 0 for more than a minute: not enough copies |
| Alerts firing | 0 | anything else |

Then the panel **"Where the time goes"**:

- *Waiting* rises while *inference* stays flat → the model is fine; there
  aren't enough copies (KEDA should be adding them).
- *Inference* itself rises → the model or the machine got slower (a bad
  version, a busy CPU).

**Argo Rollouts**: http://localhost:3100/rollouts. It's empty until you run a
canary (step 5).

---

## 4. Make it busy, and watch it react

Open two terminals.

**Terminal 1**: watch the number of copies:

```
kubectl -n switchboard get hpa -w
```

**Terminal 2**: four callers, sending audio non-stop:

```
for i in 1 2 3 4; do (while true; do curl -s -o /dev/null -F file=@loadtest/probe/1089-134686-0002.wav http://localhost:8000/v1/transcribe; done) & done
```

What should happen:

- **Within about a minute**, *Queued for the model* goes above 0 on the
  dashboard and p95 turns orange or red.
- **Within 1–2 minutes**, terminal 1 shows `REPLICAS` climbing to 4 and the
  queue drains.
- **About a minute into the overload**, the alerts `SwitchboardBacklog` /
  `SwitchboardSlow` may fire (Grafana → Alerting). They clear once the copies
  catch up.

Stop the callers in terminal 2:

```
kill $(jobs -p)
```

About two minutes later the copies go back down to 1, one at a time.

---

## 5. The full proofs (the "deep" end-to-end tests)

Each task has a script that proves its part with numbers and writes them to
`results/`. They are longer than the health check, and several of them
**reinstall** parts of the platform. Run `scripts/up-local.sh` again afterwards
to get back to the standard setup.

| script | proves | time | cost | notes |
|---|---|---|---|---|
| `prove-task4.sh` | Helm installs, upgrades, and undoes a broken release with zero failed requests | ~4 min | free | reinstalls switchboard |
| `prove-task6.sh` | monitoring finds the service; overload fires alerts; they clear | ~10 min | free | real model, 1 copy |
| `prove-task7.sh` | autoscaling 1→4→1; the scale-to-zero trap; scale-to-zero done right | ~15 min | free | reinstalls switchboard |
| `prove-task8.sh` | a good version is promoted; a slow one is caught and rolled back | ~10 min | free | switches to canary mode |
| `prove-task5.sh` | the same chart on Google Cloud, a transcript over the internet | ~45 min | **trial credit** | see below |

Run one with, for example, `bash scripts/prove-task8.sh`, and watch the
matching dashboard while it runs.

---

## 6. Stop everything

```
bash scripts/down-local.sh
```

This gives back about 3 GB of memory. The image stays in the cluster, so the
next `up-local.sh` is quick. To free Kubernetes' own memory as well, switch it
off in Docker Desktop's settings.

---

## 7. Google Cloud (the only part that costs anything)

The cloud runs on a free trial. The rules that keep it free:

1. **Never** click *Activate full account* / *Upgrade* in the Google Cloud console.
2. A cloud session is always: `CONFIRM=yes bash scripts/prove-task5.sh` → look →
   `bash scripts/destroy-task5.sh`.
3. A session isn't over until `bash scripts/cloud-check.sh` prints
   **NOTHING RUNNING**. `check-platform.sh` runs that check too.
4. Budget alert emails arrive at $10, $25 and $50 of usage. Treat any of them as
   a reason to run `destroy-task5.sh` immediately.

---

## If something goes wrong

| symptom | likely cause | fix |
|---|---|---|
| `Kubernetes isn't answering` | Docker Desktop or its Kubernetes is stopped | start it; wait for green |
| everything slow, pods restarting, `kubectl` timing out | the machine is out of memory | `bash scripts/down-local.sh`, close heavy apps, try again |
| a Grafana page won't load | the monitoring stack isn't installed | `bash scripts/up-local.sh` |
| `helm` says *another operation is in progress* | an install was interrupted | `helm list -A --pending`, then `helm uninstall <name> -n <namespace>` and re-run |
| `check-platform.sh`: *Prometheus scrapes switchboard* FAIL | new pods not picked up yet | wait a minute, re-run |
