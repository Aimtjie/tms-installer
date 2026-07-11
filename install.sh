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

log "Pulling images from GHCR"
docker compose "${COMPOSE_ARGS[@]}" pull --quiet

log "Starting stack (postgres, keycloak, apiservice, web)"
docker compose "${COMPOSE_ARGS[@]}" up -d

# ── 5. Done — print next steps ─────────────────────────────────────────────
# Read host-port overrides from .env so the printed URLs match what compose
# actually published. Defaults mirror the `${VAR:-NNNN}` fallbacks in docker-compose.yml.
read_env_port() {
    local key="$1" default="$2" val
    # `|| true` so a missing key (grep exit 1 + pipefail) doesn't trip set -e
    # under shells that have `shopt -s inherit_errexit` enabled.
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

  First run: open the Web UI — it redirects to the /setup wizard where you
  create your admin account. (Prefer demo data + demo logins instead? Set
  DEMO_SEEDER_ENABLED=true in $TMS_DIR/.env and re-run docker compose up -d
  BEFORE completing /setup.)

  LAN access: set BIND_ADDRESS=0.0.0.0 and point the *_PUBLIC_BASE_URL
  variables in $TMS_DIR/.env at this machine's LAN IP, then re-run
  docker compose up -d. Details (firewall, caveats): see the "LAN access"
  section in .env.example or the README.

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
