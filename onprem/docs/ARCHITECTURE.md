# Architecture

For an IT or security reviewer assessing a self-hosted TMS installation. It
describes what runs, what leaves your network, and how data is protected.

---

## Shape

Everything is served from **one hostname** over HTTPS:

```
                    your users
                        │
                    HTTPS 443
                        │
              ┌─────────▼─────────┐
              │   ingress-nginx   │   TLS terminates here
              └─────────┬─────────┘
          ┌─────────────┼─────────────┐
          │             │             │
      /  │  /api      │  /auth       │
     ┌────▼───┐   ┌────▼────┐   ┌─────▼────┐
     │  web   │   │   api   │   │ keycloak │   sign-in
     └────────┘   └────┬────┘   └─────┬────┘
                       │              │
                  ┌────▼──────────────▼────┐
                  │   PostgreSQL (CNPG)    │   TLS-only
                  └────────────────────────┘
```

A single origin means the browser never makes a cross-origin request, so there
are no CORS rules to misconfigure, one DNS record, and one certificate.

| Component | Purpose | Holds data? |
|---|---|---|
| `tms-web` | The user interface | No |
| `tms-api` | Application logic | No |
| `keycloak` | Sign-in and identity | In the database |
| `tms-postgres` | PostgreSQL, managed by CloudNativePG | **Yes — everything** |
| `redis` | Carries real-time notifications between copies of the API | No; safe to lose |
| `ingress-nginx` | TLS termination and path routing | No |

---

## What leaves your network

Three things, all outbound, all initiated from your servers:

| Destination | When | Contains |
|---|---|---|
| `ghcr.io` | Install and upgrade | Nothing — downloads container images |
| Your backup location | Nightly, wherever you chose | Encrypted backups |
| Your mail server | When TMS sends notifications | Whatever those notifications say |

**There is no telemetry, no phone-home, and no remote access.** Nobody outside
your network can reach the system or see into it. The consequence — worth
understanding before handover — is that support depends on you sending a
diagnostic archive (`tmsctl support-bundle`), which is redacted before it leaves.

Inbound, only ports 80 and 443 need to be reachable, and only from wherever your
users are. Port 80 exists to redirect to 443.

---

## Data protection

**In transit.** HTTPS from the browser, terminated at the ingress with your own
certificate. Between the application and the database, TLS with certificate
verification (`verify-full`) — the database is configured to refuse any
connection that is not encrypted, so there is no silent downgrade.

**At rest.** Personal fields are encrypted in the database with AES-GCM using a
separate key per tenant. Those keys are themselves encrypted by a key ring stored
in the database, which is in turn protected by secrets held outside it — the
escrow bundle. Someone with a copy of the database alone cannot read the
protected fields.

Searching encrypted fields uses a keyed one-way index, so email lookups work
without storing anything searchable in the clear. That key is the
`BLIND_INDEX_SECRET`, and it can never be changed once data exists — which is why
it is called out repeatedly.

**Backups** are encrypted by restic before leaving the server, with a password
you hold. The backup location never sees readable data.

**Deliberately separate:** backups do not contain the secrets that unlock them.
Whoever holds your backup repository cannot read what is in it. The trade-off is
that restoring needs both, and that is stated at the top of the restore procedure.

---

## Availability

**Single server (Stage A).** No redundancy. If the server fails, TMS is down until
it is repaired or a backup is restored elsewhere. Recovery point: up to 24 hours,
or the age of the most recent backup.

**Three servers (Stage B).** Any one server can fail:

| Failure | Effect |
|---|---|
| A server holding a database standby | None |
| A server holding the database primary | A standby is promoted automatically, no data lost, users reconnect |
| The server holding the shared address | The address moves to another within seconds |
| **Two servers at once** | The system stops making changes until one returns — see RUNBOOK §4.2 |

The database survives the loss of one server with **no data loss**: a write is
only acknowledged once a second copy has it.

Two limits worth stating plainly:

- The API currently runs as a single copy. Losing the server it is on means it
  restarts elsewhere — roughly a minute — rather than continuing uninterrupted.
  Improving that is in progress upstream.
- Three servers tolerate one failure, not two. Backups, not redundancy, are what
  protect against losing a site.

---

## Access and accounts

Sign-in is handled by Keycloak. TMS itself issues short-lived tokens (15 minutes)
that refresh in the background, so a stolen token has a narrow window.

**There are no default accounts.** The first administrator is created through a
setup page on first visit, so there is nothing shipped to change and nothing to
forget to change.

Permissions are checked per action rather than by role name, so roles can be
adjusted without code changes.

Every change to a ticket, user or configuration is recorded in an audit trail
held in the same database, and covered by the same backups.

---

## Multi-tenancy

One installation can serve several client organisations. Records carry the
organisation they belong to, and every query is filtered by it automatically.

The filter is **fail-closed**: when no organisation can be determined, queries
return nothing rather than everything. Encryption keys are per-organisation, so
even a query that escaped the filter would return unreadable data.

---

## What this installation assumes of you

| | |
|---|---|
| Certificate | You supply and renew it. Nothing here obtains one automatically. |
| Backup location | You supply it. Install refuses to complete without one. |
| Mail server | You supply it. Set under Administration → Notifications after install. |
| DNS | One record pointing at the server, or at the shared address on three. |
| Secrets custody | The escrow bundle and passphrase live in your password manager. |
| Operating system patching | Ordinary Linux maintenance; TMS is unaffected by reboots. |

---

## Versions

`manifest.lock`, shipped with each release, records the exact version of every
component down to the image digest. It answers "what is actually running" without
inspecting the system, which is usually the first question in an audit.
