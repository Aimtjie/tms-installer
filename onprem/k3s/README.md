# k3s target

Installs Kubernetes (k3s) and TMS onto servers you provide. This is the only
target that can survive losing a whole server, because it is the only one that can
run CloudNativePG — the piece that promotes a database standby automatically.

Two shapes, same manifests with different numbers:

| | **Stage A** | **Stage B** |
|---|---|---|
| Servers | 1 | 3 |
| Survives a server dying | No | Yes |
| Database failover | — | Automatic, no data loss |
| If the server dies | Restore from last night's backup | Standby is promoted, users reconnect |
| Suits | Demo, evaluation, small sites | Production |

Start with Stage A even if you have three servers. It is the same software and the
same operator commands, so nothing is wasted, and it gets you something working
while the remaining prerequisites for Stage B are settled.

---

## What you must provide

**For Stage A:**

- One Linux server. 4 CPU / 4 GB RAM / 15 GB free disk is enough — that is roughly
  1 GB of application on top of 1.2 GB for the OS, k3s and containerd, with about
  10 GB left for data.
- A DNS name pointing at it, e.g. `tickets.example.internal`.
- A TLS certificate covering that name, **including intermediates**. A leaf-only
  certificate works in the browser you tested with and fails elsewhere.
- Somewhere off this machine to send backups: an SFTP server, an NFS/SMB mount, or
  S3-compatible storage. Install will not finish without it.

**Additionally for Stage B:**

- Three servers, ideally 4 CPU / 8 GB RAM / 80 GB disk each.
- A spare IP address on the **same network segment** as all three, for the virtual
  IP. It moves between servers by re-announcing itself at the network layer, which
  does not cross a router — so three servers on three subnets cannot use it.
- A second disk per server if you can. The cluster's own state and the database
  journal both write constantly, and sharing one disk makes a small cluster feel
  slow without anything visibly failing.

Run `../common/preflight.sh` (add `--ha` for Stage B) to check most of this
automatically.

---

## Installing

Run these from the `onprem/` directory — **not** from `onprem/k3s/`. The `.env` lives
next to `tmsctl`, and both `bootstrap.sh` and `tmsctl` read it from there.

```sh
cd onprem
cp common/.env.example .env
chmod 600 .env
$EDITOR .env                 # hostname, certificate paths, backup location
./common/preflight.sh
sudo ./k3s/bootstrap.sh      # or: sudo ./tmsctl install
```

Then open `https://<your hostname>/` and follow the setup wizard to create the
first administrator. **There are no default accounts** — nothing to change, and
nothing to forget to change.

One step the installer cannot do for you: **email**. TMS reads its mail settings
from the database so they can be changed without a redeploy, so set them under
Administration → Notifications after your first login. Until then TMS sends no
mail, including password resets.

---

## How it is laid out

Everything is served from **one hostname**:

```
https://tickets.example.internal/         web application
https://tickets.example.internal/api/     API
https://tickets.example.internal/auth/    sign-in (Keycloak)
```

One DNS record, one certificate, and — because the browser only ever talks to one
origin — no cross-origin request rules to get wrong.

| Component | Notes |
|---|---|
| `tms-web`, `tms-api` | The application. Images pulled from a public registry, so there are no registry credentials to expire. |
| `keycloak` | Sign-in. Keeps its data in the same database. |
| `tms-postgres` | PostgreSQL, managed by CloudNativePG. TLS-only. |
| `redis` | Carries real-time notifications between copies of the API. Holds nothing worth keeping. |
| `ingress-nginx` | Terminates TLS and routes by path. Runs on every server. |

Traffic reaches the cluster on ports 80 and 443. Nothing else needs to be open
from outside.

---

## Before you use Stage B — two open prerequisites

Both are being worked on. Neither prevents Stage A.

**The API still runs a single copy.** Several of its background jobs — scheduled
report delivery, incoming-mail collection, SLA monitoring — have no way yet to
agree on which copy is in charge, so a second copy would send duplicate report
emails and process the same incoming mail twice. Until that is resolved, losing
the server running the API means it restarts elsewhere in roughly a minute rather
than continuing uninterrupted.

**The database failover is real regardless.** That is the harder half, and it works
today: lose the server holding the primary and a standby is promoted with no data
loss and nobody paged.

**Attachments need storage every server can reach.** The default storage is local
to one server, so if that server dies the files are gone *and* the API cannot start
anywhere else. Before using Stage B, either point `K8S_STORAGE_CLASS` at shared
storage (NFS or SMB) or wait for the option to keep attachments in the database,
which removes the question entirely.

**The ingress runs as a single copy.** It is installed on the host's network so it
owns ports 80 and 443 directly, which is what makes the single-hostname layout work
without an external load balancer. On more than one server it needs to become a
DaemonSet — one copy per server — because two copies scheduled onto the same server
would collide on those ports. Tracked with the rest of Stage B.

---

## A caveat about growing from one server to three

A single-server install runs its cluster state in an embedded SQLite database
rather than the clustered store, because that saves 1–2 GB of disk and avoids
competing with PostgreSQL for disk writes — both of which matter on a 15 GB
server.

The consequence: **a Stage A server cannot be joined to by two more and become a
Stage B cluster.** Moving to three servers means building the new cluster and
restoring a backup into it. That is a supported, documented path — but it is a
migration, not an expansion, and it is worth knowing before you plan the work.

If you already know you are heading for three servers soon and have the disk,
say so at install time and Stage A will be built the clustered way from the start.

---

## Day-to-day

```sh
../tmsctl status          # start here; it answers in English
../tmsctl logs api
../tmsctl backup now
../tmsctl support-bundle  # collect diagnostics to send to your supplier
```

Operating procedures — a server failing, restoring, replacing the certificate,
upgrading — are in `../docs/RUNBOOK.md`. Read section 4 before you need it.
