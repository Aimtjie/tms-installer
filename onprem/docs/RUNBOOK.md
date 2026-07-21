# TMS operations runbook

For whoever is looking after a self-hosted TMS installation.

You do not need to know Kubernetes. Everything here is a `tmsctl` command or a
short sequence of them. If a procedure ever needs you to reach past `tmsctl` to
`kubectl`, that is a gap worth reporting.

**Keep a copy of this file on the server.** It is also in `docs/` next to
`tmsctl`, which matters on the day the problem is the network.

---

## 1. The one command to remember

```sh
tmsctl status
```

Run it when something feels wrong, and once a week when nothing does. It answers
in plain language, and anything unhealthy tells you which section below to open.

```
Application     HEALTHY    tms-api 1/1, tms-web 1/1, keycloak 1/1
Database        HEALTHY    3/3 primary=tms-postgres-1
Backups         HEALTHY    last successful 4h ago
Servers         HEALTHY    3/3 ready
Certificate     HEALTHY    expires in 214 days (2027-02-19)
Real-time       HEALTHY    live updates flowing
```

---

## 2. Things worth doing before anything goes wrong

| When | What | Why |
|---|---|---|
| Now | Put the certificate expiry date in a shared calendar, 30 days ahead | Nothing renews it for you. Expiry is a total outage. |
| Now | Confirm the secrets escrow file **and** its passphrase are in your password manager | Without them a backup cannot be restored. See §8. |
| Weekly | `tmsctl status` | Catches a stopped backup before it matters |
| Quarterly | A practice restore (§6.5) | An untested backup is a hope, not a backup |

---

## 3. Everyday tasks

**Look at what a component is doing**

```sh
tmsctl logs api          # or: web, auth, db, ingress
tmsctl logs api -f       # keep following
```

**Take a backup right now** — before any change you are unsure about:

```sh
tmsctl backup now
tmsctl backup list
```

**Collect diagnostics to send to your supplier**

```sh
tmsctl support-bundle
```

Writes one archive with logs, component status and version information.
Passwords and tokens are removed. Nobody can see into your system from outside,
so this archive is how anyone helps you — it is usually the fastest route to an
answer, and often the only one.

---

## 4. Something is broken

### 4.1 One server is down

`tmsctl status` shows `Servers DEGRADED 2/3 ready`.

**Users are not affected.** The system is designed for this. Work through it in
order, and do not rush.

1. **Do not shut down or reboot any other server.** Losing a second one is a
   different and much worse situation — see §4.2.
2. If the server is coming back — someone is rebooting it, or a power supply is
   being replaced — just wait. It rejoins by itself. Confirm with `tmsctl status`.
3. If it is gone for good, replace it:
   ```sh
   tmsctl node list                  # confirm which one
   sudo ./k3s/bootstrap.sh --join <token> --server https://<a-working-server>:6443
   ```
   Run that on the replacement machine. Get the token from a working server:
   ```sh
   sudo cat /var/lib/rancher/k3s/server/node-token
   ```
4. Watch it come back: `tmsctl status` until Servers reads 3/3.

If the failed server was running the database primary, a standby was already
promoted automatically — probably before you noticed. `tmsctl status` names the
current primary.

### 4.2 Two servers are down

This is the serious one.

Three servers agree on decisions by majority. With only one left there is no
majority, so the system stops making changes — no failover, no restarts, no
deployments. Whatever is still running keeps running, but nothing recovers.

1. **Get one of the two failed servers back.** That restores the majority and
   everything resumes on its own. This is by far the best outcome and is worth
   real effort before trying anything below.
2. If both are genuinely unrecoverable, the surviving server can be told to
   continue alone:
   ```sh
   sudo systemctl stop k3s
   sudo k3s server --cluster-reset
   sudo systemctl start k3s
   tmsctl status
   ```
   Then rebuild the other two with `--join` as in §4.1.

⚠️ Only do step 2 when you are certain the other two are not coming back. If one
of them later starts up still believing it is part of the old cluster, you can
end up with two halves that disagree about the data.

### 4.3 The website will not load

Work outwards from the application.

```sh
tmsctl status
```

| What it says | What to do |
|---|---|
| `Application CRITICAL` | `tmsctl logs api` and `tmsctl logs web` |
| `Database CRITICAL` | §5 |
| `Certificate CRITICAL` | Expired — §7 |
| Everything HEALTHY | The problem is outside TMS: DNS, the network, or a firewall between your users and these servers |

If the browser complains about the certificate rather than failing to connect,
go to §7 — the system is running.

### 4.4 It is slow

```sh
tmsctl status
tmsctl logs api | tail -50
```

Most commonly:

- **A server is down** and the rest are carrying the load. §4.1.
- **The disk is full.** `df -h` on each server. Backups staging, container images
  and the database all compete for the same space. Old images can be cleared
  safely; never delete anything under `/var/lib/rancher` by hand.
- **The database is busy** — usually a large import or report. It normally
  finishes on its own.

### 4.5 Nobody can log in

```sh
tmsctl logs auth | tail -50
```

If the log mentions the database, treat it as §5 — sign-in keeps its data there.

⚠️ **If this started right after restoring a backup**, stop and read §6.4. Almost
always it means the database was restored without its matching secrets, and there
is a correct way to recover that does not involve trying things.

---

## 5. Database problems

`tmsctl status` shows `Database` as anything but HEALTHY.

**DEGRADED** — one copy is missing, the rest are serving. Usually a server is
down (§4.1). It repairs itself when the server returns. No action needed.

**CRITICAL** — no copy is ready. Users cannot work.

```sh
tmsctl logs db | tail -80
```

Two common causes:

- **Disk full.** `df -h` on the servers. Free space and the database recovers on
  its own.
- **The server holding the only copy is down.** On a single-server installation
  this is expected — recovery is a restore (§6.3).

Do not delete database storage to reclaim space. That is the one action that can
turn a recoverable problem into data loss.

---

## 6. Backups and restoring

### 6.1 What is backed up

Every night at 02:00 UTC: all tickets and their history, all users and sign-in
configuration, and attachments when stored on a local volume — pushed to the
off-site location configured at install.

**Not included: your secrets.** They are in the escrow bundle you were told to
store at install (§8). That separation is deliberate: whoever holds the backups
cannot read the data in them.

**Both halves are needed to restore.** A backup without the escrow is unreadable.

### 6.2 Checking backups are working

```sh
tmsctl status         # the Backups line
tmsctl backup list
```

`Backups CRITICAL` means none has succeeded in over 36 hours. Investigate the
same day: `tmsctl logs backup`. Usually the off-site location has filled up,
changed its password, or become unreachable.

A separate check runs weekly and re-reads every backup to prove it is genuinely
restorable, rather than merely present.

### 6.3 Restoring

⚠️ **Read this box first.**
>
> Restoring replaces all current data. Anything created since the backup is lost.
>
> You need **both** the backup **and** the secrets escrow bundle with its
> passphrase. Restoring the database without the matching secrets leaves the data
> unreadable — not corrupted, just permanently opaque. There is no recovery from
> that other than finding the original secrets.
>
> If you do not have the escrow bundle and passphrase, **stop and find them
> before touching anything.**

1. **Secrets first.** Decrypt the escrow bundle:
   ```sh
   openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in tms-secrets-escrow.enc
   ```
   Put those values into `.env`.

2. **Choose the backup:**
   ```sh
   tmsctl backup list
   ```

3. **Restore:**
   ```sh
   tmsctl restore <snapshot-id>
   ```
   You will be asked to type the hostname to confirm. That is on purpose.

4. **Verify** — always, not only when something looks wrong:
   ```sh
   tmsctl verify-recovery
   ```

5. Log in and check a ticket you recognise, including an attachment.

### 6.4 Restored, but nobody can log in

This almost always means the database was restored with different secrets than it
was created with — specifically `BLIND_INDEX_SECRET`.

That value scrambles email addresses into a searchable form. If it changes, the
system cannot find any existing user, so every login fails even though the data
is intact.

**Fix:** put the original `BLIND_INDEX_SECRET` from the escrow bundle into `.env`
and re-run the installer. Nothing is lost — the data was never damaged.

**If the original is genuinely gone**, the accounts cannot be recovered. Tickets
and history are still readable, but users must be recreated. This is the single
reason the installer refuses to finish until you confirm the escrow is stored.

### 6.5 Practice restore (quarterly)

Do this on a spare machine, not the live one.

1. Install TMS on a test server with the same version.
2. Restore last night's backup into it.
3. Run `tmsctl verify-recovery`.
4. Log in; open a ticket; download an attachment.
5. Write down how long it took. That number is your honest recovery time.

If any step surprises you, that is exactly what the exercise is for — much better
found now than during an incident.

---

## 7. Certificates

Nothing renews the certificate for you. `tmsctl status` warns at 30 days and
turns critical at 7.

```sh
tmsctl cert replace /path/to/fullchain.pem /path/to/privkey.pem
```

It checks the certificate and key are a matching pair and that the certificate
covers your hostname **before** installing anything — a mismatched pair would
take the site down the moment it was applied.

Use the **fullchain** file, the one including intermediates. A certificate
without them often works in the browser you test with, because it already has
the intermediate cached, and fails for everyone else.

No restart or downtime; the change takes effect within seconds.

---

## 8. Secrets

At install you were given an encrypted file and a passphrase shown once.

**Both belong in your organisation's password manager**, not on these servers.
A copy that dies with the cluster protects nothing.

To re-write the file:

```sh
tmsctl secret export
```

**What can be changed**

| Secret | Changeable | Effect |
|---|---|---|
| `JWT_SECRET` | Yes | Everyone is signed out and logs in again |
| `KEYCLOAK_ADMIN_PASSWORD` | Yes | None for users |
| `POSTGRES_PASSWORD` | Yes | Brief interruption |
| `BACKUP_PASSWORD` | Only for future backups | Existing backups still need the old one — keep it |
| **`BLIND_INDEX_SECRET`** | **No — ever** | Every user becomes unfindable, login stops working, no way back |

`tmsctl` refuses to change the last one rather than warning about it.

---

## 9. Upgrading

See `UPGRADE.md`. Briefly: a backup is taken first, the new version is applied,
and if it does not come up healthy it rolls back on its own.

---

## 10. Getting help

Nobody can see into your installation. Run:

```sh
tmsctl support-bundle
```

and send the archive, along with:

- what you were doing when it happened
- what `tmsctl status` says
- what changed recently — an upgrade, a certificate, a network change, a reboot

That is usually enough to get an answer without a call.
