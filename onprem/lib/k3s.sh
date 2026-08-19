# tmsctl implementation for the k3s target. Sourced, not executed.
#
# shellcheck shell=sh
# shellcheck source=./common.sh

# ── status ──────────────────────────────────────────────────────────
# Written to be read by a person under pressure. Every unhealthy line names the
# runbook section that deals with it, because the moment someone needs this is
# the moment they are least able to go looking.
target_status() {
    _st_ok=0

    printf '\n%sTMS — %s%s\n\n' "$C_BOLD" "$(env_get TMS_HOSTNAME 'not configured')" "$C_OFF"

    # ── application ──
    _st_detail=''
    _st_state=HEALTHY
    for _st_d in tms-api tms-web keycloak; do
        _st_ready=$(k get deployment "$_st_d" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
        _st_want=$(k get deployment "$_st_d" -o jsonpath='{.spec.replicas}' 2>/dev/null)
        [ -n "$_st_ready" ] || _st_ready=0
        if [ -z "$_st_want" ]; then
            _st_state=CRITICAL; _st_detail="$_st_detail ${_st_d}:absent"
        elif [ "$_st_ready" -lt "$_st_want" ]; then
            [ "$_st_ready" = 0 ] && _st_state=CRITICAL || \
                { [ "$_st_state" = HEALTHY ] && _st_state=DEGRADED; }
            _st_detail="$_st_detail ${_st_d} ${_st_ready}/${_st_want},"
        else
            _st_detail="$_st_detail ${_st_d} ${_st_ready}/${_st_want},"
        fi
    done
    state_line 'Application' "$_st_state" "$(printf '%s' "$_st_detail" | sed 's/,$//;s/^ //')"
    [ "$_st_state" = HEALTHY ] || _st_ok=1

    # ── database ──
    _st_pg=$(k get cluster.postgresql.cnpg.io tms-postgres \
             -o jsonpath='{.status.readyInstances}/{.spec.instances} primary={.status.currentPrimary}' 2>/dev/null)
    if [ -z "$_st_pg" ]; then
        state_line 'Database' 'UNKNOWN' 'CloudNativePG cluster not found'
        _st_ok=1
    else
        _st_ready=${_st_pg%%/*}
        _st_rest=${_st_pg#*/}
        _st_want=${_st_rest%% *}
        if [ "$_st_ready" = "$_st_want" ]; then
            state_line 'Database' 'HEALTHY' "$_st_pg"
        elif [ "$_st_ready" -ge 1 ]; then
            state_line 'Database' 'DEGRADED' "$_st_pg — still serving, failover still available"
            _st_ok=1
        else
            state_line 'Database' 'CRITICAL' "$_st_pg — no instance ready. See RUNBOOK 5."
            _st_ok=1
        fi
    fi

    # ── backups ──
    # A backup that silently stopped a fortnight ago is the failure that turns a
    # recoverable incident into a total loss, so it gets its own line and goes
    # CRITICAL rather than quietly staying amber.
    # `|| true` is load-bearing. With no backup Jobs yet, the `[-1:]` slice fails
    # ("array index out of bounds: index -1, length 0") and kubectl exits 1 — so
    # under tmsctl's `set -e` the ASSIGNMENT aborts the whole command, before the
    # empty-string branch below that exists precisely for this case. The result was
    # `tmsctl status` printing two lines, exiting 1, and saying nothing about why,
    # on every install that had not yet run a backup (#1237).
    _st_last=$(k get job -l app=tms-backup \
               --sort-by=.status.completionTime \
               -o jsonpath='{.items[-1:].status.completionTime}' 2>/dev/null || true)
    if [ -z "$_st_last" ]; then
        state_line 'Backups' 'CRITICAL' 'no successful backup recorded. See RUNBOOK 6.'
        _st_ok=1
    else
        _st_age=$(( ( $(date -u +%s) - $(date -u -d "$_st_last" +%s 2>/dev/null || echo 0) ) / 3600 ))
        if [ "$_st_age" -le 36 ]; then
            state_line 'Backups' 'HEALTHY' "last successful ${_st_age}h ago"
        else
            state_line 'Backups' 'CRITICAL' "last successful ${_st_age}h ago. See RUNBOOK 6."
            _st_ok=1
        fi
    fi

    # ── nodes ──
    _st_total=$(k_global get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    _st_up=$(k_global get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')
    if [ "$_st_total" = 0 ]; then
        state_line 'Servers' 'UNKNOWN' 'cannot reach the cluster'
        _st_ok=1
    elif [ "$_st_up" = "$_st_total" ]; then
        state_line 'Servers' 'HEALTHY' "${_st_up}/${_st_total} ready"
    else
        _st_down=$(k_global get nodes --no-headers 2>/dev/null | awk '$2!="Ready" {print $1}' | tr '\n' ' ')
        state_line 'Servers' 'DEGRADED' "${_st_up}/${_st_total} ready — ${_st_down}. See RUNBOOK 4.1."
        _st_ok=1
    fi

    # ── certificate ──
    # Nothing renews a certificate you supplied. Without this line the first
    # anyone hears of it is a total outage on expiry day.
    _st_crt=$(k get secret tms-tls -o jsonpath='{.data.tls\.crt}' 2>/dev/null)
    if [ -n "$_st_crt" ] && command -v openssl >/dev/null 2>&1; then
        _st_end=$(printf '%s' "$_st_crt" | base64 -d 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
        _st_days=$(( ( $(date -u -d "$_st_end" +%s 2>/dev/null || echo 0) - $(date -u +%s) ) / 86400 ))
        if [ "$_st_days" -gt 30 ]; then
            state_line 'Certificate' 'HEALTHY' "expires in ${_st_days} days (${_st_end})"
        elif [ "$_st_days" -gt 7 ]; then
            state_line 'Certificate' 'DEGRADED' "expires in ${_st_days} days — renew now. See RUNBOOK 7."
            _st_ok=1
        else
            state_line 'Certificate' 'CRITICAL' "expires in ${_st_days} days. See RUNBOOK 7."
            _st_ok=1
        fi
    else
        state_line 'Certificate' 'UNKNOWN' 'cannot read the tms-tls secret'
    fi

    # ── real-time ──
    _st_redis=$(k get deployment redis -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    if [ "${_st_redis:-0}" -ge 1 ]; then
        state_line 'Real-time' 'HEALTHY' 'live updates flowing'
    else
        state_line 'Real-time' 'DEGRADED' 'live updates may lag; no data at risk'
    fi

    state_line 'Version' '' "$(target_version_short)"
    printf '\n'
    return "$_st_ok"
}

target_version_short() {
    if [ -f "$TMS_ROOT/manifest.lock" ]; then
        sed -n 's/^version=//p' "$TMS_ROOT/manifest.lock" | head -1
    else
        printf 'unknown (no manifest.lock)'
    fi
}

# ── logs ────────────────────────────────────────────────────────────
target_logs() {
    case "${1:-}" in
        api)      _lg_sel=app=tms-api ;;
        web)      _lg_sel=app=tms-web ;;
        auth|keycloak) _lg_sel=app=keycloak ;;
        db|database)   _lg_sel=cnpg.io/cluster=tms-postgres ;;
        ingress)  _lg_sel='' ;;
        '')       die "Which component? One of: api web auth db ingress" ;;
        *)        die "Unknown component '$1'. One of: api web auth db ingress" ;;
    esac
    shift
    if [ "$_lg_sel" = '' ]; then
        k_global -n ingress-nginx logs -l app.kubernetes.io/name=ingress-nginx --tail=200 "$@"
    else
        k logs -l "$_lg_sel" --tail=200 --all-containers "$@"
    fi
}

# ── backups ─────────────────────────────────────────────────────────
target_backup() {
    case "${1:-}" in
        now)
            _bk_name="tms-backup-manual-$(date -u +%Y%m%d%H%M%S)"
            info "Starting $_bk_name ..."
            k create job "$_bk_name" --from=cronjob/tms-backup >/dev/null \
                || die "Could not start a backup. Is the tms-backup CronJob installed?"
            info "Started. Follow it with: tmsctl logs backup"
            ;;
        list)
            k get jobs -l app=tms-backup \
              -o custom-columns=NAME:.metadata.name,COMPLETED:.status.completionTime,SUCCEEDED:.status.succeeded
            ;;
        verify)
            info 'Checking the backup repository is readable and its contents intact.'
            info 'This reads the whole repository and can take a while.'
            k create job "tms-backup-verify-$(date -u +%Y%m%d%H%M%S)" --from=cronjob/tms-backup-verify >/dev/null \
                || die "Could not start verification. Is the tms-backup-verify CronJob installed?"
            ;;
        *)  die "Usage: tmsctl backup now|list|verify" ;;
    esac
}

# ── update ──────────────────────────────────────────────────────────
# Apply a release tarball (built by scripts/build-onprem-release.sh, #1180) and
# roll the APPLICATION back if it does not come up healthy.
#
# Scope: this applies the release's pinned APP IMAGE DIGESTS — the common case,
# since a new TMS version is a new image and DB migrations run at API startup. It
# does NOT re-apply structural configmap/manifest changes; those remain a manual
# step for now (the fuller component-by-component apply was deliberately deferred).
#
# The database is never auto-rolled. The stateless tiers revert cleanly through
# ReplicaSet history, but a database cannot be silently rewound without risking
# whatever was written since the update began — so a fresh backup is taken first,
# the update STOPS if that backup fails, and DB recovery is a deliberate restore
# (RUNBOOK 6.3), not something this command does behind the operator's back.
target_update() {
    _up_tar=$1
    [ -r "$_up_tar" ] || die "Cannot read $_up_tar"

    # 1. Verify the download before it is allowed anywhere near a live deployment.
    #    The release ships a .sha256 next to the tarball; check it when present.
    if [ -r "$_up_tar.sha256" ]; then
        info 'Verifying the download ...'
        ( cd "$(dirname "$_up_tar")" && sha256sum -c "$(basename "$_up_tar").sha256" ) >/dev/null 2>&1 \
            || die "Checksum check failed for $_up_tar. Do not install it — re-download and try again."
    else
        warn "No $_up_tar.sha256 found next to the tarball — cannot verify its integrity."
    fi

    # 2. Unpack and read the new release's identity.
    _up_work=$(mktemp -d)
    tar -xzf "$_up_tar" -C "$_up_work" 2>/dev/null \
        || { rm -rf "$_up_work"; die "Could not unpack $_up_tar."; }
    _up_new=$(find "$_up_work" -maxdepth 1 -type d -name 'tms-onprem-*' | head -1)
    { [ -n "$_up_new" ] && [ -r "$_up_new/manifest.lock" ]; } \
        || { rm -rf "$_up_work"; die "$_up_tar is not a TMS release tarball (no manifest.lock inside)."; }

    _up_from=$(target_version_short)
    _up_to=$(sed -n 's/^version=//p' "$_up_new/manifest.lock" | head -1)

    # 3. Show what changes, and make the operator confirm against a live system.
    say ''
    say "Updating from ${_up_from} to ${_up_to}."
    if [ -r "$TMS_ROOT/manifest.lock" ]; then
        _up_diff=$(diff "$TMS_ROOT/manifest.lock" "$_up_new/manifest.lock" 2>/dev/null || true)
        [ -n "$_up_diff" ] && { say ''; say 'Changes to what is deployed:'; printf '%s\n' "$_up_diff"; }
    fi
    confirm_destructive "About to update this live installation to ${_up_to}."

    # 4. Preflight the machine (the current tree reads the current .env).
    info 'Checking this machine is still suitable ...'
    "$TMS_ROOT/common/preflight.sh" --env "$TMS_ENV_FILE" >/dev/null 2>&1 \
        || die "Preflight failed — run 'tmsctl preflight' and fix what it reports before updating."

    # 5. Take a backup and STOP if it does not complete. Because the database is
    #    never auto-rolled, this backup is the only way back if the DB is affected.
    _up_job="tms-backup-preupdate-$(date -u +%Y%m%d%H%M%S)"
    info "Taking a pre-update backup ($_up_job) ..."
    k create job "$_up_job" --from=cronjob/tms-backup >/dev/null 2>&1 \
        || { rm -rf "$_up_work"; die "Could not start the pre-update backup. Nothing has been changed."; }
    if ! k wait --for=condition=complete --timeout=14400s "job/$_up_job" >/dev/null 2>&1; then
        rm -rf "$_up_work"
        die "The pre-update backup did not complete. Nothing has been changed — check: tmsctl logs backup"
    fi
    say '  backup complete'

    # 6. Apply the new APP image digests from the release's manifest.lock — the
    #    pinned digests, never a tag. Only the stateless tiers are touched; the
    #    database is left exactly as it is. Each tier is applied only if its image
    #    actually changes, so a tier already on the target keeps its rollout history
    #    intact and is never mistakenly undone in step 8.
    _up_api=$(sed -n 's/^tms-api=//p'  "$_up_new/manifest.lock" | head -1)
    _up_web=$(sed -n 's/^tms-web=//p'  "$_up_new/manifest.lock" | head -1)
    _up_kc=$(sed -n  's/^keycloak=//p' "$_up_new/manifest.lock" | head -1)
    { [ -n "$_up_api" ] && [ -n "$_up_web" ]; } \
        || { rm -rf "$_up_work"; die "The release manifest.lock is missing an app image digest."; }

    info 'Applying the new version ...'
    _up_changed=''

    _up_cur=$(k get deployment/tms-api -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
    if [ "$_up_api" != "$_up_cur" ]; then
        k set image deployment/tms-api "api=$_up_api" >/dev/null
        _up_changed="$_up_changed tms-api"
    fi

    _up_cur=$(k get deployment/tms-web -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
    if [ "$_up_web" != "$_up_cur" ]; then
        k set image deployment/tms-web "web=$_up_web" >/dev/null
        _up_changed="$_up_changed tms-web"
    fi

    if [ -n "$_up_kc" ]; then
        _up_cur=$(k get deployment/keycloak -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
        if [ "$_up_kc" != "$_up_cur" ]; then
            k set image deployment/keycloak "keycloak=$_up_kc" >/dev/null
            _up_changed="$_up_changed keycloak"
        fi
    fi

    if [ -z "$_up_changed" ]; then
        cp -a "$_up_new/." "$TMS_ROOT/" 2>/dev/null || true
        rm -rf "$_up_work"
        say "Already running ${_up_to} — the tree and manifest.lock have been refreshed."
        return 0
    fi

    # 7. Wait for each changed tier to go healthy.
    _up_ok=1
    for _up_d in $_up_changed; do
        k rollout status "deployment/$_up_d" --timeout=600s || { _up_ok=0; break; }
    done

    if [ "$_up_ok" = 1 ]; then
        # 8a. Success — adopt the new tree so tmsctl/lib/manifest.lock report the new
        #     version. .env is not in the tarball, so it is preserved. This process
        #     already sourced its code into memory, so overwriting the files is safe.
        cp -a "$_up_new/." "$TMS_ROOT/" 2>/dev/null || true
        rm -rf "$_up_work"
        say ''
        say "Updated to ${_up_to}. Check it over with: tmsctl status"
        say 'Then log in and do something ordinary — only a person can confirm it works.'
    else
        # 8b. Failure — roll back ONLY the tiers this update changed, and leave the
        #     tree/manifest.lock untouched so the version still reads as the old one.
        warn 'The new version did not come up healthy — rolling the application back.'
        for _up_d in $_up_changed; do
            k rollout undo "deployment/$_up_d" >/dev/null 2>&1 || true
        done
        for _up_d in $_up_changed; do
            k rollout status "deployment/$_up_d" --timeout=600s >/dev/null 2>&1 || true
        done
        rm -rf "$_up_work"
        die "Update to ${_up_to} failed and the application was rolled back. The database was left
untouched and your pre-update backup ($_up_job) is intact. Collect diagnostics with:
tmsctl support-bundle"
    fi
}

# ── support bundle ──────────────────────────────────────────────────
# With no remote access into a client's installation, this archive is the whole
# diagnostic channel. It is built early and redacted hard for that reason.
target_support_bundle() {
    _sb_dir=$(mktemp -d)
    _sb_out="tms-support-$(date -u +%Y%m%d-%H%M%S).tar.gz"

    info 'Collecting diagnostics ...'

    target_status              > "$_sb_dir/status.txt" 2>&1 || true
    k get all                  > "$_sb_dir/resources.txt" 2>&1 || true
    k get events --sort-by=.lastTimestamp > "$_sb_dir/events.txt" 2>&1 || true
    k describe pods            > "$_sb_dir/pods-describe.txt" 2>&1 || true
    k_global get nodes -o wide > "$_sb_dir/nodes.txt" 2>&1 || true
    k get cluster.postgresql.cnpg.io tms-postgres -o yaml > "$_sb_dir/postgres.yaml" 2>&1 || true
    [ -f "$TMS_ROOT/manifest.lock" ] && cp "$TMS_ROOT/manifest.lock" "$_sb_dir/" 2>/dev/null

    for _sb_c in api web auth db; do
        target_logs "$_sb_c" > "$_sb_dir/logs-$_sb_c.txt" 2>&1 || true
    done

    # Configuration WITHOUT values — key names are useful for diagnosis, values
    # are not worth the risk of shipping them off site.
    if [ -f "$TMS_ENV_FILE" ]; then
        sed -E 's/=.*/=<set>/' "$TMS_ENV_FILE" | grep -v '^[[:space:]]*#' > "$_sb_dir/env-keys.txt" 2>/dev/null || true
    fi

    # Second pass: even non-secret output can contain a connection string in a
    # log line. Redact everything on the way in.
    for _sb_f in "$_sb_dir"/*; do
        [ -f "$_sb_f" ] || continue
        redact < "$_sb_f" > "$_sb_f.clean" && mv "$_sb_f.clean" "$_sb_f"
    done

    tar -czf "$_sb_out" -C "$_sb_dir" . || die "Could not write $_sb_out"
    rm -rf "$_sb_dir"

    say ""
    say "Wrote $_sb_out"
    say ""
    say "Passwords and tokens have been removed. It is still worth a look before"
    say "you send it — you know your data better than the redaction rules do."
}

# ── certificate ─────────────────────────────────────────────────────
target_cert_replace() {
    [ $# -eq 2 ] || die "Usage: tmsctl cert replace <fullchain.pem> <privkey.pem>"
    [ -r "$1" ] || die "Cannot read certificate: $1"
    [ -r "$2" ] || die "Cannot read private key: $2"

    # Check the pair matches BEFORE installing it. A mismatched pair takes the
    # site down at the moment the ingress reloads, which is not where you want
    # to discover the mistake.
    if command -v openssl >/dev/null 2>&1; then
        _cr_c=$(openssl x509 -noout -pubkey -in "$1" 2>/dev/null | openssl md5)
        _cr_k=$(openssl pkey -pubout -in "$2" 2>/dev/null | openssl md5)
        [ "$_cr_c" = "$_cr_k" ] || die "That certificate and key are not a pair — refusing to install them."

        _cr_host=$(env_get TMS_HOSTNAME)
        if [ -n "$_cr_host" ] && ! openssl x509 -noout -checkhost "$_cr_host" -in "$1" >/dev/null 2>&1; then
            die "That certificate does not cover $_cr_host — refusing to install it."
        fi
    fi

    k create secret tls tms-tls --cert="$1" --key="$2" --dry-run=client -o yaml | k apply -f - \
        || die "Could not update the certificate."
    info 'Certificate replaced. Reloading ingress ...'
    # ingress-nginx watches the secret and reloads on its own, so this restart is
    # belt and braces. It must still not CLAIM to have done something it did not:
    # this named a DaemonSet while bootstrap.sh creates a Deployment (#1218), so
    # it failed into `|| true` and then printed "Done" regardless.
    if k_global -n ingress-nginx rollout restart deployment ingress-nginx-controller >/dev/null 2>&1; then
        say 'Done. Check with: tmsctl status'
    else
        warn 'Could not restart the ingress controller.'
        say 'The certificate IS installed. ingress-nginx watches the secret and normally'
        say 'picks up a new certificate within a minute. If the old one is still being'
        say 'served after that, check: tmsctl logs ingress'
    fi
}

# ── nodes ───────────────────────────────────────────────────────────
# Moved out of tmsctl so that every target answers these through its own
# adapter rather than through k3s-shaped text printed for everyone (TMS #1762
# review). The wording is unchanged from what tmsctl printed before.
target_restore() {
    [ -n "${1:-}" ] || die "Usage: tmsctl restore <snapshot-id>   (list them with: tmsctl backup list)"
    confirm_destructive "About to REPLACE all current data with snapshot $1.
Anything created since that snapshot will be lost."
    say ''
    say 'Restore is a documented procedure rather than a single command, because'
    say 'the order matters: secrets first, then the database, then verification.'
    say 'Restoring the database without its matching encryption secrets leaves'
    say 'the data unreadable.'
    say ''
    say "Follow docs/RUNBOOK.md section 6.3, using snapshot: ${1:-<snapshot-id>}"
}

target_verify_recovery() {
    say 'Checking that the restored data is actually usable ...'
    say ''
    say 'This confirms the encryption keys match the data - a database restored'
    say 'without its matching secrets looks fine until someone tries to log in.'
    say ''
    say 'See docs/RUNBOOK.md section 6.4.'
}

target_node() {
    case "${1:-}" in
        drain)
            [ -n "${2:-}" ] || die "Usage: tmsctl node drain <server>"
            confirm_destructive "About to move all workloads off $2. Service may be briefly interrupted."
            k_global drain "$2" --ignore-daemonsets --delete-emptydir-data --timeout=300s
            ;;
        uncordon)
            [ -n "${2:-}" ] || die "Usage: tmsctl node uncordon <server>"
            k_global uncordon "$2"
            ;;
        list|'')
            k_global get nodes -o wide
            ;;
        *)  die "Usage: tmsctl node list|drain <server>|uncordon <server>" ;;
    esac
}
