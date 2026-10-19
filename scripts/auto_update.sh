#!/bin/bash
# Auto Updater from GitHub
# ========================

PANEL_DIR="/etc/ssh-vpn-panel"
SCRIPT_DIR="$PANEL_DIR/scripts"
DB="$PANEL_DIR/db/users.db"
LOG="$PANEL_DIR/logs/update.log"
TMP="/tmp/ssh-vpn-update"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"
}

repo=$(sqlite3 "$DB" "SELECT value FROM settings WHERE key='github_repo';" 2>/dev/null)
if [[ -z "$repo" || "$repo" == "YOUR_USERNAME/ssh-vpn-panel" ]]; then
    log "ERROR: GitHub repo not configured. Skip update."
    exit 1
fi

log "Checking update from github.com/$repo ..."

# Fetch the published version.
remote_ver=$(curl -sL "https://raw.githubusercontent.com/$repo/main/VERSION" 2>/dev/null | tr -d '\r\n')
local_ver=$(sqlite3 "$DB" "SELECT value FROM settings WHERE key='panel_version';")

if [[ -z "$remote_ver" ]]; then
    log "ERROR: Could not fetch remote VERSION."
    exit 1
fi

if [[ "$remote_ver" == "$local_ver" ]]; then
    log "Already up to date (v$local_ver)."
    exit 0
fi

log "New version available: $remote_ver (local: $local_ver). Downloading..."

rm -rf "$TMP"
mkdir -p "$TMP"
cd "$TMP"

# Download the GitHub source archive.
curl -sL "https://github.com/$repo/archive/refs/heads/main.zip" -o update.zip
if [[ ! -f update.zip ]]; then
    log "ERROR: Download failed."
    exit 1
fi

unzip -qo update.zip
folder=$(ls -d */ | head -1)

if [[ -z "$folder" ]]; then
    log "ERROR: Extract failed."
    exit 1
fi

# Back up the installed scripts.
cp -r "$SCRIPT_DIR" "$SCRIPT_DIR.bak.$(date +%s)" 2>/dev/null || true

# Install updated scripts and configuration.
cp -r "$folder/scripts/"* "$SCRIPT_DIR/" 2>/dev/null || true
cp -r "$folder/config/"* "$PANEL_DIR/config/" 2>/dev/null || true
cp -r "$folder/worker/"* "$PANEL_DIR/worker/" 2>/dev/null || true
if [[ -d "$folder/systemd" ]]; then
    cp -a "$folder/systemd/"*.service "$folder/systemd/"*.timer /etc/systemd/system/ 2>/dev/null || true
    systemctl daemon-reload
    systemctl enable --now sshvpn-banner-refresh.timer sshvpn-traffic-sampler.timer
    if [[ -s "$PANEL_DIR/config/telegram.env" ]]; then
        systemctl enable --now sshvpn-telegram-bot.service || true
    fi
fi

sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS user_traffic (username TEXT PRIMARY KEY, bytes_total INTEGER NOT NULL DEFAULT 0, last_counter INTEGER NOT NULL DEFAULT 0, last_sample TEXT);"
chmod +x "$SCRIPT_DIR"/*.sh
chmod +x "$SCRIPT_DIR"/*.py 2>/dev/null || true

# Store the new panel version.
sqlite3 "$DB" "UPDATE settings SET value='$remote_ver' WHERE key='panel_version';"

log "Update to v$remote_ver completed successfully."
rm -rf "$TMP"

# Restart essential services if required.
# systemctl restart dropbear
