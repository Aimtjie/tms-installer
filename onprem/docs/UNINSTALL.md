# Removing TMS

For when you want to take TMS off a server — to reinstall it cleanly, or to give
the machine back.

Unlike the rest of the runbook, this procedure reaches past `tmsctl` to `kubectl`
and a few file deletions. There is no `tmsctl uninstall` yet (tracked as a gap),
so the steps are written out in full. Follow them in order.

---

## Read this first

Removing TMS destroys two things you cannot get back:

- **Your data** — the database and any uploaded attachments. They live on this
  server and nowhere else unless you have a backup.
- **Your secrets** — in particular the blind-index secret, which can never be
  regenerated. A backup restored without it leaves every user unfindable and
  login impossible.

If this is a test server you are wiping on purpose, that is all fine — read on.

**If there is any chance you want the data back**, do both of these *before* you
delete anything:

```sh
tmsctl backup now          # take a fresh backup
tmsctl backup list         # confirm it is there
```

and confirm the secrets escrow file **and** its passphrase are in your password
manager — the file is `tms-secrets-escrow.enc` in your **install directory**
(the folder you ran `bootstrap.sh` from, containing the `tmsctl` script and the
`k3s/` folder — *not* the `/usr/local/bin/tmsctl` command on your PATH). Without
both, a backup cannot be restored. Once the steps below run, the data on this
server is gone.

**Run every command below from that install directory.** Several steps delete
files by their name alone, and `rm` from the wrong place fails silently — you
would think a secret was removed when it was not. Change into it first:

```sh
cd /path/to/your/install-directory      # the folder containing tmsctl and k3s/
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```

Every `kubectl` command below also needs `sudo` — the cluster configuration is
readable only by root on purpose.

---

## Which of the two do you want?

| | Reinstall the app | Give the server back |
|---|---|---|
| Removes TMS and its data | Yes | Yes |
| Removes k3s and everything under it | **No — kept** | **Yes — all of it** |
| Good for | putting a fresh TMS on the *same* machine | returning the machine to bare OS |
| Which section | **A** below | **B** below |

If you are not sure, **B** is the cleaner choice — it leaves nothing behind and
is the closest thing to a machine that never had TMS on it.

---

## A. Reinstall the app on the same server

This removes TMS but keeps k3s (the cluster) and its supporting parts, so a fresh
install is quick. The installer notices they are already there and skips them.

**1. Remove TMS.** This deletes the application, its settings, and its storage:

```sh
sudo kubectl delete namespace tms --wait=true
```

**2. Confirm the storage was actually reclaimed.** This is the one step that
bites if skipped. Deleting TMS *should* delete the disk space its database used —
but if a leftover piece lingers, a fresh install will find the old database with
the old password and fail to start in a way that looks like a database fault.

```sh
sudo kubectl get pv | grep -E 'tms-postgres|tms-attachments' || echo "clean — nothing left"
```

If that prints "clean", you are done — skip to step 3. If any rows remain, each
one names a folder still on disk. Ask the leftover volume where that folder is
rather than guessing — the location depends on how storage was configured:

```sh
sudo kubectl describe pv <name-from-above> | grep -i path   # shows the folder on disk
sudo kubectl delete pv <name-from-above> --wait=false
sudo rm -rf <the-exact-path-that-describe-printed>
```

(On a default k3s install that path is under `/var/lib/rancher/k3s/storage/`, but
trust what `describe` shows over that assumption.)

**3. (Optional) Start completely fresh.** If you want a brand-new set of
passwords rather than reusing the old ones, remove the escrow file and blank the
generated lines in `.env`:

```sh
sudo rm -f tms-secrets-escrow.enc
```

Then edit `.env` and empty the values after `POSTGRES_PASSWORD=`,
`KEYCLOAK_ADMIN_PASSWORD=` and `SSO_CLIENT_SECRET=` (the installer regenerates any
that are blank). Skip this step to keep the same passwords.

**4. Reinstall:**

```sh
sudo ./k3s/bootstrap.sh
```

---

## B. Give the server back (remove everything)

This removes the whole cluster in one command, and with it every trace of TMS,
its database, and its attachments. Nothing survives — which is exactly what makes
it a clean slate.

**1. (Only if you might want the data) take a final backup** — see *Read this
first* above.

**2. Remove k3s and everything it holds:**

```sh
sudo /usr/local/bin/k3s-uninstall.sh
```

This stops the services, removes the cluster, and deletes the storage — including
the TMS database and attachments — because they all live inside k3s. When it
finishes, the command itself is gone too; running it again says "not found",
which is expected.

**3. Remove the TMS files that live outside k3s.** Run these from your install
directory (see *Read this first*). This includes `.env` and the escrow — on a
machine you are handing to someone else, leaving them behind hands over your
secrets: `.env` holds the backup-encryption password (and the signing and
blind-index secrets if you set them by hand) in plain text, and the escrow wraps
every one of them.

```sh
sudo rm -f  .env                         # your config — contains secrets in plain text
sudo rm -f  tms-secrets-escrow.enc       # the secrets escrow (irreversible)
sudo rm -f  /usr/local/bin/tmsctl        # the tmsctl command
sudo rm -rf /etc/tms                     # your TLS certificate and key
sudo rm -f  tms-support-*.tar.gz         # any diagnostic bundles
```

**4. To install again from scratch** (if you are reusing the machine), re-create
a certificate first — see *Generating a certificate for testing* in
`../k3s/README.md` — then:

```sh
sudo ./k3s/bootstrap.sh
```

---

## Why the two paths differ

Deleting the `tms` namespace (path A) removes the application but leaves k3s,
CloudNativePG and the ingress controller running, along with some cluster-wide
pieces a namespace delete does not touch. That is fine for a reinstall — the
installer reuses them — but it is not a clean machine. The k3s uninstaller (path
B) removes the cluster wholesale, so there is nothing left to reconcile and no
leftover storage to trip over. When in doubt, prefer B.
