#!/usr/bin/env python3
"""Database backups for all projects in ~/Desktop/apps.

Every run (hourly via backup.timer) stores the dump in ALL three places:
  1. local disk    ~/Desktop/backups/<project>/backup_*.sql.gz
  2. Google Drive  gdrive:<project>/backup_*.sql.gz (rclone, OAuth)
  3. USB stick     /mnt/backup-usb/<project>/backup_*.sql.gz

Dedup: the sha256 fingerprint of the dump is compared with the previous run
(backup_state.json). If the database has not changed, no new file is created —
so the kept copies cover the last N real changes, not the last N hours.
Destinations are self-healing: every run checks that the newest dump exists in
each place and copies it if missing (e.g. USB was unplugged, Drive was down).

Failures are logged to configs/logs/backup_<timestamp>.log and POSTed to the
healthcheck URL from configs/healthcheck.txt (if set).
"""

import gzip
import hashlib
import json
import os
import shutil
import subprocess
import sys
import urllib.request
from datetime import datetime
from pathlib import Path

# The systemd service runs as root, but the rclone config lives in piatek's home.
# Point rclone at it explicitly so Google Drive uploads work regardless of user.
os.environ.setdefault("RCLONE_CONFIG", "/home/piatek/.config/rclone/rclone.conf")

APPS_DIR = Path("/home/piatek/Desktop/apps")
CONFIG_DIR = APPS_DIR / "configs"
LOG_DIR = CONFIG_DIR / "logs"
STATE_FILE = CONFIG_DIR / "backup_state.json"

# Destination 1: a dedicated folder next to ~/Desktop/apps
BACKUP_DIR = Path("/home/piatek/Desktop/backups")

# Destination 2: Google Drive via rclone with an OAuth token.
# NOTE: service accounts do NOT work here — since 2025 Google gives them zero
# storage quota on personal accounts ("storageQuotaExceeded" on upload).
# One-time setup:
#   1. On any machine with a browser:  rclone authorize "drive"
#      -> log in with the Google account that owns the ServerBackups folder
#      -> copy the printed token JSON (one line).
#   2. On the server, ~/.config/rclone/rclone.conf (chmod 600):
#        [gdrive]
#        type = drive
#        scope = drive
#        token = {"access_token":"...","refresh_token":"...","expiry":"..."}
#        root_folder_id = <ID of the ServerBackups folder from its URL>
#   3. rclone refreshes the token automatically via refresh_token. If Google
#      ever revokes it (password reset etc.) — just repeat steps 1-2.
# root_folder_id already points inside ServerBackups, so the remote root is "gdrive:".
RCLONE_REMOTE = "gdrive:"

# Destination 3: USB stick, auto-mounted via /etc/fstab (by UUID, with nofail)
USB_DIR = Path("/mnt/backup-usb")

# How many copies to keep in each destination. Thanks to dedup these are
# "last N changes of the database", not "last N hours".
KEEP_LOCAL = 48
KEEP_GDRIVE = 48
KEEP_USB = 48

TS = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
LOG_FILE = LOG_DIR / f"backup_{TS}.log"

errors: list[str] = []


def log(message: str) -> None:
    line = f"{datetime.now():%Y-%m-%d %H:%M:%S} {message}"
    print(line)
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    with LOG_FILE.open("a", encoding="utf-8") as f:
        f.write(line + "\n")


def error(message: str) -> None:
    log(f"ERROR: {message}")
    errors.append(message)


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=False, **kwargs)


def read_env(env_file: Path) -> dict[str, str]:
    env = {}
    if env_file.exists():
        for line in env_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, _, value = line.partition("=")
                env[key.strip()] = value.strip()
    return env


def load_state() -> dict:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            pass
    return {}


def save_state(state: dict) -> None:
    STATE_FILE.write_text(json.dumps(state, indent=2), encoding="utf-8")


def healthcheck_url() -> str:
    hc_file = CONFIG_DIR / "healthcheck.txt"
    if hc_file.exists():
        lines = hc_file.read_text(encoding="utf-8").strip().splitlines()
        url = lines[0].strip() if lines else ""
        if url.startswith(("http://", "https://")):
            return url
    return ""


def post_healthcheck(subject: str, body: str) -> None:
    url = healthcheck_url()
    if not url:
        return
    try:
        request = urllib.request.Request(
            url,
            data=body.encode("utf-8"),
            headers={"Content-Type": "text/plain; charset=utf-8", "X-Project": subject},
            method="POST",
        )
        urllib.request.urlopen(request, timeout=15)
        log(f"Healthcheck POST sent ({subject})")
    except OSError as exc:
        log(f"WARNING: healthcheck POST failed: {exc}")


def find_projects() -> list[Path]:
    def has_compose(p: Path) -> bool:
        # some projects use docker-compose.yaml, others docker-compose.yml
        return (p / "docker-compose.yml").exists() or (p / "docker-compose.yaml").exists()
    return [
        path for path in sorted(APPS_DIR.iterdir())
        if path.is_dir() and path.name != "configs" and has_compose(path)
    ]


def db_container_id(project: Path) -> str:
    result = run(["docker", "compose", "ps", "-q", "db"], cwd=project)
    return result.stdout.decode().strip() if result.returncode == 0 else ""


def dump_fingerprint(dump: bytes) -> str:
    """sha256 of the dump content, ignoring lines that differ on every run.

    pg_dump 17+ emits \\restrict / \\unrestrict lines with a RANDOM token each
    time, so hashing the raw dump would never match. Those lines carry no data,
    they are excluded from the fingerprint (but kept in the saved file).
    """
    hasher = hashlib.sha256()
    for line in dump.splitlines():
        if line.startswith(b"\\restrict") or line.startswith(b"\\unrestrict"):
            continue
        hasher.update(line)
        hasher.update(b"\n")
    return hasher.hexdigest()


def latest_local(name: str) -> Path | None:
    files = sorted((BACKUP_DIR / name).glob("*.sql.gz"), key=lambda p: p.stat().st_mtime)
    return files[-1] if files else None


def make_dump(project: Path, state: dict) -> Path | None:
    """pg_dump into a gzipped local file; skip if the database is unchanged."""
    name = project.name
    container = db_container_id(project)
    if not container:
        log(f"Skipping {name}: no running 'db' service")
        return None

    env = read_env(project / ".env")
    db_user = env.get("POSTGRES_USER")
    db_name = env.get("POSTGRES_DB")
    if not db_user or not db_name:
        error(f"{name}: POSTGRES_USER/POSTGRES_DB not found in .env")
        return None

    result = run(["docker", "exec", container, "pg_dump", "-U", db_user, db_name])
    if result.returncode != 0:
        error(f"{name}: pg_dump failed: {result.stderr.decode(errors='replace')[:500]}")
        return None

    fingerprint = dump_fingerprint(result.stdout)
    hashes = state.setdefault("last_hash", {})
    previous = latest_local(name)
    if previous is not None and hashes.get(name) == fingerprint:
        log(f"{name}: no changes since last backup — reusing {previous.name}")
        return previous

    dest_dir = BACKUP_DIR / name
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / f"backup_{TS}.sql.gz"
    with gzip.open(dest, "wb") as f:
        f.write(result.stdout)
    hashes[name] = fingerprint
    log(f"{name}: new dump ({dest.stat().st_size} bytes) -> {dest}")

    files = sorted(dest_dir.glob("*.sql.gz"), key=lambda p: p.stat().st_mtime)
    for old in files[:-KEEP_LOCAL]:
        old.unlink()
        log(f"{name}: pruned local {old.name}")
    return dest


def mount_usb() -> bool:
    """Make sure the USB stick is mounted; try to mount it if not.

    /etc/fstab has:  LABEL=bkp_pendr /mnt/backup-usb exfat defaults,nofail,user,...
    - LABEL instead of UUID: any stick labelled bkp_pendr works (easy to swap)
    - 'user' option: mounting does not require root, so both the systemd timer
      and manual runs can mount it
    So a stick re-plugged at any time is picked up by the next backup run.
    """
    if USB_DIR.is_mount():
        return True
    result = run(["mount", str(USB_DIR)])
    if result.returncode == 0 and USB_DIR.is_mount():
        log(f"USB stick mounted at {USB_DIR}")
        return True
    return False


def ensure_on_usb(name: str, dump: Path) -> None:
    """Copy the newest dump to the USB stick unless it is already there."""
    if not mount_usb():
        error(f"USB stick is not available at {USB_DIR} (not plugged in?)")
        return
    dest_dir = USB_DIR / name
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / dump.name
    if dest.exists():
        return
    shutil.copy2(dump, dest)
    log(f"{name}: copied to USB -> {dest}")
    files = sorted(dest_dir.glob("*.sql.gz"), key=lambda p: p.stat().st_mtime)
    for old in files[:-KEEP_USB]:
        old.unlink()
        log(f"{name}: pruned USB {old.name}")


def ensure_on_gdrive(name: str, dump: Path) -> None:
    """Upload the newest dump to Google Drive unless it is already there."""
    if not shutil.which("rclone"):
        error("rclone is not installed")
        return
    remote_dir = f"{RCLONE_REMOTE}{name}"
    listing = run(["rclone", "lsf", remote_dir])
    remote_files = sorted(
        f for f in listing.stdout.decode().splitlines() if f.endswith(".sql.gz")
    ) if listing.returncode == 0 else []
    if dump.name in remote_files:
        return
    result = run(["rclone", "copyto", str(dump), f"{remote_dir}/{dump.name}"])
    if result.returncode != 0:
        error(f"{name}: rclone upload failed: {result.stderr.decode(errors='replace')[:500]}")
        return
    log(f"{name}: uploaded to Drive -> {remote_dir}/{dump.name}")
    for old in remote_files[:-(KEEP_GDRIVE - 1) or None]:
        run(["rclone", "deletefile", f"{remote_dir}/{old}"])
        log(f"{name}: pruned Drive {old}")


def main() -> int:
    state = load_state()
    log("Backup run started")

    for project in find_projects():
        dump = make_dump(project, state)
        if dump is None:
            continue
        ensure_on_usb(project.name, dump)
        ensure_on_gdrive(project.name, dump)

    save_state(state)

    if errors:
        post_healthcheck("backup", "Backup errors:\n" + "\n".join(errors))
        log("Done with errors")
        return 1
    log("Done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
