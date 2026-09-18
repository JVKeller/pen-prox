# pen-prox — Penpot on Proxmox, without Docker

A [community-scripts](https://github.com/community-scripts/ProxmoxVED) style helper
script that installs [Penpot](https://penpot.app) into a **single Debian 13 LXC**,
built natively from Penpot's own source. No Docker, no Compose, no container runtime
inside the container.

Tested on Proxmox VE with Penpot 2.17.x.

---

## Why no Docker

Penpot ships as five Docker images behind a Compose file. That's the only install path
upstream documents. On Proxmox, that means Docker inside an LXC (nested, and awkward on
unprivileged containers) or a full VM just to host a container runtime.

The helper script skips all of it. Everything is a plain systemd service on Debian.

**What that saves you:**

| Docker Compose path | This script |
| --- | --- |
| Install Docker + Compose in the LXC (or a VM) | Nothing to install |
| 5 containers with an internal bridge network | 3 systemd services on localhost |
| Traefik or the bundled proxy container | System Nginx on port 80 |
| A `postgres:15` container | Debian's PostgreSQL 16 |
| A `valkey:8` container | Debian's `valkey-server` |
| Volume mounts and container UID mapping | Normal paths owned by a `penpot` user |
| `docker compose pull`, then recreate containers | `update` in the helper menu |
| Env spread across `docker-compose.yaml` services | One `/opt/penpot/penpot.env` |
| Logs via `docker logs` | `journalctl -u penpot-backend` |
| Nested virtualization / privileged container concerns | Unprivileged LXC, no nesting |

You also get one backup unit that actually means something: a Proxmox snapshot or
vzdump of the container is the whole application, database included.

---

## Install

On the Proxmox host:

```bash
curl -fsSL https://raw.githubusercontent.com/community-scripts/core/main/tools/run.sh |
  bash -s -- https://raw.githubusercontent.com/JVKeller/pen-prox/main ct/penpot.sh
```

Defaults: Debian 13, unprivileged, 4 vCPU, 8 GB RAM, 40 GB disk. Pick **Verbose** mode
the first time so you can watch the build.

**The install compiles Penpot from source, so expect 30–90 minutes.** Nothing is
wrong if it sits on the frontend build for a while.

### First login

1. Browse to `http://<container-ip>`.
2. Register the first account. Registration is open by default and email verification
   is off, so the account is usable immediately.
3. Lock it down afterwards: remove `enable-registration` from `PENPOT_FLAGS` in
   `/opt/penpot/penpot.env` and from `/opt/penpot/config.js`, then
   `systemctl restart penpot-backend` and `systemctl reload nginx`.
4. Database credentials are saved to `~/penpot.creds` in the container.

---

## What gets installed

| Piece | How it runs | Port |
| --- | --- | --- |
| Frontend | Static files at `/opt/penpot/frontend`, served by Nginx | 80 |
| Backend | JVM, `penpot-backend.service` | 6060 |
| Exporter | Node + Playwright Chromium, `penpot-exporter.service` | 6061 |
| MCP server | Node, multi-user mode, `penpot-mcp.service` | 4401–4403 |
| PostgreSQL 16 | `postgresql.service` | 5432 |
| Valkey | `valkey-server.service` | 6379 |

Only Nginx listens on the LAN. Everything else is bound to localhost.

**Paths:**

- `/opt/penpot/penpot.env` — all backend, exporter and MCP settings
- `/opt/penpot/config.js` — frontend feature flags (copied into the frontend on each build)
- `/opt/penpot/data/assets` — uploaded files and media
- `/opt/penpot/build.sh` — build and deploy, reused by the updater
- `/opt/penpot-src` — the release source tree

---

## Dependencies

Installed via `apt` during setup:

- `build-essential`, `git`, `rsync`, `jq`, `openssl`, `sudo`
- `python3`, `python3-tabulate`, `fontforge`, `woff2`, `imagemagick`
- `fontconfig`, `libfreetype6`
- `nginx`, `valkey-server`
- PostgreSQL 16 (via the community-scripts `setup_postgresql` helper)

Plus the build toolchain listed below.

---

## Updating

Run the same command you used to install, and choose **Update** from the menu. The
script:

1. Checks GitHub for a newer Penpot release and exits if you're current.
2. Stops the MCP, exporter and backend services.
3. Downloads the new release source to `/opt/penpot-src`.
4. Runs `/opt/penpot/build.sh`, which compiles the frontend, backend, exporter and MCP
   server, then swaps the deployed copies.
5. Restarts the services and reloads Nginx. The backend applies its own database
   migrations on startup.

Your `penpot.env`, `config.js`, assets and database are left untouched.

**Updates rebuild from source, so budget the same 30–90 minutes.** Snapshot the
container first; a rollback is then a one-click restore.

---

## Build toolchain

Installed once into the container and kept, because updates rebuild from source.
Versions are pinned to Penpot's `docker/devenv/Dockerfile`, and need rechecking when
upstream bumps them.

- Azul Zulu JDK 26 at `/opt/jdk` (fetched via the Azul metadata API)
- Clojure CLI at `/opt/clojure`, plus Babashka
- Node 24 with corepack and pnpm
- Rust 1.91.0 with the `wasm32-unknown-emscripten` target, and emsdk 4.0.6 at `/opt/emsdk`,
  for Penpot's `render-wasm` module (Skia comes prebuilt and isn't compiled)
- ImageMagick 7 for backend media processing

The compiling itself is done by Penpot's own `frontend/`, `backend/`, `exporter/` and
`mcp/scripts/build` scripts — the same ones upstream runs to produce their Docker
images. This project only supplies the LXC, the toolchain, the Nginx config and the
systemd units.

---

## MCP (AI clients)

The MCP server is enabled by default, which lets Claude Code and similar clients drive
Penpot directly.

1. In Penpot: **Settings → Integrations**, create an MCP key.
2. Open a design file and connect the **MCP plugin**. The plugin has to stay open,
   because the server reaches Penpot through your browser session.
3. Add the server to your client:
   ```bash
   claude mcp add penpot -t http "http://<container-ip>/mcp/stream?userToken=<KEY>"
   ```
   Claude Desktop needs the `mcp-remote` bridge with `--allow-http`. Claude.ai web
   connectors need a public HTTPS URL, so those require a reverse proxy.

---

## HTTPS / reverse proxy

The default config assumes plain HTTP on the LAN, so secure session cookies are
disabled. Behind a proxy:

1. Set `PENPOT_PUBLIC_URI=https://penpot.example.com` in `/opt/penpot/penpot.env`.
2. Remove `disable-secure-session-cookies` from `PENPOT_FLAGS`.
3. Forward WebSockets for `/ws/notifications` and `/mcp/ws`.
4. `systemctl restart penpot-backend penpot-exporter penpot-mcp`

---

## Troubleshooting

```bash
systemctl status penpot-backend penpot-exporter penpot-mcp
journalctl -u penpot-backend -f
ss -tlnp | grep -E '6060|6061|440'      # should all be 127.0.0.1
curl -s localhost:6060/readyz           # backend health
```

Two harmless warnings show up during the build: an "unreachable code" lint warning from
Penpot's own ClojureScript, and a `/opt/penpot/common` missing-directory warning from
the MCP setup step. The MCP types are bundled into its `index.js`, and upstream's
Docker image reports the same thing.

Exports failing usually means Chromium dependencies. Re-run
`cd /opt/penpot/exporter && pnpm exec playwright install-deps chromium`.

---

## Status and license

Working, but young. Filed as a candidate for
[community-scripts/ProxmoxVED](https://github.com/community-scripts/ProxmoxVED)
(see discussion #1143, which asked for exactly this). Scripts are MIT, matching
community-scripts. Penpot itself is MPL-2.0 and belongs to the Penpot project.