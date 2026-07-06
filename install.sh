#!/bin/bash
# Розкатує конфігурацію з цього репозиторію на сервер.
# Запускати НА СЕРВЕРІ з теки репозиторію: bash install.sh
# Потрібен sudo (systemd + cloudflared).

set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Встановлюю startup.sh (виконуваний) ==="
chmod +x "$REPO_DIR/startup.sh"

echo "=== Встановлюю systemd-юніт ==="
sudo cp "$REPO_DIR/apps-startup.service" /etc/systemd/system/apps-startup.service
sudo systemctl daemon-reload
sudo systemctl enable apps-startup.service

echo "=== Оновлюю конфіг cloudflared ==="
TUNNEL_SECRET="$REPO_DIR/cloudflared/tunnel-secret.yml"
TUNNEL_INGRESS="$REPO_DIR/cloudflared/ingress.yml"
if [ ! -f "$TUNNEL_SECRET" ]; then
    echo "ПРОПУСКАЮ: немає cloudflared/tunnel-secret.yml (він у .gitignore)."
    echo "Створи його за шаблоном templates/tunnel-secret.yml.example"
else
    TMP_CONFIG=$(mktemp)
    cat "$TUNNEL_SECRET" "$TUNNEL_INGRESS" > "$TMP_CONFIG"
    if ! sudo diff -q "$TMP_CONFIG" /etc/cloudflared/config.yml >/dev/null 2>&1; then
        cloudflared tunnel --config "$TMP_CONFIG" ingress validate
        sudo cp "$TMP_CONFIG" /etc/cloudflared/config.yml
        sudo systemctl restart cloudflared
        echo "cloudflared перезапущено"
    else
        echo "cloudflared без змін"
    fi
    rm -f "$TMP_CONFIG"
fi

echo "=== Шаблони конфігів (якщо ще нема реальних) ==="
[ -f "$REPO_DIR/wifi.txt" ] || cp "$REPO_DIR/templates/wifi.txt.example" "$REPO_DIR/wifi.txt"
[ -f "$REPO_DIR/healthcheck.txt" ] || touch "$REPO_DIR/healthcheck.txt"
chmod 600 "$REPO_DIR/wifi.txt"

echo "=== Готово ==="
echo "Перевірка: sudo systemctl restart apps-startup && systemctl status apps-startup"
