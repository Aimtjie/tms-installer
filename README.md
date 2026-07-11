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

**First boot takes ~60 seconds** — Keycloak needs to import the realm before the API can start. The stack runs in **Production mode**: on first run, open the Web UI and the **setup wizard** prompts you to create your administrator account (see [First run](#first-run) below).

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

## First run

Open the Web UI at http://localhost:8081. With no accounts yet, it redirects to the **`/setup` wizard**, where you create your administrator account — no default password ships with the stack.

> Prefer demo data for a quick look? Set `DEMO_SEEDER_ENABLED=true` in `./tms/.env` and re-apply (`docker compose --project-directory ~/tms up -d`) **before** completing setup. That seeds demo tenants and the `admin@tms.local` / `Admin@1234` login. It's convenient for evaluation but weak for anything reachable by others — don't enable it on an exposed stack.

## LAN / remote access

By default the stack binds to `127.0.0.1`, so it's reachable only from the machine it runs on. To reach it from other devices on your network:

1. In `./tms/.env`, set `BIND_ADDRESS=0.0.0.0` (web + api listen on all interfaces).
2. Point the public URLs at this machine's LAN IP (keep each a single origin):
   ```
   WEB_PUBLIC_BASE_URL=http://192.168.1.50:8081
   API_PUBLIC_BASE_URL=http://192.168.1.50:8080
   KEYCLOAK_PUBLIC_BASE_URL=http://192.168.1.50:8090
   ```
   Browsing from the host itself (`localhost` / `127.0.0.1`) keeps working.
3. Apply: `docker compose --project-directory ~/tms up -d`
4. If the host runs a firewall (Ubuntu `ufw`), allow the app ports:
   ```bash
   sudo ufw allow 8081/tcp   # web
   sudo ufw allow 8080/tcp   # api (the browser calls it directly)
   ```

**Caveats**

- **ufw does not gate this stack.** Docker publishes ports through its own iptables rules, which bypass ufw — `BIND_ADDRESS`, not the firewall, is what actually controls exposure. The ufw rules above are defence-in-depth for any non-Docker services on the host.
- **Plain HTTP.** LAN traffic is unencrypted — fine for evaluation. For anything more, put a TLS-terminating reverse proxy in front, then set `REQUIRE_HTTPS=true` and `TRUSTED_PROXY_CIDR` (see the comments in `.env`).
- **The Keycloak admin console stays loopback-only** regardless of `BIND_ADDRESS`. Set `KEYCLOAK_BIND_ADDRESS=0.0.0.0` (and `ufw allow 8090/tcp`) only if you need Entra SSO browser redirects or remote console access.
- **PWA / offline** features need `https://` or `http://localhost`, so they're inactive when browsing via a LAN IP.
- If this install previously ran with demo seeding, the demo accounts still exist in the database — change or remove them before exposing the stack.

## Configuration

Edit `./tms/.env` before or after running the installer. Key variables:

| Variable | Purpose |
|---|---|
| `JWT_SECRET` | JWT signing secret (auto-generated) |
| `BLIND_INDEX_SECRET` | Search encryption HMAC key (auto-generated, **do not change after first boot**) |
| `POSTGRES_PASSWORD` | Database password (auto-generated) |
| `KEYCLOAK_ADMIN_PASSWORD` | Keycloak admin password (auto-generated) |
| `WEB_HTTP_PORT` / `API_HTTP_PORT` / `KEYCLOAK_HTTP_PORT` | Host ports (defaults: 8081 / 8080 / 8090) |
| `BIND_ADDRESS` | Interface the web + api ports bind to (default: `127.0.0.1`; `0.0.0.0` for LAN) |
| `KEYCLOAK_BIND_ADDRESS` | Bind for the Keycloak console (default: `127.0.0.1`; independent of `BIND_ADDRESS`) |
| `WEB_PUBLIC_BASE_URL` / `API_PUBLIC_BASE_URL` / `KEYCLOAK_PUBLIC_BASE_URL` | Origins the browser hits — mirror your host/ports or LAN IP |
| `ASPNETCORE_ENVIRONMENT` | `Production` (default; `/setup` first-run) or `Development` |
| `DEMO_SEEDER_ENABLED` | Seed demo tenants + `admin@tms.local` login — `true`/`false` (default false) |
| `REQUIRE_HTTPS` | Force Secure cookies — `true` only behind a TLS proxy — `true`/`false` (default false) |
| `TRUSTED_PROXY_CIDR` | CIDR whose `X-Forwarded-*` headers are trusted (default: loopback only) |
| `TICKET_NUMBER_PREFIX` | Ticket number prefix, e.g. `SS-1` (default: SS) |

After editing `.env`, apply changes with:

```bash
docker compose --project-directory ~/tms up -d
```

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

## Re-running the installer / upgrading

Safe to re-run at any time — this is also the upgrade path. Your `.env` values are always preserved. The managed files (`docker-compose.yml`, `.env.example`, the Postgres init script, the realm config) are refreshed to the latest published versions; if you had edited one locally, your copy is kept beside it as `<file>.bak`.

```bash
curl -fsSL https://raw.githubusercontent.com/Aimtjie/tms-installer/main/install.sh | bash
docker compose --project-directory ~/tms up -d
```

To pull newer images without re-running the installer:

```bash
docker compose --project-directory ~/tms pull
docker compose --project-directory ~/tms up -d
```

## PWA offline mode

Open the Web UI once on the machine to prime the service-worker cache. After that, the UI continues to work if the stack is stopped or the network is disconnected.

> **Note:** Service workers only register on `https://` or `http://localhost`. For cross-machine demos, use SSH port-forwarding or a TLS reverse proxy.
