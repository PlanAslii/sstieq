#!/bin/bash
# Optional helper for displaying the configured banner in a login shell.
# It can also fetch and display the banner from the configured Worker.

PANEL_DIR="/etc/ssh-vpn-panel"
DB="$PANEL_DIR/db/users.db"

url=$(sqlite3 "$DB" "SELECT value FROM settings WHERE key='success_worker_url';" 2>/dev/null)

if [[ -n "$url" ]]; then
    msg=$(curl -s --max-time 4 "$url" 2>/dev/null)
    if [[ -n "$msg" ]]; then
        echo "$msg"
    else
        echo "✨ Connected successfully via SSH-VPN Panel ✨"
    fi
else
    cat "$PANEL_DIR/config/banner.txt" 2>/dev/null || echo "Connected successfully!"
fi

# Record the connection in the local database.
user=$(whoami)
ip=$(echo $SSH_CLIENT | awk '{print $1}')
sqlite3 "$DB" "INSERT INTO connections (username, ip) VALUES ('$user', '$ip');" 2>/dev/null || true
