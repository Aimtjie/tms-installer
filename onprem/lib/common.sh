# Shared helpers for tmsctl. Sourced, not executed.
#
# POSIX sh throughout — no `local`, no bashisms. Variables are prefixed by area
# so that sourcing several of these files cannot collide.
#
# shellcheck shell=sh

# ── output ──────────────────────────────────────────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_GREEN=$(printf '\033[32m'); C_YELLOW=$(printf '\033[33m')
    C_RED=$(printf '\033[31m');   C_DIM=$(printf '\033[2m')
    C_BOLD=$(printf '\033[1m');   C_OFF=$(printf '\033[0m')
else
    C_GREEN=''; C_YELLOW=''; C_RED=''; C_DIM=''; C_BOLD=''; C_OFF=''
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s\n' "$*" >&2; }
warn() { printf '%sWarning:%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
die()  { printf '%sError:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

# A health line in `tmsctl status`. Deliberately fixed-width so the states line
# up and an unhealthy one is obvious at a glance.
state_line() {
    # $1 label, $2 state, $3 detail
    case "$2" in
        HEALTHY)  _sl_c=$C_GREEN ;;
        DEGRADED) _sl_c=$C_YELLOW ;;
        CRITICAL|UNKNOWN) _sl_c=$C_RED ;;
        *)        _sl_c='' ;;
    esac
    printf '%-16s%s%-10s%s%s\n' "$1" "$_sl_c" "$2" "$C_OFF" "$3"
}

# ── configuration ───────────────────────────────────────────────────
# Reads a key from .env without sourcing it. Sourcing would execute whatever is
# in there, and a stray backtick in a password would run as a command.
env_get() {
    # $1 key, $2 optional default
    [ -f "$TMS_ENV_FILE" ] || { printf '%s' "${2:-}"; return 0; }
    _eg_val=$(sed -n "s/^[[:space:]]*$1=//p" "$TMS_ENV_FILE" | tail -n 1)
    # Trim a trailing CR so a file edited on Windows does not yield "local\r",
    # which compares unequal to "local" in every subsequent test.
    _eg_val=$(printf '%s' "$_eg_val" | tr -d '\r')
    [ -n "$_eg_val" ] || _eg_val=${2:-}
    printf '%s' "$_eg_val"
}

require_env() {
    _re_val=$(env_get "$1")
    [ -n "$_re_val" ] || die "$1 is not set in $TMS_ENV_FILE"
    printf '%s' "$_re_val"
}

# ── kubectl ─────────────────────────────────────────────────────────
# k3s ships its own kubectl, so nothing extra has to be installed.
kubectl_bin() {
    if [ -x /usr/local/bin/kubectl ]; then printf '%s' /usr/local/bin/kubectl
    elif command -v kubectl >/dev/null 2>&1; then printf '%s' kubectl
    elif [ -x /usr/local/bin/k3s ]; then printf '%s' "/usr/local/bin/k3s kubectl"
    else die "kubectl not found. Is k3s installed on this machine?"
    fi
}

k() {
    # shellcheck disable=SC2086  # kubectl_bin may legitimately return two words
    KUBECONFIG="${TMS_KUBECONFIG}" $(kubectl_bin) -n "$TMS_NAMESPACE" "$@"
}

k_global() {
    # shellcheck disable=SC2086
    KUBECONFIG="${TMS_KUBECONFIG}" $(kubectl_bin) "$@"
}

# ── safety ──────────────────────────────────────────────────────────
# Destructive operations make you type the hostname. A y/N prompt is too easy to
# answer on autopilot, and these are the commands you cannot take back.
confirm_destructive() {
    # $1 what is about to happen
    _cd_host=$(env_get TMS_HOSTNAME "this installation")
    printf '\n%s%s%s\n\n' "$C_BOLD" "$1" "$C_OFF" >&2
    printf 'Type the hostname (%s) to continue, anything else to abort: ' "$_cd_host" >&2
    read -r _cd_answer
    [ "$_cd_answer" = "$_cd_host" ] || die "Aborted — nothing has been changed."
}

# Redact anything that looks like a secret from text destined for a support
# bundle. Deliberately eager: a false positive costs a reader some context, a
# miss leaks a credential to whoever receives the archive.
redact() {
    sed -E \
        -e 's/(password|passwd|secret|token|apikey|api_key)([":= ]+)[^",[:space:]]+/\1\2***REDACTED***/Ig' \
        -e 's/(Bearer|Basic)[[:space:]]+[A-Za-z0-9._~+\/-]+=*/\1 ***REDACTED***/g' \
        -e 's/[A-Za-z0-9._-]+:[^@[:space:]]+@/***REDACTED***@/g'
}
