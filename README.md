# Ticket Management System — Installer

One-shot installer for the Ticket Management System. Runs on any Ubuntu machine with Docker. No git clone, no .NET SDK, no build step required.

## Prerequisites

```bash
sudo apt-get update
sudo apt-get install -y curl docker.io docker-compose-v2 openssl
sudo usermod -aG docker $USER && newgrp docker
```

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Aimtjie/tms-installer/main/install.sh | bash
```

The script will:
1. Download `docker-compose.yml`, `.env.example`, the Postgres init script, and the Keycloak realm config into a `./tms/` directory
2. Create a `.env` file from the template and auto-generate secure random values for all required secrets
3. Pull the pre-built images from GHCR
4. Start all four services with `docker compose up -d`

**First boot takes ~60 seconds** — Keycloak needs to import the realm before the API can start.

### Interactive setup

When run in a terminal (including the `curl … | bash` line above), the installer prompts on **first install** for the settings people most often change, and writes them into `.env` for you:

- **PostgreSQL** — bundled container (default) or an [external server](#external-postgresql).
- **Host ports** — Web / API / Keycloak (defaults 8081 / 8080 / 8090).
- **How you'll reach it** — this machine only, your **LAN**, or behind a **TLS reverse proxy** (see [Remote access](#remote-access-lan-and-reverse-proxy)).

Prefer non-interactive? Set `TMS_NONINTERACTIVE=1` (or pipe with no terminal available) and the installer keeps the template defaults + auto-generated secrets. Re-runs never re-prompt — they preserve your existing `.env`.

## Custom install directory

```bash
curl -fsSL https://raw.githubusercontent.com/Aimtjie/tms-installer/main/install.sh | TMS_DIR=/opt/tms bash
```

## Services

| Service  | Default port | URL |
|----------|-------------|-----|
| Web UI   | 8081 | http://localhost:8081 |
| API      | 8080 | http://localhost:8080 |
| Keycloak | 8090 | http://localhost:8090 |
| Postgres | —    | internal only |

On first boot the Web UI redirects to a **`/setup` wizard** to create your admin account — the default (Production) mode ships **no** demo accounts. Prefer demo data for a quick look? Set `DEMO_SEEDER_ENABLED=true` in `.env` before first boot for demo tenants and a demo login (`admin@tms.local` / `Admin@1234`).

## Configuration

Edit `./tms/.env` before or after running the installer. Key variables:

| Variable | Purpose |
|---|---|
| `JWT_SECRET` | JWT signing secret (auto-generated) |
| `BLIND_INDEX_SECRET` | Search encryption HMAC key (auto-generated, **do not change after first boot**) |
| `POSTGRES_PASSWORD` | Database password (auto-generated) |
| `KEYCLOAK_ADMIN_PASSWORD` | Keycloak admin password (auto-generated) |
| `WEB_HTTP_PORT` | Web UI host port (default: 8081) |
| `API_HTTP_PORT` | API host port (default: 8080) |
| `KEYCLOAK_HTTP_PORT` | Keycloak host port (default: 8090) |
| `TICKET_NUMBER_PREFIX` | Ticket number prefix, e.g. `SS-1` (default: SS) |
| `BIND_ADDRESS` | Interface the web + API ports publish on. `127.0.0.1` (default) = this machine only; `0.0.0.0` = reachable on the LAN (see [Remote access](#remote-access-lan-and-reverse-proxy)) |
| `*_PUBLIC_BASE_URL` | Origins the browser uses for Web / API / Keycloak — must match how you reach the stack (LAN IP or proxy hostname) |
| `REQUIRE_HTTPS` | `true` when a TLS reverse proxy fronts the stack (Secure cookies + HSTS) |
| `PG_HOST` | Set to use an [external PostgreSQL](#external-postgresql) server instead of the bundled container |

> Tip: `install.sh` prompts for Postgres (bundled/external), host ports, and LAN / reverse-proxy exposure on first run — you don't have to hand-edit these.

After editing `.env`, apply changes with:

```bash
docker compose --project-directory ~/tms up -d
```

## Remote access (LAN and reverse proxy)

By default the stack binds to `127.0.0.1`, so it's reachable only from the machine running it — browsing from another device gives **connection refused** until you expose it. The installer's [interactive setup](#interactive-setup) configures this; to do it by hand, edit `.env` and re-run `docker compose --project-directory ~/tms up -d`.

### On your LAN (plain HTTP)

```dotenv
BIND_ADDRESS=0.0.0.0
WEB_PUBLIC_BASE_URL=http://<SERVER_LAN_IP>:8081
API_PUBLIC_BASE_URL=http://<SERVER_LAN_IP>:8080
```

- Set **both** the bind address **and** the URLs — Production-mode CORS and the `/setup` origin check are exact-match, so a mismatched origin loads the page but rejects its own API calls. The browser calls the API directly, so port **8080** must be reachable too (both are governed by `BIND_ADDRESS`).
- Traffic is **plain HTTP** — fine for LAN evaluation. PWA/offline features stay inactive over a bare IP (they need `https://` or `http://localhost`).
- `ufw` does **not** gate Docker-published ports (Docker's iptables rules bypass it), so `BIND_ADDRESS` is the real control. On a **cloud VM**, open inbound TCP `8081` + `8080` in the provider's security group.

### Behind a TLS reverse proxy (nginx / Caddy / Traefik)

For anything beyond LAN evaluation, terminate TLS in a reverse proxy and set:

```dotenv
WEB_PUBLIC_BASE_URL=https://tickets.example.com
API_PUBLIC_BASE_URL=https://api.example.com
REQUIRE_HTTPS=true
TRUSTED_PROXY_CIDR=127.0.0.1/32   # where the proxy's traffic ENTERS the app
```

- `REQUIRE_HTTPS=true` issues Secure cookies + HSTS and trusts `X-Forwarded-Proto: https` from your proxy — set it only once TLS actually fronts the stack.
- `TRUSTED_PROXY_CIDR` is where the proxy connects **from**: the loopback default for a proxy on the same host reaching `127.0.0.1`, or the Docker network CIDR for a proxy running as a container.
- The browser calls the **API** directly, so give it its own public hostname and proxy `server` block (not a path under the web host).
- Choosing reverse-proxy mode in the interactive setup writes a ready-to-edit **`nginx.tms.conf.example`** next to `.env`.

## External PostgreSQL

To use an existing PostgreSQL server instead of the bundled container, set in `.env`:

```dotenv
PG_HOST=db.internal
PG_PORT=5432
POSTGRES_USER=postgres
POSTGRES_PASSWORD=<the existing server's password>
```

Both **`ticketdb`** and **`keycloakdb`** must already exist on that server (see `scripts/postgres-init/01-create-databases.sh` for the exact SQL). `install.sh` auto-activates `docker-compose.external-pg.yml` — which disables the bundled Postgres — whenever `PG_HOST` is set. The interactive setup can configure all of this for you.

## Common commands

```bash
# View logs (all services)
docker compose --project-directory ~/tms logs -f

# View logs for a specific service
docker compose --project-directory ~/tms logs -f apiservice

# Check service status
docker compose --project-directory ~/tms ps

# Stop the stack
docker compose --project-directory ~/tms down

# Wipe everything (database + Keycloak state — irreversible)
docker compose --project-directory ~/tms down -v
```

## Re-running the installer

Safe to re-run at any time. Existing `.env` values are preserved, existing files are not overwritten, and `docker compose up -d` is idempotent.

```bash
curl -fsSL https://raw.githubusercontent.com/Aimtjie/tms-installer/main/install.sh | bash
```

## Updating to a newer version

Pull the latest images and restart:

```bash
docker compose --project-directory ~/tms pull
docker compose --project-directory ~/tms up -d
```

## PWA offline mode

Open the Web UI once on the machine to prime the service-worker cache. After that, the UI continues to work if the stack is stopped or the network is disconnected.

> **Note:** Service workers only register on `https://` or `http://localhost`. For cross-machine demos, use SSH port-forwarding or a TLS reverse proxy.
