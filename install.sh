#!/usr/bin/env bash
# Ticket Management System — one-shot local installer.
#
# Pulls the four files compose needs (compose file, .env template, postgres
# init script, Keycloak realm) from GitHub raw and brings the stack up using
# the pre-built GHCR images. No git clone, no .NET SDK, no build.
#
#   curl -fsSL https://raw.githubusercontent.com/Aimtjie/tms-installer/main/install.sh | bash
#
# Or with a custom target directory:
#   curl -fsSL .../install.sh | TMS_DIR=/opt/tms bash
#
# Re-running is safe: existing .env values are preserved, existing files are
# not overwritten, and `docker compose up -d` is idempotent.

set -euo pipefail

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/Aimtjie/tms-installer/main}"
TMS_DIR="${TMS_DIR:-$PWD/tms}"
# Expand a leading `~` ourselves — bash skips tilde expansion when the value
# was quoted at assignment (e.g. `TMS_DIR="~/tms" bash install.sh`).
TMS_DIR="${TMS_DIR/#\~/$HOME}"

log()  { printf '\033[1;34m[tms]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[tms]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[tms]\033[0m %s\n' "$*" >&2; exit 1; }

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

# ── 2. Fetch the four files compose needs ──────────────────────────────────
log "Target directory: $TMS_DIR"
mkdir -p "$TMS_DIR/scripts/postgres-init" "$TMS_DIR/ticket-management-system.AppHost/Realms"
cd "$TMS_DIR"

fetch() {
    local path="$1"
    # -s (non-empty) instead of -f (exists) so a zero-byte file from a prior
    # interrupted run is not silently "kept". Download to .tmp and rename so a
    # mid-flight Ctrl-C leaves nothing at the real path for the next run.
    if [[ -s "$path" ]]; then
        log "  keeping existing $path"
    else
        log "  downloading $path"
        curl -fsSL "$REPO_RAW/$path" -o "$path.tmp"
        mv "$path.tmp" "$path"
    fi
}

fetch docker-compose.yml
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
if [[ ! -f .env ]]; then
    log "Creating .env from .env.example"
    # Subshell so the tight umask doesn't leak into later commands. cp
    # respects umask for the destination file, so .env lands at 0600
    # atomically — no transient world-readable window before chmod runs.
    (umask 077 && cp .env.example .env)
fi
# Always enforce 0600 — covers the re-run case where someone has loosened
# the file mode by hand. No-op on the freshly-cp'd path above.
chmod 600 .env

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
        value=$(generate_secret "$key")
        SED_ARGS+=(-e "s|^${key}=(CHANGE_ME)?[[:space:]]*\$|${key}=${value}|")
        REPAIRED+=("$key")
    elif ! grep -qE "^${key}=" .env; then
        value=$(generate_secret "$key")
        APPEND_LINES+=("${key}=${value}")
        REPAIRED+=("$key")
    fi
    [[ -n "$value" && "$key" == "KEYCLOAK_ADMIN_PASSWORD" ]] && GENERATED_KEYCLOAK_PW="$value"
done

if [[ ${#REPAIRED[@]} -gt 0 ]]; then
    log "Repaired/added required secrets: ${REPAIRED[*]}"
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

if grep -qE '^(JWT_SECRET|BLIND_INDEX_SECRET|POSTGRES_PASSWORD|KEYCLOAK_ADMIN_PASSWORD)=(CHANGE_ME|)[[:space:]]*$' .env; then
    die ".env still contains unset/placeholder values for required secrets after repair pass. Edit .env manually before bringing the stack up."
fi

# ── 4. Bring the stack up ──────────────────────────────────────────────────
log "Pulling images from GHCR"
docker compose pull --quiet

log "Starting stack (postgres, keycloak, apiservice, web)"
docker compose up -d

# ── 5. Done — print next steps ─────────────────────────────────────────────
read_env_port() {
    local key="$1" default="$2" val
    val=$(grep -E "^${key}=" .env 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '[:space:]' || true)
    printf '%s' "${val:-$default}"
}
WEB_PORT=$(read_env_port WEB_HTTP_PORT 8081)
API_PORT=$(read_env_port API_HTTP_PORT 8080)
KC_PORT=$(read_env_port KEYCLOAK_HTTP_PORT 8090)

cat <<EOF

──────────────────────────────────────────────────────────────────────────
  TMS is starting up. First boot takes ~60s for Keycloak to import the realm.

  Web UI       http://localhost:$WEB_PORT
  API          http://localhost:$API_PORT
  Keycloak     http://localhost:$KC_PORT

  Login (dev seed):  admin@tms.local  /  Admin@1234

  Logs:     docker compose --project-directory "$TMS_DIR" logs -f
  Status:   docker compose --project-directory "$TMS_DIR" ps
  Stop:     docker compose --project-directory "$TMS_DIR" down
  Wipe:     docker compose --project-directory "$TMS_DIR" down -v   (drops DB)

  PWA offline demo: open the Web UI once on this machine to prime the
  service-worker cache, then stop the stack or disconnect the network and
  reload. Service workers register only on https:// or http://localhost,
  so cross-machine demos need SSH port-forwarding or a TLS reverse proxy.
EOF

if [[ -n "${GENERATED_KEYCLOAK_PW:-}" && -t 1 ]]; then
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
