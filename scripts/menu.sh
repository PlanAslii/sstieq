#!/bin/bash
# SSH-VPN Panel Main Menu
# ========================

PANEL_DIR="/etc/ssh-vpn-panel"
SCRIPT_DIR="$PANEL_DIR/scripts"
DB_DIR="$PANEL_DIR/db"
LOG_DIR="$PANEL_DIR/logs"
CONFIG_DIR="$PANEL_DIR/config"
DB="$DB_DIR/users.db"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

# ===================== Helper Functions =====================

get_setting() {
    sqlite3 "$DB" "SELECT value FROM settings WHERE key='$1';" 2>/dev/null
}

set_setting() {
    sqlite3 "$DB" "INSERT OR REPLACE INTO settings (key, value) VALUES ('$1', '$2');"
}

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_DIR/panel.log"
}

# ===================== User Management =====================

create_user() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         ایجاد کاربر جدید             ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo ""
    read -p "نام کاربری (Username): " username
    if [[ -z "$username" ]]; then
        echo -e "${RED}نام کاربری نمی‌تواند خالی باشد.${NC}"
        sleep 2
        return
    fi
    # چک تکراری
    exists=$(sqlite3 "$DB" "SELECT COUNT(*) FROM users WHERE username='$username';")
    if [[ "$exists" -gt 0 ]]; then
        echo -e "${RED}کاربر از قبل وجود دارد!${NC}"
        sleep 2
        return
    fi

    read -p "رمز عبور (Password): " password
    if [[ -z "$password" ]]; then
        password=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 12)
        echo -e "${YELLOW}رمز تصادفی تولید شد: $password${NC}"
    fi

    read -p "تعداد روز اعتبار (مثلاً 30): " days
    days=${days:-30}
    expire_date=$(date -d "+$days days" +%Y-%m-%d 2>/dev/null || date -v+${days}d +%Y-%m-%d)

    read -p "حداکثر دستگاه همزمان (پیش‌فرض 1): " max_dev
    max_dev=${max_dev:-1}

    read -p "محدودیت ترافیک GB (0 = نامحدود): " bw_limit
    bw_limit=${bw_limit:-0}

    read -p "یادداشت (اختیاری): " note

    # ایجاد کاربر سیستم
    useradd -m -s /bin/false -e "$expire_date" "$username" 2>/dev/null || {
        echo -e "${RED}خطا در ایجاد کاربر سیستم.${NC}"
        sleep 2
        return
    }
    echo "$username:$password" | chpasswd

    # ذخیره در دیتابیس
    sqlite3 "$DB" "INSERT INTO users (username, password, expire_date, max_devices, bandwidth_limit_gb, note) 
                   VALUES ('$username', '$password', '$expire_date', $max_dev, $bw_limit, '$note');"

    # ساخت فایل لاگین برای injectors
    IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    HOSTNAME=$(hostname -f 2>/dev/null || echo "$IP")

    clear
    echo -e "${GREEN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║           User successfully created!!                    ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║  Username     : $username"
    echo "║  Password     : $password"
    echo "║  Host Name    : $IP (Host To IP)"
    echo "║  Host Name DNS: $HOSTNAME"
    echo "║  Dropbear     : 143, 444, 666, 5555, 701, 179"
    echo "║  Dropbear SSL : 110, 443, 587"
    echo "║  Squid        : 8080, 8000, 3128"
    echo "║  BadVPN       : 7300"
    echo "║  Expired      : $expire_date"
    echo "║  Max Devices  : $max_dev"
    echo "║  Bandwidth    : ${bw_limit} GB"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    log_msg "USER_CREATE: $username | expire: $expire_date | devices: $max_dev"
    echo ""
    read -p "برای بازگشت Enter بزنید..."
}

delete_user() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           حذف کاربر                  ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo ""
    list_users_simple
    echo ""
    read -p "نام کاربری برای حذف: " username
    if [[ -z "$username" ]]; then return; fi

    exists=$(sqlite3 "$DB" "SELECT COUNT(*) FROM users WHERE username='$username';")
    if [[ "$exists" -eq 0 ]]; then
        echo -e "${RED}کاربر یافت نشد.${NC}"
        sleep 2
        return
    fi

    read -p "آیا مطمئن هستید؟ (y/n): " conf
    if [[ "$conf" != "y" && "$conf" != "Y" ]]; then return; fi

    userdel -r "$username" 2>/dev/null || true
    pkill -u "$username" 2>/dev/null || true
    sqlite3 "$DB" "DELETE FROM users WHERE username='$username';"
    sqlite3 "$DB" "DELETE FROM connections WHERE username='$username';"

    echo -e "${GREEN}کاربر $username حذف شد.${NC}"
    log_msg "USER_DELETE: $username"
    sleep 2
}

list_users() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                           لیست کاربران                                      ║${NC}"
    echo -e "${CYAN}╠════════════════════════════════════════════════════════════════════════════╣${NC}"
    printf "${YELLOW}%-4s %-18s %-14s %-12s %-8s %-8s %-6s${NC}\n" "ID" "Username" "Expire" "Status" "Devices" "BW(GB)" "Active"
    echo -e "${CYAN}────────────────────────────────────────────────────────────────────────────${NC}"

    sqlite3 -separator '|' "$DB" "SELECT id, username, expire_date, is_active, max_devices, bandwidth_limit_gb FROM users ORDER BY id;" | while IFS='|' read -r id user exp active maxdev bw; do
        today=$(date +%Y-%m-%d)
        if [[ "$exp" < "$today" ]]; then
            status="${RED}EXPIRED${NC}"
        else
            status="${GREEN}ACTIVE${NC}"
        fi
        act_icon=$([ "$active" = "1" ] && echo "✓" || echo "✗")
        printf "%-4s %-18s %-14s %-12s %-8s %-8s %-6s\n" "$id" "$user" "$exp" "$status" "$maxdev" "$bw" "$act_icon"
    done
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    read -p "Enter برای بازگشت..."
}

list_users_simple() {
    sqlite3 -header -column "$DB" "SELECT id, username, expire_date, is_active FROM users ORDER BY id;"
}

# ===================== Connection & Bandwidth =====================

show_online() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              کاربران آنلاین در حال حاضر                  ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # از who و ps برای Dropbear
    echo -e "${YELLOW}--- اتصالات فعال Dropbear/SSH ---${NC}"
    who 2>/dev/null | grep -v "root" || echo "هیچ کاربری متصل نیست."

    echo ""
    echo -e "${YELLOW}--- تعداد اتصالات به تفکیک کاربر ---${NC}"
    # شمارش پروسه‌های dropbear بر اساس کاربر
    ps aux | grep -E '[d]ropbear|[s]shd' | awk '{print $1}' | sort | uniq -c | sort -nr

    echo ""
    total=$(who 2>/dev/null | grep -v root | wc -l)
    echo -e "${GREEN}مجموع کاربران متصل (تقریبی): $total${NC}"
    echo ""
    read -p "Enter برای بازگشت..."
}

show_user_traffic() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         مصرف ترافیک کاربر            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo ""
    list_users_simple
    echo ""
    read -p "نام کاربری: " username
    if [[ -z "$username" ]]; then return; fi

    # استفاده از vnstat اگر کاربر خاص پشتیبانی شود، در غیر این صورت کلی
    echo ""
    echo -e "${YELLOW}آمار کلی سرور (vnstat):${NC}"
    vnstat -i eth0 2>/dev/null || vnstat 2>/dev/null || echo "vnstat نصب نیست یا اینترفیس پیدا نشد."

    echo ""
    echo -e "${YELLOW}تاریخچه اتصالات کاربر $username:${NC}"
    sqlite3 -header -column "$DB" "SELECT id, ip, connected_at, disconnected_at, bytes_sent, bytes_recv FROM connections WHERE username='$username' ORDER BY id DESC LIMIT 20;"
    echo ""
    read -p "Enter برای بازگشت..."
}

# ===================== Settings =====================

set_worker_url() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     تنظیم آدرس Worker موفقیت         ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo ""
    current=$(get_setting "success_worker_url")
    echo -e "آدرس فعلی: ${YELLOW}${current:-خالی}${NC}"
    echo ""
    echo "مثال: https://your-worker.yourname.workers.dev/success"
    echo "این آدرس وقتی کاربر وصل شد، پیام موفقیت را از آن می‌گیرد."
    echo ""
    read -p "آدرس جدید Worker: " url
    if [[ -n "$url" ]]; then
        set_setting "success_worker_url" "$url"
        # به‌روزرسانی بنر
        update_banner_from_worker
        echo -e "${GREEN}آدرس ذخیره شد و بنر به‌روز شد.${NC}"
        log_msg "WORKER_URL_SET: $url"
    fi
    sleep 2
}

update_banner_from_worker() {
    url=$(get_setting "success_worker_url")
    if [[ -z "$url" ]]; then return; fi

    msg=$(curl -s --max-time 5 "$url" 2>/dev/null)
    if [[ -n "$msg" ]]; then
        cat > "$CONFIG_DIR/banner.txt" << EOF

$msg

EOF
        systemctl restart dropbear 2>/dev/null || true
    fi
}

# ===================== Auto Update =====================

check_update() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         بررسی آپدیت از GitHub        ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo ""
    repo=$(get_setting "github_repo")
    if [[ -z "$repo" || "$repo" == "YOUR_USERNAME/ssh-vpn-panel" ]]; then
        echo -e "${YELLOW}ابتدا ریپوی GitHub را در تنظیمات وارد کنید.${NC}"
        read -p "username/repo (مثلاً myuser/ssh-vpn-panel): " repo
        set_setting "github_repo" "$repo"
    fi

    echo -e "در حال بررسی آپدیت از: ${YELLOW}$repo${NC}"
    # ساده: دانلود install.sh جدید و مقایسه نسخه
    remote_ver=$(curl -s "https://raw.githubusercontent.com/$repo/main/VERSION" 2>/dev/null || echo "0")
    local_ver=$(get_setting "panel_version")
    echo "نسخه محلی: $local_ver"
    echo "نسخه ریموت: $remote_ver"
    if [[ "$remote_ver" != "$local_ver" && "$remote_ver" != "0" ]]; then
        echo -e "${GREEN}آپدیت موجود است!${NC}"
        read -p "آیا می‌خواهید آپدیت کنید؟ (y/n): " conf
        if [[ "$conf" == "y" || "$conf" == "Y" ]]; then
            bash "$SCRIPT_DIR/auto_update.sh"
        fi
    else
        echo -e "${GREEN}پنل به‌روز است.${NC}"
    fi
    sleep 2
}

# ===================== System Info =====================

system_info() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                   اطلاعات سیستم                          ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}--- وضعیت سرویس‌ها ---${NC}"
    for svc in dropbear stunnel4 squid badvpn; do
        status=$(systemctl is-active $svc 2>/dev/null || echo "unknown")
        if [[ "$status" == "active" ]]; then
            echo -e "  $svc : ${GREEN}● running${NC}"
        else
            echo -e "  $svc : ${RED}● $status${NC}"
        fi
    done
    echo ""
    echo -e "${YELLOW}--- پورت‌های باز ---${NC}"
    ss -tlnp | grep -E ':(143|444|666|5555|701|179|110|443|587|8080|8000|3128|7300)\s' || netstat -tlnp 2>/dev/null | grep -E ':(143|444|...)\s'
    echo ""
    echo -e "${YELLOW}--- BBR Status ---${NC}"
    sysctl net.ipv4.tcp_congestion_control
    echo ""
    echo -e "${YELLOW}--- استفاده از منابع ---${NC}"
    free -h | head -2
    df -h / | tail -1
    echo ""
    echo -e "${YELLOW}--- تعداد کاربران دیتابیس ---${NC}"
    total_users=$(sqlite3 "$DB" "SELECT COUNT(*) FROM users;")
    active_users=$(sqlite3 "$DB" "SELECT COUNT(*) FROM users WHERE is_active=1 AND expire_date >= date('now');")
    echo "کل کاربران: $total_users | فعال: $active_users"
    echo ""
    read -p "Enter برای بازگشت..."
}

# ===================== Main Menu =====================

main_menu() {
    while true; do
        clear
        IP=$(curl -s --max-time 3 ifconfig.me 2>/dev/null || echo "N/A")
        ver=$(get_setting "panel_version")
        online=$(who 2>/dev/null | grep -v root | wc -l)
        echo -e "${PURPLE}"
        echo "╔══════════════════════════════════════════════════════════╗"
        echo "║              🚀 SSH-VPN Panel v${ver}                   ║"
        echo "║──────────────────────────────────────────────────────────║"
        echo "║  Server IP: $IP          Online: $online users         ║"
        echo "╚══════════════════════════════════════════════════════════╝"
        echo -e "${NC}"
        echo -e "${GREEN}  1)${NC} ایجاد کاربر جدید"
        echo -e "${GREEN}  2)${NC} حذف کاربر"
        echo -e "${GREEN}  3)${NC} لیست کاربران"
        echo -e "${GREEN}  4)${NC} کاربران آنلاین / اتصالات"
        echo -e "${GREEN}  5)${NC} مصرف ترافیک کاربر"
        echo -e "${GREEN}  6)${NC} تنظیم آدرس Worker موفقیت"
        echo -e "${GREEN}  7)${NC} بررسی و نصب آپدیت (GitHub)"
        echo -e "${GREEN}  8)${NC} اطلاعات سیستم و سرویس‌ها"
        echo -e "${GREEN}  9)${NC} ریستارت سرویس‌ها"
        echo -e "${GREEN} 10)${NC} تمدید کاربر"
        echo -e "${RED}  0)${NC} خروج"
        echo ""
        read -p "انتخاب شما: " choice

        case $choice in
            1) create_user ;;
            2) delete_user ;;
            3) list_users ;;
            4) show_online ;;
            5) show_user_traffic ;;
            6) set_worker_url ;;
            7) check_update ;;
            8) system_info ;;
            9)
                systemctl restart dropbear stunnel4 squid badvpn
                echo -e "${GREEN}سرویس‌ها ریستارت شدند.${NC}"
                sleep 2
                ;;
            10)
                clear
                list_users_simple
                read -p "نام کاربری برای تمدید: " u
                read -p "تعداد روز اضافه: " d
                if [[ -n "$u" && -n "$d" ]]; then
                    newexp=$(date -d "+$d days" +%Y-%m-%d)
                    sqlite3 "$DB" "UPDATE users SET expire_date='$newexp', is_active=1 WHERE username='$u';"
                    chage -E "$newexp" "$u" 2>/dev/null || true
                    echo -e "${GREEN}کاربر $u تا $newexp تمدید شد.${NC}"
                    log_msg "USER_EXTEND: $u -> $newexp"
                fi
                sleep 2
                ;;
            0) exit 0 ;;
            *) echo -e "${RED}گزینه نامعتبر${NC}"; sleep 1 ;;
        esac
    done
}

# چک وجود دیتابیس
if [[ ! -f "$DB" ]]; then
    echo -e "${RED}دیتابیس پیدا نشد. ابتدا install.sh را اجرا کنید.${NC}"
    exit 1
fi

main_menu
