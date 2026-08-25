# Backups — setup, drills, and disaster recovery

Routine backup and restore commands are in `RUNBOOK.md` §6. This covers the
things you do rarely: choosing and configuring a backup location, proving it
works, and rebuilding from nothing.

---

## Choosing where backups go

The only hard requirement is that it is **not these servers**. A backup on the
machine it is protecting is not a backup.

| Option | Set `BACKUP_REPOSITORY` to | Notes |
|---|---|---|
| SFTP to another server | `sftp:user@backup.example.internal:/srv/tms` | Simplest if you already have one. Uses SSH keys — no password in configuration. |
| A mounted network share | `/mnt/backup/tms` | Mount it on every server, at the same path, before installing. Check it survives a reboot. |
| S3-compatible storage | `s3:https://s3.example.internal/tms-backups` | Needs credentials — see below. |

### SFTP

Create a key on each TMS server and authorise it on the backup server:

```sh
sudo ssh-keygen -t ed25519 -f /root/.ssh/tms_backup -N ''
sudo ssh-copy-id -i /root/.ssh/tms_backup backupuser@backup.example.internal
```

Confirm it works non-interactively before installing — the backup job cannot
answer a prompt:

```sh
sudo ssh -i /root/.ssh/tms_backup backupuser@backup.example.internal true && echo ok
```

### S3-compatible

```
BACKUP_REPOSITORY=s3:https://s3.example.internal/tms-backups
BACKUP_ENV_EXTRA=AWS_ACCESS_KEY_ID=...,AWS_SECRET_ACCESS_KEY=...
```

Use credentials that can write and read that bucket and nothing else.

### A network share

Mount it on every server at the same path. If the mount is missing when the job
runs, the backup fails — which is at least loud. Worse is a share that silently
mounts empty, so check after a reboot that files written before it are still
visible.

---

## How much space

Each night stores only what changed, so a year of daily backups is typically two
to three times the size of the data itself rather than 365 times.

Retention defaults to 14 daily, 4 weekly and 6 monthly — about six months of
history. Adjust in `.env` if your policy differs.

---

## Two things that must be true

**1. The backup password is stored somewhere else.**

Backups are encrypted before leaving the server. `BACKUP_PASSWORD` is the only
thing that can read them. Lose it and every backup you hold is permanently
unreadable — there is no recovery path and no support route around it.

**2. So is the secrets escrow.**

Backups deliberately do **not** contain the secrets that unlock the data inside
them, so whoever holds your backup repository cannot read it. The consequence is
that restoring needs both halves.

Both belong in your organisation's password manager. Not on these servers.

---

## Quarterly restore drill

An untested backup is a hope. Do this on a spare machine, four times a year, and
write down what happened.

| | Step | Record |
|---|---|---|
| 1 | Install TMS on a test server at the same version | |
| 2 | Restore the most recent backup (RUNBOOK §6.3) | Time taken |
| 3 | `tmsctl verify-recovery` | Pass / fail |
| 4 | Log in as a real user | Worked? |
| 5 | Open a ticket you recognise | Data correct? |
| 6 | Download an attachment from it | Worked? |
| 7 | Check the ticket's history is present | |

**Step 4 is the one that catches the expensive mistake.** If login fails, the
database was restored without its original `BLIND_INDEX_SECRET` — see RUNBOOK
§6.5. If login works but ticket text comes back as gibberish, it is the
DataProtection certificate instead — RUNBOOK §6.4. Far better to discover either
during a drill than during an incident.

The time from step 2 to step 6 is your honest recovery time. If it is longer than
your organisation assumes, that gap is worth raising before anyone needs it.

---

## Rebuilding from nothing

If all the servers are gone — a site loss, or hardware that is not coming back:

**You need:** the backup repository and its password, the secrets escrow bundle
and its passphrase, the release tarball at the version you were running, a
certificate for the hostname, and replacement servers.

**Missing the escrow or the backup password?** Stop. The data cannot be recovered
without them, and the time is better spent finding them than rebuilding something
that will not open.

1. Build the servers and install the operating system.
2. Point DNS at the new address, or keep the old one and re-point it later.
3. Restore the secrets from the escrow bundle into `.env`.
4. Install TMS with the same hostname and settings.
5. Restore the most recent backup (RUNBOOK §6.3).
6. `tmsctl verify-recovery`.
7. Log in and check real data before telling anyone it is back.

Use the **same version** you were running. Restoring into a newer version may
work, but recovery day is not the moment to find out — upgrade afterwards, once
the data is confirmed good.

---

## When a backup fails

`tmsctl status` shows `Backups CRITICAL` after 36 hours without a success.

```sh
tmsctl logs backup
```

| Message mentions | Usually |
|---|---|
| no space | The backup location is full. Old backups are pruned automatically, so this normally means the retention policy is too generous for the space available. |
| permission / denied | Credentials changed, or a key was rotated on the backup server. |
| connection / timeout | The backup location is unreachable — network, or it is down. |
| repository / lock | A previous run was interrupted. It usually clears itself; if not, that is worth reporting. |

Treat it the same day. The failure that matters is not one missed night — it is
the fortnight of missed nights nobody noticed, which is exactly why this goes
straight to CRITICAL rather than sitting amber.
