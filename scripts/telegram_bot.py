#!/usr/bin/env python3
"""Admin-only, interactive Telegram control panel for SSH VPN Panel."""
import datetime
import html
import json
import math
import os
import pwd
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request

PANEL = "/etc/ssh-vpn-panel"
DB = f"{PANEL}/db/users.db"
CONFIG = f"{PANEL}/config/telegram.env"
PROMPTS = {}
USERNAME_RE = re.compile(r"[a-zA-Z_][a-zA-Z0-9_.-]{0,31}")


def read_config():
    values = {}
    try:
        with open(CONFIG, encoding="utf-8") as stream:
            for line in stream:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    key, value = line.split("=", 1)
                    values[key] = value
    except OSError:
        pass
    return values


def bot_api(method, data=None, token=None, timeout=40):
    token = token or read_config().get("BOT_TOKEN", "")
    if not token:
        raise RuntimeError("Telegram bot token is not configured")
    url = f"https://api.telegram.org/bot{token}/{method}"
    body = urllib.parse.urlencode(data or {}).encode()
    request = urllib.request.Request(url, data=body, headers={"Content-Type": "application/x-www-form-urlencoded"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        result = json.loads(response.read().decode())
    if not result.get("ok"):
        raise RuntimeError(result.get("description", "Telegram API error"))
    return result["result"]


def validate_token(token):
    return bot_api("getMe", token=token, timeout=10).get("username", "bot")


def db_connect():
    import sqlite3
    connection = sqlite3.connect(DB, timeout=10)
    connection.row_factory = sqlite3.Row
    return connection


def esc(value):
    return html.escape(str(value), quote=False)


def send(chat_id, text, keyboard=None):
    payload = {"chat_id": chat_id, "text": text, "parse_mode": "HTML", "disable_web_page_preview": "true"}
    if keyboard:
        payload["reply_markup"] = json.dumps({"inline_keyboard": keyboard}, ensure_ascii=False)
    bot_api("sendMessage", payload, timeout=20)


def ack(callback_id, text=""):
    try:
        bot_api("answerCallbackQuery", {"callback_query_id": callback_id, "text": text[:180]}, timeout=12)
    except Exception:
        pass


def check_admin(sender_id):
    return str(sender_id) == read_config().get("ADMIN_ID", "")


def main_keyboard():
    # Glass-style feel via emoji + short labels (Telegram inline buttons)
    return [
        [{"text": "✨ Create", "callback_data": "create"}, {"text": "👥 Accounts", "callback_data": "users"}],
        [{"text": "📊 Dashboard", "callback_data": "stats"}, {"text": "🖥 Status", "callback_data": "status"}],
        [{"text": "🔑 Reset pass", "callback_data": "reset"}, {"text": "📅 Extend", "callback_data": "extend"}],
        [{"text": "⏳ Expiring", "callback_data": "expiring"}, {"text": "🔎 Find", "callback_data": "search"}],
        [{"text": "🌐 Worker", "callback_data": "worker"}, {"text": "🚀 Speed", "callback_data": "speedtest"}],
    ]


def menu(chat_id):
    send(
        chat_id,
        "╭──────────────────────────╮\n"
        "│  <b>✨ SSH VPN Admin</b>           │\n"
        "╰──────────────────────────╯\n"
        "Private glass panel · only your admin ID.\n\n"
        "<b>Quick commands</b>\n"
        "/users · /stats · /status · /expiring\n"
        "/user name · /password name · /delete name · /cancel",
        main_keyboard(),
    )


def get_users():
    with db_connect() as db:
        return db.execute("SELECT id, username, expire_date, is_active, max_devices, bandwidth_limit_gb, created_at, note FROM users ORDER BY id").fetchall()


def get_user(username):
    with db_connect() as db:
        return db.execute("SELECT id, username, password, expire_date, is_active, max_devices, bandwidth_limit_gb, created_at, note FROM users WHERE username=?", (username,)).fetchone()


def traffic_bytes(username):
    with db_connect() as db:
        row = db.execute("SELECT bytes_total FROM user_traffic WHERE username=?", (username,)).fetchone()
    return int(row[0]) if row else 0


def _uid_for(username):
    try:
        return pwd.getpwnam(username).pw_uid
    except KeyError:
        return None


def connected_for(username):
    """Count live sessions for a panel account.

    Tries several methods because Dropbear process names and ownership vary by distro:
    1) ps by user (dropbear-like names preferred)
    2) pgrep by UID
    3) scan /proc for matching Uid
    4) ss ESTAB sockets owned by that UID (best-effort)
    """
    uid = _uid_for(username)
    counts = []

    try:
        result = subprocess.run(
            ["ps", "-u", username, "-o", "comm="],
            capture_output=True,
            text=True,
            timeout=5,
        )
        lines = [line.strip().lower() for line in result.stdout.splitlines() if line.strip()]
        dropbear_like = sum(1 for name in lines if "dropbear" in name or name == "dbclient")
        counts.append(dropbear_like if dropbear_like else len(lines))
    except Exception:
        pass

    try:
        result = subprocess.run(["pgrep", "-u", username], capture_output=True, text=True, timeout=5)
        counts.append(len([line for line in result.stdout.splitlines() if line.strip()]))
    except Exception:
        pass

    if uid is not None:
        try:
            n = 0
            for entry in os.listdir("/proc"):
                if not entry.isdigit():
                    continue
                try:
                    with open(f"/proc/{entry}/status", encoding="utf-8", errors="ignore") as stream:
                        for line in stream:
                            if line.startswith("Uid:"):
                                if int(line.split()[1]) == uid:
                                    n += 1
                                break
                except (OSError, ValueError, IndexError):
                    continue
            counts.append(n)
        except OSError:
            pass

    if uid is not None:
        try:
            result = subprocess.run(
                ["ss", "-tnpH", "state", "established"],
                capture_output=True,
                text=True,
                timeout=8,
            )
            marker = f"uid:{uid}"
            n = sum(1 for line in result.stdout.splitlines() if marker in line)
            counts.append(n)
        except Exception:
            pass

    return max(counts) if counts else 0


def force_traffic_sample():
    """Run one traffic sampler pass so Last sample / Used GB update immediately."""
    try:
        subprocess.run(
            ["/usr/bin/python3", f"{PANEL}/scripts/traffic_sampler.py"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=25,
        )
        return True
    except Exception:
        return False


def account_state(row):
    if not row["is_active"]:
        return "🔒 Disabled"
    try:
        if datetime.date.fromisoformat(row["expire_date"]) < datetime.date.today():
            return "⏰ Expired"
    except (ValueError, TypeError):
        return "⚠️ Date error"
    return "🟢 Active"


def user_keyboard(username, enabled):
    toggle_label = "⛔ Disable" if enabled else "✅ Enable"
    return [
        [{"text": "🔄 Refresh", "callback_data": "refresh:" + username}],
        [{"text": "🔑 Reset pass", "callback_data": "pw:" + username}, {"text": "📅 Extend", "callback_data": "extendu:" + username}],
        [{"text": "📦 Set limit", "callback_data": "limit:" + username}, {"text": toggle_label, "callback_data": "toggle:" + username}],
        [{"text": "🗑 Delete", "callback_data": "del:" + username}, {"text": "👥 Accounts", "callback_data": "users"}],
    ]


def show_user(chat_id, username):
    row = get_user(username)
    if not row:
        send(chat_id, "⚠️ Account not found.", [[{"text": "🏠 Main menu", "callback_data": "home"}]])
        return
    used_gb = traffic_bytes(username) / (1024 ** 3)
    sessions = connected_for(username)
    last_sample = ""
    try:
        with db_connect() as db:
            samp = db.execute("SELECT last_sample FROM user_traffic WHERE username=?", (username,)).fetchone()
            if samp and samp[0]:
                last_sample = str(samp[0])
    except Exception:
        pass
    try:
        account = pwd.getpwnam(username)
        shell = account.pw_shell
        linux_found = True
    except KeyError:
        shell = "missing"
        linux_found = False
    passwd_state = "unknown"
    if linux_found:
        result = subprocess.run(["passwd", "-S", username], capture_output=True, text=True)
        fields = result.stdout.split()
        if len(fields) > 1:
            passwd_state = {"P": "password set", "L": "locked", "NP": "no password"}.get(fields[1], fields[1])
    limit = float(row["bandwidth_limit_gb"] or 0)
    limit_text = "Unlimited" if limit == 0 else f"{limit:g} GB"
    created = row["created_at"] or "Unknown"
    note = esc((row["note"] or "—")[:300])
    if sessions:
        online_label = f"🟢 {sessions} process(es)"
    else:
        online_label = "⚪ none"
    if last_sample:
        sample_line = f"\n<b>Last sample:</b> {esc(last_sample)}"
    else:
        sample_line = "\n<b>Last sample:</b> not yet — tap 🔄 Refresh or wait ~60s"
    if not sessions:
        sample_line += (
            "\n<i>Tip: if you are online but see none, on the VPS run:\n"
            f"<code>ps -u {esc(username)} -o pid,comm</code> and "
            "<code>systemctl status sshvpn-traffic-sampler.timer</code></i>"
        )
    text = (
        f"╭ <b>👤 {esc(username)}</b>\n"
        f"├ Status: {account_state(row)}\n"
        f"├ Expires: {esc(row['expire_date'])}\n"
        f"├ Devices: {row['max_devices']}\n"
        f"├ 📤 Used: <b>{used_gb:.3f} GB</b> outbound\n"
        f"├ 📦 Limit: {esc(limit_text)}\n"
        f"├ 🔌 Connected: {online_label}"
        f"{sample_line}\n"
        f"├ Linux: {'present' if linux_found else 'missing'} · {esc(passwd_state)}\n"
        f"├ Shell: <code>{esc(shell)}</code>\n"
        f"├ Created: {esc(created)}\n"
        f"╰ Note: {note}\n\n"
        f"<i>Traffic updates every ~60s (outbound only). Shell /bin/false — no server shell.</i>"
    )
    send(chat_id, text, user_keyboard(username, bool(row["is_active"])))


def render_users(chat_id):
    rows = get_users()
    if not rows:
        send(chat_id, "📭 No accounts yet.", [[{"text": "✨ Create first", "callback_data": "create"}]])
        return
    active = sum(1 for row in rows if row["is_active"] and "Active" in account_state(row))
    online_total = 0
    text = (
        f"╭ <b>👥 Accounts</b>\n"
        f"├ Total: <b>{len(rows)}</b> · Active: <b>{active}</b>\n"
        f"╰ Tap a user for traffic, online count, enable/disable"
    )
    keyboard = []
    for row in rows[:40]:
        username = row["username"]
        gb = traffic_bytes(username) / (1024 ** 3)
        sessions = connected_for(username)
        if sessions:
            online_total += 1
        state = account_state(row)
        # Glass-style row: status dot + user + traffic + online
        dot = "🟢" if sessions else ("🔒" if "Disabled" in state else "⚪")
        label = f"{dot} {username} · {gb:.2f}GB · {sessions} online"
        keyboard.append([{"text": label[:64], "callback_data": "user:" + username}])
    keyboard.append([{"text": "🏠 Main menu", "callback_data": "home"}])
    if len(rows) > 40:
        text += f"\nShowing first 40 of {len(rows)}; use /user name for others."
    text += f"\n\n🔌 Online accounts now: <b>{online_total}</b>"
    send(chat_id, text, keyboard)


def stats_text():
    rows = get_users()
    active_count = expired_count = disabled_count = online_accounts = online_sessions = 0
    total_bytes = 0
    online_lines = []
    for row in rows:
        username = row["username"]
        total_bytes += traffic_bytes(username)
        state = account_state(row)
        if "Active" in state:
            active_count += 1
        elif "Expired" in state:
            expired_count += 1
        else:
            disabled_count += 1
        sessions = connected_for(username)
        if sessions:
            online_accounts += 1
            online_sessions += sessions
            online_lines.append(
                f"🟢 <code>{esc(username)}</code> — {sessions} proc · {traffic_bytes(username)/(1024**3):.3f} GB"
            )
    lines = [
        "╭ <b>📊 Dashboard</b>",
        f"├ 👥 Accounts: <b>{len(rows)}</b>  ·  🟢 Active: <b>{active_count}</b>",
        f"├ ⏰ Expired: <b>{expired_count}</b>  ·  🔒 Disabled: <b>{disabled_count}</b>",
        f"├ 🔌 Online: <b>{online_accounts}</b>  ·  processes: <b>{online_sessions}</b>",
        f"╰ 📤 Tracked out: <b>{total_bytes/(1024**3):.3f} GB</b>",
    ]
    lines.extend(["", "<b>Connected users</b>"] + (online_lines[:20] or ["⚪ No live sessions detected."]))
    lines.append("\n<i>Traffic is outbound-only · samples every ~60s.</i>")
    latest = f"{PANEL}/logs/speedtest-latest.txt"
    try:
        with open(latest, encoding="utf-8") as stream:
            lines.extend(["", "<b>🚀 Last speed test</b>", "<code>" + esc(stream.read().strip()[:700]) + "</code>"])
    except OSError:
        lines.extend(["", "No saved speed test yet."])
    return "\n".join(lines)


def server_status_text():
    bbr = subprocess.run(["sysctl", "-n", "net.ipv4.tcp_congestion_control"], capture_output=True, text=True).stdout.strip() or "unavailable"
    services = []
    for service in ("dropbear", "stunnel4", "squid", "badvpn", "sshvpn-telegram-bot"):
        result = subprocess.run(["systemctl", "is-active", service], capture_output=True, text=True)
        status = result.stdout.strip() or "unknown"
        icon = "🟢" if status == "active" else "🔴"
        services.append(f"{icon} {service}: <b>{esc(status)}</b>")
    try:
        memory = subprocess.run(["free", "-h"], capture_output=True, text=True).stdout.splitlines()
        memory_line = next((line for line in memory if line.startswith("Mem:")), "Unknown")
    except Exception:
        memory_line = "Unknown"
    disk = subprocess.run(["df", "-h", "/"], capture_output=True, text=True).stdout.splitlines()
    disk_line = disk[-1] if len(disk) > 1 else "Unknown"
    return (
        "╭ <b>🖥 Server status</b>\n"
        f"├ TCP: <code>{esc(bbr)}</code>\n"
        f"├ Memory: <code>{esc(memory_line)}</code>\n"
        f"╰ Disk: <code>{esc(disk_line)}</code>\n\n"
        "<b>Services</b>\n" + "\n".join(services)
    )


def show_expiring(chat_id):
    today = datetime.date.today()
    upcoming = []
    for row in get_users():
        try:
            remaining = (datetime.date.fromisoformat(row["expire_date"]) - today).days
        except (ValueError, TypeError):
            continue
        if 0 <= remaining <= 7 and row["is_active"]:
            upcoming.append((row["username"], row["expire_date"], remaining))
    if not upcoming:
        send(chat_id, "No enabled accounts expire within the next 7 days.", [[{"text": "Main menu", "callback_data": "home"}]])
        return
    text = ["<b>Expiring within 7 days</b>"]
    keys = []
    for username, expiry, days in upcoming[:40]:
        text.append(f"• <code>{esc(username)}</code> — {expiry} ({days} day(s))")
        keys.append([{"text": f"{username} · {days}d", "callback_data": "user:" + username}])
    keys.append([{"text": "Main menu", "callback_data": "home"}])
    send(chat_id, "\n".join(text), keys)


def shell_fix():
    if not os.path.exists("/bin/false") or not os.path.exists("/etc/shells"):
        raise RuntimeError("/bin/false or /etc/shells is missing")
    with open("/etc/shells", "r+", encoding="utf-8") as stream:
        contents = stream.read().splitlines()
        if "/bin/false" not in contents:
            stream.write("\n/bin/false\n")


def home_root_ready():
    home_root = "/home"
    try:
        os.makedirs(home_root, mode=0o755, exist_ok=True)
        if not os.path.isdir(home_root):
            raise RuntimeError("/home exists but is not a directory")
        if not os.access(home_root, os.W_OK | os.X_OK):
            raise RuntimeError("/home is not writable/searchable by root")
    except OSError as exc:
        raise RuntimeError(f"Cannot prepare /home: {exc}. Check the /home mount and disk space.") from exc


def expected_home(username):
    return os.path.join("/home", username)


def repair_missing_home(username):
    account = pwd.getpwnam(username)
    home = expected_home(username)
    if account.pw_dir != home:
        raise RuntimeError(f"Unexpected home path for {username}: {account.pw_dir}; refusing to change it")
    if os.path.lexists(home):
        if not recoverable_partial_user(username):
            raise RuntimeError(f"{home} already exists with unexpected owner/type/content; refusing to overwrite it")
        ensure_home_owner(username)
        return
    try:
        os.mkdir(home, 0o700)
        os.chown(home, account.pw_uid, account.pw_gid)
        os.chmod(home, 0o700)
    except OSError as exc:
        raise RuntimeError(f"Could not create {home}: {exc}. Check free disk/inodes and whether /home is read-only.") from exc


def skeleton_tree_only(path):
    """True only when a leftover home contains a subset of the OS default skeleton."""
    if os.path.islink(path) or not os.path.isdir(path):
        return False
    allowed = set()
    actual = set()
    for base, dirs, files in os.walk("/etc/skel", followlinks=False):
        relbase = os.path.relpath(base, "/etc/skel")
        for name in dirs + files:
            rel = name if relbase == "." else os.path.join(relbase, name)
            allowed.add(rel)
    for base, dirs, files in os.walk(path, followlinks=False):
        relbase = os.path.relpath(base, path)
        for name in dirs + files:
            full = os.path.join(base, name)
            if os.path.islink(full):
                return False
            rel = name if relbase == "." else os.path.join(relbase, name)
            actual.add(rel)
    return actual.issubset(allowed)


def recoverable_partial_user(username):
    try:
        account = pwd.getpwnam(username)
    except KeyError:
        return False
    home = expected_home(username)
    if account.pw_uid < 1000 or account.pw_shell != "/bin/false" or account.pw_dir != home or connected_for(username) != 0:
        return False
    if not os.path.lexists(home):
        return True
    # Prior useradd may leave only a standard skeleton directory, owned by root or this UID.
    try:
        info = os.stat(home, follow_symlinks=False)
        return (not os.path.islink(home) and os.path.isdir(home)
                and info.st_uid in (0, account.pw_uid) and skeleton_tree_only(home))
    except OSError:
        return False


def ensure_home_owner(username):
    account = pwd.getpwnam(username)
    home = expected_home(username)
    if not skeleton_tree_only(home):
        raise RuntimeError(f"{home} contains files outside the default OS skeleton; refusing to change its contents")
    for base, dirs, files in os.walk(home, topdown=True, followlinks=False):
        os.chown(base, account.pw_uid, account.pw_gid)
        for name in dirs + files:
            full = os.path.join(base, name)
            if os.path.islink(full):
                raise RuntimeError(f"Symlink found in {home}; refusing to change it")
            os.chown(full, account.pw_uid, account.pw_gid)
    os.chmod(home, 0o700)


def ensure_linux_account(username, expiry):
    """Create account; repair a clearly incomplete panel account if home creation failed."""
    home_root_ready()
    home = expected_home(username)
    if subprocess.run(["id", username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        if recoverable_partial_user(username):
            repair_missing_home(username)
            subprocess.run(["usermod", "-e", expiry, username], check=True, capture_output=True, text=True)
            return True
        raise RuntimeError(f"Linux account '{username}' already exists outside the panel; refusing to modify it.")
    if os.path.lexists(home):
        raise RuntimeError(f"Home path {home} already exists. No files were changed; inspect it before retrying.")

    first = subprocess.run(["useradd", "-m", "-s", "/bin/false", "-e", expiry, username], capture_output=True, text=True)
    if first.returncode == 0:
        return False
    detail = (first.stderr or first.stdout or "useradd failed").strip()

    # Some useradd versions write the passwd entry before failing to make the home directory.
    if recoverable_partial_user(username):
        try:
            repair_missing_home(username)
            subprocess.run(["usermod", "-e", expiry, username], check=True, capture_output=True, text=True)
            return True
        except Exception as exc:
            raise RuntimeError(f"Home creation failed for {home}; the account could not be repaired. Check free disk/inodes and /home mount permissions. Original error: {detail}. Repair error: {exc}") from exc
    # If this invocation created both the passwd record and home but failed later,
    # accept only the exact expected owner/path and do not touch pre-existing files.
    try:
        partial = pwd.getpwnam(username)
        home_stat = os.stat(home, follow_symlinks=False)
        if partial.pw_uid >= 1000 and partial.pw_shell == "/bin/false" and partial.pw_dir == home and not os.path.islink(home) and os.path.isdir(home) and home_stat.st_uid == partial.pw_uid:
            subprocess.run(["usermod", "-e", expiry, username], check=True, capture_output=True, text=True)
            return True
    except (KeyError, FileNotFoundError):
        pass

    lower = detail.lower()
    if "directory" not in lower and "/home" not in lower:
        raise RuntimeError(f"useradd failed: {detail}")

    # Fallback: create the Linux identity without a home, then create/chown it explicitly.
    retry = subprocess.run(["useradd", "-M", "-s", "/bin/false", "-e", expiry, username], capture_output=True, text=True)
    if retry.returncode:
        retry_error = (retry.stderr or retry.stdout or "useradd -M failed").strip()
        raise RuntimeError(f"Could not create the account or its home. useradd: {detail}; fallback: {retry_error}. Check /home permissions, free disk space/inodes, and read-only mounts.")
    try:
        repair_missing_home(username)
        return True
    except Exception as exc:
        subprocess.run(["userdel", username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        raise RuntimeError(f"Account creation was rolled back because {home} could not be prepared. Check /home mount, permissions, and free disk/inodes. Details: {exc}") from exc


def create_account(username, days, limit, max_devices=1):
    if not USERNAME_RE.fullmatch(username):
        raise ValueError("Invalid username. Use 1–32 letters, digits, dot, underscore, or hyphen; start with a letter/underscore.")
    shell_fix()
    with db_connect() as db:
        if db.execute("SELECT 1 FROM users WHERE username=?", (username,)).fetchone():
            raise ValueError("That username already exists in the panel.")
    expiry = (datetime.date.today() + datetime.timedelta(days=days)).isoformat()
    password = subprocess.check_output(["openssl", "rand", "-hex", "10"], text=True).strip()
    recovered = ensure_linux_account(username, expiry)
    try:
        changed = subprocess.run(["chpasswd"], input=f"{username}:{password}\n", text=True, capture_output=True)
        if changed.returncode:
            raise RuntimeError(changed.stderr.strip() or "chpasswd failed")
        with db_connect() as db:
            db.execute("INSERT INTO users(username,password,expire_date,max_devices,bandwidth_limit_gb,is_active,note) VALUES(?,?,?,?,?,1,?)",
                       (username, password, expiry, max_devices, limit, "Created via Telegram"))
            db.execute("INSERT OR IGNORE INTO user_traffic(username,bytes_total,last_counter) VALUES(?,0,0)", (username,))
        started = subprocess.run(["systemctl", "enable", "--now", "dropbear"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
        account = pwd.getpwnam(username)
        password_state = subprocess.run(["passwd", "-S", username], capture_output=True, text=True).stdout.split()
        with open("/etc/shells", encoding="utf-8") as stream:
            shells = stream.read().splitlines()
        service_active = subprocess.run(["systemctl", "is-active", "--quiet", "dropbear"]).returncode == 0
        if started.returncode or account.pw_shell != "/bin/false" or "/bin/false" not in shells or len(password_state) < 2 or password_state[1] != "P" or not service_active:
            raise RuntimeError("Account was created but SSH readiness verification failed")
        subprocess.run(["/usr/bin/python3", f"{PANEL}/scripts/traffic_sampler.py"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
    except Exception:
        with db_connect() as db:
            db.execute("DELETE FROM users WHERE username=?", (username,))
            db.execute("DELETE FROM user_traffic WHERE username=?", (username,))
        subprocess.run(["/usr/bin/python3", f"{PANEL}/scripts/traffic_sampler.py", "--remove-user", username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        subprocess.run(["userdel", "-r", username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        raise
    return password, expiry, recovered


def delete_account(username):
    if not USERNAME_RE.fullmatch(username):
        raise ValueError("Invalid account name")
    with db_connect() as db:
        row = db.execute("SELECT 1 FROM users WHERE username=?", (username,)).fetchone()
    if not row:
        raise ValueError("Panel account not found")
    subprocess.run(["pkill", "-u", username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["/usr/bin/python3", f"{PANEL}/scripts/traffic_sampler.py", "--remove-user", username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    if subprocess.run(["id", username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        removed = subprocess.run(["userdel", "-r", username], capture_output=True, text=True)
        if removed.returncode:
            raise RuntimeError(removed.stderr.strip() or "userdel failed; panel record was kept")
    with db_connect() as db:
        db.execute("DELETE FROM users WHERE username=?", (username,))
        db.execute("DELETE FROM connections WHERE username=?", (username,))
        db.execute("DELETE FROM user_traffic WHERE username=?", (username,))


def reset_password(username):
    if not USERNAME_RE.fullmatch(username):
        raise ValueError("Invalid account name")
    with db_connect() as db:
        row = db.execute("SELECT 1 FROM users WHERE username=?", (username,)).fetchone()
    if not row:
        raise ValueError("Panel account not found")
    shell_fix()
    shell_result = subprocess.run(["usermod", "-s", "/bin/false", username], capture_output=True, text=True)
    if shell_result.returncode:
        raise RuntimeError(shell_result.stderr.strip() or "Could not repair account shell")
    password = subprocess.check_output(["openssl", "rand", "-hex", "10"], text=True).strip()
    result = subprocess.run(["chpasswd"], input=f"{username}:{password}\n", text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "Password reset failed")
    with db_connect() as db:
        db.execute("UPDATE users SET password=? WHERE username=?", (password, username))
    started = subprocess.run(["systemctl", "enable", "--now", "dropbear"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
    state = subprocess.run(["passwd", "-S", username], capture_output=True, text=True).stdout.split()
    shell = pwd.getpwnam(username).pw_shell
    ready = not (started.returncode or shell != "/bin/false" or len(state) < 2 or state[1] != "P" or subprocess.run(["systemctl", "is-active", "--quiet", "dropbear"]).returncode)
    return password, ready


def extend_account(username, days):
    row = get_user(username)
    if not row:
        raise ValueError("Panel account not found")
    if subprocess.run(["id", username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        raise RuntimeError("Linux account is missing; no expiry change was made")
    today = datetime.date.today()
    try:
        current = datetime.date.fromisoformat(row["expire_date"])
    except (ValueError, TypeError):
        current = today
    expiry = (max(today, current) + datetime.timedelta(days=days)).isoformat()
    result = subprocess.run(["chage", "-E", expiry, username], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "Could not update Linux account expiry")
    unlock = subprocess.run(["usermod", "-U", username], capture_output=True, text=True)
    if unlock.returncode:
        raise RuntimeError(unlock.stderr.strip() or "Could not unlock Linux account")
    with db_connect() as db:
        db.execute("UPDATE users SET expire_date=?, is_active=1 WHERE username=?", (expiry, username))
    return expiry


def set_bandwidth_limit(username, limit):
    if not get_user(username):
        raise ValueError("Panel account not found")
    with db_connect() as db:
        db.execute("UPDATE users SET bandwidth_limit_gb=? WHERE username=?", (limit, username))


def toggle_account(username):
    row = get_user(username)
    if not row:
        raise ValueError("Panel account not found")
    if row["is_active"]:
        subprocess.run(["pkill", "-u", username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        result = subprocess.run(["usermod", "-L", username], capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stderr.strip() or "Could not lock Linux account")
        with db_connect() as db:
            db.execute("UPDATE users SET is_active=0 WHERE username=?", (username,))
        return False
    if datetime.date.fromisoformat(row["expire_date"]) < datetime.date.today():
        raise ValueError("This account has expired. Extend it before enabling.")
    result = subprocess.run(["usermod", "-U", username], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "Could not unlock Linux account")
    with db_connect() as db:
        db.execute("UPDATE users SET is_active=1 WHERE username=?", (username,))
    return True


def update_worker(chat_id):
    result = subprocess.run([f"{PANEL}/scripts/refresh_banner.sh"], capture_output=True, text=True, timeout=25)
    detail = (result.stdout + result.stderr).strip()
    if result.returncode == 0:
        message = "Worker banner check completed using the URL saved in the panel. The SSH service restarts only if the text changed."
        if detail:
            message += "\n<code>" + esc(detail[-800:]) + "</code>"
        send(chat_id, message)
    else:
        send(chat_id, "Worker check failed; the current banner was kept.\n<code>" + esc(detail[-1000:]) + "</code>")


def run_speedtest(chat_id):
    send(chat_id, "Running a server-side test. It can take up to three minutes and does not measure an individual phone.")
    try:
        result = subprocess.run([f"{PANEL}/scripts/run_speedtest.sh"], capture_output=True, text=True, timeout=190)
        output = (result.stdout + result.stderr).strip()
        label = "Latest server test" if result.returncode == 0 else "Speed test failed"
        send(chat_id, f"<b>{label}</b>\n<code>{esc(output[:2500])}</code>")
    except Exception as exc:
        send(chat_id, "Speed test error: " + esc(exc))


def on_callback(query):
    data = query.get("data", "")
    chat_id = query.get("message", {}).get("chat", {}).get("id")
    sender = query.get("from", {}).get("id")
    if not check_admin(sender) or query.get("message", {}).get("chat", {}).get("type") != "private":
        ack(query["id"], "Private chat with the configured admin only")
        return
    ack(query["id"])
    if data in ("home", "menu"):
        menu(chat_id)
    elif data == "create":
        PROMPTS[sender] = {"step": "username"}
        send(chat_id, "<b>Create account</b>\nSend a username (letters, digits, dot, underscore, hyphen; start with a letter or underscore).\nI will generate a secure password. Use /cancel to stop.")
    elif data == "users":
        render_users(chat_id)
    elif data.startswith("user:"):
        show_user(chat_id, data[5:])
    elif data == "search":
        PROMPTS[sender] = {"step": "search"}
        send(chat_id, "Send the exact username to find, or /cancel.")
    elif data == "delete":
        render_users(chat_id)
    elif data.startswith("del:"):
        username = data[4:]
        send(chat_id, f"<b>Delete <code>{esc(username)}</code>?</b>\nThis stops its sessions and removes its Linux home directory.", [[{"text": "Confirm delete", "callback_data": "confirmdel:" + username}, {"text": "Cancel", "callback_data": "user:" + username}]])
    elif data.startswith("confirmdel:"):
        username = data[len("confirmdel:"):]
        try:
            delete_account(username)
            send(chat_id, f"<code>{esc(username)}</code> was deleted and its sessions were stopped.", [[{"text": "Accounts", "callback_data": "users"}, {"text": "Menu", "callback_data": "home"}]])
        except Exception as exc:
            send(chat_id, "Delete failed: " + esc(exc))
    elif data.startswith("pw:"):
        username = data[3:]
        try:
            password, ready = reset_password(username)
            status = "SSH checks passed" if ready else "Password changed; check Dropbear service"
            send(chat_id, f"<b>{status}</b>\nUsername: <code>{esc(username)}</code>\nPassword: <code>{esc(password)}</code>\nKeep this message private; delete it after copying.", [[{"text": "Account details", "callback_data": "user:" + username}]])
        except Exception as exc:
            send(chat_id, "Password reset failed: " + esc(exc))
    elif data == "reset":
        rows = get_users()
        if not rows:
            send(chat_id, "No accounts to reset.")
        else:
            keyboard = [[{"text": "" + row["username"], "callback_data": "pw:" + row["username"]}] for row in rows[:40]]
            send(chat_id, "Choose an account for a generated-password reset:", keyboard)
    elif data == "extend":
        rows = get_users()
        if not rows:
            send(chat_id, "No accounts to extend.")
        else:
            keyboard = [[{"text": "" + row["username"], "callback_data": "extendu:" + row["username"]}] for row in rows[:40]]
            send(chat_id, "Choose an account to extend:", keyboard)
    elif data.startswith("extendu:"):
        username = data[len("extendu:"):]
        PROMPTS[sender] = {"step": "extend_days", "username": username}
        send(chat_id, f"How many days should <code>{esc(username)}</code> be extended? Days are added to the later of today or its current expiry. Send 1–3650.")
    elif data.startswith("limit:"):
        username = data[len("limit:"):]
        PROMPTS[sender] = {"step": "limit", "username": username}
        send(chat_id, f"Send the stored limit in GB for <code>{esc(username)}</code> (0 = unlimited). Note: this field is not enforced as a hard traffic quota.")
    elif data.startswith("toggle:"):
        username = data[len("toggle:"):]
        send(chat_id, f"Change access state for <code>{esc(username)}</code>?", [[{"text": "Confirm", "callback_data": "confirmtoggle:" + username}, {"text": "Cancel", "callback_data": "user:" + username}]])
    elif data.startswith("confirmtoggle:"):
        username = data[len("confirmtoggle:"):]
        try:
            enabled = toggle_account(username)
            send(chat_id, f"{'Access enabled' if enabled else 'Access disabled'} for <code>{esc(username)}</code>.", [[{"text": "Account details", "callback_data": "user:" + username}]])
        except Exception as exc:
            send(chat_id, "Could not change access: " + esc(exc))
    elif data.startswith("refresh:"):
        username = data[len("refresh:"):]
        force_traffic_sample()
        show_user(chat_id, username)
    elif data == "stats":
        force_traffic_sample()
        send(chat_id, stats_text(), [[{"text": "🔄 Refresh", "callback_data": "stats"}, {"text": "🏠 Menu", "callback_data": "home"}]])
    elif data == "status":
        send(chat_id, server_status_text(), [[{"text": "🔄 Refresh", "callback_data": "status"}, {"text": "🏠 Menu", "callback_data": "home"}]])
    elif data == "expiring":
        show_expiring(chat_id)
    elif data == "worker":
        update_worker(chat_id)
    elif data == "speedtest":
        run_speedtest(chat_id)
    else:
        send(chat_id, "Unknown action. Use /start.")


def handle_command(chat_id, sender, text):
    command = text.split()[0].split("@", 1)[0].lower()
    args = text.split()[1:]
    if command in ("/start", "/menu"):
        menu(chat_id)
    elif command == "/help":
        menu(chat_id)
    elif command == "/create":
        PROMPTS[sender] = {"step": "username"}
        send(chat_id, "<b>Create account</b>\nSend a username. Use /cancel to stop.")
    elif command == "/search":
        if args:
            show_user(chat_id, args[0])
        else:
            PROMPTS[sender] = {"step": "search"}
            send(chat_id, "Send the exact username to find, or /cancel.")
    elif command == "/users":
        render_users(chat_id)
    elif command in ("/stats", "/online"):
        send(chat_id, stats_text())
    elif command == "/status":
        send(chat_id, server_status_text())
    elif command == "/expiring":
        show_expiring(chat_id)
    elif command == "/refresh":
        update_worker(chat_id)
    elif command == "/speedtest":
        run_speedtest(chat_id)
    elif command == "/user" and args:
        show_user(chat_id, args[0])
    elif command == "/password" and args:
        username = args[0]
        try:
            password, ready = reset_password(username)
            status = "SSH checks passed" if ready else "Password changed; check Dropbear service"
            send(chat_id, f"<b>{status}</b>\nUsername: <code>{esc(username)}</code>\nPassword: <code>{esc(password)}</code>\nKeep this message private; delete it after copying.")
        except Exception as exc:
            send(chat_id, "Password reset failed: " + esc(exc))
    elif command == "/delete" and args:
        username = args[0]
        if not USERNAME_RE.fullmatch(username):
            send(chat_id, "Invalid username format.")
        else:
            send(chat_id, f"<b>Delete <code>{esc(username)}</code>?</b> This removes its Linux home directory.", [[{"text": "Confirm", "callback_data": "confirmdel:" + username}, {"text": "Cancel", "callback_data": "user:" + username}]])
    elif command == "/cancel":
        PROMPTS.pop(sender, None)
        send(chat_id, "Action cancelled. Use /start to reopen the menu.")
    else:
        send(chat_id, "Unknown command. Use /start or /help.")


def handle_message(message):
    sender = message.get("from", {}).get("id")
    chat_id = message.get("chat", {}).get("id")
    text = (message.get("text") or "").strip()
    if not check_admin(sender) or message.get("chat", {}).get("type") != "private":
        return
    if text.startswith("/"):
        handle_command(chat_id, sender, text)
        return
    state = PROMPTS.get(sender)
    if not state:
        send(chat_id, "Use /start to open the admin panel.")
        return
    step = state["step"]
    if step == "search":
        PROMPTS.pop(sender, None)
        show_user(chat_id, text)
    elif step == "username":
        if not USERNAME_RE.fullmatch(text):
            send(chat_id, "Invalid name. Try letters, digits, dot, underscore, or hyphen; start with a letter/underscore. Or /cancel.")
            return
        state.update(username=text, step="days")
        send(chat_id, "Account lifetime in days? Enter 1–3650.")
    elif step == "days":
        if not text.isdigit() or not 1 <= int(text) <= 3650:
            send(chat_id, "Enter a whole number from 1 to 3650.")
            return
        state.update(days=int(text), step="devices")
        send(chat_id, "Maximum devices? Enter 1–100.")
    elif step == "devices":
        if not text.isdigit() or not 1 <= int(text) <= 100:
            send(chat_id, "Enter a whole number from 1 to 100.")
            return
        state.update(max_devices=int(text), step="create_limit")
        send(chat_id, "Stored bandwidth limit in GB (0 = unlimited). This is not a hard quota.")
    elif step == "create_limit":
        try:
            limit = float(text)
            if not math.isfinite(limit) or limit < 0 or limit > 100000:
                raise ValueError
        except ValueError:
            send(chat_id, "Enter a non-negative number (0 = unlimited).")
            return
        username, days, max_devices = state["username"], state["days"], state["max_devices"]
        PROMPTS.pop(sender, None)
        try:
            password, expiry, recovered = create_account(username, days, limit, max_devices)
            prefix = "♻️ Recovered and completed an earlier incomplete account.\n" if recovered else ""
            send(chat_id, f"<b>Account ready — SSH checks passed</b>\n{prefix}User: <code>{esc(username)}</code>\nPassword: <code>{esc(password)}</code>\n⏰ Expires: {expiry}\nMax devices: {max_devices}\nStored limit: {limit:g} GB\nShell compatibility, password, and Dropbear were verified.\n\n<i>Keep the password private; delete this message after copying.</i>", [[{"text": "View account", "callback_data": "user:" + username}, {"text": "Main menu", "callback_data": "home"}]])
        except Exception as exc:
            send(chat_id, "<b>Account creation failed</b>\n" + esc(exc) + "\n\nCheck /home mount, free disk/inodes, and account status. You can retry with the same name if an incomplete panel account was detected.")
    elif step == "extend_days":
        if not text.isdigit() or not 1 <= int(text) <= 3650:
            send(chat_id, "Enter whole days from 1 to 3650.")
            return
        username = state["username"]
        PROMPTS.pop(sender, None)
        try:
            expiry = extend_account(username, int(text))
            send(chat_id, f"<code>{esc(username)}</code> extended through <b>{expiry}</b>.", [[{"text": "View account", "callback_data": "user:" + username}]])
        except Exception as exc:
            send(chat_id, "Extension failed: " + esc(exc))
    elif step == "limit":
        try:
            limit = float(text)
            if not math.isfinite(limit) or limit < 0 or limit > 100000:
                raise ValueError
        except ValueError:
            send(chat_id, "Enter a non-negative number (0 = unlimited).")
            return
        username = state["username"]
        PROMPTS.pop(sender, None)
        try:
            set_bandwidth_limit(username, limit)
            send(chat_id, f"Stored limit for <code>{esc(username)}</code> set to <b>{limit:g} GB</b>.", [[{"text": "View account", "callback_data": "user:" + username}]])
        except Exception as exc:
            send(chat_id, "Limit update failed: " + esc(exc))


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "--validate-token-stdin":
        token = sys.stdin.read().strip()
        try:
            print(validate_token(token))
            return 0
        except Exception as exc:
            print(str(exc), file=sys.stderr)
            return 1
    if os.geteuid() != 0:
        print("Telegram bot must run as root", file=sys.stderr)
        return 1
    cfg = read_config()
    token, admin = cfg.get("BOT_TOKEN", ""), cfg.get("ADMIN_ID", "")
    if not token or not admin:
        print("Bot is not configured", file=sys.stderr)
        return 1
    try:
        int(admin)
        info = bot_api("getMe", token=token, timeout=15)
        print(f"PlanAsli bot @{info.get('username', '')} started", flush=True)
    except Exception as exc:
        print(f"Telegram startup failed: {exc}", file=sys.stderr)
        return 1
    offset = 0
    while True:
        try:
            updates = bot_api("getUpdates", {"offset": offset, "timeout": 30, "allowed_updates": json.dumps(["message", "callback_query"])}, token=token, timeout=40)
            for update in updates:
                offset = update["update_id"] + 1
                try:
                    if "callback_query" in update:
                        on_callback(update["callback_query"])
                    elif "message" in update:
                        handle_message(update["message"])
                except Exception as exc:
                    print(f"Update handler error: {exc}", file=sys.stderr, flush=True)
        except KeyboardInterrupt:
            break
        except Exception as exc:
            print(f"Telegram polling error: {exc}", file=sys.stderr, flush=True)
            time.sleep(5)
    return 0


if __name__ == "__main__":
    sys.exit(main())
