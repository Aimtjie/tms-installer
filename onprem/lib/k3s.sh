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
