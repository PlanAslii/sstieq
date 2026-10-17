#!/bin/bash
# Disable accounts that have expired.
# Scheduled by cron every six hours.

PANEL_DIR="/etc/ssh-vpn-panel"
DB="$PANEL_DIR/db/users.db"
LOG="$PANEL_DIR/logs/expire.log"

today=$(date +%Y-%m-%d)

# Find expired accounts.
expired=$(sqlite3 "$DB" "SELECT username FROM users WHERE expire_date < '$today' AND is_active=1;")

for user in $expired; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deactivating expired user: $user" >> "$LOG"
    # Lock the Linux account.
    usermod -L "$user" 2>/dev/null || true
    pkill -u "$user" 2>/dev/null || true
    sqlite3 "$DB" "UPDATE users SET is_active=0 WHERE username='$user';"
done

# Re-enable the account if its expiry date was extended.
reactivated=$(sqlite3 "$DB" "SELECT username FROM users WHERE expire_date >= '$today' AND is_active=0;")
for user in $reactivated; do
    usermod -U "$user" 2>/dev/null || true
    sqlite3 "$DB" "UPDATE users SET is_active=1 WHERE username='$user';"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Reactivated user: $user" >> "$LOG"
done
