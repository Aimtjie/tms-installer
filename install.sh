#!/usr/bin/env bash
# Ticket Management System — one-shot local installer.
#
# Pulls the files compose needs (compose files, .env template, postgres init
# script, Keycloak realm) from GitHub raw and brings the stack up using the
# pre-built GHCR images. No git clone, no .NET SDK, no build.
#
# External Postgres: set PG_HOST in .env before running and the bundled
# postgres container is automatically replaced with your external instance.
#
#   curl -fsSL https://raw.githubusercontent.com/Aimtjie/tms-installer/main/install.sh | bash
#
# Or with a custom target directory:
#   curl -fsSL .../install.sh | TMS_DIR=/opt/tms bash
#
# Re-running is safe and doubles as the upgrade path: managed files (compose
# files, init script, realm) are refreshed to the latest published versions —
# a locally modified copy is kept beside the new one as *.bak — while existing
# .env values are always preserved, and `docker compose up -d` is idempotent.

set -euo pipefail

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/Aimtjie/tms-installer/main}"
TMS_DIR="${TMS_DIR:-$PWD/tms}"
# Expand a leading `~` ourselves — bash skips tilde expansion when the value
# was quoted at assignment (e.g. `TMS_DIR="~/tms" bash install.sh`).
TMS_DIR="${TMS_DIR/#\~/$HOME}"

log()  { printf '\033[1;34m[tms]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[tms]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[tms]\033[0m %s\n' "$*" >&2; exit 1; }

# ── Interactive first-run configuration helpers ─────────────────────────────
# Prompts read from $PROMPT_FD, which defaults to the controlling terminal.
# This matters because the documented `curl … | bash` install pipes the SCRIPT
# into bash's stdin — a bare `read` would consume the script text, not the
# user's keystrokes. Reading from /dev/tty (opened on demand by ensure_prompt_fd)
# reaches the keyboard instead. Tests set PROMPT_FD to a pipe to drive answers.
# When no terminal is available, or TMS_NONINTERACTIVE is set, prompting is
# skipped entirely and the .env template defaults + generated secrets stand.
PROMPT_FD="${PROMPT_FD:-}"

# Open /dev/tty on a spare descriptor the first time it's needed. Returns
# non-zero when prompting isn't possible (headless, piped with no tty, or
# explicitly disabled) so callers can fall back to non-interactive behaviour.
ensure_prompt_fd() {
    [[ -n "$PROMPT_FD" ]] && return 0
    [[ -z "${TMS_NONINTERACTIVE:-}" && -r /dev/tty ]] || return 1
    exec {PROMPT_FD}</dev/tty
}

# ask VAR "Prompt" ["default"] — free-text; empty input takes the default.
# Prompt text goes to stderr (still the terminal under `curl | bash`, where only
# stdin is the pipe), so it's visible even when stdout is redirected to a file.
ask() {
    local __var="$1" __prompt="$2" __default="${3:-}" __ans
    if [[ -n "$__default" ]]; then
        printf '%s [%s]: ' "$__prompt" "$__default" >&2
    else
        printf '%s: ' "$__prompt" >&2
    fi
    IFS= read -r -u "$PROMPT_FD" __ans || __ans=""
    printf -v "$__var" '%s' "${__ans:-$__default}"
}

# ask_yes_no VAR "Prompt" [default(y|n)] — normalises the answer to yes/no.
ask_yes_no() {
    local __var="$1" __prompt="$2" __default="${3:-n}" __ans __hint
    case "$__default" in [yY]*) __hint="Y/n" ;; *) __hint="y/N" ;; esac
    while true; do
        printf '%s [%s]: ' "$__prompt" "$__hint" >&2
        IFS= read -r -u "$PROMPT_FD" __ans || __ans=""
        case "${__ans:-$__default}" in
            [yY]|[yY][eE][sS]) printf -v "$__var" 'yes'; return 0 ;;
            [nN]|[nN][oO])     printf -v "$__var" 'no';  return 0 ;;
            *) printf '  Please answer y or n.\n' >&2 ;;
        esac
    done
}

# ask_port VAR "Prompt" default — validates 1..65535.
ask_port() {
    local __var="$1" __prompt="$2" __default="$3" __ans
    while true; do
        printf '%s [%s]: ' "$__prompt" "$__default" >&2
        IFS= read -r -u "$PROMPT_FD" __ans || __ans=""
        __ans="${__ans:-$__default}"
        if [[ "$__ans" =~ ^[0-9]+$ ]] && (( __ans >= 1 && __ans <= 65535 )); then
            printf -v "$__var" '%s' "$__ans"; return 0
        fi
        printf '  Enter a port between 1 and 65535.\n' >&2
    done
}

# Best-effort primary LAN IPv4, used only as the default for LAN mode (the user
# confirms/overrides it). `ip route get` yields the source address actually used
# to reach off-box — never docker0; hostname -I is the fallback. Empty if none.
detect_lan_ip() {
    local ip=""
    if command -v ip >/dev/null 2>&1; then
        ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' | head -n1 || true)
    fi
    if [[ -z "$ip" ]] && command -v hostname >/dev/null 2>&1; then
        ip=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+(\.[0-9]+){3}$' | grep -vE '^127\.' | head -n1 || true)
    fi
    printf '%s' "$ip"
}

# url_host "https://host:port/path" → "host"
url_host() { local u="${1#*://}"; u="${u%%/*}"; u="${u%%:*}"; printf '%s' "$u"; }

# set_env_var KEY VALUE — replace the first active KEY= line in .env (or append
# if none), atomically, preserving mode 0600. awk carries VALUE literally, so
# URLs, CIDRs and base64 survive without sed metacharacter pitfalls. Commented
# template lines (#KEY=…) don't match, so a fresh active line is appended.
set_env_var() {
    local key="$1" value="$2" tmp
    tmp=$(mktemp "${TMS_DIR}/.env.XXXXXX")
    if grep -qE "^${key}=" .env; then
        awk -v k="$key" -v v="$value" 'BEGIN{done=0}
            !done && index($0, k "=") == 1 { print k "=" v; done=1; next }
            { print }' .env > "$tmp"
    else
        cat .env > "$tmp"
        printf '%s=%s\n' "$key" "$value" >> "$tmp"
    fi
    chmod 600 "$tmp"
    mv "$tmp" .env
}

# Write a ready-to-edit nginx reverse-proxy config next to .env. nginx's own
# $variables are backslash-escaped so bash leaves them literal; ${web_host} etc.
# ARE interpolated. Pairs with REQUIRE_HTTPS=true + TRUSTED_PROXY_CIDR in .env.
write_nginx_sample() {
    local web_url="$1" api_url="$2" web_port="$3" api_port="$4"
    local out="${TMS_DIR}/nginx.tms.conf.example" web_host api_host
    web_host=$(url_host "$web_url"); api_host=$(url_host "$api_url")
    cat > "$out" <<NGINX
# Sample nginx reverse-proxy for TMS — generated by install.sh.
# TLS-terminate here and forward to the loopback-published app ports. Edit the
# server_name / ssl_certificate paths, then: nginx -t && systemctl reload nginx.
#
# Pair with .env: REQUIRE_HTTPS=true, and (proxy on this host) BIND_ADDRESS
# stays 127.0.0.1 with TRUSTED_PROXY_CIDR=127.0.0.1/32. The app infers HTTPS and
# the real client IP from the X-Forwarded-* headers below — keep them.

server {
    listen 443 ssl;
    http2 on;
    server_name ${web_host};

    ssl_certificate     /etc/ssl/certs/${web_host}.pem;      # <- your fullchain
    ssl_certificate_key /etc/ssl/private/${web_host}.key;    # <- your private key

    # Web UI (Blazor Server + SignalR websockets on first load)
    location / {
        proxy_pass http://127.0.0.1:${web_port};
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade           \$http_upgrade;
        proxy_set_header Connection        "upgrade";
        proxy_read_timeout 100s;
    }
}

server {
    listen 443 ssl;
    http2 on;
    server_name ${api_host};

    ssl_certificate     /etc/ssl/certs/${api_host}.pem;
    ssl_certificate_key /etc/ssl/private/${api_host}.key;

    # API — the browser calls this directly (its CORS origin is the Web URL above)
    location / {
        proxy_pass http://127.0.0.1:${api_port};
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

# HTTP → HTTPS redirect
server {
    listen 80;
    server_name ${web_host} ${api_host};
    return 301 https://\$host\$request_uri;
}
NGINX
    chmod 644 "$out"
}

# Interactive first-run configuration. Only invoked on a freshly created .env,
# and returns immediately (leaving template defaults in place) when no terminal
# is available or TMS_NONINTERACTIVE is set. Writes chosen values into .env via
# set_env_var BEFORE the secret-repair pass, so an external-Postgres password
# the operator supplies is preserved rather than auto-generated over.
prompt_config() {
    if ! ensure_prompt_fd; then
        log "Non-interactive install — keeping .env defaults. Edit ${TMS_DIR}/.env (Postgres/ports/LAN/proxy) or re-run in a terminal to configure."
        return 0
    fi

    local pg_external pg_host pg_port pg_user pg_pass
    local web_port api_port kc_port
    local mode detected ip
    local web_url api_url proxy_local trusted

    log "First-run setup — press Enter to accept each [default]. (Ctrl-C to abort.)"

    # ── Postgres: bundled container vs external server ──
    ask_yes_no pg_external "Use an EXTERNAL PostgreSQL server (instead of the bundled container)?" n
    if [[ "$pg_external" == yes ]]; then
        ask pg_host "  External Postgres host (or IP)" ""
        while [[ -z "$pg_host" ]]; do
            warn "  A host is required for external Postgres."
            ask pg_host "  External Postgres host (or IP)" ""
        done
        ask_port pg_port "  External Postgres port" 5432
        ask pg_user "  Postgres username" "postgres"
        ask pg_pass "  Postgres password (the EXISTING server credential)" ""
        while [[ -z "$pg_pass" ]]; do
            warn "  A password is required so the app can connect."
            ask pg_pass "  Postgres password (the EXISTING server credential)" ""
        done
        set_env_var PG_HOST "$pg_host"
        set_env_var PG_PORT "$pg_port"
        set_env_var POSTGRES_USER "$pg_user"
        set_env_var POSTGRES_PASSWORD "$pg_pass"
        warn "  Ensure databases 'ticketdb' AND 'keycloakdb' already exist on ${pg_host} (see scripts/postgres-init/01-create-databases.sh)."
    fi

    # ── Host ports (asked before exposure so LAN/proxy URLs use them) ──
    ask_port web_port "Web UI host port" 8081
    ask_port api_port "API host port" 8080
    ask_port kc_port  "Keycloak host port" 8090
    [[ "$web_port" != 8081 ]] && set_env_var WEB_HTTP_PORT "$web_port"
    [[ "$api_port" != 8080 ]] && set_env_var API_HTTP_PORT "$api_port"
    [[ "$kc_port"  != 8090 ]] && set_env_var KEYCLOAK_HTTP_PORT "$kc_port"

    # ── Exposure / access mode ──
    printf '\n  How will you reach TMS from a browser?\n' >&2
    printf '    1) This machine only  (localhost — default, most secure)\n' >&2
    printf '    2) Other machines on your LAN  (plain HTTP)\n' >&2
    printf '    3) Behind a TLS reverse proxy  (nginx / Caddy / Traefik, HTTPS)\n' >&2
    ask mode "  Choose 1, 2 or 3" "1"

    case "$mode" in
        2)
            detected=$(detect_lan_ip)
            ask ip "  This host's LAN IP address" "$detected"
            while [[ -z "$ip" ]]; do
                warn "  A LAN IP (or hostname) is required for option 2."
                ask ip "  This host's LAN IP address" "$detected"
            done
            set_env_var BIND_ADDRESS "0.0.0.0"
            set_env_var WEB_PUBLIC_BASE_URL "http://${ip}:${web_port}"
            set_env_var API_PUBLIC_BASE_URL "http://${ip}:${api_port}"
            log "LAN mode: publishing on 0.0.0.0 — browse http://${ip}:${web_port} from other devices."
            warn "Traffic is plain HTTP (LAN eval only); PWA/offline stays inactive over a bare IP."
            warn "On a cloud VM, also open inbound TCP ${web_port} + ${api_port} in its security group."
            ;;
        3)
            ask web_url "  Public Web URL (e.g. https://tickets.example.com)" ""
            while [[ -z "$web_url" ]]; do warn "  Required."; ask web_url "  Public Web URL" ""; done
            ask api_url "  Public API URL (e.g. https://api.example.com)" ""
            while [[ -z "$api_url" ]]; do warn "  Required."; ask api_url "  Public API URL" ""; done
            set_env_var WEB_PUBLIC_BASE_URL "$web_url"
            set_env_var API_PUBLIC_BASE_URL "$api_url"
            set_env_var REQUIRE_HTTPS "true"
            ask_yes_no proxy_local "  Does the proxy run on THIS host (forwarding to localhost)?" y
            if [[ "$proxy_local" == yes ]]; then
                set_env_var TRUSTED_PROXY_CIDR "127.0.0.1/32"
            else
                set_env_var BIND_ADDRESS "0.0.0.0"
                ask trusted "  CIDR the proxy connects FROM (Docker net e.g. 172.16.0.0/12, or proxy-host /32)" "172.16.0.0/12"
                set_env_var TRUSTED_PROXY_CIDR "$trusted"
            fi
            write_nginx_sample "$web_url" "$api_url" "$web_port" "$api_port"
            log "Reverse-proxy mode: REQUIRE_HTTPS=true. Sample nginx config → ${TMS_DIR}/nginx.tms.conf.example"
            warn "The browser calls the API URL directly, so give it public DNS + a proxy server block too."
            warn "Using Entra SSO? Also set KEYCLOAK_PUBLIC_BASE_URL + KEYCLOAK_BIND_ADDRESS in .env (Keycloak stays loopback by default)."
            ;;
        *)
            log "Localhost mode: stack stays on 127.0.0.1 (browse http://localhost:${web_port} on this machine)."
            ;;
    esac
}

# ── 1. Prerequisites ───────────────────────────────────────────────────────
command -v curl >/dev/null   || die "curl is required — install with: sudo apt-get install -y curl"
command -v docker >/dev/null || die "docker is required — install with: sudo apt-get install -y docker.io docker-compose-v2"
docker compose version >/dev/null 2>&1 \
    || die "'docker compose' plugin is required — install with: sudo apt-get install -y docker-compose-v2"
command -v openssl >/dev/null || die "openssl is required — install with: sudo apt-get install -y openssl"

if ! docker info >/dev/null 2>&1; then
    die "docker daemon not reachable. If you just installed docker, run:
       sudo usermod -aG docker \$USER && newgrp docker
     or re-run this script with sudo."
fi

# ── 2. Fetch the files compose needs ──────────────────────────────────────
log "Target directory: $TMS_DIR"
mkdir -p "$TMS_DIR/scripts/postgres-init" "$TMS_DIR/ticket-management-system.AppHost/Realms"
cd "$TMS_DIR"

# Managed files are refreshed so a re-run upgrades an old install — otherwise the
# footer's instructions (BIND_ADDRESS, DEMO_SEEDER_ENABLED, …) silently do nothing
# against a kept pre-upgrade docker-compose.yml. Download to .tmp and rename so a
# mid-flight Ctrl-C leaves nothing at the real path. If the download fails but an
# existing copy is present, keep it and continue (so an offline / rate-limited
# re-run can still apply .env changes and restart) — only a missing file with a
# failed download is fatal. The FIRST time a file is replaced by a differing
# version its previous contents are preserved as $path.bak; an existing .bak is
# never overwritten, so a user's original customization survives across upgrades.
# .env is user state, handled separately below — never overwritten.
fetch() {
    local path="$1"
    if ! curl -fsSL "$REPO_RAW/$path" -o "$path.tmp" 2>/dev/null; then
        rm -f "$path.tmp"
        if [[ -s "$path" ]]; then
            warn "  could not download $path — keeping existing copy"
            return 0
        fi
        die "could not download $path and no existing copy is present. Check your network connection and re-run."
    fi
    if [[ -s "$path" ]] && ! cmp -s "$path" "$path.tmp"; then
        if [[ -e "$path.bak" ]]; then
            log "  updating $path (existing $path.bak preserved)"
        else
            log "  updating $path (previous copy kept as $path.bak)"
            cp "$path" "$path.bak"
        fi
    elif [[ ! -s "$path" ]]; then
        log "  downloading $path"
    fi
    mv "$path.tmp" "$path"
}

fetch docker-compose.yml
fetch docker-compose.external-pg.yml
fetch .env.example
fetch scripts/postgres-init/01-create-databases.sh
fetch ticket-management-system.AppHost/Realms/tms-realm.json
chmod +x scripts/postgres-init/01-create-databases.sh

# ── 3. .env — create from template, then repair any placeholder secrets ───
# Two-step model so an operator can iterate on .env without `rm .env` first:
#   1. If .env is missing, seed it from .env.example.
#   2. Scan the four required secret keys (JWT_SECRET, BLIND_INDEX_SECRET,
#      POSTGRES_PASSWORD, KEYCLOAK_ADMIN_PASSWORD) — any that are still blank
#      or CHANGE_ME (tolerating trailing whitespace) are replaced with fresh
#      random values. Everything else in .env is preserved verbatim: custom
#      ports, public URLs, Bitwarden / GitHub-Secrets config, ticket-number
#      prefix, ASPNETCORE_ENVIRONMENT, etc. (#696)
FRESH_ENV=0
if [[ ! -f .env ]]; then
    log "Creating .env from .env.example"
    # Subshell so the tight umask doesn't leak into later commands. cp
    # respects umask for the destination file, so .env lands at 0600
    # atomically — no transient world-readable window before chmod runs.
    (umask 077 && cp .env.example .env)
    FRESH_ENV=1
fi
# Always enforce 0600 — covers the re-run case where someone has loosened
# the file mode by hand. No-op on the freshly-cp'd path above.
chmod 600 .env

# First install only: offer interactive configuration of the settings that most
# commonly need changing (Postgres bundled/external, host ports, and LAN /
# reverse-proxy exposure). Re-runs preserve the existing .env, so prompting is
# skipped there — matching the "existing .env values are always preserved"
# contract above. Values chosen here are written BEFORE the secret-repair pass,
# so a supplied external-Postgres password is kept rather than regenerated.
if [[ "$FRESH_ENV" == 1 ]]; then
    prompt_config
fi

# JWT + blind-index need the full 48-byte entropy; the two password fields
# strip /+= so they round-trip cleanly through compose interpolation, env
# vars, and copy-paste.
generate_secret() {
    case "$1" in
        JWT_SECRET|BLIND_INDEX_SECRET)
            openssl rand -base64 48 | tr -d '\n' ;;
        POSTGRES_PASSWORD|KEYCLOAK_ADMIN_PASSWORD)
            openssl rand -base64 24 | tr -d '\n/=+' ;;
    esac
}

SED_ARGS=()
APPEND_LINES=()
REPAIRED=()
GENERATED_KEYCLOAK_PW=""

for key in JWT_SECRET BLIND_INDEX_SECRET POSTGRES_PASSWORD KEYCLOAK_ADMIN_PASSWORD; do
    value=""
    if grep -qE "^${key}=(CHANGE_ME|)[[:space:]]*$" .env; then
        # Line present but placeholder/blank — replace in place. Sed pattern
        # is narrowed to the same placeholder/blank shape so a user who
        # left `KEY=CHANGE_ME` at the top AND added `KEY=real_override`
        # at the bottom doesn't lose the override. (#697 C11)
        value=$(generate_secret "$key")
        SED_ARGS+=(-e "s|^${key}=(CHANGE_ME)?[[:space:]]*\$|${key}=${value}|")
        REPAIRED+=("$key")
    elif ! grep -qE "^${key}=" .env; then
        # Key missing entirely (truncated / user-written .env) — append it.
        # Without this, the stack would fail later via compose's :? guard
        # after the slow image pull rather than fast here. (#697 C10)
        value=$(generate_secret "$key")
        APPEND_LINES+=("${key}=${value}")
        REPAIRED+=("$key")
    fi
    [[ -n "$value" && "$key" == "KEYCLOAK_ADMIN_PASSWORD" ]] && GENERATED_KEYCLOAK_PW="$value"
done

if [[ ${#REPAIRED[@]} -gt 0 ]]; then
    log "Repaired/added required secrets: ${REPAIRED[*]}"
    # Write via .env.tmp + mv so an interrupted run never leaves a
    # half-substituted .env behind. `|` as sed delimiter dodges base64's /+.
    # Subshell umask keeps .env.tmp at 0600 from the moment `>` creates it,
    # closing the transient world-readable window. (#697 C12)
    (
        umask 077
        if [[ ${#SED_ARGS[@]} -gt 0 ]]; then
            sed -E "${SED_ARGS[@]}" .env > .env.tmp
        else
            cp .env .env.tmp
        fi
        if [[ ${#APPEND_LINES[@]} -gt 0 ]]; then
            printf '%s\n' "${APPEND_LINES[@]}" >> .env.tmp
        fi
    )
    chmod 600 .env.tmp
    mv .env.tmp .env
else
    log ".env has real values for all required secrets — no repair needed"
fi

# Safety net: belt-and-suspenders against the repair regex failing somehow
# (e.g. a malformed line that grep matched but sed couldn't substitute).
if grep -qE '^(JWT_SECRET|BLIND_INDEX_SECRET|POSTGRES_PASSWORD|KEYCLOAK_ADMIN_PASSWORD)=(CHANGE_ME|)[[:space:]]*$' .env; then
    die ".env still contains unset/placeholder values for required secrets after repair pass. Edit .env manually before bringing the stack up."
fi

# ── 3b. DataProtection key-ring certificate (#913) ─────────────────────────
# Both key rings wrap their master keys with this. Without it they are persisted
# to the DataProtectionKeys table in cleartext, and since the ring is the top of
# KEK -> per-tenant DEK -> field ciphertext, a database dump decrypts every
# tenant offline.
#
# Generated once, for NEW installs only. An existing .env with no
# DATAPROTECTION_REQUIRE_CERT line keeps its current behaviour: docker-compose.yml
# defaults it to false, so an upgrade never breaks a running stack. Turning it on
# afterwards is a documented step in .env.example.
#
# Never regenerated once present. The key ring resolves its decryptor by
# certificate thumbprint, so a replacement cannot unwrap what the old one wrote --
# not even a reissue of the same private key.
DP_DIR="$TMS_DIR/secrets/dataprotection"
if [[ -f "$DP_DIR/tls.key" ]]; then
    log "DataProtection certificate already present — keeping it"
elif ! command -v openssl >/dev/null 2>&1; then
    log "WARNING: openssl not found — skipping DataProtection certificate."
    log "         The key ring will be stored UNENCRYPTED at rest. See .env.example."
else
    (
        umask 077
        mkdir -p "$DP_DIR"
        openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
            -subj "/CN=dataprotection.tms" \
            -keyout "$DP_DIR/tls.key" -out "$DP_DIR/tls.crt" >/dev/null 2>&1
    )
    chmod 600 "$DP_DIR/tls.key"
    chmod 644 "$DP_DIR/tls.crt"

    # The container reads these through a BIND MOUNT, which preserves host
    # ownership -- unlike the Swarm target, where the secret carries an explicit
    # uid/gid. Both images run as $APP_UID (1654), and the files above belong to
    # whoever ran this script, so without the chown the app cannot traverse the
    # directory or read its own key.
    #
    # Not fatal if it fails: this script is documented as runnable by a
    # docker-group user, who cannot chown to another uid. The alternative --
    # chmod 644 on a key that unwraps every tenant's data -- is worse than
    # leaving the feature switched off, so that is what happens instead.
    DP_OWNED=0
    if chown 1654:1654 "$DP_DIR" "$DP_DIR/tls.key" "$DP_DIR/tls.crt" 2>/dev/null; then
        DP_OWNED=1
    elif docker run --rm -v "$DP_DIR:/dp" --entrypoint chown \
            ghcr.io/aimtjie/tms-api:latest -R 1654:1654 /dp >/dev/null 2>&1; then
        # The daemon runs as root even when this script does not, so a throwaway
        # container does what the calling user cannot. Deliberately the same image
        # the stack is about to start (matching docker-compose.yml), so this pulls
        # nothing that the next step would not pull anyway.
        DP_OWNED=1
    fi

    # Only claim the setting once the files actually exist AND the app can read
    # them, so a failed openssl -- or a key the container cannot open -- cannot
    # leave .env asserting a certificate that does not work, which would turn the
    # next `docker compose up` into a startup failure.
    if [[ "$DP_OWNED" != 1 ]]; then
        log "WARNING: could not give the DataProtection certificate to uid 1654."
        log "         Leaving it switched OFF rather than loosening the key to 644 —"
        log "         the stack will start, with the key ring unencrypted at rest."
        log "         To finish it, run:"
        log "           sudo chown -R 1654:1654 $DP_DIR"
        log "         then set DATAPROTECTION_REQUIRE_CERT=true in .env and restart."
    elif [[ -s "$DP_DIR/tls.key" && -s "$DP_DIR/tls.crt" ]]; then
        # `|| true` because grep exits 1 when it filters everything out, and under
        # `set -e` that would abort mid-write leaving a stray 0600 .env.tmp and a
        # cryptic failure. The emptiness check below is the real guard: .env always
        # has other keys, so an empty result means something went wrong and the
        # original must not be replaced.
        (
            umask 077
            {
                grep -vE '^DATAPROTECTION_(REQUIRE_CERT|CERT_PATH|KEY_PATH)=' .env || true
                echo 'DATAPROTECTION_REQUIRE_CERT=true'
                echo 'DATAPROTECTION_CERT_PATH=/etc/tms-dataprotection/tls.crt'
                echo 'DATAPROTECTION_KEY_PATH=/etc/tms-dataprotection/tls.key'
            } > .env.tmp
        )
        if [[ -s .env.tmp ]] && grep -q '^JWT_SECRET=' .env.tmp; then
            chmod 600 .env.tmp
            mv .env.tmp .env
            log "Generated DataProtection certificate in secrets/dataprotection/"
            log "  ⚠ Back up tls.key somewhere your database backups are NOT."
            log "    Without it a restored backup is unreadable, and it can never be replaced."
        else
            rm -f .env.tmp
            log "WARNING: could not rewrite .env — leaving it untouched."
            log "         The certificate exists but is not switched on. Add these three lines"
            log "         to .env by hand (see .env.example):"
            log "           DATAPROTECTION_REQUIRE_CERT=true"
            log "           DATAPROTECTION_CERT_PATH=/etc/tms-dataprotection/tls.crt"
            log "           DATAPROTECTION_KEY_PATH=/etc/tms-dataprotection/tls.key"
        fi
    else
        rm -f "$DP_DIR/tls.key" "$DP_DIR/tls.crt"
        log "WARNING: DataProtection certificate generation failed — key ring stays unencrypted."
    fi
fi

# ── 4. Bring the stack up ──────────────────────────────────────────────────
# Detect external-pg mode: if PG_HOST is set to a non-empty value in .env,
# activate the overlay that disables the bundled postgres container.
# COMPOSE_ARGS is a bash array so paths with spaces in $TMS_DIR are handled
# correctly. A separate COMPOSE_DISPLAY string is built for the copy-pasteable
# management commands printed in the footer.
COMPOSE_ARGS=(-f "$TMS_DIR/docker-compose.yml")
# tail -n1: last PG_HOST line wins (handles accidental duplicates in .env).
# sed strips inline comments (e.g. PG_HOST=myhost # note → myhost).
pg_host=$(grep -E "^PG_HOST=" .env 2>/dev/null | tail -n1 | cut -d= -f2- | sed 's/[[:space:]]*#.*//' | tr -d '[:space:]' || true)
if [[ -n "$pg_host" ]]; then
    log "External Postgres detected (PG_HOST=$pg_host) — using docker-compose.external-pg.yml overlay"
    COMPOSE_ARGS+=(-f "$TMS_DIR/docker-compose.external-pg.yml")
fi

# Pre-quoted display string for the footer — readable and copy-pasteable even
# when $TMS_DIR contains spaces.
COMPOSE_DISPLAY="-f \"$TMS_DIR/docker-compose.yml\""
[[ -n "$pg_host" ]] && COMPOSE_DISPLAY="$COMPOSE_DISPLAY -f \"$TMS_DIR/docker-compose.external-pg.yml\""

# Stale bundled-Postgres volume guard. Postgres only sets its password on the
# FIRST init of its data volume; if we just generated a new POSTGRES_PASSWORD
# but a bundled volume already exists (internal mode only), the app + Keycloak
# fail auth against the old baked-in password ("password authentication failed
# … 28P01" → Keycloak crash-loop). Catch it here, before the pull/up, rather
# than let the operator debug a healthy-looking-but-broken stack. Only fires
# when the script itself generated the password (a hand-set password is left
# untouched, so this can't detect that case — a manual restore/wipe is needed).
if [[ -z "$pg_host" && " ${REPAIRED[*]:-} " == *" POSTGRES_PASSWORD "* ]] \
   && docker volume ls -q -f name=tms_postgres_data 2>/dev/null | grep -q .; then
    warn "An existing bundled Postgres volume (tms_postgres_data) was found, but POSTGRES_PASSWORD was just (re)generated."
    warn "Postgres keeps the password from its first init, so login + Keycloak will fail (28P01) until the volume is reset."
    if ensure_prompt_fd; then
        ask_yes_no wipe_vol "  Reset the DB volume now so the new password applies? (bundled DB data is lost)" n
        if [[ "$wipe_vol" == yes ]]; then
            docker compose "${COMPOSE_ARGS[@]}" down -v >/dev/null 2>&1 || docker volume rm tms_postgres_data >/dev/null 2>&1 || true
            log "Removed tms_postgres_data — Postgres will re-initialise with the current password."
        else
            warn "Keeping it — run  docker compose ${COMPOSE_DISPLAY} down -v  to reset, or restore the previous POSTGRES_PASSWORD in .env."
        fi
    else
        warn "Run  docker compose ${COMPOSE_DISPLAY} down -v  to reset the DB, or restore the previous POSTGRES_PASSWORD in .env."
    fi
fi

log "Pulling images from GHCR"
docker compose "${COMPOSE_ARGS[@]}" pull --quiet

log "Starting stack (postgres, keycloak, apiservice, web)"
docker compose "${COMPOSE_ARGS[@]}" up -d

# ── 5. Done — print next steps ─────────────────────────────────────────────
# Read host-port overrides from .env so the printed URLs match what compose
# actually published. Defaults mirror the `${VAR:-NNNN}` fallbacks in docker-compose.yml.
read_env_value() {
    local key="$1" default="$2" val
    # `|| true` so a missing key (grep exit 1 + pipefail) doesn't trip set -e
    # under shells that have `shopt -s inherit_errexit` enabled. Values here
    # (ports, URLs, IPs, CIDRs) carry no internal whitespace, so trimming is safe.
    val=$(grep -E "^${key}=" .env 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '[:space:]' || true)
    printf '%s' "${val:-$default}"
}
WEB_PORT=$(read_env_value WEB_HTTP_PORT 8081)
API_PORT=$(read_env_value API_HTTP_PORT 8080)
KC_PORT=$(read_env_value KEYCLOAK_HTTP_PORT 8090)
# Public URLs the browser actually uses — reflect the chosen exposure mode so the
# footer prints the right address (localhost / LAN IP / proxy hostname).
WEB_PUBLIC=$(read_env_value WEB_PUBLIC_BASE_URL "http://localhost:$WEB_PORT")
API_PUBLIC=$(read_env_value API_PUBLIC_BASE_URL "http://localhost:$API_PORT")

cat <<EOF

──────────────────────────────────────────────────────────────────────────
  TMS is starting up. First boot takes ~60s for Keycloak to import the realm.

  Open in your browser   $WEB_PUBLIC
  API (browser-facing)   $API_PUBLIC
  Keycloak console       http://localhost:$KC_PORT   (stays loopback by default)

  First run: open the Web UI — it redirects to the /setup wizard where you
  create your admin account. (Prefer demo data + demo logins instead? Set
  DEMO_SEEDER_ENABLED=true in $TMS_DIR/.env and re-run docker compose up -d
  BEFORE completing /setup.)

  Change how it's reached (localhost / LAN / reverse proxy): edit BIND_ADDRESS,
  the *_PUBLIC_BASE_URL variables, and REQUIRE_HTTPS in $TMS_DIR/.env, then
  docker compose up -d. Details (firewall, caveats, nginx): see the "LAN access"
  section in .env.example or the README. A fresh interactive install can set
  these for you — run install.sh in a terminal.

  Logs:     docker compose $COMPOSE_DISPLAY logs -f
  Status:   docker compose $COMPOSE_DISPLAY ps
  Stop:     docker compose $COMPOSE_DISPLAY down
  Wipe:     docker compose $COMPOSE_DISPLAY down -v   (drops DB)

  PWA offline demo: open the Web UI once on this machine to prime the
  service-worker cache, then stop the stack or disconnect the network and
  reload. Service workers register only on https:// or http://localhost,
  so cross-machine demos need SSH port-forwarding or a TLS reverse proxy.
EOF

if [[ -n "${GENERATED_KEYCLOAK_PW:-}" && -t 1 ]]; then
    # Only echo the freshly-generated admin password when stdout is a TTY —
    # the value is persisted in .env regardless, and printing it would leak
    # the credential into CI logs / shell transcripts when piped to a file.
    cat <<EOF

  Generated Keycloak admin password (stored in $TMS_DIR/.env):
    KEYCLOAK_ADMIN_PASSWORD=$GENERATED_KEYCLOAK_PW
EOF
elif [[ -n "${GENERATED_KEYCLOAK_PW:-}" ]]; then
    cat <<EOF

  Generated Keycloak admin password is stored in $TMS_DIR/.env.
  Open that file from a TTY to retrieve it (not echoed here to avoid log leaks).
EOF
fi

echo "──────────────────────────────────────────────────────────────────────────"
