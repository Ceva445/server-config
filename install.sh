#!/bin/bash
# Deploys the configuration from this repository onto the server.
# Run ON THE SERVER from the repo directory: bash install.sh
# Requires sudo (systemd + cloudflared).

set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Installing startup.sh (executable) ==="
chmod +x "$REPO_DIR/startup.sh"

echo "=== Installing systemd unit ==="
sudo cp "$REPO_DIR/apps-startup.service" /etc/systemd/system/apps-startup.service
sudo systemctl daemon-reload
sudo systemctl enable apps-startup.service

echo "=== Updating cloudflared config ==="
TUNNEL_SECRET="$REPO_DIR/cloudflared/tunnel-secret.yml"
TUNNEL_INGRESS="$REPO_DIR/cloudflared/ingress.yml"
if [ ! -f "$TUNNEL_SECRET" ]; then
    echo "SKIPPING: cloudflared/tunnel-secret.yml is missing (it is gitignored)."
    echo "Create it from templates/tunnel-secret.yml.example"
else
    TMP_CONFIG=$(mktemp)
    cat "$TUNNEL_SECRET" "$TUNNEL_INGRESS" > "$TMP_CONFIG"
    if ! sudo diff -q "$TMP_CONFIG" /etc/cloudflared/config.yml >/dev/null 2>&1; then
        cloudflared tunnel --config "$TMP_CONFIG" ingress validate
        sudo cp "$TMP_CONFIG" /etc/cloudflared/config.yml
        sudo systemctl restart cloudflared
        echo "cloudflared restarted"
    else
        echo "cloudflared unchanged"
    fi
    rm -f "$TMP_CONFIG"
fi

echo "=== Config templates (if real ones are missing) ==="
[ -f "$REPO_DIR/wifi.txt" ] || cp "$REPO_DIR/templates/wifi.txt.example" "$REPO_DIR/wifi.txt"
[ -f "$REPO_DIR/healthcheck.txt" ] || touch "$REPO_DIR/healthcheck.txt"
chmod 600 "$REPO_DIR/wifi.txt"

echo "=== Done ==="
echo "Verify with: sudo systemctl restart apps-startup && systemctl status apps-startup"
