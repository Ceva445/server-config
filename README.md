# server-config

Configuration for the home server (NucBox, Ubuntu) hosting projects under the
`piatek-magazyn.com` domain, published through a Cloudflare Tunnel.

## What's here

| File | Purpose |
|---|---|
| `startup.sh` | Boot script: Wi-Fi → git pull → docker compose up --build → health check → logs/alerts |
| `apps-startup.service` | systemd unit that runs `startup.sh` at boot |
| `cloudflared/ingress.yml` | Tunnel ingress rules (subdomain → local port) |
| `backup.py` | Hourly DB backups to local disk + Google Drive + USB (48 copies each, dedup) |
| `backup.service` + `backup.timer` | systemd timer that runs `backup.py` every hour |
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

## Backups

`backup.timer` runs `backup.py` every hour. Each run stores the dump in ALL
three destinations (48 copies kept in each):

| Destination | Path | Protects against |
|---|---|---|
| Ubuntu disk | `~/Desktop/backups/<project>/` | accidental data deletion |
| Google Drive | `gdrive:` (ServerBackups folder) | disk/server loss |
| USB stick | `/mnt/backup-usb/<project>/` | offline copy |

Dedup: if the database content has not changed (sha256 fingerprint in
`backup_state.json`), no new file is created — 48 copies means the last 48
real changes, not the last 48 hours. Destinations are self-healing: every run
re-checks that the newest dump exists in each place (a re-plugged USB stick
catches up automatically). Failures are POSTed to the healthcheck URL.

One-time setup requirements:
- `rclone` installed and configured with a `gdrive` remote (`rclone config`).
- USB stick labelled `bkp_pendr`, `/etc/fstab` entry (any stick with this label works;
  `user` lets backup.py mount it without root, `nofail` keeps boot safe without it):
  `LABEL=bkp_pendr /mnt/backup-usb exfat defaults,nofail,user,uid=1000,gid=1000,umask=022 0 0`

Restore example:
```bash
gunzip -c ~/Desktop/backups/szafa/backup_<ts>.sql.gz | docker exec -i szafa-db psql -U szafa_user -d szafa
```

## Rebuilding the server from scratch

1. Install Ubuntu, docker.io, docker-compose-v2, git, cloudflared.
2. `cloudflared tunnel login` + `cloudflared tunnel create piatek`
   (or move the saved `~/.cloudflared/*.json` from the old server).
3. `git clone https://github.com/Ceva445/server-config.git ~/Desktop/apps/configs`
4. Fill in `wifi.txt`, `healthcheck.txt`, `cloudflared/tunnel-secret.yml`,
   clone the projects, put the `.env` files in place.
5. `bash ~/Desktop/apps/configs/install.sh`
