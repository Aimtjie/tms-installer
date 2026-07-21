# Upgrading

Upgrades are something you choose to do, not something that happens to you.
Nothing here updates itself — no agent watches for new versions, and no version
changes without someone running a command.

That is deliberate. An automatic updater that breaks at two in the morning, at a
site nobody can reach, is worse than being a few weeks behind.

---

## Check what you are running

```sh
tmsctl version
tmsctl update --check
```

Releases are listed at:
<https://github.com/Aimtjie/Ticket-Management-System/releases>

---

## Before you upgrade

| | |
|---|---|
| Read the release notes | Particularly anything marked **breaking** |
| `tmsctl status` | Upgrading a system that is already unhealthy makes diagnosis harder |
| `tmsctl backup now` | The upgrade does this too, but a backup you took yourself is one you know about |
| Pick a quiet time | Users see a brief interruption on a single server; none on three |

---

## Upgrading

```sh
tmsctl update ./tms-onprem-<version>.tar.gz
```

What it does, in order:

1. Checks the download is intact.
2. Shows you what will change, and waits.
3. Runs the preflight checks.
4. **Takes a backup**, and stops if that fails.
5. Applies the new version, one component at a time.
6. Waits for each to report healthy.
7. **Rolls back automatically** if anything does not come up.

Step 7 is why this is a single command rather than a sequence you assemble. A
half-applied upgrade is the state that is hardest to get out of, so it is the one
state the tool will not leave you in.

---

## Afterwards

```sh
tmsctl status
```

Then log in and do something ordinary — open a ticket, add a comment, download an
attachment. Automated checks confirm the software started; only a person can
confirm it works.

---

## If it goes wrong

The rollback is automatic, so by the time you are reading an error the previous
version is usually already back. Confirm with `tmsctl status`.

If you are left somewhere unclear:

```sh
tmsctl support-bundle
```

and send the archive with the version you came from and the one you were going
to. Do not attempt a second upgrade to escape a failed one — that turns a known
state into an unknown one.

---

## Skipping versions

Going up several versions at once is supported, but each release's notes still
apply. If any of the ones you are skipping mentions a manual step, it does not
stop being necessary because you jumped over it.

If you are more than a year behind, upgrade in a couple of steps rather than one,
and take a backup between them.

---

## Downgrading

Not supported. A newer version may have changed how data is stored, and older
software will not understand it.

To go back, restore a backup taken before the upgrade — see RUNBOOK §6.3. This is
another reason step 4 exists.
