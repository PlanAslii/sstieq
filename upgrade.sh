#!/bin/bash
# Safe in-place upgrade: does not reset UFW or overwrite the current banner.
set -euo pipefail
PANEL_DIR="/etc/ssh-vpn-panel"
DB="$PANEL_DIR/db/users.db"
SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo ./upgrade.sh" >&2
    exit 1
fi
if [[ ! -f "$DB" || ! -d "$SOURCE_DIR/scripts" || ! -d "$SOURCE_DIR/systemd" ]]; then
    echo "Existing panel database or release files are missing; upgrade was not applied." >&2
    exit 1
fi
command -v sqlite3 >/dev/null || { echo "sqlite3 is required." >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required." >&2; exit 1; }

backup="$PANEL_DIR/backups/v1.3.3-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$backup/scripts" "$backup/systemd"
cp -a "$PANEL_DIR/scripts/." "$backup/scripts/"
cp -a /etc/systemd/system/sshvpn-*.service /etc/systemd/system/sshvpn-*.timer "$backup/systemd/" 2>/dev/null || true

mkdir -p "$PANEL_DIR/scripts" "$PANEL_DIR/logs" "$PANEL_DIR/config" "$PANEL_DIR/db"
cp -a "$SOURCE_DIR/scripts/." "$PANEL_DIR/scripts/"
cp -a "$SOURCE_DIR/worker/." "$PANEL_DIR/worker/" 2>/dev/null || true
cp -a "$SOURCE_DIR/systemd/"*.service "$SOURCE_DIR/systemd/"*.timer /etc/systemd/system/
chmod 0755 "$PANEL_DIR/scripts"/*.sh "$PANEL_DIR/scripts"/*.py
chmod 0600 "$DB"
sqlite3 "$DB" <<'SQL'
CREATE TABLE IF NOT EXISTS user_traffic (
    username TEXT PRIMARY KEY,
    bytes_total INTEGER NOT NULL DEFAULT 0,
    last_counter INTEGER NOT NULL DEFAULT 0,
    last_sample TEXT
);
INSERT OR IGNORE INTO settings(key,value) VALUES ('github_repo','PlanAslii/sstieq');
UPDATE settings SET value='1.3.3' WHERE key='panel_version';
SQL

# Remove only the legacy banner polling cron line; preserve all unrelated root cron jobs.
if crontab -l >/tmp/sshvpn-crontab-before 2>/dev/null; then
    grep -Fv '/etc/ssh-vpn-panel/scripts/refresh_banner.sh' /tmp/sshvpn-crontab-before | crontab -
fi
rm -f /tmp/sshvpn-crontab-before
systemctl daemon-reload
systemctl enable --now sshvpn-banner-refresh.timer sshvpn-traffic-sampler.timer
if [[ -s "$PANEL_DIR/config/telegram.env" ]]; then
    systemctl enable --now sshvpn-telegram-bot.service || true
    systemctl restart sshvpn-telegram-bot.service || true
fi
if command -v apt-get >/dev/null 2>&1 && apt-cache show speedtest-cli >/dev/null 2>&1; then
    apt-get install -y speedtest-cli || echo "Warning: speedtest-cli could not be installed; the panel update succeeded."
fi

echo "SSH VPN Panel upgraded to v1.3.3. Existing firewall rules and banner file were preserved."
echo "Worker polling: every 5 seconds; traffic sampling: every 60 seconds."
echo "Open the menu with: sshvpn"
