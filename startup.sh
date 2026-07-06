#!/bin/bash
# Boot-time startup for projects in ~/Desktop/apps:
# 1) waits for internet (connects to Wi-Fi from configs/wifi.txt if needed)
# 2) git pull + docker compose up --build for every project folder
# 3) verifies container state; on failure saves logs and posts them to the healthcheck URL

APPS_DIR="/home/piatek/Desktop/apps"
CONFIG_DIR="$APPS_DIR/configs"
LOG_DIR="$CONFIG_DIR/logs"
TS=$(date '+%Y-%m-%d_%H-%M-%S')
STARTUP_LOG="$LOG_DIR/startup_$TS.log"

mkdir -p "$LOG_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$STARTUP_LOG"
}

check_internet() {
    ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1
}

# ---------- 1. Internet / Wi-Fi ----------
if ! check_internet && [ -f "$CONFIG_DIR/wifi.txt" ]; then
    SSID=$(grep '^SSID=' "$CONFIG_DIR/wifi.txt" | cut -d= -f2-)
    PASSWORD=$(grep '^PASSWORD=' "$CONFIG_DIR/wifi.txt" | cut -d= -f2-)
    for attempt in $(seq 1 10); do
        log "No internet, attempt $attempt/10: connecting to Wi-Fi \"$SSID\""
        nmcli dev wifi connect "$SSID" password "$PASSWORD" >>"$STARTUP_LOG" 2>&1
        sleep 10
        if check_internet; then
            log "Internet is up"
            break
        fi
    done
fi

if ! check_internet; then
    log "ERROR: still no internet — not starting containers"
    exit 1
fi

# ---------- healthcheck URL (optional) ----------
HEALTHCHECK_URL=""
if [ -f "$CONFIG_DIR/healthcheck.txt" ]; then
    HEALTHCHECK_URL=$(head -n 1 "$CONFIG_DIR/healthcheck.txt" | tr -d '[:space:]')
fi
case "$HEALTHCHECK_URL" in
    http://*|https://*) log "Healthcheck URL: $HEALTHCHECK_URL" ;;
    *) HEALTHCHECK_URL=""; log "Healthcheck URL not set — error logs will stay local only" ;;
esac

# run git as the repo owner (the service runs as root)
git_pull() {
    if [ "$(id -u)" = "0" ]; then
        sudo -u piatek git -C "$1" pull --ff-only
    else
        git -C "$1" pull --ff-only
    fi
}

# ---------- 2. Update code and start projects ----------
for dir in "$APPS_DIR"/*/; do
    name=$(basename "$dir")
    [ "$name" = "configs" ] && continue
    [ -f "$dir/docker-compose.yml" ] || { log "Skipping $name (no docker-compose.yml)"; continue; }

    if [ -d "$dir/.git" ]; then
        log "git pull for $name..."
        git_pull "$dir" >>"$STARTUP_LOG" 2>&1 \
            || log "WARNING: git pull failed for $name — starting with current code"
    fi

    log "Building and starting $name..."
    (cd "$dir" && docker compose up -d --build) >>"$STARTUP_LOG" 2>&1 \
        || log "ERROR: docker compose up failed for $name"
done

log "Waiting 30 seconds before health check..."
sleep 30

# ---------- 3. Health check ----------
for dir in "$APPS_DIR"/*/; do
    name=$(basename "$dir")
    [ "$name" = "configs" ] && continue
    [ -f "$dir/docker-compose.yml" ] || continue

    ps_json=$(cd "$dir" && docker compose ps -a --format json)
    failed=0
    if [ -z "$ps_json" ]; then
        failed=1   # no containers were created at all
    else
        # a container that is not running or is unhealthy => failure
        if echo "$ps_json" | grep -qv '"State":"running"'; then failed=1; fi
        if echo "$ps_json" | grep -q '"Health":"unhealthy"'; then failed=1; fi
    fi

    if [ "$failed" -eq 1 ]; then
        err_log="$LOG_DIR/${name}_error_$TS.log"
        {
            echo "=== Project: $name | $(date '+%Y-%m-%d %H:%M:%S') ==="
            echo "=== docker compose ps ==="
            (cd "$dir" && docker compose ps -a)
            echo "=== Last 200 log lines ==="
            (cd "$dir" && docker compose logs --tail=200 --no-color)
        } > "$err_log" 2>&1
        log "FAILURE in $name — log saved: $err_log"

        if [ -n "$HEALTHCHECK_URL" ]; then
            if curl -s -m 15 -X POST \
                -H "Content-Type: text/plain; charset=utf-8" \
                -H "X-Project: $name" \
                --data-binary @"$err_log" \
                "$HEALTHCHECK_URL" >>"$STARTUP_LOG" 2>&1; then
                log "Error log posted to healthcheck URL"
            else
                log "ERROR: failed to post log to $HEALTHCHECK_URL"
            fi
        fi
    else
        log "OK: $name is running"
    fi
done

log "Done"
