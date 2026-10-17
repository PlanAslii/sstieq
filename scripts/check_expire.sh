#!/bin/bash
# چک کردن کاربران منقضی شده و غیرفعال کردن آن‌ها
# اجرا هر ۶ ساعت توسط cron

PANEL_DIR="/etc/ssh-vpn-panel"
DB="$PANEL_DIR/db/users.db"
LOG="$PANEL_DIR/logs/expire.log"

today=$(date +%Y-%m-%d)

# پیدا کردن کاربران منقضی
expired=$(sqlite3 "$DB" "SELECT username FROM users WHERE expire_date < '$today' AND is_active=1;")

for user in $expired; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deactivating expired user: $user" >> "$LOG"
    # قفل کردن کاربر
    usermod -L "$user" 2>/dev/null || true
    pkill -u "$user" 2>/dev/null || true
    sqlite3 "$DB" "UPDATE users SET is_active=0 WHERE username='$user';"
done

# فعال کردن دوباره اگر تاریخ تمدید شده باشد
reactivated=$(sqlite3 "$DB" "SELECT username FROM users WHERE expire_date >= '$today' AND is_active=0;")
for user in $reactivated; do
    usermod -U "$user" 2>/dev/null || true
    sqlite3 "$DB" "UPDATE users SET is_active=1 WHERE username='$user';"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Reactivated user: $user" >> "$LOG"
done
