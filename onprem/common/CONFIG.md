# Configuration reference

Every setting in `.env`, what it does, and which targets read it.

The right-hand column gives the application setting each one maps to. You do not
need it for a normal install — it is there for when you are reading application
logs, which refer to settings by those names.

**Legend:** ● required · ○ optional · — not used by that target

---

## Settings you cannot change later

Read this section before you install. Everything else in this file is a
preference; these three are decisions.

| Setting | Why it is permanent |
|---|---|
| `BLIND_INDEX_SECRET` | Derives the searchable index over encrypted fields. Change it and existing users become unfindable and cannot log in. There is no migration path — only restoring a backup taken with the original value. `./tmsctl secret rotate` refuses this one on purpose. |
| `BACKUP_PASSWORD` | Encrypts the backups. Lose it and every backup you hold is unreadable. It is not recoverable from the running system. |
| `STORAGE_PROVIDER` | Decides where uploaded files live. Changing it later means moving every file with `./tmsctl storage migrate`, not editing this value. |

All three belong in your password manager, and in the encrypted escrow bundle
that `./tmsctl install` produces. **Keep the escrow bundle somewhere other than
the servers it protects** — a backup you cannot decrypt after losing the machine
is not a backup.

---

## Target

| Setting | Default | Notes |
|---|---|---|
| `TMS_TARGET` | `k3s` | `k3s` · `k8s` · `compose` · `swarm`. Set by `./tmsctl install`; `tmsctl` uses it to decide how to talk to your installation. |

## Secrets

| Setting | k3s | k8s | compose | swarm | Application setting |
|---|:-:|:-:|:-:|:-:|---|
| `JWT_SECRET` | ○ | ● | ● | ● | `Jwt:Secret` |
| `BLIND_INDEX_SECRET` | ○ | ● | ● | ● | `Encryption:BlindIndexSecret` |
| `POSTGRES_PASSWORD` | ● | ● | ● | ● | part of `ConnectionStrings:ticketdb`. On k3s, Keycloak shares this database login (one `tms` role owns both `ticketdb` and `keycloakdb`). |
| `KEYCLOAK_ADMIN_PASSWORD` | ● | ● | ● | ● | `Keycloak:AdminPassword` |
| `SSO_CLIENT_SECRET` | ○ | ○ | ○ | ○ | `Sso:Keycloak:ClientSecret`. Used only for Microsoft Entra sign-in, and auto-generated at install when left blank — you rarely need to set it. |

On the **k3s** installer you can leave both `JWT_SECRET` and `BLIND_INDEX_SECRET`
blank: bootstrap generates a strong value for each and writes them into the
encrypted escrow bundle. Set one only to supply your own — most importantly when
**restoring a backup**, where `BLIND_INDEX_SECRET` must exactly match the value
the backup was taken with, or the restored data is unreadable. This is why k3s
shows `○` above.

The **k8s** target deliberately generates nothing: you create the Secret yourself
before installing, and `../k8s/README.md` §3 explains why — every Helm idiom for
generate-and-remember mints a NEW value during `helm template`, `--dry-run`, or
any render without cluster access, and a regenerated `BLIND_INDEX_SECRET` is an
unrecoverable database. The **compose** and **swarm** installers are still not
implemented; their `●` records the current expectation that you supply the values
rather than verified installer behaviour, and preflight keeps failing a blank
secret on those targets until one ships that generates them.

**A value you _do_ supply must be at least 32 bytes.** This is enforced at
startup, not at install: a shorter value makes the API refuse to start with a
message naming the setting and the length it actually got — preflight also
catches a too-short value up front. Generate them with `openssl rand -base64 48`
and the length takes care of itself.

## Address and TLS

| Setting | k3s | k8s | compose | swarm | Application setting |
|---|:-:|:-:|:-:|:-:|---|
| `TMS_HOSTNAME` | ● | ● | ● | ● | drives `Cors:WebOrigin`, `Sso:WebRedirectBaseUrl`, `Keycloak:PublicBaseUrl` |
| `TLS_CERT_FILE` | ● | ● | ○ | ○ | — |
| `TLS_KEY_FILE` | ● | ● | ○ | ○ | — |

TMS is served from **one hostname**, with the API under `/api/` and the login
service under `/auth/`. That is why there is a single setting here rather than
three URLs: same-origin means the browser never makes a cross-origin request, so
there is no CORS configuration to get wrong, one DNS record, and one certificate.

The certificate **must** cover `TMS_HOSTNAME` — preflight fails the install if it
does not. It **should** include the **full chain**: a leaf-only certificate is a
common and confusing failure, because your browser has the intermediate cached so
it works for you and fails for everyone else. Preflight *warns* on a single
certificate rather than blocking — a self-signed cert with no chain is a valid way
to stand the system up for testing (see the k3s README) before your real
certificate arrives, which you then swap in with `tmsctl cert replace`.

On `compose` and `swarm`, TLS is optional because those targets are often placed
behind a reverse proxy you already run. If you do that, the proxy must send
`X-Forwarded-Proto: https`, and you must set `TRUSTED_PROXY_CIDR` — see below.

## Backups

| Setting | Default | Notes |
|---|---|---|
| `BACKUP_REPOSITORY` | — | **Required on every target.** A restic repository URL. `sftp:user@host:/path`, a filesystem path to a mounted share, or `s3:https://…`. |
| `BACKUP_PASSWORD` | — | **Required.** Encrypts the repository. |
| `BACKUP_ENV_EXTRA` | — | Extra credentials for the backend, as `KEY=value` lines. S3 wants `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`; SFTP normally uses a key file instead and needs nothing here. |
| `BACKUP_SCHEDULE` | `0 2 * * *` | Cron expression, UTC. |
| `BACKUP_KEEP_DAILY` | `14` | |
| `BACKUP_KEEP_WEEKLY` | `4` | |
| `BACKUP_KEEP_MONTHLY` | `6` | |

The nightly backup contains the database (which includes every tenant's
encryption keys), the login service's configuration, and — **only when
`STORAGE_PROVIDER=postgres`** — your attachments.

With `STORAGE_PROVIDER=local`, attachments are **not** in the TMS backup. If that
directory is a mount from storage you already back up, that is a reasonable
arrangement; just make sure someone actually owns it. `./tmsctl install` asks you
to confirm this explicitly rather than assuming.

## Attachments

| Setting | Default | Notes |
|---|---|---|
| `STORAGE_PROVIDER` | `local` | **k3s implements `local` only.** `s3` and `postgres` are rejected at install — see below. |
| `STORAGE_LOCAL_PATH` | `/var/lib/tms/attachments` | **Not used by k3s** (the path there is fixed at `/var/tms/attachments`, backed by a Kubernetes volume). Applies to compose and swarm. |
| `STORAGE_S3_ENDPOINT` | — | `s3` only — **not read yet**. |
| `STORAGE_S3_BUCKET` | `tms-attachments` | `s3` only — **not read yet**. |
| `STORAGE_S3_ACCESS_KEY_ID` | — | `s3` only — **not read yet**. |
| `STORAGE_S3_SECRET_ACCESS_KEY` | — | `s3` only — **not read yet**. |

**Attachments are backed up.** On the k3s target the nightly job mounts the attachment volume
read-only and includes it in the same restic snapshot as the database dump, so one restore brings
back both. The volume does live on a single server, which is why a 3-server install needs storage
every server can reach — see `k3s/README.md`.

**`s3` and `postgres` are refused rather than accepted** because the application treats any
unrecognised provider as `local`. A value accepted here but not wired into the deployment would put
attachments somewhere the operator did not choose, and it would surface at a restore rather than at
install.

Maps to `Storage:Provider`, `Storage:Local:BasePath` and `Storage:S3:*`.

> **Why unrecognised values are rejected rather than ignored.** The application
> treats any provider name it does not recognise as `local`. If a typo — or a
> value from a newer version — were passed through, TMS would start normally and
> quietly write attachments to a local disk, while the nightly backup covered
> only the database. You would not find out until a restore. `./tmsctl install`
> therefore validates this value against the list above and stops.

## Kubernetes — `k3s`

> **The `k8s` target does not read these.** It is a Helm chart, so everything
> below is a value in `../k8s/values.example.yaml` instead — storage class,
> namespace (`helm install -n`), replica counts and the database are all set
> there. The keys this file still supplies on `k8s` are `TMS_TARGET` (which
> tells `tmsctl` which adapter to load) and `K8S_NAMESPACE` (which namespace
> `tmsctl status` and `tmsctl logs` look in — it must match the `helm install -n`
> you used, or a healthy install is reported as absent). See
> [`../k8s/README.md`](../k8s/README.md).

| Setting | Default | Notes |
|---|---|---|
| `K8S_NAMESPACE` | `tms` | |
| `K8S_STORAGE_CLASS` | `local-path` | StorageClass for the **attachments** volume only; the database stays on `local-path` regardless (CNPG replicates onto each server's own disk). ⚠ Applied at **install** time — a volume's storage class cannot be changed afterwards, so set it before installing if you plan on 3-server HA. On `k8s`, use `storage.className` in the chart's values instead. |
| `K8S_STORAGE_ACCESS_MODE` | `ReadWriteOnce` | How the attachments volume may be mounted. `ReadWriteOnce` means one server **at a time**, not one server for ever — the API still relocates after a failure — so leave it unless your shared storage forces otherwise. Set `ReadWriteMany` only when the volume your storage admin pre-provisioned is offered *only* as `ReadWriteMany`: binding matches the mode exactly, so such a volume never satisfies a `ReadWriteOnce` request and the install stops with it unbound. Also fixed at creation. |
| `TMS_VIP` | — | 3-server HA only. An unused IP on the **same network segment** as all three servers. |
| `REPLICAS_API` | `3` | |
| `REPLICAS_WEB` | `3` | |
| `REPLICAS_KEYCLOAK` | `2` | |
| `POSTGRES_INSTANCES` | `1` | `1` for a single server, `3` for HA. |

> **`POSTGRES_INSTANCES=2` is rejected.** With two copies and synchronous
> replication, losing one server leaves no one to acknowledge writes, so the
> database stops accepting them entirely — strictly worse than a single copy,
> which at least keeps working. Use `1` or `3`.

`TMS_VIP` needs all three servers on one network segment because the address
moves by re-announcing itself at the network layer, which does not cross a
router. If your servers are on different subnets, `../k3s/README.md` describes
the fallback and is honest about how much worse it is.

## Single-server targets — `compose` and `swarm` only

| Setting | Default | Notes |
|---|---|---|
| `WEB_HTTP_PORT` | `8081` | |
| `API_HTTP_PORT` | `8080` | |
| `BIND_ADDRESS` | `127.0.0.1` | `0.0.0.0` exposes the ports to your network. |
| `REQUIRE_HTTPS` | `false` | `Security:RequireHttps`. Set `true` once a TLS proxy fronts the stack. |
| `TRUSTED_PROXY_CIDR` | `127.0.0.1/32` | `RateLimiting:TrustedProxyCidrs`. |

Two things that surprise people here:

**Docker bypasses `ufw`.** Published ports are opened through Docker's own
firewall rules, which sit in front of `ufw`. `BIND_ADDRESS` is what actually
controls who can reach the stack; a `ufw deny` will not save you.

**`TRUSTED_PROXY_CIDR` is where the proxy's traffic *arrives*, not the proxy's
public address.** A proxy running as another container reaches TMS over the
Docker network, so the value is that network's range. A proxy on the host
reaching `127.0.0.1` needs the loopback default. Getting this wrong while
`REQUIRE_HTTPS=true` makes first-run setup fail with a 500, because the
application never sees the request as secure.

Note also that setting this **replaces** the default rather than adding to it —
so an explicit value can narrow trust as easily as widen it.

## Everything else

| Setting | Default | Application setting |
|---|---|---|
| `TICKET_NUMBER_PREFIX` | `SS` | `Tickets:NumberPrefix` |
| `REGIONS_DEFAULT` | `ZA` | `Regions:Default`. One of `EU` `UK` `US` `APAC` `ZA`. |
| `DEMO_SEEDER_ENABLED` | `false` | `DemoSeeder:Enabled`. Exactly `true` or `false` — `1`, `yes` and `on` are not accepted. |

## Email is not configured here

TMS reads its mail settings from the database, so they can be changed without a
redeploy or a restart. Set them in **Administration → Notifications** after your
first login. Until you do, TMS will not send email — no password resets, no
notifications. It is the most commonly missed step of a new install, so it is on
the checklist in `../docs/RUNBOOK.md`.
