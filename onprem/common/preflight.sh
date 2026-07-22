#!/bin/sh
# TMS self-hosted preflight check.
#
# Read-only. Changes nothing. Run it before installing, and again any time the
# system is behaving oddly — several of these checks catch problems that
# otherwise show up much later as confusing failures.
#
#   ./preflight.sh              single-server / demo thresholds
#   ./preflight.sh --ha         thresholds for a server in a 3-server HA cluster
#   ./preflight.sh --env FILE   also validate settings in FILE
#                               (default: the .env next to tmsctl, whatever
#                                directory you happen to be standing in)
#
# Exit status: 0 if nothing FAILed (warnings still allow install), 1 otherwise.

set -eu

# ── thresholds ──────────────────────────────────────────────────────
# Demo: measured steady-state use is ~1 GB of RAM and ~4.5 GB of disk for the
# platform, so these leave real headroom rather than being the bare minimum.
PF_MIN_CPU=2
PF_MIN_MEM_MB=3500
PF_MIN_DISK_GB=12
PF_WANT_DISK_GB=20

PF_MODE=demo

# Resolved from this script's own location, NOT the working directory (#1219).
# bootstrap.sh and tmsctl both read onprem/.env; defaulting to ./.env meant that
# running preflight from onprem/k3s/ validated a different file than the one the
# install would read — so it could pass on a config bootstrap then rejected.
PF_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
PF_ENV_FILE=$PF_ROOT/.env

PF_FAILED=0
PF_WARNED=0

# ── output ──────────────────────────────────────────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    PF_G=$(printf '\033[32m'); PF_Y=$(printf '\033[33m')
    PF_R=$(printf '\033[31m'); PF_D=$(printf '\033[2m'); PF_0=$(printf '\033[0m')
else
    PF_G=''; PF_Y=''; PF_R=''; PF_D=''; PF_0=''
fi

pf_pass() { printf '  %sPASS%s  %s\n' "$PF_G" "$PF_0" "$1"; }
pf_warn() { printf '  %sWARN%s  %s\n' "$PF_Y" "$PF_0" "$1"; PF_WARNED=$((PF_WARNED + 1)); }
pf_fail() { printf '  %sFAIL%s  %s\n' "$PF_R" "$PF_0" "$1"; PF_FAILED=$((PF_FAILED + 1)); }
pf_note() { printf '        %s%s%s\n' "$PF_D" "$1" "$PF_0"; }
pf_head() { printf '\n%s\n' "$1"; }

pf_usage() {
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

# ── arguments ───────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --ha)
            PF_MODE=ha
            PF_MIN_CPU=4
            PF_MIN_MEM_MB=7500
            PF_MIN_DISK_GB=60
            PF_WANT_DISK_GB=80
            ;;
        --env)
            [ $# -ge 2 ] || { printf 'preflight: --env needs a file path\n' >&2; exit 2; }
            PF_ENV_FILE=$2
            shift
            ;;
        -h|--help) pf_usage ;;
        *) printf 'preflight: unknown option "%s" (try --help)\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

printf 'TMS preflight — %s thresholds\n' "$PF_MODE"

# ── host ────────────────────────────────────────────────────────────
pf_head 'Host'

if [ "$(uname -s)" = "Linux" ]; then
    pf_pass "Operating system: Linux ($(uname -r))"
else
    pf_fail "Operating system: $(uname -s) — TMS self-hosted targets require Linux"
fi

pf_arch=$(uname -m)
case "$pf_arch" in
    x86_64|amd64|aarch64|arm64) pf_pass "Architecture: $pf_arch" ;;
    *) pf_fail "Architecture: $pf_arch — only x86_64 and arm64 images are published" ;;
esac

# ── capacity ────────────────────────────────────────────────────────
pf_head 'Capacity'

pf_cpu=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 0)
if [ "$pf_cpu" -ge "$PF_MIN_CPU" ]; then
    pf_pass "CPU: ${pf_cpu} cores"
else
    pf_fail "CPU: ${pf_cpu} cores — need at least ${PF_MIN_CPU}"
fi

pf_mem_mb=0
if [ -r /proc/meminfo ]; then
    pf_mem_kb=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)
    pf_mem_mb=$((pf_mem_kb / 1024))
fi
if [ "$pf_mem_mb" -ge "$PF_MIN_MEM_MB" ]; then
    pf_pass "Memory: ${pf_mem_mb} MB"
elif [ "$PF_MODE" = ha ] && [ "$pf_mem_mb" -ge 3500 ]; then
    pf_warn "Memory: ${pf_mem_mb} MB — below the ${PF_MIN_MEM_MB} MB recommended for HA"
    pf_note 'Workable, but reduce the replica counts in .env: KEYCLOAK=1, API/WEB=2.'
    pf_note 'With one server down the remaining two carry everything, and that is'
    pf_note 'the case with no headroom left.'
else
    pf_fail "Memory: ${pf_mem_mb} MB — need at least ${PF_MIN_MEM_MB} MB"
fi

# Measure the filesystem that will actually hold container images and data.
pf_disk_path=/var/lib
[ -d "$pf_disk_path" ] || pf_disk_path=/
pf_disk_gb=$(df -Pk "$pf_disk_path" 2>/dev/null | awk 'NR==2 {print int($4/1048576)}')
[ -n "$pf_disk_gb" ] || pf_disk_gb=0
if [ "$pf_disk_gb" -ge "$PF_WANT_DISK_GB" ]; then
    pf_pass "Disk free on ${pf_disk_path}: ${pf_disk_gb} GB"
elif [ "$pf_disk_gb" -ge "$PF_MIN_DISK_GB" ]; then
    pf_warn "Disk free on ${pf_disk_path}: ${pf_disk_gb} GB — ${PF_WANT_DISK_GB} GB recommended"
    pf_note 'Container images take roughly twice their download size on disk, because'
    pf_note 'both the compressed layers and the unpacked copy are kept.'
else
    pf_fail "Disk free on ${pf_disk_path}: ${pf_disk_gb} GB — need at least ${PF_MIN_DISK_GB} GB"
fi

# #1252 — when the disk is short AND on LVM, the usual cause is not a small disk
# but an Ubuntu install that grew the root logical volume to only part of the
# volume group, leaving the rest unclaimed. The operator sees a shortfall on a
# machine that has plenty of physical disk, with no obvious next step — and on a
# client install (#1173) cannot ask us. Surface the reclaim command. Detection is
# read-only and needs NO root: findmnt reports the backing device, and an LVM
# filesystem is a device-mapper node. `vgs`/`lvs` would confirm the free extents
# but need privilege, so we point the operator at `sudo vgs` rather than run it.
if [ "$pf_disk_gb" -lt "$PF_WANT_DISK_GB" ] && command -v findmnt >/dev/null 2>&1; then
    # `|| true`: findmnt resolves / and /var/lib in practice, but a non-zero exit
    # from a command substitution under `set -e` would abort preflight here and
    # skip every check below — the #1237 failure mode. pf_swap does the same.
    pf_src=$(findmnt -no SOURCE --target "$pf_disk_path" 2>/dev/null || true)
    case "$pf_src" in
        /dev/mapper/* | /dev/dm-*)
            pf_note 'This filesystem is on LVM. A fresh Ubuntu install commonly leaves half the'
            pf_note 'volume group unallocated, so the disk is larger than it looks. Confirm with:'
            pf_note '  sudo vgs                      # a non-zero VFree is unclaimed space'
            pf_note 'and reclaim it (this also grows the filesystem in place, no reboot):'
            pf_note "  sudo lvextend -r -l +100%FREE $pf_src"
            pf_note 'then run this check again.'
            ;;
    esac
fi

if [ "$PF_MODE" = ha ]; then
    # etcd fsyncs constantly; PostgreSQL writes its journal constantly. Sharing
    # one disk between them is a well-known way to make a cluster feel unwell
    # without anything obviously failing.
    if [ "$(df -Pk /var/lib 2>/dev/null | awk 'NR==2 {print $1}')" \
       = "$(df -Pk /var 2>/dev/null | awk 'NR==2 {print $1}')" ]; then
        pf_warn 'Cluster state and database share one filesystem'
        pf_note 'A second disk for /var/lib/rancher is strongly recommended in HA.'
    fi
fi

# ── kernel and system ───────────────────────────────────────────────
pf_head 'System'

# awk exits 0 with no output when nothing matches, so the result can be empty
# rather than a number — check for that before comparing numerically.
pf_swap=$(awk '/^SwapTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)
[ -n "$pf_swap" ] || pf_swap=0
if [ "$pf_swap" -eq 0 ]; then
    pf_pass 'Swap: disabled'
else
    pf_warn 'Swap: enabled — Kubernetes expects it off'
    pf_note 'Disable with: sudo swapoff -a  (and comment the swap line in /etc/fstab)'
fi

if [ -e /sys/fs/cgroup/cgroup.controllers ]; then
    pf_pass 'Control groups: v2'
elif [ -d /sys/fs/cgroup ]; then
    pf_warn 'Control groups: v1 — v2 is recommended; memory limits are less reliable on v1'
else
    pf_fail 'Control groups: not found'
fi

if command -v timedatectl >/dev/null 2>&1; then
    if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q '^yes$'; then
        pf_pass 'Clock: synchronised'
    else
        pf_warn 'Clock: not synchronised with a time source'
        pf_note 'Certificate validation and token expiry both depend on an accurate clock.'
    fi
fi

# ── required commands ───────────────────────────────────────────────
pf_head 'Required commands'

for pf_cmd in curl openssl tar; do
    if command -v "$pf_cmd" >/dev/null 2>&1; then
        pf_pass "$pf_cmd"
    else
        pf_fail "$pf_cmd — not found; install it before continuing"
    fi
done

# ── network ─────────────────────────────────────────────────────────
pf_head 'Network'

pf_port_busy() {
    if command -v ss >/dev/null 2>&1; then
        ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"
    else
        return 1
    fi
}

if [ "$PF_MODE" = ha ]; then
    pf_ports='80 443 6443 2379 2380'
else
    pf_ports='80 443 6443'
fi
# bootstrap.sh promises "safe to re-run … if it stops partway, fix what it
# complained about and run it again", and runs this script as its own first step.
# But by the time it can stop partway it has usually installed k3s (step 3) and
# ingress-nginx (step 4) — which hold 6443 and 80/443 respectively. Failing on
# those blocks every re-run of a partially completed install, including the
# recovery path the operator was just told to take (#1235).
#
# Warned rather than passed: a warning does not block, but neither does it claim
# the port is free when something might genuinely be squatting on it. Telling ours
# from a stray Apache needs `ss -ltnp` and therefore root, which this script does
# not require, so it reports what it can actually establish.
pf_k3s_active=no
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet k3s 2>/dev/null; then
    pf_k3s_active=yes
fi

for pf_port in $pf_ports; do
    if pf_port_busy "$pf_port"; then
        if [ "$pf_k3s_active" = yes ]; then
            pf_warn "Port ${pf_port} is in use — k3s is already running on this machine"
            pf_note 'Expected when re-running an install. If this is meant to be a fresh'
            pf_note "server, check with: sudo ss -ltnp | grep :${pf_port}"
        else
            pf_fail "Port ${pf_port} is already in use"
            pf_note "Find it with: sudo ss -ltnp | grep :${pf_port}"
        fi
    else
        pf_pass "Port ${pf_port} is free"
    fi
done

if command -v curl >/dev/null 2>&1; then
    # ghcr.io answers 401 to an unauthenticated probe — that still proves we can
    # reach it. Only a connection failure (000) means no route out.
    #
    # `|| true`, never `|| echo 000`: on a connection failure curl BOTH prints
    # 000 via -w AND exits non-zero, so appending a default yields "000000",
    # which would not match below and would report this check as passing.
    pf_code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 https://ghcr.io/v2/ 2>/dev/null || true)
    [ -n "$pf_code" ] || pf_code=000
    if [ "$pf_code" = "000" ]; then
        pf_fail 'Cannot reach ghcr.io — container images are pulled from there'
        pf_note 'Check outbound HTTPS, DNS, and any proxy configuration.'
    else
        pf_pass "Container registry reachable (ghcr.io responded ${pf_code})"
    fi
fi

# ── configuration ───────────────────────────────────────────────────
if [ -f "$PF_ENV_FILE" ]; then
    pf_head "Configuration ($PF_ENV_FILE)"

    pf_get() { sed -n "s/^[[:space:]]*$1=//p" "$PF_ENV_FILE" | tail -n 1; }

    # Blank is NOT a failure ON THE TARGET THAT GENERATES. The k3s bootstrap generates both of
    # these when empty (step 5) and writes them into the encrypted escrow bundle it makes you
    # store (step 6), so failing there would refuse a configuration that installer accepts — the
    # #1215 inconsistency in mirror image (#1279). Only k3s mints them, so blank is accepted ONLY
    # for k3s; other targets have no such step and must supply the values, exactly as CONFIG.md
    # marks them. TMS_TARGET defaults to k3s (see CONFIG.md). A value that IS set is length-checked
    # regardless of target: bootstrap uses it verbatim and the API refuses to start on anything
    # shorter than 32 bytes, so this is the only place a supplied-but-short value is caught before
    # it becomes a crash-looping pod.
    pf_target=$(pf_get TMS_TARGET)
    for pf_key in JWT_SECRET BLIND_INDEX_SECRET; do
        pf_val=$(pf_get "$pf_key")
        if [ -z "$pf_val" ] && [ "${pf_target:-k3s}" = k3s ]; then
            pf_pass "$pf_key not set — the installer will generate and escrow one"
            if [ "$pf_key" = BLIND_INDEX_SECRET ]; then
                pf_note 'A fresh value is correct for a NEW install. If you are RESTORING a backup,'
                pf_note 'paste the ORIGINAL BLIND_INDEX_SECRET here first — a new one makes the'
                pf_note 'restored data permanently unreadable.'
            fi
        elif [ -z "$pf_val" ]; then
            pf_fail "$pf_key is empty — the ${pf_target:-k3s} target does not generate it for you"
            pf_note 'Generate one with: openssl rand -base64 48'
        elif [ "${#pf_val}" -lt 32 ]; then
            pf_fail "$pf_key is ${#pf_val} characters — must be at least 32 bytes"
            pf_note 'Generate one with: openssl rand -base64 48'
        else
            pf_pass "$pf_key is set and long enough"
        fi
    done

    pf_val=$(pf_get BACKUP_REPOSITORY)
    if [ -z "$pf_val" ]; then
        pf_fail 'BACKUP_REPOSITORY is empty — install will not complete without a backup target'
    else
        case "$pf_val" in
            /*) pf_warn "BACKUP_REPOSITORY is a local path (${pf_val})"
                pf_note 'Make sure this is a mount from another machine. A directory on this'
                pf_note 'server dies with the server it is meant to protect.' ;;
            *)  pf_pass 'BACKUP_REPOSITORY is set' ;;
        esac
    fi

    # Must accept EXACTLY what bootstrap.sh accepts. Preflight exists to answer "will this
    # install?" before anything changes — and bootstrap runs it as its own first step — so a value
    # passed here and refused there is the one answer it must never give (#1215). #1224 narrowed
    # the install to `local` and corrected .env.example and CONFIG.md but left this arm passing
    # `s3`, so an operator was told their configuration was good and then had the install die on it.
    pf_val=$(pf_get STORAGE_PROVIDER)
    case "${pf_val:-local}" in
        local)
            pf_pass "STORAGE_PROVIDER=${pf_val:-local}" ;;
        s3)
            pf_fail 'STORAGE_PROVIDER=s3 is not wired up on the k3s target yet'
            pf_note 'The setting is read but nothing applies it, so attachments would stay on a'
            pf_note 'local disk while you believed they were on object storage. Use local — they'
            pf_note 'are included in the nightly backup either way.' ;;
        postgres)
            pf_fail 'STORAGE_PROVIDER=postgres is not available in this version'
            pf_note 'Use local. An unrecognised value would be silently treated as "local",'
            pf_note 'putting attachments somewhere you did not choose.' ;;
        *)
            pf_fail "STORAGE_PROVIDER=${pf_val} is not a recognised value"
            pf_note 'Use local.' ;;
    esac

    pf_val=$(pf_get POSTGRES_INSTANCES)
    case "$pf_val" in
        2)  pf_fail 'POSTGRES_INSTANCES=2 — use 1 or 3'
            pf_note 'With two copies and synchronous replication, losing one server leaves'
            pf_note 'nobody to acknowledge writes, so the database stops accepting them.' ;;
        ''|1|3) [ -n "$pf_val" ] && pf_pass "POSTGRES_INSTANCES=${pf_val}" ;;
        *)  pf_warn "POSTGRES_INSTANCES=${pf_val} — 1 or 3 are the tested values" ;;
    esac

    # ── certificate ─────────────────────────────────────────────────
    pf_cert=$(pf_get TLS_CERT_FILE)
    if [ -n "$pf_cert" ] && [ -r "$pf_cert" ] && command -v openssl >/dev/null 2>&1; then
        if openssl x509 -in "$pf_cert" -noout -checkend 604800 >/dev/null 2>&1; then
            pf_pass "Certificate valid for more than 7 days ($(openssl x509 -in "$pf_cert" -noout -enddate | cut -d= -f2))"
        elif openssl x509 -in "$pf_cert" -noout -checkend 0 >/dev/null 2>&1; then
            pf_warn 'Certificate expires within 7 days'
        else
            pf_fail 'Certificate has expired'
        fi

        # A leaf-only certificate works in your browser (which cached the
        # intermediate) and fails for everyone else. Catch it here instead.
        # `|| true`, never `|| echo 0`: grep -c prints 0 and exits 1 when there
        # are no matches, so appending a default yields "0\n0" and the numeric
        # comparison below aborts the script.
        pf_chain=$(openssl crl2pkcs7 -nocrl -certfile "$pf_cert" 2>/dev/null \
                   | openssl pkcs7 -print_certs -noout 2>/dev/null \
                   | grep -c '^subject' 2>/dev/null || true)
        [ -n "$pf_chain" ] || pf_chain=0
        if [ "$pf_chain" -ge 2 ]; then
            pf_pass "Certificate includes a chain (${pf_chain} certificates)"
        else
            pf_warn 'Certificate contains only one certificate — no intermediates'
            pf_note 'It may work in your browser and fail elsewhere. Use the "fullchain" file.'
        fi

        pf_host=$(pf_get TMS_HOSTNAME)
        if [ -n "$pf_host" ]; then
            if openssl x509 -in "$pf_cert" -noout -checkhost "$pf_host" >/dev/null 2>&1; then
                pf_pass "Certificate covers ${pf_host}"
            else
                pf_fail "Certificate does not cover ${pf_host}"
            fi
        fi
    elif [ -n "$pf_cert" ]; then
        pf_warn "TLS_CERT_FILE is set but ${pf_cert} cannot be read"
    fi
fi

# ── summary ─────────────────────────────────────────────────────────
printf '\n'
if [ "$PF_FAILED" -gt 0 ]; then
    printf '%s%d check(s) failed%s' "$PF_R" "$PF_FAILED" "$PF_0"
    [ "$PF_WARNED" -gt 0 ] && printf ', %d warning(s)' "$PF_WARNED"
    printf '. Fix the failures before installing.\n'
    exit 1
fi
if [ "$PF_WARNED" -gt 0 ]; then
    printf '%sAll checks passed with %d warning(s).%s\n' "$PF_Y" "$PF_WARNED" "$PF_0"
    printf 'Read them above — none of them block an install, but each one is\n'
    printf 'something that tends to matter later.\n'
    exit 0
fi
printf '%sAll checks passed.%s\n' "$PF_G" "$PF_0"
