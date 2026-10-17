#!/bin/bash
# SSH-VPN Panel Main Menu
# ========================

PANEL_DIR="/etc/ssh-vpn-panel"
SCRIPT_DIR="$PANEL_DIR/scripts"
DB_DIR="$PANEL_DIR/db"
LOG_DIR="$PANEL_DIR/logs"
CONFIG_DIR="$PANEL_DIR/config"
DB="$DB_DIR/users.db"
DROPBEAR_SHELL_FIX_APPLIED=0

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    RED='\033[1;31m'
    GREEN='\033[1;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[1;34m'
    CYAN='\033[1;36m'
    PURPLE='\033[1;35m'
    DIM='\033[2m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' PURPLE='' DIM='' BOLD='' NC=''
fi

clear_screen() {
    if [[ -t 1 && -n "${TERM:-}" ]]; then
        clear 2>/dev/null || true
    fi
}

print_title() {
    local title="$1"
    printf '\n%b╭──────────────────────────────────────────────────────────╮%b\n' "$CYAN" "$NC"
    printf '%b│%b  %-56s%b│%b\n' "$CYAN" "$BOLD" "$title" "$CYAN" "$NC"
    printf '%b╰──────────────────────────────────────────────────────────╯%b\n\n' "$CYAN" "$NC"
}

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

ensure_vpn_shell_allowed() {
    local vpn_shell="/bin/false"
    [[ $EUID -eq 0 && -x "$vpn_shell" && -f /etc/shells ]] || return 1
    if ! grep -Fxq -- "$vpn_shell" /etc/shells; then
        printf '%s\n' "$vpn_shell" >> /etc/shells || return 1
        DROPBEAR_SHELL_FIX_APPLIED=1
        log_msg "DROPBEAR_SHELL_COMPAT: registered /bin/false for non-interactive VPN accounts"
        if systemctl is-active --quiet dropbear; then
            systemctl restart dropbear || return 1
        fi
    fi
    if ! systemctl is-active --quiet dropbear; then
        systemctl enable --now dropbear || return 1
    fi
}

ensure_dropbear_banner_option() {
    local config="/etc/default/dropbear"
    local banner_flag="-b /etc/ssh-vpn-panel/config/banner.txt"
    local changed=0
    [[ $EUID -eq 0 && -f "$config" ]] || return 0

    # Ubuntu's systemd unit passes DROPBEAR_EXTRA_ARGS directly; DROPBEAR_BANNER
    # alone is not translated to Dropbear's -b option by that unit.
    if grep -Fq -- "$banner_flag" "$config"; then
        if grep -q '^DROPBEAR_BANNER=' "$config"; then
            sed -i '/^DROPBEAR_BANNER=/d' "$config"
            changed=1
        fi
    else
        if grep -q '^DROPBEAR_EXTRA_ARGS="' "$config"; then
            sed -i "s|^DROPBEAR_EXTRA_ARGS=\"|DROPBEAR_EXTRA_ARGS=\"$banner_flag |" "$config"
        elif grep -q '^DROPBEAR_EXTRA_ARGS=' "$config"; then
            sed -i "s|^DROPBEAR_EXTRA_ARGS=\\(.*\\)$|DROPBEAR_EXTRA_ARGS=\"$banner_flag \\1\"|" "$config"
        else
            printf 'DROPBEAR_EXTRA_ARGS="%s"\n' "$banner_flag" >> "$config"
        fi
        sed -i '/^DROPBEAR_BANNER=/d' "$config"
        changed=1
    fi

    if [[ "$changed" -eq 1 ]]; then
        if systemctl restart dropbear; then
            log_msg "DROPBEAR_BANNER_COMPAT: enabled -b banner file option"
        else
            return 1
        fi
    fi
}

check_ssh_account_ready() {
    local username="$1" account_shell password_state
    account_shell=$(getent passwd "$username" | awk -F: '{print $7}')
    password_state=$(passwd -S "$username" 2>/dev/null | awk '{print $2}')
    [[ -n "$account_shell" ]] || return 1
    grep -Fxq -- "$account_shell" /etc/shells || return 1
    [[ "$password_state" == "P" ]] || return 1
    systemctl is-active --quiet dropbear
}

# ===================== User Management =====================

create_user() {
    clear_screen
    print_title "CREATE NEW SSH ACCOUNT"
    echo ""
    read -p "Username: " username
    if [[ -z "$username" ]]; then
        echo -e "${RED}Username cannot be empty.${NC}"
        sleep 2
        return
    fi
    # Reject duplicate usernames
    exists=$(sqlite3 "$DB" "SELECT COUNT(*) FROM users WHERE username='$username';")
    if [[ "$exists" -gt 0 ]]; then
        echo -e "${RED}This username already exists.${NC}"
        sleep 2
        return
    fi

    read -p "Password (leave blank to generate one): " password
    if [[ -z "$password" ]]; then
        password=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 12)
        echo -e "${YELLOW}Generated password: $password${NC}"
    fi

    read -p "Validity in days [30]: " days
    days=${days:-30}
    expire_date=$(date -d "+$days days" +%Y-%m-%d 2>/dev/null || date -v+${days}d +%Y-%m-%d)

    read -p "Maximum concurrent devices [1]: " max_dev
    max_dev=${max_dev:-1}

    read -p "Bandwidth limit in GB (0 = unlimited): " bw_limit
    bw_limit=${bw_limit:-0}

    read -p "Note (optional): " note

    # Create the Linux account
    ensure_vpn_shell_allowed || {
        echo -e "${RED}Could not configure the non-interactive shell for Dropbear.${NC}"
        sleep 2
        return
    }
    useradd -m -s /bin/false -e "$expire_date" "$username" 2>/dev/null || {
        echo -e "${RED}Could not create the Linux account.${NC}"
        sleep 2
        return
    }
    if ! printf '%s:%s\n' "$username" "$password" | chpasswd; then
        userdel -r "$username" 2>/dev/null || true
        echo -e "${RED}Could not set the account password; account creation was rolled back.${NC}"
        sleep 2
        return
    fi

    # Save the account record
    sqlite3 "$DB" "INSERT INTO users (username, password, expire_date, max_devices, bandwidth_limit_gb, note) 
                   VALUES ('$username', '$password', '$expire_date', $max_dev, $bw_limit, '$note');"

    # Print connection details for SSH clients
    IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    HOSTNAME=$(hostname -f 2>/dev/null || echo "$IP")

    clear_screen
    echo -e "${GREEN}"
    echo "╭──────────────────────────────────────────────────────────╮"
    echo "│                 ✓  ACCOUNT CREATED                       │"
    echo "├──────────────────────────────────────────────────────────┤"
    echo "│  Username       $username"
    echo "│  Password       $password"
    echo "│  Server IP      $IP"
    echo "│  Hostname       $HOSTNAME"
    echo "│  SSH ports      143, 444, 666, 5555, 701, 179"
    echo "│  TLS ports      110, 443, 587"
    echo "│  Proxy ports    8080, 8000, 3128"
    echo "│  UDPGW port     7300"
    echo "│  Expires        $expire_date"
    echo "│  Max devices    $max_dev"
    echo "│  Bandwidth      ${bw_limit} GB"
    echo "╰──────────────────────────────────────────────────────────╯"
    echo -e "${NC}"
    if check_ssh_account_ready "$username"; then
        echo -e "${GREEN}[AUTO-FIX] SSH setup is ready: valid shell, password set, and Dropbear active.${NC}"
        echo -e "${CYAN}[CLIENT] Use this exact username/password with SSH port 143.${NC}"
        log_msg "USER_CREATE_AUTH_CHECK: $username | status=ready | shell_fix=$DROPBEAR_SHELL_FIX_APPLIED"
    else
        echo -e "${RED}[AUTO-CHECK] The account was created, but one SSH readiness check failed. Review the service/account status.${NC}"
        log_msg "USER_CREATE_AUTH_CHECK: $username | status=failed"
    fi
    log_msg "USER_CREATE: $username | expire: $expire_date | devices: $max_dev"
    echo ""
    read -p "Press Enter to return..."
}

reset_user_password() {
    local username new_password exists
    clear_screen
    print_title "RESET SSH ACCOUNT PASSWORD"
    read -r -p "Username: " username
    if [[ ! "$username" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*$ ]]; then
        echo -e "${RED}Invalid username format.${NC}"
        sleep 2
        return
    fi

    exists=$(sqlite3 "$DB" "SELECT COUNT(*) FROM users WHERE username='$username';" 2>/dev/null)
    if [[ "$exists" != "1" ]] || ! id "$username" >/dev/null 2>&1; then
        echo -e "${RED}Panel account not found. Create it from option 1 first.${NC}"
        sleep 2
        return
    fi
    ensure_vpn_shell_allowed || {
        echo -e "${RED}Could not configure the non-interactive shell for Dropbear.${NC}"
        sleep 2
        return
    }

    new_password=$(openssl rand -hex 10) || {
        echo -e "${RED}Could not generate a password.${NC}"
        sleep 2
        return
    }
    if ! printf '%s:%s\n' "$username" "$new_password" | chpasswd; then
        echo -e "${RED}Password reset failed.${NC}"
        sleep 2
        return
    fi
    sqlite3 "$DB" "UPDATE users SET password='$new_password' WHERE username='$username';"
    log_msg "PASSWORD_RESET: $username"
    echo ""
    echo -e "${GREEN}Password reset. Enter these credentials in your SSH client:${NC}"
    printf '%bUsername:%b %s\n' "$CYAN" "$NC" "$username"
    printf '%bNew password:%b %s\n' "$YELLOW" "$NC" "$new_password"
    echo ""
    read -r -p "Copy the password now, then press Enter to return..."
}

delete_user() {
    clear_screen
    print_title "DELETE SSH ACCOUNT"
    echo ""
    list_users_simple
    echo ""
    read -p "Username to delete: " username
    if [[ -z "$username" ]]; then return; fi

    exists=$(sqlite3 "$DB" "SELECT COUNT(*) FROM users WHERE username='$username';")
    if [[ "$exists" -eq 0 ]]; then
        echo -e "${RED}Account not found.${NC}"
        sleep 2
        return
    fi

    read -p "Delete this account? (y/N): " conf
    if [[ "$conf" != "y" && "$conf" != "Y" ]]; then return; fi

    userdel -r "$username" 2>/dev/null || true
    pkill -u "$username" 2>/dev/null || true
    sqlite3 "$DB" "DELETE FROM users WHERE username='$username';"
    sqlite3 "$DB" "DELETE FROM connections WHERE username='$username';"

    echo -e "${GREEN}Account $username has been deleted.${NC}"
    log_msg "USER_DELETE: $username"
    sleep 2
}

list_users() {
    clear_screen
    print_title "SSH ACCOUNT DIRECTORY"
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
    echo ""
    read -p "Press Enter to return..."
}

list_users_simple() {
    sqlite3 -header -column "$DB" "SELECT id, username, expire_date, is_active FROM users ORDER BY id;"
}

# ===================== Connection & Bandwidth =====================

show_online() {
    clear_screen
    print_title "LIVE CONNECTIONS"
    echo ""

    # Use who and process information for SSH sessions
    echo -e "${YELLOW}--- Active SSH sessions ---${NC}"
    who 2>/dev/null | grep -v "root" || echo "No active non-root sessions found."

    echo ""
    echo -e "${YELLOW}--- SSH processes by account ---${NC}"
    # Count SSH processes by account
    ps aux | grep -E '[d]ropbear|[s]shd' | awk '{print $1}' | sort | uniq -c | sort -nr

    echo ""
    total=$(who 2>/dev/null | grep -v root | wc -l)
    echo -e "${GREEN}Approximate logged-in users: $total${NC}"
    echo ""
    read -p "Press Enter to return..."
}

show_user_traffic() {
    clear_screen
    print_title "TRAFFIC & CONNECTION HISTORY"
    echo ""
    list_users_simple
    echo ""
    read -p "Username: " username
    if [[ -z "$username" ]]; then return; fi

    # vnStat reports server-wide totals, not per-account usage
    echo ""
    echo -e "${YELLOW}Server-wide network statistics (vnStat):${NC}"
    vnstat -i eth0 2>/dev/null || vnstat 2>/dev/null || echo "vnStat is unavailable or no network interface was detected."

    echo ""
    echo -e "${YELLOW}Recent connection history for $username:${NC}"
    sqlite3 -header -column "$DB" "SELECT id, ip, connected_at, disconnected_at, bytes_sent, bytes_recv FROM connections WHERE username='$username' ORDER BY id DESC LIMIT 20;"
    echo ""
    read -p "Press Enter to return..."
}

# ===================== Settings =====================

set_worker_url() {
    clear_screen
    print_title "CONNECTION BANNER · CLOUDFLARE WORKER"
    echo ""
    current=$(get_setting "success_worker_url")
    echo -e "Current URL: ${YELLOW}${current:-not set}${NC}"
    echo ""
    echo "Example: https://your-worker.yourname.workers.dev"
    echo "Edit the Worker response to customize the message shown in SSH client logs."
    echo ""
    read -p "New Worker URL (blank keeps current): " url
    if [[ -n "$url" ]]; then
        set_setting "success_worker_url" "$url"
        # Refresh the server login banner
        log_msg "WORKER_URL_SET: $url"
    elif [[ -n "$current" ]]; then
        url="$current"
    else
        echo -e "${YELLOW}No Worker URL is configured.${NC}"
        sleep 2
        return
    fi
    if update_banner_from_worker; then
        echo -e "${GREEN}Worker banner fetched and applied.${NC}"
    else
        echo -e "${RED}Could not fetch the Worker banner. Check the URL and network.${NC}"
    fi
    sleep 2
}

update_banner_from_worker() {
    url=$(get_setting "success_worker_url")
    if [[ -z "$url" ]]; then return; fi

    msg=$(curl -fsS --max-time 8 "$url" 2>/dev/null) || return 1
    if [[ -n "$msg" ]]; then
        cat > "$CONFIG_DIR/banner.txt" << EOF

$msg

EOF
        systemctl restart dropbear 2>/dev/null || return 1
        return 0
    fi
    return 1
}

# ===================== Auto Update =====================

check_update() {
    clear_screen
    print_title "PANEL UPDATE"
    echo ""
    repo=$(get_setting "github_repo")
    if [[ -z "$repo" || "$repo" == "YOUR_USERNAME/ssh-vpn-panel" ]]; then
        repo="PlanAslii/sstieq"
        set_setting "github_repo" "$repo"
    fi

    echo -e "Checking for updates from: ${YELLOW}$repo${NC}"
    # Compare the repository version with the installed version
    remote_ver=$(curl -s "https://raw.githubusercontent.com/$repo/main/VERSION" 2>/dev/null || echo "0")
    local_ver=$(get_setting "panel_version")
    echo "Installed version: $local_ver"
    echo "Latest repository version: $remote_ver"
    if [[ "$remote_ver" != "$local_ver" && "$remote_ver" != "0" ]]; then
        echo -e "${GREEN}A new version is available.${NC}"
        read -p "Install this update? (y/N): " conf
        if [[ "$conf" == "y" || "$conf" == "Y" ]]; then
            bash "$SCRIPT_DIR/auto_update.sh"
        fi
    else
        echo -e "${GREEN}The panel is up to date.${NC}"
    fi
    sleep 2
}

# ===================== System Info =====================

system_info() {
    clear_screen
    print_title "SERVER HEALTH & SYSTEM INFO"
    echo ""
    echo -e "${YELLOW}--- Service status ---${NC}"
    for svc in dropbear stunnel4 squid badvpn; do
        status=$(systemctl is-active $svc 2>/dev/null || echo "unknown")
        if [[ "$status" == "active" ]]; then
            echo -e "  $svc : ${GREEN}● running${NC}"
        else
            echo -e "  $svc : ${RED}● $status${NC}"
        fi
    done
    echo ""
    echo -e "${YELLOW}--- Listening service ports ---${NC}"
    ss -tlnp | grep -E ':(143|444|666|5555|701|179|110|443|587|8080|8000|3128|7300)\s' || netstat -tlnp 2>/dev/null | grep -E ':(143|444|...)\s'
    echo ""
    echo -e "${YELLOW}--- BBR Status ---${NC}"
    sysctl net.ipv4.tcp_congestion_control
    echo ""
    echo -e "${YELLOW}--- Resource usage ---${NC}"
    free -h | head -2
    df -h / | tail -1
    echo ""
    echo -e "${YELLOW}--- Account totals ---${NC}"
    total_users=$(sqlite3 "$DB" "SELECT COUNT(*) FROM users;")
    active_users=$(sqlite3 "$DB" "SELECT COUNT(*) FROM users WHERE is_active=1 AND expire_date >= date('now');")
    echo "Total accounts: $total_users | Active: $active_users"
    echo ""
    read -p "Press Enter to return..."
}

# ===================== Main Menu =====================

main_menu() {
    while true; do
        clear_screen
        IP=$(curl -s --max-time 3 ifconfig.me 2>/dev/null || echo "N/A")
        ver=$(get_setting "panel_version")
        online=$(who 2>/dev/null | grep -v root | wc -l)
        printf '\n%b' "$PURPLE"
        printf '╭──────────────────────────────────────────────────────────╮\n'
        printf '│       ✦  SSH VPN CONTROL PANEL  ·  v%-8s              │\n' "${ver:-unknown}"
        printf '├──────────────────────────────────────────────────────────┤\n'
        printf '│  Server  %-18s  │  Online sessions  %-6s         │\n' "$IP" "$online"
        printf '╰──────────────────────────────────────────────────────────╯\n'
        printf '%b\n' "$NC"
        echo -e "${BLUE}${BOLD}  ACCOUNTS${NC}"
        echo -e "${GREEN}  1)${NC} ✚  Create account"
        echo -e "${GREEN}  2)${NC} ✕  Delete account"
        echo -e "${GREEN}  3)${NC} ▤  List accounts"
        echo ""
        echo -e "${BLUE}${BOLD}  MONITORING & SETTINGS${NC}"
        echo -e "${GREEN}  4)${NC} ◉  Live connections"
        echo -e "${GREEN}  5)${NC} ⇅  Traffic & history"
        echo -e "${GREEN}  6)${NC} ✨  Connection banner (Worker)"
        echo -e "${GREEN}  7)${NC} ⟳  Check for updates"
        echo -e "${GREEN}  8)${NC} ◈  Server health"
        echo -e "${GREEN}  9)${NC} ↻  Restart services"
        echo -e "${GREEN} 10)${NC} ◷  Extend account"
        echo -e "${GREEN} 11)${NC} 🔑 Reset account password"
        echo ""
        echo -e "${RED}  0)${NC} ⏻  Exit"
        echo ""
        read -p "Select an option: " choice

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
                echo -e "${GREEN}Services restarted.${NC}"
                sleep 2
                ;;
            10)
                clear_screen
                list_users_simple
                read -p "Username to extend: " u
                read -p "Number of days to add: " d
                if [[ -n "$u" && -n "$d" ]]; then
                    newexp=$(date -d "+$d days" +%Y-%m-%d)
                    sqlite3 "$DB" "UPDATE users SET expire_date='$newexp', is_active=1 WHERE username='$u';"
                    chage -E "$newexp" "$u" 2>/dev/null || true
                    echo -e "${GREEN}Account $u extended through $newexp.${NC}"
                    log_msg "USER_EXTEND: $u -> $newexp"
                fi
                sleep 2
                ;;
            11) reset_user_password ;;
            0) exit 0 ;;
            *) echo -e "${RED}Invalid option.${NC}"; sleep 1 ;;
        esac
    done
}

# Verify that the database exists
if [[ ! -f "$DB" ]]; then
    echo -e "${RED}Database not found. Run install.sh first.${NC}"
    exit 1
fi

ensure_project_defaults() {
    local repo worker_url
    repo=$(get_setting "github_repo")
    worker_url=$(get_setting "success_worker_url")

    if [[ -z "$repo" || "$repo" == "YOUR_USERNAME/ssh-vpn-panel" ]]; then
        set_setting "github_repo" "PlanAslii/sstieq"
    fi
    if [[ -z "$worker_url" ]]; then
        set_setting "success_worker_url" "https://mute-bar-da37.planasli1.workers.dev/"
    fi
}

ensure_project_defaults
ensure_vpn_shell_allowed
ensure_dropbear_banner_option
main_menu
