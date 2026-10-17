#!/bin/bash
# این اسکریپت می‌تواند به عنوان ForceCommand یا در .bashrc کاربران استفاده شود
# تا پیام موفقیت را از Worker بگیرد و نمایش دهد

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

# ثبت اتصال در دیتابیس
user=$(whoami)
ip=$(echo $SSH_CLIENT | awk '{print $1}')
sqlite3 "$DB" "INSERT INTO connections (username, ip) VALUES ('$user', '$ip');" 2>/dev/null || true
