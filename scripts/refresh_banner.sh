#!/bin/bash
# Refresh the Dropbear login banner from the configured Cloudflare Worker.
set -euo pipefail

PANEL_DIR="/etc/ssh-vpn-panel"
DB="$PANEL_DIR/db/users.db"
BANNER="$PANEL_DIR/config/banner.txt"
LOCK="/run/lock/ssh-vpn-panel-banner.lock"
ERROR_STAMP="/run/ssh-vpn-panel-banner-error-stamp"

log_limited_error() {
    local now previous
    now=$(date +%s)
    previous=$(cat "$ERROR_STAMP" 2>/dev/null || echo 0)
    if [[ ! "$previous" =~ ^[0-9]+$ ]] || (( now - previous >= 60 )); then
        printf '%s\n' "$now" > "$ERROR_STAMP"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    fi
}

[[ -f "$DB" ]] || exit 0
exec 9>"$LOCK"
flock -n 9 || exit 0

url=$(sqlite3 "$DB" "SELECT value FROM settings WHERE key='success_worker_url';" 2>/dev/null || true)
[[ -n "$url" ]] || exit 0
case "$url" in
    https://*) ;;
    *) log_limited_error "ERROR: Worker URL must use HTTPS; keeping current banner."; exit 0 ;;
esac

tmp=$(mktemp "$PANEL_DIR/config/banner.txt.XXXXXX")
trap 'rm -f "$tmp"' EXIT
if ! curl -fsSL --max-time 12 --max-filesize 4096 "$url" -o "$tmp"; then
    log_limited_error "Worker fetch failed; keeping current banner."
    exit 0
fi
if [[ ! -s "$tmp" ]]; then
    log_limited_error "Worker returned an empty banner; keeping current banner."
    exit 0
fi
if cmp -s "$tmp" "$BANNER"; then
    exit 0
fi

chmod 0644 "$tmp"
mv -f "$tmp" "$BANNER"
if systemctl is-active --quiet dropbear; then
    systemctl restart dropbear
else
    systemctl start dropbear
fi
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Worker banner changed; updated Dropbear."