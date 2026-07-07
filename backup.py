#!/usr/bin/env python3
"""Database backups for all projects in ~/Desktop/apps.

Tiers:
  hourly -> local disk   (~/backups/<project>/hourly_*.sql.gz,  keep 48)
  daily  -> Google Drive (rclone remote, daily_*.sql.gz,        keep 30)
  weekly -> USB stick    (/mnt/backup-usb/<project>/weekly_*,   keep 7)

Runs every hour via backup.timer. The daily/weekly tiers reuse the freshest
hourly dump, so all tiers contain identical data. Tier scheduling is based on
a state file, so missed runs (server was off) catch up automatically thanks
to Persistent=true on the timer.

Failures are logged to configs/logs/backup_<timestamp>.log and POSTed to the
healthcheck URL from configs/healthcheck.txt (if set).
"""

import gzip
import json
import shutil
import subprocess
import sys
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path

APPS_DIR = Path("/home/piatek/Desktop/apps")
CONFIG_DIR = APPS_DIR / "configs"
LOG_DIR = CONFIG_DIR / "logs"
STATE_FILE = CONFIG_DIR / "backup_state.json"
BACKUP_DIR = Path("/home/piatek/backups")
USB_DIR = Path("/mnt/backup-usb")
RCLONE_REMOTE = "gdrive:ServerBackups"

KEEP_HOURLY = 48
KEEP_DAILY = 30
KEEP_WEEKLY = 7

DAILY_EVERY = timedelta(hours=23)      # a bit less than 24h to tolerate drift
WEEKLY_EVERY = timedelta(days=6, hours=12)

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
        url = hc_file.read_text(encoding="utf-8").strip().splitlines()
        url = url[0].strip() if url else ""
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
    projects = []
    for path in sorted(APPS_DIR.iterdir()):
        if path.is_dir() and path.name != "configs" and (path / "docker-compose.yml").exists():
            projects.append(path)
    return projects


def db_container_id(project: Path) -> str:
    result = run(["docker", "compose", "ps", "-q", "db"], cwd=project)
    return result.stdout.decode().strip() if result.returncode == 0 else ""


def make_hourly_dump(project: Path) -> Path | None:
    """pg_dump the project's db container into a gzipped local file."""
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

    dest_dir = BACKUP_DIR / name
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / f"hourly_{TS}.sql.gz"

    result = run(["docker", "exec", container, "pg_dump", "-U", db_user, db_name])
    if result.returncode != 0:
        error(f"{name}: pg_dump failed: {result.stderr.decode(errors='replace')[:500]}")
        return None

    with gzip.open(dest, "wb") as f:
        f.write(result.stdout)
    log(f"{name}: hourly dump OK ({dest.stat().st_size} bytes) -> {dest}")
    return dest


def prune_local(directory: Path, prefix: str, keep: int) -> None:
    files = sorted(directory.glob(f"{prefix}_*.sql.gz"))
    for old in files[:-keep] if keep else files:
        old.unlink()
        log(f"Pruned {old}")


def daily_to_gdrive(name: str, dump: Path) -> bool:
    if not shutil.which("rclone"):
        error("rclone is not installed — daily tier skipped")
        return False
    remote_dir = f"{RCLONE_REMOTE}/{name}"
    remote_file = f"{remote_dir}/daily_{TS}.sql.gz"
    result = run(["rclone", "copyto", str(dump), remote_file])
    if result.returncode != 0:
        error(f"{name}: rclone upload failed: {result.stderr.decode(errors='replace')[:500]}")
        return False
    log(f"{name}: daily uploaded -> {remote_file}")

    listing = run(["rclone", "lsf", remote_dir])
    if listing.returncode == 0:
        files = sorted(
            f for f in listing.stdout.decode().splitlines() if f.startswith("daily_")
        )
        for old in files[:-KEEP_DAILY]:
            run(["rclone", "deletefile", f"{remote_dir}/{old}"])
            log(f"{name}: pruned remote {old}")
    return True


def weekly_to_usb(name: str, dump: Path) -> bool:
    if not USB_DIR.is_mount():
        error(f"USB stick is not mounted at {USB_DIR} — weekly tier skipped")
        return False
    dest_dir = USB_DIR / name
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / f"weekly_{TS}.sql.gz"
    shutil.copy2(dump, dest)
    log(f"{name}: weekly copied -> {dest}")
    prune_local(dest_dir, "weekly", KEEP_WEEKLY)
    return True


def main() -> int:
    state = load_state()
    now = datetime.now()

    def due(key: str, interval: timedelta) -> bool:
        last = state.get(key)
        if not last:
            return True
        try:
            return now - datetime.fromisoformat(last) >= interval
        except ValueError:
            return True

    daily_due = due("last_daily", DAILY_EVERY)
    weekly_due = due("last_weekly", WEEKLY_EVERY)
    log(f"Backup run: hourly=yes daily={'yes' if daily_due else 'no'} "
        f"weekly={'yes' if weekly_due else 'no'}")

    daily_ok = weekly_ok = True
    for project in find_projects():
        dump = make_hourly_dump(project)
        if dump is None:
            continue
        prune_local(BACKUP_DIR / project.name, "hourly", KEEP_HOURLY)
        if daily_due:
            daily_ok = daily_to_gdrive(project.name, dump) and daily_ok
        if weekly_due:
            weekly_ok = weekly_to_usb(project.name, dump) and weekly_ok

    if daily_due and daily_ok:
        state["last_daily"] = now.isoformat()
    if weekly_due and weekly_ok:
        state["last_weekly"] = now.isoformat()
    save_state(state)

    if errors:
        post_healthcheck("backup", "Backup errors:\n" + "\n".join(errors))
        log("Done with errors")
        return 1
    if daily_due and daily_ok:
        post_healthcheck("backup", f"backup OK {TS}")
    log("Done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
