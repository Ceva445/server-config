#!/bin/bash
# Автозапуск проектів у ~/Desktop/apps після завантаження сервера:
# 1) чекає інтернет (за потреби підключає Wi-Fi з configs/wifi.txt)
# 2) піднімає docker compose у кожній теці-проекті
# 3) перевіряє стан контейнерів, при збої зберігає лог і шле на healthcheck URL

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

# ---------- 1. Інтернет / Wi-Fi ----------
if ! check_internet && [ -f "$CONFIG_DIR/wifi.txt" ]; then
    SSID=$(grep '^SSID=' "$CONFIG_DIR/wifi.txt" | cut -d= -f2-)
    PASSWORD=$(grep '^PASSWORD=' "$CONFIG_DIR/wifi.txt" | cut -d= -f2-)
    for attempt in $(seq 1 10); do
        log "Немає інтернету, спроба $attempt/10: підключаюсь до Wi-Fi \"$SSID\""
        nmcli dev wifi connect "$SSID" password "$PASSWORD" >>"$STARTUP_LOG" 2>&1
        sleep 10
        if check_internet; then
            log "Інтернет з'явився"
            break
        fi
    done
fi

if ! check_internet; then
    log "ПОМИЛКА: інтернет так і не з'явився — контейнери не запускаю"
    exit 1
fi

# ---------- healthcheck URL (може бути відсутній) ----------
HEALTHCHECK_URL=""
if [ -f "$CONFIG_DIR/healthcheck.txt" ]; then
    HEALTHCHECK_URL=$(head -n 1 "$CONFIG_DIR/healthcheck.txt" | tr -d '[:space:]')
fi
case "$HEALTHCHECK_URL" in
    http://*|https://*) log "Healthcheck URL: $HEALTHCHECK_URL" ;;
    *) HEALTHCHECK_URL=""; log "Healthcheck URL не заданий — логи помилок лишаються тільки локально" ;;
esac

# git від імені власника репозиторію (сервіс працює від root)
git_pull() {
    if [ "$(id -u)" = "0" ]; then
        sudo -u piatek git -C "$1" pull --ff-only
    else
        git -C "$1" pull --ff-only
    fi
}

# ---------- 2. Оновлення коду та запуск проектів ----------
for dir in "$APPS_DIR"/*/; do
    name=$(basename "$dir")
    [ "$name" = "configs" ] && continue
    [ -f "$dir/docker-compose.yml" ] || { log "Пропускаю $name (немає docker-compose.yml)"; continue; }

    if [ -d "$dir/.git" ]; then
        log "git pull для $name..."
        git_pull "$dir" >>"$STARTUP_LOG" 2>&1 \
            || log "ПОПЕРЕДЖЕННЯ: git pull впав для $name — запускаю на поточному коді"
    fi

    log "Збираю і запускаю $name..."
    (cd "$dir" && docker compose up -d --build) >>"$STARTUP_LOG" 2>&1 \
        || log "ПОМИЛКА: docker compose up впав для $name"
done

log "Чекаю 30 секунд перед перевіркою стану..."
sleep 30

# ---------- 3. Перевірка стану ----------
for dir in "$APPS_DIR"/*/; do
    name=$(basename "$dir")
    [ "$name" = "configs" ] && continue
    [ -f "$dir/docker-compose.yml" ] || continue

    ps_json=$(cd "$dir" && docker compose ps -a --format json)
    failed=0
    if [ -z "$ps_json" ]; then
        failed=1   # жоден контейнер не створився
    else
        # контейнер не running або unhealthy => збій
        if echo "$ps_json" | grep -qv '"State":"running"'; then failed=1; fi
        if echo "$ps_json" | grep -q '"Health":"unhealthy"'; then failed=1; fi
    fi

    if [ "$failed" -eq 1 ]; then
        err_log="$LOG_DIR/${name}_error_$TS.log"
        {
            echo "=== Проект: $name | $(date '+%Y-%m-%d %H:%M:%S') ==="
            echo "=== docker compose ps ==="
            (cd "$dir" && docker compose ps -a)
            echo "=== Останні 200 рядків логів ==="
            (cd "$dir" && docker compose logs --tail=200 --no-color)
        } > "$err_log" 2>&1
        log "ЗБІЙ у $name — лог збережено: $err_log"

        if [ -n "$HEALTHCHECK_URL" ]; then
            if curl -s -m 15 -X POST \
                -H "Content-Type: text/plain; charset=utf-8" \
                -H "X-Project: $name" \
                --data-binary @"$err_log" \
                "$HEALTHCHECK_URL" >>"$STARTUP_LOG" 2>&1; then
                log "Лог помилки відправлено на healthcheck URL"
            else
                log "ПОМИЛКА: не вдалося відправити лог на $HEALTHCHECK_URL"
            fi
        fi
    else
        log "OK: $name працює"
    fi
done

log "Готово"
