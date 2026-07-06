# server-config

Configuration for the home server (NucBox, Ubuntu) hosting projects under the
`piatek-magazyn.com` domain, published through a Cloudflare Tunnel.

## What's here

| File | Purpose |
|---|---|
| `startup.sh` | Boot script: Wi-Fi → git pull → docker compose up --build → health check → logs/alerts |
| `apps-startup.service` | systemd unit that runs `startup.sh` at boot |
| `cloudflared/ingress.yml` | Tunnel ingress rules (subdomain → local port) |
| `install.sh` | Deploys everything above onto the server |
| `templates/` | Templates for secret configs (real ones live only on the server, never committed) |

## Architecture

- Each project is a folder in `~/Desktop/apps/<name>` with its own `docker-compose.yml`
  (a dedicated app container + a dedicated Postgres).
- This repository lives on the server at `~/Desktop/apps/configs` (excluded from the project loop).
- Ports: pinokio → 8000, szafa → 8001; next project → 8002 and so on.
- Cloudflare Tunnel (`cloudflared`, systemd) maps subdomains to local ports —
  no open ports on the router.

## Deploying changes

```bash
cd ~/Desktop/apps/configs
git pull
bash install.sh
```

## Adding a new project

1. Clone the project repository into `~/Desktop/apps/<name>` (the branch with docker-compose).
2. Copy its `.env` over (via scp; it never lives in git).
3. Add a block to `cloudflared/ingress.yml` (in THIS repo) before `http_status:404`:
   ```yaml
   - hostname: <name>.piatek-magazyn.com
     service: http://localhost:<port>
   ```
4. Create the DNS record: `cloudflared tunnel route dns piatek <name>.piatek-magazyn.com`
5. `git pull` + `bash install.sh` on the server — the tunnel picks up the new route,
   and `startup.sh` will bring the project up on the next boot.
   To start it right away: `sudo systemctl restart apps-startup`.

## Secrets (server only)

- `wifi.txt` — `SSID=` / `PASSWORD=` of the network to join after reboot.
- `healthcheck.txt` — a single line with the URL that receives POSTed logs of failed
  containers (empty file = logs stay local in `logs/`).
- `cloudflared/tunnel-secret.yml` — tunnel name and path to the credentials file
  (template: `templates/tunnel-secret.yml.example`); install.sh merges it with
  `cloudflared/ingress.yml` into `/etc/cloudflared/config.yml`.
- Each project's `.env` — inside the project folder itself.

## Rebuilding the server from scratch

1. Install Ubuntu, docker.io, docker-compose-v2, git, cloudflared.
2. `cloudflared tunnel login` + `cloudflared tunnel create piatek`
   (or move the saved `~/.cloudflared/*.json` from the old server).
3. `git clone https://github.com/Ceva445/server-config.git ~/Desktop/apps/configs`
4. Fill in `wifi.txt`, `healthcheck.txt`, `cloudflared/tunnel-secret.yml`,
   clone the projects, put the `.env` files in place.
5. `bash ~/Desktop/apps/configs/install.sh`
