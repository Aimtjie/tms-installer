#!/bin/sh
# Install TMS onto this server, or join it to an existing cluster.
#
#   ./bootstrap.sh              first server
#   ./bootstrap.sh --join TOKEN additional server (Stage B only)
#   ./bootstrap.sh --stage b    build the first server as a clustered node
#
# Safe to re-run: every step checks whether it has already been done. If it stops
# partway, fix what it complained about and run it again.

set -eu

BS_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMS_ROOT=$BS_ROOT
TMS_ENV_FILE=${TMS_ENV_FILE:-$BS_ROOT/.env}
TMS_KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export TMS_ROOT TMS_ENV_FILE TMS_KUBECONFIG

# shellcheck source=../lib/common.sh
. "$BS_ROOT/lib/common.sh"

BS_STAGE=a
BS_JOIN_TOKEN=''
BS_SERVER_URL=''

while [ $# -gt 0 ]; do
    case "$1" in
        --join)   [ $# -ge 2 ] || die "--join needs the token printed by the first server"
                  BS_JOIN_TOKEN=$2; shift ;;
        --server) [ $# -ge 2 ] || die "--server needs a URL"
                  BS_SERVER_URL=$2; shift ;;
        --stage)  [ $# -ge 2 ] || die "--stage needs a or b"
                  BS_STAGE=$2; shift ;;
        -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

[ "$(id -u)" = 0 ] || die "Run this with sudo — it installs system services."

TMS_NAMESPACE=$(env_get K8S_NAMESPACE tms)
export TMS_NAMESPACE

# ── 1. preflight ────────────────────────────────────────────────────
say ''
say "${C_BOLD}Step 1 — checking this machine${C_OFF}"
if [ "$BS_STAGE" = b ]; then
    "$BS_ROOT/common/preflight.sh" --ha --env "$TMS_ENV_FILE" \
        || die "Preflight failed. Fix the items marked FAIL and run this again."
else
    "$BS_ROOT/common/preflight.sh" --env "$TMS_ENV_FILE" \
        || die "Preflight failed. Fix the items marked FAIL and run this again."
fi

# ── 2. required settings ────────────────────────────────────────────
say ''
say "${C_BOLD}Step 2 — checking configuration${C_OFF}"

BS_HOSTNAME=$(require_env TMS_HOSTNAME)
BS_CERT=$(require_env TLS_CERT_FILE)
BS_KEY=$(require_env TLS_KEY_FILE)
[ -r "$BS_CERT" ] || die "Cannot read the certificate at $BS_CERT"
[ -r "$BS_KEY" ]  || die "Cannot read the private key at $BS_KEY"

# An installation with no off-site backup is not something anyone should be
# handed. Refusing here is kinder than discovering it during an incident.
BS_BACKUP_REPO=$(env_get BACKUP_REPOSITORY)
[ -n "$BS_BACKUP_REPO" ] || die "BACKUP_REPOSITORY is not set in $TMS_ENV_FILE.

Install will not complete without somewhere off this machine to send backups.
An SFTP server, a mounted network share, or S3-compatible storage all work.
See common/CONFIG.md."

# Only values this target actually IMPLEMENTS are accepted. Everything else is
# refused rather than allowed through, because the application treats any
# unrecognised provider as local — so a value we accept but do not wire up would
# silently store attachments somewhere the operator did not choose, and they
# would find out at a restore (#1224).
BS_STORAGE=$(env_get STORAGE_PROVIDER local)
case "$BS_STORAGE" in
    local) ;;
    s3) die "STORAGE_PROVIDER=s3 is not wired up on the k3s target yet.

The setting is read, but nothing applies it: the deployment hardcodes local
storage, and the STORAGE_S3_* values are not passed to the application. Accepting
it would leave your attachments on a local disk while you believed they were on
object storage.

Use local for now. Attachments are included in the nightly backup either way." ;;
    postgres) die "STORAGE_PROVIDER=postgres is not available in this version.

Use local. This is refused rather than accepted because the application treats
any unrecognised value as 'local', so your attachments would end up somewhere you
did not choose." ;;
    *) die "STORAGE_PROVIDER='$BS_STORAGE' is not a recognised value. Use local." ;;
esac

if [ "$BS_STORAGE" = local ]; then
    say ''
    say '  Attachments will be stored on a volume on this server, and ARE included'
    say '  in the nightly backup alongside the database — the backup job mounts them'
    say '  and pushes them to your off-box repository with everything else.'
    say ''
    say '  Note for later: that volume lives on ONE server. Growing to three servers'
    say '  needs storage every server can reach — see k3s/README.md.'
fi

# ── 3. k3s ──────────────────────────────────────────────────────────
say ''
say "${C_BOLD}Step 3 — installing k3s${C_OFF}"

if [ -n "$BS_JOIN_TOKEN" ]; then
    [ -n "$BS_SERVER_URL" ] || die "--join also needs --server https://<first-server>:6443"
    if [ -x /usr/local/bin/k3s ]; then
        say '  already installed, skipping'
    else
        curl -fsSL https://get.k3s.io | \
            K3S_TOKEN="$BS_JOIN_TOKEN" K3S_URL="$BS_SERVER_URL" sh -s - \
            --disable=traefik --disable=servicelb --write-kubeconfig-mode=600
    fi
    say ''
    say 'Joined. Check from the first server with: tmsctl node list'
    exit 0
fi

if [ -x /usr/local/bin/k3s ]; then
    say '  already installed, skipping'
else
    # --secrets-encryption MUST be set at first start; it cannot be added to an
    # existing cluster without re-keying, so it is not optional here.
    #
    # --write-kubeconfig-mode=600, not 644. This is a client's server.
    #
    # Image garbage collection is pulled well below the default because a 15 GB
    # disk fills faster than the default thresholds expect.
    BS_K3S_ARGS="--disable=traefik --disable=servicelb --secrets-encryption \
--write-kubeconfig-mode=600 --tls-san=$BS_HOSTNAME \
--kubelet-arg=image-gc-high-threshold=70 --kubelet-arg=image-gc-low-threshold=60"

    # Stage A stays on the embedded SQLite store: it saves 1-2 GB of disk and
    # avoids competing with PostgreSQL for disk writes, both of which matter on
    # a small server. The trade is that this node cannot later be joined to —
    # growing to three servers means a rebuild and a restore.
    [ "$BS_STAGE" = b ] && BS_K3S_ARGS="$BS_K3S_ARGS --cluster-init"

    # shellcheck disable=SC2086  # word splitting is intended for the argument list
    curl -fsSL https://get.k3s.io | sh -s - $BS_K3S_ARGS
fi

say '  waiting for the cluster to come up ...'
BS_TRIES=0
until k_global get nodes >/dev/null 2>&1; do
    BS_TRIES=$((BS_TRIES + 1))
    [ "$BS_TRIES" -lt 60 ] || die "k3s did not become ready. Check: journalctl -u k3s"
    sleep 5
done
say '  ready'

# ── 4. supporting components ────────────────────────────────────────
say ''
say "${C_BOLD}Step 4 — installing supporting components${C_OFF}"

k_global create namespace "$TMS_NAMESPACE" --dry-run=client -o yaml | k_global apply -f - >/dev/null

if k_global get deployment -n cnpg-system cnpg-controller-manager >/dev/null 2>&1; then
    say '  CloudNativePG already present'
else
    say '  CloudNativePG (manages PostgreSQL and its failover)'
    k_global apply --server-side -f \
        "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.25/releases/cnpg-1.25.0.yaml" >/dev/null
    k_global wait --for=condition=Available --timeout=300s \
        -n cnpg-system deployment/cnpg-controller-manager >/dev/null
fi

if k_global get deployment -n ingress-nginx ingress-nginx-controller >/dev/null 2>&1; then
    say '  ingress-nginx already present'
else
    say '  ingress-nginx (terminates TLS, routes by path)'
    k_global apply -f \
        "https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/baremetal/deploy.yaml" >/dev/null

    # The upstream baremetal manifest publishes the controller through a NodePort
    # Service, which listens somewhere in 30000-32767. Without the patch below
    # NOTHING binds 80 or 443, so https://<hostname>/ does not connect even though
    # every pod is healthy and every other check passes (#1218).
    #
    # hostNetwork puts the controller straight onto the node's own ports instead.
    # dnsPolicy has to move with it: a hostNetwork pod otherwise inherits the
    # node's resolver and cannot resolve cluster service names, so the ingress
    # would come up unable to reach tms-web or keycloak.
    #
    # NOTE for Stage B: with more than one server this must become a DaemonSet.
    # A hostNetwork Deployment with several replicas can have two pods scheduled
    # onto one node, where the second gets stuck Pending on the port conflict.
    k_global -n ingress-nginx patch deployment ingress-nginx-controller --type merge -p \
        '{"spec":{"template":{"spec":{"hostNetwork":true,"dnsPolicy":"ClusterFirstWithHostNet"}}}}' >/dev/null

    # `wait --for=condition=Available` is satisfied by the PRE-patch ReplicaSet, so
    # it returns while the rollout the patch above just triggered is still
    # replacing the pod. `rollout status` tracks THIS rollout instead.
    k_global -n ingress-nginx rollout status deployment/ingress-nginx-controller \
        --timeout=300s >/dev/null 2>&1 \
        || warn 'ingress-nginx is taking longer than expected. Check: tmsctl logs ingress'

    # Step 8 creates an Ingress, and the API server validates it by CALLING
    # ingress-nginx's admission webhook. Until a controller pod is Ready that
    # webhook Service has no endpoints, and the apply dies with "no endpoints
    # available for service ingress-nginx-controller-admission" — leaving an
    # install where every pod is healthy and nothing can reach it (#1238).
    #
    # Only reachable on a fast unattended run: a human re-running the installer
    # hands the rollout the seconds it needs, which is precisely why this survived
    # the first manual install and appeared the moment the whole thing was
    # scripted — the way a client would actually run it.
    k_global -n ingress-nginx wait --for=condition=Ready pod \
        -l app.kubernetes.io/component=controller --timeout=300s >/dev/null 2>&1 \
        || warn 'ingress-nginx admission webhook is not ready; the Ingress may fail to apply.'
fi

# ── 5. secrets ──────────────────────────────────────────────────────
say ''
say "${C_BOLD}Step 5 — generating secrets${C_OFF}"

gen() { openssl rand -base64 48 | tr -d '\n'; }

if k -n "$TMS_NAMESPACE" get secret tms-secrets >/dev/null 2>&1; then
    say '  already generated, keeping the existing values'
    BS_NEW_SECRETS=0

    # Recover the database password from the connection string we stored last
    # time. Step 8 renders __POSTGRES_PASSWORD__ into the tms-postgres-app Secret
    # on EVERY run, so without this a re-run overwrites the real credential with
    # a placeholder (#1223): Keycloak reads its database password from that
    # Secret and stops being able to sign anyone in, while the API — whose
    # connection string lives here in tms-secrets and is untouched — keeps
    # working. A confusing half-failure, and reachable on the documented path,
    # since this script tells you to fix what it complained about and run it
    # again.
    BS_PGPW=$(k get secret tms-secrets -o jsonpath='{.data.ConnectionStrings__ticketdb}' 2>/dev/null \
              | base64 -d 2>/dev/null \
              | sed -n 's/.*[;[:space:]]Password=\([^;]*\).*/\1/p' || true)

    [ -n "$BS_PGPW" ] || die "Could not recover the database password from the existing
tms-secrets Secret in namespace $TMS_NAMESPACE.

Install stopped rather than continue: the next step would have written a
placeholder password into tms-postgres-app, and Keycloak would then be unable to
reach its database.

If this installation is not one you want to keep, delete the namespace and start
over. If it is, restore the password from your secrets escrow bundle."

    # Back-fill the tms-sso client secret on an install that predates it (#1267).
    # Add-only — never rotate an existing value, just supply the key when it is
    # missing, so re-running bootstrap heals an older install instead of leaving the
    # operator to patch it by hand. Regenerable plumbing (the API re-pushes it to
    # Keycloak at startup), so minting a fresh one here is safe.
    if ! k get secret tms-secrets -o jsonpath='{.data.Sso__Keycloak__ClientSecret}' 2>/dev/null | grep -q .; then
        k patch secret tms-secrets --type merge \
            -p "{\"stringData\":{\"Sso__Keycloak__ClientSecret\":\"$(gen)\"}}" >/dev/null
        say '  added the missing tms-sso client secret'
    fi
else
    BS_NEW_SECRETS=1
    BS_JWT=$(env_get JWT_SECRET);            [ -n "$BS_JWT" ] || BS_JWT=$(gen)
    BS_BLIND=$(env_get BLIND_INDEX_SECRET)
    if [ -z "$BS_BLIND" ]; then
        BS_BLIND=$(gen)
        # Guard the irreversible action itself, not only preflight's advisory note (#1279 review).
        # BLIND_INDEX_SECRET can never be changed: a generated one is correct for a NEW install but
        # makes a RESTORE permanently unreadable. Warn where it is actually minted, so it cannot
        # scroll past unseen the way a preflight line can — this is the last point a restoring
        # operator can still stop before the fresh key is written.
        warn "Generated a NEW BLIND_INDEX_SECRET — correct for a fresh install.
  If you are RESTORING a backup, STOP now: put the ORIGINAL value in $TMS_ENV_FILE
  first, or the restored data will be permanently unreadable."
    fi
    BS_PGPW=$(env_get POSTGRES_PASSWORD);    [ -n "$BS_PGPW" ] || BS_PGPW=$(gen)
    BS_KCPW=$(env_get KEYCLOAK_ADMIN_PASSWORD); [ -n "$BS_KCPW" ] || BS_KCPW=$(gen)
    BS_REDISPW=$(gen)
    # The secret shared between the API and the tms-sso Keycloak client. The realm ships a
    # placeholder the API overwrites at startup (EnsureSsoClientAsync), and the SSO callback
    # authenticates the token exchange with it — so without it every Microsoft Entra sign-in
    # fails at the callback while the pod stays healthy (#1267). Generated unconditionally: the
    # sign-in button is gated by per-tenant IdP config, not by this value, so this is pure
    # plumbing that must always be present. Honour an operator-supplied value, else mint one.
    BS_SSO=$(env_get SSO_CLIENT_SECRET);     [ -n "$BS_SSO" ] || BS_SSO=$(gen)

    # verify-full against the CNPG-issued certificate, matching the TLS-only
    # pg_hba in the cluster manifest.
    BS_CONN="Host=tms-postgres-rw;Port=5432;Database=ticketdb;Username=tms;Password=${BS_PGPW};Ssl Mode=VerifyFull;Root Certificate=/etc/postgres-tls/ca.crt"

    k create secret generic tms-secrets \
        --from-literal=Jwt__Secret="$BS_JWT" \
        --from-literal=Encryption__BlindIndexSecret="$BS_BLIND" \
        --from-literal=ConnectionStrings__ticketdb="$BS_CONN" \
        --from-literal=Keycloak__AdminUsername=admin \
        --from-literal=Keycloak__AdminPassword="$BS_KCPW" \
        --from-literal=Redis__Password="$BS_REDISPW" \
        --from-literal=Sso__Keycloak__ClientSecret="$BS_SSO" \
        --dry-run=client -o yaml | k apply -f - >/dev/null
    say '  generated'
fi

# Backup credentials are applied on every run, not just the first, so that
# changing the repository or its password in .env takes effect on the next
# install without needing to know which kubectl command to run.
BS_BACKUP_PW=$(env_get BACKUP_PASSWORD)
[ -n "$BS_BACKUP_PW" ] || die "BACKUP_PASSWORD is not set in $TMS_ENV_FILE.

It encrypts the backups. Generate one with: openssl rand -base64 48
Store it with the other secrets — without it the backups cannot be read."

k create secret generic tms-backup-credentials \
    --from-literal=RESTIC_REPOSITORY="$BS_BACKUP_REPO" \
    --from-literal=RESTIC_PASSWORD="$BS_BACKUP_PW" \
    --from-literal=KEEP_DAILY="$(env_get BACKUP_KEEP_DAILY 14)" \
    --from-literal=KEEP_WEEKLY="$(env_get BACKUP_KEEP_WEEKLY 4)" \
    --from-literal=KEEP_MONTHLY="$(env_get BACKUP_KEEP_MONTHLY 6)" \
    --dry-run=client -o yaml | k apply -f - >/dev/null

# Extra credentials for backends that need them (S3 keys, for example). Written
# as KEY=value lines so one setting covers every backend without the manifest
# knowing which one is in use.
BS_BACKUP_EXTRA=$(env_get BACKUP_ENV_EXTRA)
if [ -n "$BS_BACKUP_EXTRA" ]; then
    printf '%s\n' "$BS_BACKUP_EXTRA" | tr ',' '\n' | while IFS= read -r _line; do
        [ -n "$_line" ] || continue
        k patch secret tms-backup-credentials --type merge \
            -p "{\"stringData\":{\"${_line%%=*}\":\"${_line#*=}\"}}" >/dev/null
    done
fi
say '  backup credentials applied'

# ── 6. escrow ───────────────────────────────────────────────────────
# The single most important step, and the easiest to skip.
#
# The database holds a key ring that wraps every tenant's encryption key. Restore
# a backup without the matching secrets and the data is unreadable — not
# corrupted, not recoverable, just permanently opaque. So the secrets have to
# leave this machine, and the installer refuses to finish until someone says
# they have.
if [ "$BS_NEW_SECRETS" = 1 ]; then
    say ''
    say "${C_BOLD}Step 6 — saving your secrets somewhere safe${C_OFF}"

    BS_ESCROW="$BS_ROOT/tms-secrets-escrow.enc"
    BS_PASS=$(openssl rand -base64 24 | tr -d '\n')

    # Only the secrets that cannot be regenerated go in here. The tms-sso client
    # secret and the Redis password are deliberately left out: both are regenerable
    # plumbing (the API re-pushes the SSO secret to Keycloak at startup), so a
    # rebuild mints fresh ones with no data loss — unlike BLIND_INDEX_SECRET below.
    {
        printf 'TMS secrets escrow — %s\n' "$BS_HOSTNAME"
        printf 'Created: %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'JWT_SECRET=%s\n' "$BS_JWT"
        printf 'BLIND_INDEX_SECRET=%s\n' "$BS_BLIND"
        printf 'POSTGRES_PASSWORD=%s\n' "$BS_PGPW"
        printf 'KEYCLOAK_ADMIN_PASSWORD=%s\n' "$BS_KCPW"
        printf 'BACKUP_PASSWORD=%s\n' "$(env_get BACKUP_PASSWORD)"
        printf '\nBLIND_INDEX_SECRET can never be changed. Restoring a backup\n'
        printf 'without it makes every user unfindable and login impossible.\n'
    } | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -pass "pass:$BS_PASS" \
        -out "$BS_ESCROW"
    chmod 600 "$BS_ESCROW"

    say ''
    say "  Encrypted secrets written to: $BS_ESCROW"
    say ''
    say "  ${C_BOLD}Passphrase: ${BS_PASS}${C_OFF}"
    say ''
    say '  This passphrase is shown once and is not stored anywhere.'
    say '  Copy BOTH the file and the passphrase somewhere that is NOT these'
    say '  servers — a password manager, or your organisation'"'"'s secret store.'
    say ''
    say '  Without them, a backup of this system cannot be restored.'
    say ''
    printf '  Type stored to confirm you have done this: ' >&2
    read -r BS_ACK
    [ "$BS_ACK" = stored ] || die "Aborted. Nothing further has been installed.
Store the escrow file and passphrase, then run this again."
fi

# ── 7. certificate and realm ────────────────────────────────────────
say ''
say "${C_BOLD}Step 7 — installing certificate and sign-in configuration${C_OFF}"

k create secret tls tms-tls --cert="$BS_CERT" --key="$BS_KEY" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
say '  certificate installed'

# Two sources, in order: the copy shipped in the release tarball, then the one in
# a source checkout. The realm is deliberately not committed under onprem/ — it
# already lives in two places that have to change together, and a third would be a
# third place to forget — so bootstrap bridges the gap rather than requiring the
# operator to copy a file by hand (#1220).
BS_REALM="$BS_ROOT/k3s/tms-realm.json"
[ -r "$BS_REALM" ] || BS_REALM="$BS_ROOT/../ticket-management-system.AppHost/Realms/tms-realm.json"
[ -r "$BS_REALM" ] || die "Sign-in configuration not found.

Looked in:
  $BS_ROOT/k3s/tms-realm.json
  $BS_ROOT/../ticket-management-system.AppHost/Realms/tms-realm.json

It ships in the release tarball. If you are running from a source checkout, the
second path should exist — check you copied the whole repository."

# The realm's SSO redirect URIs are written for development: localhost, and the
# maintainer's own domain. Left alone they mean Microsoft Entra sign-in cannot work
# here (Keycloak rejects a callback that is not listed), and someone else's hostname
# would sit in this client's configuration.
#
# Replaced rather than appended to, so nothing foreign survives. The array's closing
# line is echoed back verbatim so its punctuation stays valid whatever it was.
BS_REALM_DIR=$(mktemp -d)
BS_REALM_OUT="$BS_REALM_DIR/tms-realm.json"

awk -v host="$BS_HOSTNAME" '
    /"redirectUris"[[:space:]]*:[[:space:]]*\[/ {
        print "      \"redirectUris\": ["
        print "        \"https://" host "/api/auth/sso/callback\""
        in_uris = 1
        next
    }
    in_uris && /^[[:space:]]*\]/ { print $0; in_uris = 0; next }
    in_uris { next }
    { print }
' "$BS_REALM" > "$BS_REALM_OUT"

# Confirm the substitution actually happened, rather than trusting that it did. A
# realm whose redirect URIs silently stayed as they were would install cleanly and
# fail only when someone first tried to sign in with Entra.
grep -q "https://$BS_HOSTNAME/api/auth/sso/callback" "$BS_REALM_OUT" \
    || die "Could not set the SSO redirect URI in the realm. The file at
$BS_REALM may have an unexpected shape — install stopped rather than deploy a
sign-in configuration that would not work."

# And that nothing else's callback survived. Written as a host comparison rather
# than a list of known-bad domains so it stays correct as those change.
BS_FOREIGN=$(grep -o '"[^"]*/api/auth/sso/callback"' "$BS_REALM_OUT" \
             | grep -v "$BS_HOSTNAME" || true)
[ -z "$BS_FOREIGN" ] || die "The realm still lists redirect URIs for other hosts:
$BS_FOREIGN
Install stopped — these do not belong in this installation."

k create configmap keycloak-realm --from-file="$BS_REALM_OUT" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
rm -rf "$BS_REALM_DIR"
say '  sign-in configuration installed'

# ── 8. deploy ───────────────────────────────────────────────────────
say ''
say "${C_BOLD}Step 8 — deploying TMS${C_OFF}"

BS_RENDER=$(mktemp -d)
BS_OVERLAY="$BS_ROOT/k3s/manifests/stage-$BS_STAGE"

# Substitute the hostname and password placeholders, then apply. Done here
# rather than with a kustomize replacement so the rendered YAML can be read
# before it is applied, and diffed afterwards.
"$(command -v kubectl || echo /usr/local/bin/kubectl)" kustomize "$BS_OVERLAY" \
    | sed -e "s|__HOSTNAME__|$BS_HOSTNAME|g" \
          -e "s|__POSTGRES_PASSWORD__|${BS_PGPW}|g" \
    > "$BS_RENDER/tms.yaml"

k_global apply -f "$BS_RENDER/tms.yaml" >/dev/null
rm -rf "$BS_RENDER"
say '  applied'

say ''
say '  waiting for the database (this takes a few minutes on first install) ...'
k wait --for=condition=Ready --timeout=900s cluster.postgresql.cnpg.io/tms-postgres >/dev/null 2>&1 \
    || warn 'Database is taking longer than expected. Check: tmsctl status'

say '  waiting for the application ...'
k rollout status deployment/tms-api --timeout=900s >/dev/null 2>&1 \
    || warn 'API is taking longer than expected. Check: tmsctl logs api'
k rollout status deployment/tms-web --timeout=600s >/dev/null 2>&1 || true

# ── install the tmsctl command on PATH ──────────────────────────────
# #1256 — the RUNBOOK, both READMEs and the messages below all call `tmsctl`
# as a plain command, but nothing had put it on PATH, so an operator's first
# `tmsctl status` returned "command not found". Install a thin wrapper that
# forwards to the real script in the install tree.
#
# It must be a wrapper, NOT a symlink: tmsctl derives its root (lib/, .env,
# manifests) from its own $0, so a symlink in /usr/local/bin would make it look
# for those files there instead of here. The real script re-execs under sudo for
# the root-only kubeconfig, so the plain `tmsctl ...` the docs show now works.
if [ -d /usr/local/bin ]; then
    cat > /usr/local/bin/tmsctl <<EOF
#!/bin/sh
# TMS operator CLI — installed by bootstrap (#1256). Forwards to the install
# tree, so do not move or delete: $TMS_ROOT
exec "$TMS_ROOT/tmsctl" "\$@"
EOF
    chmod 0755 /usr/local/bin/tmsctl
    say '  installed the tmsctl command (run: tmsctl status)'
fi

# ── done ────────────────────────────────────────────────────────────
say ''
say "${C_GREEN}${C_BOLD}TMS is installed.${C_OFF}"
say ''
say "  Open:  https://${BS_HOSTNAME}/"
say ''
say '  You will be asked to create the first administrator. There are no'
say '  default accounts — nothing to change, nothing to forget to change.'
say ''
say '  Two things to do next:'
say '    1. Set up email under Administration -> Notifications. Until you do,'
say '       TMS sends nothing at all, including password resets.'
say '    2. Run: tmsctl backup now      and confirm it succeeds.'
say ''
say '  Day to day:  tmsctl status'
say ''

if [ "$BS_STAGE" = b ]; then
    say '  To add the other two servers, run on each of them:'
    say "    sudo ./bootstrap.sh --join $(cat /var/lib/rancher/k3s/server/node-token 2>/dev/null || echo '<token>') --server https://$(hostname -I | awk '{print $1}'):6443"
    say ''
fi
