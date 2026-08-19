# shellcheck shell=sh
# tmsctl adapter for the `k8s` target — TMS on a cluster you already run.
#
# The difference from lib/k3s.sh is not mainly technical. On k3s we installed the
# cluster, the database and the backup schedule, so tmsctl can speak about all of
# them. Here the client owns the cluster and the database, and tmsctl must be
# careful to report on what it actually knows and to say plainly what it does not.
#
# So the commands split three ways:
#
#   works        status, logs, version, cert replace, support-bundle
#   not ours     backup, restore, verify-recovery, node   — your database, your
#                cluster, your policy. Each refuses with what to do instead.
#   not here     install, join, preflight — installation is `helm install`, and
#                the machine-level preflight checks nothing relevant to a cluster
#                you already operate.
#
# POSIX sh, like the rest.

# ── status ──────────────────────────────────────────────────────────
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
            _st_state=CRITICAL; _st_detail="$_st_detail ${_st_d}:absent,"
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

    # ── API replica count ──
    #
    # The detective control for the one constraint this chart cannot enforce after
    # installation. Helm refuses a second replica and so does the optional
    # admission policy, but `kubectl scale` reaches past both unless the operator
    # is cluster-admin AND enabled apiScaleGuard.
    #
    # Its consequences are invisible from inside the cluster — customers receive
    # duplicate scheduled reports, and an import batch is adopted by the wrong
    # pod — so nothing else here would ever mention it.
    _st_api=$(k get deployment tms-api -o jsonpath='{.spec.replicas}' 2>/dev/null)
    if [ -n "$_st_api" ] && [ "$_st_api" -gt 1 ]; then
        state_line 'API replicas' 'CRITICAL' \
            "${_st_api} — must be 1. Duplicate report emails and import corruption. See k8s/README.md section 5."
        _st_ok=1
    fi

    # ── database ──
    #
    # Reported as EXTERNAL rather than probed. Not HEALTHY, which would be a claim
    # we have not checked; not DEGRADED, which would be a permanent amber line an
    # operator learns to ignore, and that habit is what makes a real amber line
    # useless later.
    state_line 'Database' 'EXTERNAL' \
        "$(env_get POSTGRES_HOST 'your PostgreSQL server') — operated by you, not by TMS"

    # ── backups ──
    state_line 'Backups' 'EXTERNAL' 'not managed by TMS — see the note below'

    # ── certificate ──
    # Nothing renews a certificate you supplied. Without this line the first
    # anyone hears of it is a total outage on expiry day.
    _st_secret=$(env_get K8S_TLS_SECRET tms-tls)
    _st_crt=$(k get secret "$_st_secret" -o jsonpath='{.data.tls\.crt}' 2>/dev/null)
    if [ -n "$_st_crt" ] && command -v openssl >/dev/null 2>&1; then
        _st_pem=$(printf '%s' "$_st_crt" | base64 -d 2>/dev/null)
        _st_end=$(printf '%s' "$_st_pem" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
        # -checkend exits 0 when the certificate is still valid that many seconds
        # from now. Deliberately not `date -u -d`, which is a GNU extension: on a
        # macOS or BusyBox workstation that fails, the fallback yields epoch 0,
        # and a perfectly good certificate is reported CRITICAL with a negative
        # number of days.
        if printf '%s' "$_st_pem" | openssl x509 -noout -checkend 2592000 >/dev/null 2>&1; then
            state_line 'Certificate' 'HEALTHY' "valid for more than 30 days (expires ${_st_end})"
        elif printf '%s' "$_st_pem" | openssl x509 -noout -checkend 604800 >/dev/null 2>&1; then
            state_line 'Certificate' 'DEGRADED' "expires within 30 days (${_st_end}) — renew now"
            _st_ok=1
        else
            state_line 'Certificate' 'CRITICAL' "expires within 7 days (${_st_end})"
            _st_ok=1
        fi
    else
        state_line 'Certificate' 'UNKNOWN' "cannot read the ${_st_secret} secret"
    fi

    # ── real-time ──
    _st_redis=$(k get deployment redis -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    if [ -z "$_st_redis" ]; then
        state_line 'Real-time' 'HEALTHY' 'in-process (Redis not deployed; correct at one web replica)'
    elif [ "$_st_redis" -ge 1 ]; then
        state_line 'Real-time' 'HEALTHY' 'live updates flowing'
    else
        state_line 'Real-time' 'DEGRADED' 'live updates may lag; no data at risk'
    fi

    state_line 'Version' '' "$(target_version_short)"

    printf '\n%sTwo things this installation does NOT do for you:%s\n' "$C_BOLD" "$C_OFF"
    printf '  * Your database is yours. Nothing here backs it up or fails it over.\n'
    printf '  * ATTACHMENTS ARE NOT BACKED UP by TMS. They live on the\n'
    printf '    tms-attachments volume and nowhere else — confirm your platform\n'
    printf '    snapshots that StorageClass.\n\n'

    return "$_st_ok"
}

target_version_short() {
    _v_chart=$(k get deployment tms-api -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}' 2>/dev/null)
    if [ -n "$_v_chart" ]; then
        printf '%s' "$_v_chart"
    elif [ -f "$TMS_ROOT/manifest.lock" ]; then
        sed -n 's/^version=//p' "$TMS_ROOT/manifest.lock" | head -1
    else
        printf 'unknown'
    fi
}

# ── logs ────────────────────────────────────────────────────────────
target_logs() {
    case "${1:-}" in
        api)           _lg_sel=app=tms-api ;;
        web)           _lg_sel=app=tms-web ;;
        auth|keycloak) _lg_sel=app=keycloak ;;
        redis)         _lg_sel=app=redis ;;
        preflight)     _lg_sel=app=tms-preflight ;;
        db|database)
            die "The database is yours, so its logs are wherever you keep them.

TMS connects to $(env_get POSTGRES_HOST 'your PostgreSQL server'); it does not run it.
To see how TMS is failing to talk to it:   tmsctl logs api"
            ;;
        ingress)
            # We do not install the ingress controller and cannot know its
            # namespace. Saying so beats guessing 'ingress-nginx' and printing a
            # confusing empty result on a cluster that runs something else.
            _lg_ns=$(env_get K8S_INGRESS_NAMESPACE)
            [ -n "$_lg_ns" ] || die "Set K8S_INGRESS_NAMESPACE in $TMS_ENV_FILE first.

The ingress controller is yours and this chart does not install it, so tmsctl
cannot know where it runs. Find it with:

    kubectl get pods -A | grep -i ingress"
            shift
            k_global -n "$_lg_ns" logs -l app.kubernetes.io/name=ingress-nginx --tail=200 "$@"
            return
            ;;
        '') die "Which component? One of: api web auth redis preflight ingress" ;;
        *)  die "Unknown component '$1'. One of: api web auth redis preflight ingress" ;;
    esac
    shift
    k logs -l "$_lg_sel" --tail=200 --all-containers "$@"
}

# ── certificate ─────────────────────────────────────────────────────
target_cert_replace() {
    [ $# -eq 2 ] || die "Usage: tmsctl cert replace <fullchain.pem> <privkey.pem>"
    [ -r "$1" ] || die "Cannot read certificate file: $1"
    [ -r "$2" ] || die "Cannot read private key file: $2"

    _cr_secret=$(env_get K8S_TLS_SECRET tms-tls)

    k create secret tls "$_cr_secret" --cert="$1" --key="$2" \
        --dry-run=client -o yaml | k apply -f - >/dev/null \
        || die "Could not update the $_cr_secret secret."

    say "Certificate replaced in secret $_cr_secret."
    say ''
    say 'Your ingress controller may cache the old certificate. If the new one does'
    say 'not appear within a minute, restart the controller — it is in your'
    say 'namespace, not ours, so tmsctl does not do it for you.'
}

# ── support bundle ──────────────────────────────────────────────────
target_support_bundle() {
    _sb_dir="tms-support-$(date -u +%Y%m%d%H%M%S)"
    mkdir -p "$_sb_dir" || die "Could not create $_sb_dir"

    k get all -o wide                 > "$_sb_dir/resources.txt"       2>&1 || true
    k get events --sort-by=.lastTimestamp > "$_sb_dir/events.txt"      2>&1 || true
    k describe deployment tms-api tms-web keycloak > "$_sb_dir/deployments.txt" 2>&1 || true
    k get ingress -o yaml             > "$_sb_dir/ingress.yaml"        2>&1 || true
    k get pvc                         > "$_sb_dir/storage.txt"         2>&1 || true

    for _sb_c in tms-api tms-web keycloak; do
        k logs -l "app=$_sb_c" --tail=2000 --all-containers > "$_sb_dir/$_sb_c.log" 2>&1 || true
    done

    # The ConfigMap holds no secrets by design, but redact anyway — a future key
    # added to it should not become a disclosure because this line assumed.
    k get configmap tms-config -o yaml 2>/dev/null | redact > "$_sb_dir/config.yaml" || true

    # `helm get values` shows what the operator set; `helm get manifest` would
    # include Secret contents verbatim, so it is deliberately NOT collected.
    if command -v helm >/dev/null 2>&1; then
        helm list -n "$TMS_NAMESPACE"                     > "$_sb_dir/helm-releases.txt" 2>&1 || true
        helm get values tms -n "$TMS_NAMESPACE" 2>/dev/null | redact > "$_sb_dir/helm-values.yaml" || true
    fi

    tar -czf "$_sb_dir.tar.gz" "$_sb_dir" && rm -rf "$_sb_dir"
    say "Wrote $_sb_dir.tar.gz"
    say ''
    say 'Secret VALUES are not collected, and helm get manifest is deliberately'
    say 'excluded because it contains them verbatim. Read the bundle before'
    say 'sending it on — it is your data.'
}

# ── deliberately not implemented here ───────────────────────────────
#
# Each of these refuses with what to do instead. A stub that half-works on
# someone else's cluster is worse than one that declines.

target_backup() {
    die "TMS does not back up this installation, and cannot.

Your database is yours: $(env_get POSTGRES_HOST 'your PostgreSQL server').
Back it up however you back up your other databases.

AND — this is the one that gets missed — ATTACHMENTS ARE NOT IN THE DATABASE.
They are on the tms-attachments PersistentVolumeClaim, and nothing in this
chart copies them anywhere. A database backup restores every ticket and none
of their files.

Confirm your platform snapshots the StorageClass that volume uses."
}

target_update() {
    die "Updates on this target are a helm upgrade, which tmsctl deliberately does not run for you.

    helm upgrade tms ./tms -n $TMS_NAMESPACE -f your-values.yaml

Running it from here would need helm and write access on this machine, and
would drift from whatever your change process expects. Read the release notes
and TAKE A DATABASE BACKUP FIRST — migrations run automatically on the new API
pod and a helm rollback does not reverse them."
}

target_restore() {
    die "TMS did not take this backup and cannot restore it.

Your database is yours: $(env_get POSTGRES_HOST 'your PostgreSQL server').
Restore it the way you restore your other databases, then restart the API:

    kubectl -n $TMS_NAMESPACE rollout restart deployment/tms-api

TWO THINGS THAT MUST BOTH BE TRUE, or the restored data is unreadable:

  * Encryption__BlindIndexSecret in your tms-secrets Secret must be EXACTLY the
    value it was when the backup was taken. It derives the searchable index over
    encrypted fields and there is no migration path.
  * The attachments volume must be restored from the same point in time, and
    that is NOT in your database backup - see 'tmsctl backup'."
}

target_verify_recovery() {
    die "Not implemented for this target.

After restoring, the check that actually matters is whether the encryption
secrets match the data: sign in, open a ticket, and confirm its description and
comments are readable rather than base64. If they are not, the database was
restored with a different Encryption__BlindIndexSecret than it was written with."
}

target_node() {
    die "Node maintenance is yours — this is your cluster.

    kubectl get nodes
    kubectl drain <node> --ignore-daemonsets --delete-emptydir-data

Note tms-api runs a single replica, so draining its node means a short outage
rather than a failover. See k8s/README.md section 5."
}
