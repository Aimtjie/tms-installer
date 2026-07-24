# Single-domain Docker Compose

Serve the whole Ticket Management System — web app, API, real-time notifications
and sign-in — from **one hostname** behind a reverse proxy, e.g.
`https://tms.server.domain`. One DNS record, one TLS certificate, and — because the
browser only ever talks to one origin — no cross-origin rules to get wrong.

This is an **additive overlay** on top of the root `docker-compose.yml`. It adds a
reverse proxy and overrides a handful of environment values; it does not modify the
root stack. If you just want a quick multi-port evaluation on `localhost`, use the
root stack directly — this overlay is for a real, TLS-fronted single-domain deploy.

---

## How it is laid out

Everything is served from one hostname, split by path:

```
https://tms.server.domain/         web application
https://tms.server.domain/api/     API
https://tms.server.domain/hubs/    real-time notifications (SignalR)
https://tms.server.domain/auth/    sign-in (Keycloak)
```

| Path | Goes to | Notes |
|---|---|---|
| `/api/`, `/odata/` | API | |
| `/hubs/` | API | SignalR — WebSocket |
| `/_blazor` | Web | Blazor Server circuit — WebSocket |
| `/auth/realms/`, `/auth/resources/` | Keycloak | the **only** Keycloak paths exposed publicly |
| everything else under `/auth/` | — | **blocked (403)** — admin console + metrics stay internal |
| `/` | Web | |

The proxy is the **only** service published to the outside world (ports 80 and 443).
The app and Keycloak containers stay bound to loopback and are reached by the proxy
over the internal Docker network.

---

## What you must provide

- A Linux host with Docker and the Compose v2 plugin — **v2.24.4 or newer**, because
  the overlay uses the `!reset` merge tag to un-publish the app ports (older Compose
  rejects it with a YAML parse error). Check with `docker compose version`.
- A DNS name pointing at it, e.g. `tms.server.domain`.
- A TLS certificate covering that name, **including intermediates** (or use the
  self-signed stopgap below to test first).

---

## Install

Run everything from the **repo root** (the directory that holds `docker-compose.yml`),
because the overlay's relative paths resolve from there.

```sh
# 1. Root secrets
cp .env.example .env
#    …then fill in JWT_SECRET, BLIND_INDEX_SECRET, POSTGRES_PASSWORD,
#    KEYCLOAK_ADMIN_PASSWORD (the root .env.example explains each).

# 2. Single-domain settings — append them to the same .env
cat onprem/compose/.env.single-domain.example >> .env
#    …then edit .env: set TMS_PUBLIC_URL, TMS_HOSTNAME, TLS_CERT_FILE, TLS_KEY_FILE.

# 3. Bring it up (root stack + single-domain overlay)
docker compose --env-file .env \
  -f docker-compose.yml \
  -f onprem/compose/docker-compose.single-domain.yml \
  up -d
```

Then open `https://tms.server.domain/` and follow the `/setup` wizard to create the
first administrator. There are no default accounts.

> **Only the proxy is exposed.** The overlay un-publishes the app and Keycloak host
> ports (`ports: !reset []`), so they are reachable only by the proxy over the internal
> Docker network. The proxy on 80/443 is the single ingress; `BIND_ADDRESS` has no effect.

> **`TRUSTED_PROXY_CIDR` is defined in both files.** The root `.env.example` defaults it to
> `127.0.0.1/32`; the appended single-domain block sets `172.16.0.0/12` (the proxy is a
> container, not loopback). Compose is last-wins, so the single-domain value takes effect —
> edit it in the appended section, **not** the root line, or your change is silently ignored.

### Generating a certificate for testing

To stand the system up before your real certificate arrives, generate a self-signed
one (browsers will show a trust warning — expected):

```sh
HOST=tms.server.domain
sudo mkdir -p /etc/tms/tls
sudo openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout /etc/tms/tls/privkey.pem -out /etc/tms/tls/fullchain.pem \
  -subj "/CN=$HOST" -addext "subjectAltName=DNS:$HOST"
sudo chmod 600 /etc/tms/tls/privkey.pem
```

Point `TLS_CERT_FILE` / `TLS_KEY_FILE` at those paths (the example defaults already do).

---

## Choosing a different proxy

**nginx** is the default (`onprem/compose/proxy/nginx.conf`) and needs no changes.
To use **Caddy** or **Traefik** instead, add a second small overlay that redefines the
`proxy` service. Only the proxy service differs — the rest of the stack is unchanged.

### Caddy (automatic HTTPS)

Caddy can obtain a certificate for you (delete the `tls` line in the `Caddyfile` for
ACME) and handles WebSockets automatically. Create
`onprem/compose/docker-compose.single-domain.caddy.yml`:

```yaml
name: tms
services:
  proxy:
    image: caddy:2-alpine
    # Reset the base proxy's nginx-specific /healthz healthcheck — Caddy does not serve
    # it, so it would report unhealthy. Nothing depends_on the proxy, so none is required.
    healthcheck: !reset []
    environment:
      TMS_HOSTNAME: ${TMS_HOSTNAME}
    volumes:
      - ./onprem/compose/proxy/Caddyfile:/etc/caddy/Caddyfile:ro
      - ${TLS_CERT_FILE}:/etc/caddy/tls/fullchain.pem:ro
      - ${TLS_KEY_FILE}:/etc/caddy/tls/privkey.pem:ro
      - caddy_data:/data
volumes:
  caddy_data:
```

Then append it after the single-domain overlay on the `docker compose … up -d` line
(`-f onprem/compose/docker-compose.single-domain.caddy.yml`).

### Traefik (file provider)

Replace `__TMS_HOSTNAME__` in `onprem/compose/proxy/traefik-dynamic.yml` with your
hostname, then create `onprem/compose/docker-compose.single-domain.traefik.yml`:

```yaml
name: tms
services:
  proxy:
    image: traefik:v3.1
    # Reset the base proxy's nginx-specific /healthz healthcheck (not served by Traefik).
    healthcheck: !reset []
    command:
      - --entrypoints.web.address=:80
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https
      - --entrypoints.websecure.address=:443
      - --providers.file.filename=/etc/traefik/dynamic.yml
      - --tls.certificates.certfile=/etc/traefik/tls/fullchain.pem
      - --tls.certificates.keyfile=/etc/traefik/tls/privkey.pem
    volumes:
      - ./onprem/compose/proxy/traefik-dynamic.yml:/etc/traefik/dynamic.yml:ro
      - ${TLS_CERT_FILE}:/etc/traefik/tls/fullchain.pem:ro
      - ${TLS_KEY_FILE}:/etc/traefik/tls/privkey.pem:ro
```

Then append it after the single-domain overlay on the `docker compose … up -d` line.

All three proxies implement the same routing table, including the tighter admin-path
restriction (only `/auth/realms/` and `/auth/resources/` are public). **nginx is the
verified default** — it is covered by the guard tests and driven end-to-end; the Caddy
and Traefik configs are provided as tested-by-inspection alternatives (a guard test
checks their admin-block, but confirm your chosen one — especially that
`https://<host>/auth/admin/` returns 403 — before production).

---

## Sign-in (SSO)

Username/password login works out of the box — the API validates credentials against
Keycloak over the internal network. **External SSO (Microsoft Entra / OIDC)** is served
at `https://tms.server.domain/auth` and is optional.

To enable it, set `SSO_CLIENT_SECRET` in `.env`. On startup the API registers the
callback `https://tms.server.domain/api/auth/sso/callback` on the `tms-sso` Keycloak
client automatically (from `Sso__WebRedirectBaseUrl`, which the overlay points at your
single origin — so the redirect URI templates itself, no manual realm edit). Then
configure the Microsoft Entra identity provider per tenant from the TMS app UI
(Client detail → SSO). Leave `SSO_CLIENT_SECRET` blank to keep SSO disabled.

---

## Verifying

```sh
# All services healthy (proxy + web + apiservice + keycloak + postgres)
docker compose -f docker-compose.yml -f onprem/compose/docker-compose.single-domain.yml ps

# The app answers on the single origin
curl -kI https://tms.server.domain/                       # 200 (web)
curl -kI https://tms.server.domain/api/health             # 200 (API, same origin)
curl -kI https://tms.server.domain/auth/realms/tms/.well-known/openid-configuration  # 200 (Keycloak)
curl -kso /dev/null -w '%{http_code}\n' https://tms.server.domain/auth/admin/        # 403 (blocked)
```

---

## What this is, and is not

- **Single host.** Like the root stack it targets one machine. There is **no database
  failover** — for automatic standby promotion, use the k3s target (Stage B).
- **One API replica.** Real-time notifications run through a single API instance; this
  overlay does not add the Redis SignalR backplane.
- **Additive.** It changes nothing in the root `docker-compose.yml`. Removing the two
  `-f onprem/compose/...` files returns you to the plain multi-port stack.
