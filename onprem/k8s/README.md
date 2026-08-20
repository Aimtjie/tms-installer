# TMS on your own Kubernetes cluster

For an organisation that **already runs Kubernetes** and **already operates a PostgreSQL server**.
TMS installs as a single Helm chart alongside whatever else you run.

If you were handed bare Linux servers instead, use [`../k3s/`](../k3s/) — it installs the cluster and
the database for you.

```
onprem/k8s/
  README.md              this file
  values.example.yaml    the settings you must decide, ready to fill in
  rendered/              what the chart produces, for reading without installing
  tms/                   the chart
```

---

## 1. What this installs, and what it does not

**Installed by the chart**

| | |
|---|---|
| `tms-api` | the application API — **one replica, and that is not tunable**; see §5 |
| `tms-web` | the web front end |
| `keycloak` | sign-in. Its realm is imported on first start |
| `redis` | carries real-time notifications between pods. Holds nothing durable |
| `tms-attachments` | a PersistentVolumeClaim for uploaded files — only when `attachments.provider` is `local`, the default. See §2 item 6 |
| two `Ingress` objects | one hostname, path-routed. See §4 for why there are two |

**Not installed, and never touched**

- **Your PostgreSQL server.** The chart connects to it. It does not create, migrate, tune, back up
  or upgrade it.
- **Your ingress controller**, cert-manager, storage provisioner, or monitoring.
- **Certificates.** You supply a Secret; nothing here renews it.
- **Backups.** See the warning in §2, item 6 — it is the one on this page most likely to matter to
  you later.

---

## 2. Prerequisites checklist

Hand this section to whoever runs the cluster. Every row is answerable without reading a manifest,
and the install cannot complete until all of them are.

| # | What we need | Why | How to find it |
|---|---|---|---|
| 1 | A **namespace**, and permission to create Deployments, Services, Ingresses, PVCs, ConfigMaps, Secrets and Jobs in it | Nothing cluster-scoped is installed by default | — |
| 2 | **PostgreSQL 16+**, host and port, reachable from pods in that namespace | Holds everything | ⚠ Also confirm no default-deny NetworkPolicy blocks egress to it. This is the most common silent failure, and it looks identical to a wrong password |
| 3 | **Two databases and a role** — `ticketdb` and `keycloakdb`. SQL below | Keycloak keeps its own schema; the app keeps everything else | Your DBA runs it once |
| 4 | Whether Keycloak **shares the application's role** or gets its own | Both are supported; shared is the default | Your policy decides |
| 5 | **TLS mode to the database** — `disable`, `require`, `verify-ca` or `verify-full` — and for the `verify-*` modes, the server's **CA certificate** | Default is `verify-full` | `SHOW ssl;` on the server, or your provider's documentation |
| 6 | **A StorageClass** for attachments, ReadWriteOnce, ~20 GB — **and whether your platform backs it up** | ⚠ **TMS does not back up attachments. Nothing in this chart does.** A database backup restores every ticket and none of their files. If you have no class you would trust with the only copy, set `attachments.provider: postgres` instead: the bytes go into the database, no volume is created, and this row does not apply | `kubectl get storageclass` |
| 7 | **The IngressClass name**, and which controller | Routing and TLS termination | `kubectl get ingressclass` |
| 8 | Confirmation the controller supports **WebSockets**, **cookie session affinity**, **request bodies ≥ 160 MB**, and a **read timeout ≥ 3600 s** | §4 explains what breaks without each | — |
| 9 | **The CIDR that ingress traffic reaches pods from** | §6. Getting this wrong breaks first-run setup and weakens rate limiting | `kubectl get pod -n <ingress-ns> -o wide`, matched against your pod network |
| 10 | **One DNS name** pointing at the ingress | Web, API and sign-in all live under it — one name, one certificate, no CORS | — |
| 11 | **A `kubernetes.io/tls` Secret** in the namespace covering that name, full chain | We do not require cert-manager and renew nothing | — |
| 12 | **Who holds `Encryption__BlindIndexSecret`**, off-cluster | It can never change. A backup is only restorable with the value it was taken with | §3 |

### The SQL for item 3

Shared role — the default, and one credential for your DBA to manage:

```sql
CREATE ROLE tms LOGIN PASSWORD 'choose-something-long';
CREATE DATABASE ticketdb   OWNER tms;
CREATE DATABASE keycloakdb OWNER tms;
```

Separate role for the identity store, if your policy requires that Keycloak's credentials cannot
read application data:

```sql
CREATE ROLE tms      LOGIN PASSWORD 'choose-something-long';
CREATE ROLE keycloak LOGIN PASSWORD 'choose-something-else';
CREATE DATABASE ticketdb   OWNER tms;
CREATE DATABASE keycloakdb OWNER keycloak;
```

then set `postgres.keycloak.username` and `postgres.keycloak.existingSecret`.

### SMTP is not configured here

Outbound mail settings are read from the database when a message is sent, so the installer cannot
set them. Configure them in the admin UI after the first sign-in.

---

## 3. Create the Secret

**The chart generates no secret material.** You create one Secret, before installing:

```sh
kubectl -n tms create secret generic tms-secrets \
  --from-literal=Jwt__Secret="$(openssl rand -base64 48)" \
  --from-literal=Encryption__BlindIndexSecret="$(openssl rand -base64 48)" \
  --from-literal=Postgres__Password='the password your DBA gave you' \
  --from-literal=Keycloak__AdminUsername=admin \
  --from-literal=Keycloak__AdminPassword="$(openssl rand -base64 48)" \
  --from-literal=Redis__Password="$(openssl rand -base64 48)"
```

Optionally add `Sso__Keycloak__ClientSecret` if you will use Microsoft Entra sign-in.

### Two constraints on the database password

It travels inside a .NET connection string, so it must contain **no `;`** (the keyword separator)
and **no `$(`** (which Kubernetes would try to expand). Any other character is fine, including
spaces. Everything `openssl rand -base64` produces is safe.

### Why the chart does not generate these for you

`Encryption__BlindIndexSecret` derives the searchable index over encrypted fields. Once data exists
it can never change — change it and every user becomes unfindable, sign-in stops, and there is no
migration path.

Helm's idiom for generate-and-remember is to look up the existing Secret and mint a new value if it
is absent. That lookup **returns nothing during `helm template`, during `--dry-run`, and during any
render that cannot reach the cluster** — so a CI render, a `helm diff`, or an Argo CD dry-run would
mint a fresh value, and if that render is what gets applied, your database becomes unreadable with
no way back.

There is no safe way to generate that field, so the chart generates nothing. Keep the values
somewhere that is not this cluster.

---

## 4. What the chart needs from your ingress controller

Four behaviours. They are functional requirements, not tuning — each one below fails in a specific
way, not by looking untidy.

| Requirement | Without it |
|---|---|
| **WebSocket upgrade** | Real-time notifications never connect |
| **Read timeout ≥ 3600 s** | The default 60 s closes the Blazor circuit and the notification stream mid-session; users see the app reloading at random |
| **Request bodies ≥ 160 MB** | A ticket import sends a manifest CSV and its companion archive in one multipart body. A lower cap **truncates** it, so the import fails with a parse error that says nothing about size |
| **Cookie session affinity on `/hubs` and `/_blazor` only** | See below |

Set `ingress.controller: nginx` and the chart renders all of this in ingress-nginx's spelling. For
any other controller set `ingress.controller: none` and supply your own via `ingressAnnotations` and
`ingressStickyAnnotations`, working from the table above rather than from our annotation names.

### Why there are two Ingress objects

Affinity is required on `/hubs` and `/_blazor`, and must **not** be on `/api`.

The first visit to TMS runs as a real Blazor Server circuit over `/_blazor`, and a circuit lives in
one pod's memory — Redis does not make it portable, and nothing else does either. The notification
hub separately buffers per-connection state in pod memory, which Redis does not replicate. A
reconnect landing on a different pod silently loses both.

`/api` is stateless, so pinning it would concentrate load for no benefit. Two objects is the only
way to express that difference, which is why the chart ships two rather than one.

---

## 5. tms-api runs one replica

This is a correctness constraint, not a capacity one, and the chart refuses to install with any
other value.

Five background services inside the API have no leader election. A second replica does not share
their work, it repeats it:

- the scheduled-report runner marks a report done only *after* it has run, so both replicas see it
  as due — **your customers receive duplicate scheduled reports**;
- both inbound mailbox pollers poll the same mailbox;
- the SLA monitor double-advances escalations;
- the import recovery sweep claims every in-flight batch with no owner, so **a starting replica
  adopts the batch another replica is still writing**.

The deployment also uses the `Recreate` strategy for the same reason: with the default rolling
update a single-replica deployment still runs **two** pods briefly during every upgrade.

`tms-web` scales freely — raise `web.replicas`. Its keys live in the database and its circuits are
pinned by the sticky Ingress.

Helm refuses a scale; `kubectl scale` is outside its reach. If you are cluster-admin, set
`apiScaleGuard.enabled=true` and the cluster will refuse it too.

This is lifted in a future chart release, and the value becomes an ordinary knob.

---

## 6. The trusted-proxy CIDR

`network.trustedProxyCidrs` decides which peers may set `X-Forwarded-For` and `X-Forwarded-Proto`.
It is usually your cluster's pod CIDR.

**Setting it replaces the default rather than adding to it**, and that is the point: the default
trusts every RFC1918 address, and on an internal deployment your own users are on RFC1918 addresses
too — so the default would let any workstation on the network forge those headers.

Get it wrong and the API stops believing it is behind TLS. The first-run `/setup` wizard returns
500 on an antiforgery check, secure cookies and HSTS stop behaving, and per-IP rate limiting can be
bypassed with a forged header.

If you genuinely cannot determine it, `network.trustProxyRfc1918: true` falls back to the old
behaviour. It is a separate deliberate setting rather than a default for the reason above.

---

## 7. Install

```sh
# 1. Check what you are about to get. Reads nothing, changes nothing.
helm template tms ./tms -n tms -f my-values.yaml | less

# 2. Install.
helm install tms ./tms -n tms --create-namespace -f my-values.yaml
```

A Job runs first and proves your database is reachable, that both databases exist, that the
credentials work, and that the negotiated TLS matches what you asked for. If any of that is wrong
the install stops with one message naming the cause, rather than deploying everything and leaving
you to work it out from three crash-looping components.

First boot then runs migrations and warms every tenant's encryption key. It takes several minutes,
and the pods are deliberately not marked ready until it finishes:

```sh
kubectl -n tms rollout status deployment/tms-api --timeout=15m
```

Then open `https://<your hostname>/` and complete the setup wizard. It creates the first
administrator; there are no seeded accounts.

### Upgrading

```sh
helm upgrade tms ./tms -n tms -f my-values.yaml
```

Read the release notes first. Database migrations run automatically on the new API pod and are not
reversed by a Helm rollback — take a database backup before upgrading.

### Uninstalling

```sh
helm uninstall tms -n tms
```

The attachments PVC and any Secret the chart created are deliberately **kept**, because nothing here
backs them up and an uninstall would otherwise be the only copy's deletion. Remove them by hand once
you are certain:

```sh
kubectl -n tms delete pvc tms-attachments
```

---

## 8. If something is wrong

| Symptom | Look at |
|---|---|
| Install stops at the preflight Job | Its message names the cause. `kubectl -n tms logs job/tms-preflight` |
| Every pod crash-loops at once | Almost always the database — wrong host, blocked by a NetworkPolicy, or a missing `keycloakdb` |
| Keycloak is healthy but nobody can sign in | Check `Keycloak__BaseUrl` carries the same path prefix as `KC_HTTP_RELATIVE_PATH`. The chart renders both from one value, so this should be impossible — but Keycloak reports healthy either way, so it is worth ruling out |
| `/setup` returns 500 | §6 — the trusted-proxy CIDR |
| The app reloads at random | §4 — the read timeout |
| Imports fail with a parse error | §4 — the body-size cap |

`../docs/RUNBOOK.md` covers day-to-day operations. `../docs/ARCHITECTURE.md` is written for a
security team: what the system is, what leaves your network (nothing), and how data is protected.
