#!/bin/bash
# ============================================================
# SSH-VPN Panel - Auto Installer
# Protocol: SSH / Dropbear + Stunnel + Squid + BadVPN
# Features: BBR, Multi-port, User Management, Bandwidth, Auto-Update
# Targets Ubuntu LTS 20.04/22.04/24.04/26.04; accepts Ubuntu with working APT sources
# Debian 11/12/13 are also supported
# ============================================================

set -e

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    RED='\033[1;31m'
    GREEN='\033[1;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[1;34m'
    CYAN='\033[1;36m'
    PURPLE='\033[1;35m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' PURPLE='' BOLD='' NC=''
fi

PANEL_DIR="/etc/ssh-vpn-panel"
SCRIPT_DIR="$PANEL_DIR/scripts"
DB_DIR="$PANEL_DIR/db"
LOG_DIR="$PANEL_DIR/logs"
CONFIG_DIR="$PANEL_DIR/config"
GITHUB_REPO="https://raw.githubusercontent.com/PlanAslii/sstieq/main"
SUCCESS_WORKER_URL="https://mute-bar-da37.planasli1.workers.dev/"
VERSION="1.1.3"

print_banner() {
    if [[ -t 1 ]]; then clear 2>/dev/null || true; fi
    printf '\n%b' "$CYAN"
    printf '╭──────────────────────────────────────────────────────────╮\n'
    printf '│             ✦  SSH VPN PANEL  ·  INSTALLER  ✦            │\n'
    printf '│                    Release v%-8s                       │\n' "$VERSION"
    printf '│      Dropbear  ·  Stunnel  ·  Squid  ·  BadVPN           │\n'
    printf '╰──────────────────────────────────────────────────────────╯\n'
    printf '%b\n' "$NC"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[ERROR] Run this installer as root (for example: sudo -i).${NC}"
        exit 1
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        echo -e "${RED}[ERROR] Cannot identify the operating system from /etc/os-release.${NC}"
        exit 1
    fi
    case "$OS" in
        ubuntu)
            echo -e "${GREEN}[INFO] Ubuntu $VER detected. The installer will use the configured APT repositories.${NC}"
            case "$VER" in
                20.04|22.04|24.04|26.04) ;;
                *) echo -e "${YELLOW}[WARN] Ubuntu $VER is not in the tested release set; package availability depends on its repositories.${NC}" ;;
            esac
            ;;
        debian)
            case "$VER" in
                11|12|13) echo -e "${GREEN}[INFO] Debian $VER detected.${NC}" ;;
                *) echo -e "${RED}[ERROR] Supported Debian releases are 11, 12, and 13 (found $VER).${NC}"; exit 1 ;;
            esac
            ;;
        *)
            echo -e "${RED}[ERROR] Unsupported operating system: $PRETTY_NAME${NC}"
            echo -e "${YELLOW}[INFO] Use Ubuntu (any release with working repositories) or Debian 11/12/13.${NC}"
            exit 1
            ;;
    esac
    echo -e "${GREEN}[INFO] Operating system: $PRETTY_NAME${NC}"
}

install_dependencies() {
    echo -e "${YELLOW}[1/9] Installing system packages...${NC}"
    if ! apt-get update -y; then
        echo -e "${RED}[ERROR] APT could not refresh package indexes. No panel packages were installed.${NC}"
        echo -e "${YELLOW}[HELP] Check /etc/apt/sources.list and /etc/apt/sources.list.d for stale Ubuntu codenames or unsupported PPAs.${NC}"
        echo -e "${YELLOW}[HELP] Ubuntu repositories must match this OS release; the installer does not rewrite APT sources.${NC}"
        exit 1
    fi
    apt-get install -y \
        dropbear \
        stunnel4 \
        squid \
        apache2-utils \
        net-tools \
        vnstat \
        sqlite3 \
        curl \
        wget \
        jq \
        iptables \
        python3 \
        python3-pip \
        git \
        unzip \
        screen \
        fail2ban \
        ufw \
        openssl \
        dos2unix \
        bc \
        cron

    # BadVPN UDPGW
    if ! command -v badvpn-udpgw &>/dev/null; then
        echo -e "${YELLOW}[INFO] Building and installing BadVPN UDPGW...${NC}"
        cd /tmp
        wget -q https://github.com/ambrop72/badvpn/archive/master.zip -O badvpn.zip
        unzip -qo badvpn.zip
        cd badvpn-master
        mkdir -p build && cd build
        cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 2>/dev/null || {
            apt-get install -y cmake build-essential
            cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1
        }
        make -j$(nproc)
        cp udpgw/badvpn-udpgw /usr/local/bin/
        chmod +x /usr/local/bin/badvpn-udpgw
        cd /
        rm -rf /tmp/badvpn*
    fi
}

enable_bbr() {
    echo -e "${YELLOW}[2/9] Enabling BBR TCP congestion control...${NC}"
    cat > /etc/sysctl.d/99-bbr.conf << EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
EOF
    sysctl --system > /dev/null 2>&1
    echo -e "${GREEN}[OK] BBR configuration applied.${NC}"
}

setup_directories() {
    mkdir -p "$PANEL_DIR" "$SCRIPT_DIR" "$DB_DIR" "$LOG_DIR" "$CONFIG_DIR"
    mkdir -p /etc/dropbear
    touch "$LOG_DIR/panel.log"
    touch "$LOG_DIR/auth.log"
}

setup_database() {
    echo -e "${YELLOW}[3/9] Preparing the SQLite database...${NC}"
    sqlite3 "$DB_DIR/users.db" << 'EOF'
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    password TEXT NOT NULL,
    expire_date TEXT NOT NULL,
    max_devices INTEGER DEFAULT 1,
    bandwidth_limit_gb REAL DEFAULT 0,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    is_active INTEGER DEFAULT 1,
    note TEXT DEFAULT ''
);

CREATE TABLE IF NOT EXISTS connections (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT NOT NULL,
    ip TEXT,
    connected_at TEXT DEFAULT CURRENT_TIMESTAMP,
    disconnected_at TEXT,
    bytes_sent INTEGER DEFAULT 0,
    bytes_recv INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT
);

INSERT OR IGNORE INTO settings (key, value) VALUES ('success_worker_url', 'https://mute-bar-da37.planasli1.workers.dev/');
INSERT OR IGNORE INTO settings (key, value) VALUES ('panel_version', '1.1.3');
INSERT OR IGNORE INTO settings (key, value) VALUES ('github_repo', 'PlanAslii/sstieq');
EOF
    sqlite3 "$DB_DIR/users.db" << 'EOF'
UPDATE settings
SET value='https://mute-bar-da37.planasli1.workers.dev/'
WHERE key='success_worker_url' AND (value IS NULL OR value='');
UPDATE settings
SET value='PlanAslii/sstieq'
WHERE key='github_repo' AND (value IS NULL OR value='' OR value='YOUR_USERNAME/ssh-vpn-panel');
EOF
    chmod 600 "$DB_DIR/users.db"
    echo -e "${GREEN}[OK] Database is ready.${NC}"
}

configure_dropbear() {
    echo -e "${YELLOW}[4/9] Configuring Dropbear SSH ports...${NC}"
    # Main SSH ports: 143, 444, 666, 5555, 701, 179
    cat > /etc/default/dropbear << EOF
NO_START=0
DROPBEAR_PORT=143
DROPBEAR_EXTRA_ARGS="-p 444 -p 666 -p 5555 -p 701 -p 179"
DROPBEAR_BANNER="/etc/ssh-vpn-panel/config/banner.txt"
DROPBEAR_RECEIVE_WINDOW=65536
EOF

    # Generate host keys if they do not already exist.
    if [[ ! -f /etc/dropbear/dropbear_rsa_host_key ]]; then
        dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key
    fi
    if [[ ! -f /etc/dropbear/dropbear_ecdsa_host_key ]]; then
        dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key
    fi
    if [[ ! -f /etc/dropbear/dropbear_ed25519_host_key ]]; then
        dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key 2>/dev/null || true
    fi

    systemctl enable dropbear
    systemctl restart dropbear
    echo -e "${GREEN}[OK] Dropbear is listening on ports 143, 444, 666, 5555, 701, 179.${NC}"
}

configure_stunnel() {
    echo -e "${YELLOW}[5/9] Configuring Stunnel TLS ports...${NC}"
    # TLS ports: 110, 443, 587
    openssl req -new -x509 -days 3650 -nodes \
        -out /etc/stunnel/stunnel.pem \
        -keyout /etc/stunnel/stunnel.pem \
        -subj "/C=US/ST=State/L=City/O=SSH-VPN/CN=localhost" 2>/dev/null

    cat > /etc/stunnel/stunnel.conf << EOF
pid = /var/run/stunnel.pid
cert = /etc/stunnel/stunnel.pem
client = no
socket = a:SO_REUSEADDR=1
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

[dropbear-110]
accept = 110
connect = 127.0.0.1:143

[dropbear-443]
accept = 443
connect = 127.0.0.1:143

[dropbear-587]
accept = 587
connect = 127.0.0.1:143
EOF

    sed -i 's/ENABLED=0/ENABLED=1/' /etc/default/stunnel4 2>/dev/null || true
    systemctl enable stunnel4
    systemctl restart stunnel4
    echo -e "${GREEN}[OK] Stunnel is configured on ports 110, 443, 587.${NC}"
}

configure_squid() {
    echo -e "${YELLOW}[6/9] Configuring Squid proxy ports...${NC}"
    cat > /etc/squid/squid.conf << EOF
http_port 8080
http_port 8000
http_port 3128
acl localnet src 0.0.0.0/0
http_access allow localnet
http_access deny all
coredump_dir /var/spool/squid
refresh_pattern ^ftp:           1440    20%     10080
refresh_pattern ^gopher:        1440    0%      1440
refresh_pattern -i (/cgi-bin/|\?) 0     0%      0
refresh_pattern .               0       20%     4320
EOF
    systemctl enable squid
    systemctl restart squid
    echo -e "${GREEN}[OK] Squid is configured on ports 8080, 8000, 3128.${NC}"
}

configure_badvpn() {
    echo -e "${YELLOW}[7/9] Configuring BadVPN UDPGW on port 7300...${NC}"
    cat > /etc/systemd/system/badvpn.service << EOF
[Unit]
Description=BadVPN UDPGW
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 2000 --max-connections-for-client 20
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable badvpn
    systemctl restart badvpn
    echo -e "${GREEN}[OK] BadVPN UDPGW is configured on port 7300.${NC}"
}

configure_sshd() {
    # Apply optional OpenSSH settings.
    sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
}

setup_banner() {
    cat > "$CONFIG_DIR/banner.txt" << 'EOF'

╭──────────────────────────────────────────────────────╮
│                 ✨  YOU'RE CONNECTED  ✨              │
├──────────────────────────────────────────────────────┤
│  🚀  SSH VPN  ·  SECURE TUNNEL                       │
│  ●   STATUS: ONLINE                                  │
│                                                      │
│  Your connection is ready. Enjoy a smooth session.  │
│  Help & updates: configure your support link.        │
╰──────────────────────────────────────────────────────╯

EOF
}

setup_firewall() {
    echo -e "${YELLOW}[8/9] Configuring the UFW firewall...${NC}"
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    # Dropbear ports
    ufw allow 143/tcp
    ufw allow 444/tcp
    ufw allow 666/tcp
    ufw allow 5555/tcp
    ufw allow 701/tcp
    ufw allow 179/tcp
    # SSL
    ufw allow 110/tcp
    ufw allow 443/tcp
    ufw allow 587/tcp
    # Squid
    ufw allow 8080/tcp
    ufw allow 8000/tcp
    ufw allow 3128/tcp
    # Keep the default SSH port available for server administration.
    ufw allow 22/tcp
    ufw --force enable
    echo -e "${GREEN}[OK] Firewall rules have been applied.${NC}"
}

install_panel_scripts() {
    echo -e "${YELLOW}[9/9] Installing panel scripts...${NC}"
    # Copy project scripts and configuration into the system directory.
    cp -r scripts/* "$SCRIPT_DIR/" 2>/dev/null || true
    cp -r config/* "$CONFIG_DIR/" 2>/dev/null || true
    cp -r worker/* "$PANEL_DIR/worker/" 2>/dev/null || true

    chmod +x "$SCRIPT_DIR"/*.sh
    ln -sf "$SCRIPT_DIR/menu.sh" /usr/local/bin/sshvpn
    ln -sf "$SCRIPT_DIR/menu.sh" /usr/bin/sshvpn

    # Schedule expiration checks and optional updates.
    (crontab -l 2>/dev/null | grep -v "ssh-vpn-panel"; echo "0 */6 * * * $SCRIPT_DIR/check_expire.sh >> $LOG_DIR/cron.log 2>&1") | crontab -
    (crontab -l 2>/dev/null | grep -v "auto_update"; echo "0 3 * * * $SCRIPT_DIR/auto_update.sh >> $LOG_DIR/update.log 2>&1") | crontab -
}

apply_worker_banner() {
    local worker_url banner_tmp
    worker_url=$(sqlite3 "$DB_DIR/users.db" "SELECT value FROM settings WHERE key='success_worker_url';" 2>/dev/null)
    [[ -n "$worker_url" ]] || return 0

    banner_tmp="$CONFIG_DIR/banner.txt.worker"
    if curl -fsS --max-time 8 --max-filesize 4096 "$worker_url" -o "$banner_tmp" 2>/dev/null && [[ -s "$banner_tmp" ]]; then
        mv "$banner_tmp" "$CONFIG_DIR/banner.txt"
        systemctl restart dropbear 2>/dev/null || true
        echo -e "${GREEN}[OK] PlanAsli connection banner fetched from Cloudflare Worker.${NC}"
    else
        rm -f "$banner_tmp"
        echo -e "${YELLOW}[WARN] Could not fetch the Worker banner; using the built-in PlanAsli banner.${NC}"
    fi
}

final_message() {
    IP=$(curl -s ifconfig.me || curl -s icanhazip.com || hostname -I | awk '{print $1}')
    echo ""
    echo -e "${GREEN}╭──────────────────────────────────────────────────────────╮${NC}"
    echo -e "${GREEN}│               ✓  INSTALLATION COMPLETE                  │${NC}"
    echo -e "${GREEN}├──────────────────────────────────────────────────────────┤${NC}"
    echo -e "${CYAN}  Server IP        ${NC} ${YELLOW}$IP${NC}"
    echo -e "${CYAN}  Dropbear SSH     ${NC} ${YELLOW}143, 444, 666, 5555, 701, 179${NC}"
    echo -e "${CYAN}  Stunnel TLS      ${NC} ${YELLOW}110, 443, 587${NC}"
    echo -e "${CYAN}  Squid Proxy      ${NC} ${YELLOW}8080, 8000, 3128${NC}"
    echo -e "${CYAN}  BadVPN UDPGW     ${NC} ${YELLOW}7300${NC}"
    echo -e "${GREEN}├──────────────────────────────────────────────────────────┤${NC}"
    echo -e "${CYAN}  Open the admin panel with: ${BOLD}${YELLOW}sshvpn${NC}"
    echo -e "${GREEN}╰──────────────────────────────────────────────────────────╯${NC}"
    echo ""
    echo -e "${BLUE}[NEXT] Set your Cloudflare Worker URL from menu option 6.${NC}"
}

main() {
    print_banner
    check_root
    detect_os
    install_dependencies
    enable_bbr
    setup_directories
    setup_database
    configure_dropbear
    configure_stunnel
    configure_squid
    configure_badvpn
    configure_sshd
    setup_banner
    setup_firewall
    install_panel_scripts
    apply_worker_banner
    final_message
}

main "$@"
