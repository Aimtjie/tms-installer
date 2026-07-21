# TMS self-hosted deployment

Everything in this folder is for running TMS **on your own servers**. Pick one target
below, then follow its README.

All targets are driven by the same operator CLI (`./tmsctl`) and read the same
configuration file (`common/.env.example` → your `.env`), so what you learn on one
carries over to the others.

---

## Choose a target

| | **k3s** | **k8s** | **compose** | **swarm** |
|---|---|---|---|---|
| **Use when** | You have 1–3 dedicated Linux servers and want us to install everything | You already run Kubernetes and want TMS on it | You have one server and want the simplest thing that works | You already run Docker Swarm |
| **Servers** | 1 (demo) or 3 (HA) | your cluster | 1 | 1 |
| **Survives a server dying** | **Yes, with 3 servers** — including automatic database failover | Depends on your cluster | No | No |
| **Database failover** | **Automatic** (CloudNativePG) | Automatic (CloudNativePG) | None — restore from backup | None — restore from backup |
| **Zero-downtime updates** | Yes | Yes | No (brief restart) | Yes |
| **What you must provide** | Servers, a DNS name, a TLS certificate, an off-box backup location | A cluster, a StorageClass, an ingress class, plus the above | A server, an off-box backup location | A server, an off-box backup location |
| **Skill needed to operate** | Basic Linux (`tmsctl` wraps the rest) | Basic Linux + your existing cluster knowledge | Basic Linux | Basic Linux + Docker Swarm |

**Most people who were handed servers want `k3s/`.** It is the only target that keeps
serving when a whole machine dies, because it is the only one that can run
CloudNativePG — the component that promotes a PostgreSQL standby automatically.

**If you only have one server, that is fine.** Start with `k3s/` in single-node mode
(or `compose/` if you would rather not run Kubernetes at all) and add servers later.
Note the caveat in `k3s/README.md` about single-node clusters not being upgradable
in place to a 3-node cluster.

---

## What "high availability" does and does not mean here

Worth being precise, because the word gets used loosely.

**With 3 servers you get:** any one server can be switched off, catch fire, or lose
its network, and TMS keeps serving. The database promotes a standby automatically
with no data loss. Users may see a brief reconnect.

**You do not get:** protection against losing *two* servers at once (the cluster
needs a majority to make decisions), against the building losing power, or against
someone deleting data. **Those are what backups are for**, which is why `tmsctl install`
will not finish until you have configured and tested an off-box backup location.

---

## Before you install anything

Run the preflight check. It is safe, read-only, and takes a few seconds:

```sh
./common/preflight.sh            # single-server / demo thresholds
./common/preflight.sh --ha       # stricter thresholds for a 3-server HA install
```

It tells you whether the machine has enough CPU, memory and disk, whether the
required ports are free, and whether it can reach the container registry. Fix
anything it reports as **FAIL** before continuing; **WARN** items are usually
survivable but worth understanding.

---

## Configuration

One file drives every target:

1. Copy `common/.env.example` to `.env`.
2. Fill in the values marked **REQUIRED** (or let `./tmsctl install` generate them).
3. `common/CONFIG.md` documents every setting: what it does, its default, and
   which targets use it.

Two settings deserve reading in full before you install, because **neither can be
changed later without data loss**: `BLIND_INDEX_SECRET` and your choice of
`STORAGE_PROVIDER`. Both are called out in `CONFIG.md`.

---

## Operating it

```sh
./tmsctl status          # is everything healthy? (start here)
./tmsctl logs api        # look at a component's logs
./tmsctl backup now      # take a backup immediately
./tmsctl support-bundle  # collect diagnostics to send to your supplier
./tmsctl --help          # everything else
```

`tmsctl status` is written to be read by a person, not parsed by a machine. If it
says `DEGRADED` it also tells you which runbook section to open.

Full operator documentation is in `docs/`:

| Document | Read it when |
|---|---|
| `docs/RUNBOOK.md` | Something is wrong, or you are doing planned maintenance |
| `docs/ARCHITECTURE.md` | Your security or infrastructure team has questions |
| `docs/BACKUP-RESTORE.md` | Setting up backups, or restoring |
| `docs/UPGRADE.md` | Moving to a newer version |
| `docs/SIZING.md` | Deciding how much hardware you need |

---

## Getting help

There is no phone-home and no remote access into your installation. If you need
support, run:

```sh
./tmsctl support-bundle
```

It writes a single archive containing logs, component status and version
information, with secrets removed. Send that file to your supplier — it is the
fastest route to a diagnosis, and often the only one.
