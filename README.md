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

Default login (development seed): `admin@tms.local` / `Admin@1234`

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
