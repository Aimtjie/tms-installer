# Sizing

How much hardware a self-hosted TMS installation needs.

⚠️ **The figures below are estimates, not measurements.** They are derived from a
running installation on a larger machine and scaled down by reasoning about what
the platform costs. They will be replaced with real numbers from a 4 GB server as
soon as one has run for a while — see "Measuring your own" at the end.

Treat them as a starting point for provisioning, not as a guarantee.

---

## Recommendation

| | **Single server** | **Three servers (HA)** |
|---|---|---|
| CPU | 4 | 4 each |
| Memory | 4 GB | 8 GB each |
| Disk | 20 GB free (15 GB workable) | 80 GB each (60 GB floor) |
| Extra disk | — | A second volume per server if possible |

Run `common/preflight.sh` (add `--ha`) on a candidate machine and it will tell
you where it falls short.

---

## Where it goes

**Memory, single server — roughly 2.3 GB of 4 GB in use.**

| | Estimate |
|---|---|
| Operating system, container runtime | ~0.6 GB |
| Kubernetes itself | ~0.6–0.7 GB |
| Sign-in (Keycloak) | ~0.5 GB |
| API | ~0.25 GB |
| Web | ~0.15 GB |
| Database | ~0.1 GB at rest, grows with use |
| Everything else | ~0.1 GB |

Keycloak is the largest single consumer, and it is a JVM — it wants headroom for
garbage collection and for bursts when many people sign in at once. On a 4 GB
server its ceiling is reduced to fit, which is a real compromise: a burst that
would previously have been absorbed may instead be cut short. That is one of the
first things worth revisiting if the server is grown.

**Disk, single server — about 4.5 GB before any of your data.**

| | Estimate |
|---|---|
| Kubernetes and its state | ~0.5 GB |
| Container images | ~3.5–4 GB |
| **Left for your data** | ~10 GB of a 15 GB disk |

Container images are the surprise. They take roughly **twice** their download
size on disk, because both the compressed layers and the unpacked copy are kept.

---

## Why three servers need considerably more disk

Two reasons that compound:

1. **The cluster's own bookkeeping.** Three servers coordinate through a shared
   log that is written constantly and compacted periodically — 1–2 GB, and it is
   busy.
2. **The database is on every server.** Each server holds a full copy. A 20 GB
   database is 20 GB on all three, not 20 GB spread across them. This is what
   makes losing a server survivable, and it is not optional.

Add the nightly backup being staged locally before it is sent, plus system logs,
and roughly 7 GB per server is spoken for before TMS stores anything.

**Running out of disk on the database server is the failure to avoid.** It is not
a slowdown — the database stops accepting writes, and if it happens on the
primary a survivable situation becomes an outage. That is why the floor is 60 GB
rather than "whatever fits".

---

## Growth

| | Rough guide |
|---|---|
| A ticket with its history and comments | tens of kilobytes |
| Audit trail | comparable to the tickets themselves |
| Attachments on a local volume | whatever your users upload; not on the database disk |
| Attachments in the database | whatever your users upload, **on every server** |

For most service desks the tickets themselves stay in the low gigabytes for
years. Attachments are what actually consume space, which is why where they are
stored is a deliberate choice at install rather than a default.

`tmsctl status` will warn as the database disk fills.

---

## CPU

Rarely the limit. A busy small service desk sits well under one core, with brief
peaks during imports and reports. Four cores are recommended less for throughput
than for headroom: the platform, the database and the application all want CPU at
the same moment during a restart, and a two-core machine makes that slower than
it needs to be.

---

## Measuring your own

Better than any estimate. On a running installation:

```sh
tmsctl status                    # overall health
kubectl top pods -n tms          # memory and CPU per component
df -h                            # disk, per server
```

Take a reading during a normal working day rather than overnight, and again while
a large import runs. Those two numbers bracket what the system actually needs.

If your figures differ substantially from the estimates above, they are worth
reporting — this page should be built from real installations rather than
arithmetic.
